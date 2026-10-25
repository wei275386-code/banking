"""Read committed settings and prepare pointer-pinned edits, without writing.

This boundary checks state membership and explicit source IDs. It is not a family
activation, processor grant, complete historical-reference extractor or commit.
Future writers must revalidate under their maintenance gate and use full-tuple CAS.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
import stat
from pathlib import Path

from scripts.household_settings import HouseholdSettings, SettingsContext, decode_settings, _text
from scripts.release_contracts import ContractError, digest_bytes, parse_json, validate_relative_path
from scripts.settings_snapshot import _hash
from scripts.workspace_state import WorkspacePaths, StateConflict, _regular

PROFILE = 'config/family-profile.json'
POLICIES = 'config/account-policies.json'
REGISTRY = 'config/review-import-sources.json'
_LIMIT = 16 * 1024 * 1024


def _read(path):
    fd = os.open(_regular(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > _LIMIT:
            raise ContractError('settings state regular bounded JSON required')
        raw = stream.read(_LIMIT + 1)
    if len(raw) > _LIMIT:
        raise ContractError('settings state JSON budget')
    return raw


def _object(raw):
    try:
        value = parse_json(raw)
    except RecursionError:
        raise ContractError('settings state JSON depth budget') from None
    if not isinstance(value, dict):
        raise ContractError('settings state JSON object required')
    pending = [(value, 0)]
    while pending:
        child, depth = pending.pop()
        if depth > 128:
            raise ContractError('settings state JSON depth budget')
        children = child.values() if isinstance(child, dict) else child if isinstance(child, list) else ()
        pending.extend((item, depth + 1) for item in children)
    return value


def _list(values):
    if not isinstance(values, (list, tuple)):
        raise ContractError('explicit settings context arrays required')
    return tuple(values)


def _sources(raw, files):
    registry = _object(raw)
    if not isinstance(registry, dict):
        raise ContractError('settings source registry version')
    sources = registry.get('sources')
    if not isinstance(sources, list) or len(sources) > 100000:
        raise ContractError('settings source registry collection')
    ids, paths, dependencies = [], set(), []
    for row in sources:
        if not isinstance(row, dict):
            raise ContractError('source registry row')
        identity, path, platform = row.get('id'), row.get('path'), row.get('platform')
        _text(identity); _text(platform); _text(path, maximum=4096)
        validate_relative_path(path)
        hash_value = _hash(row.get('sha256'))
        if path in paths or files.get(path) != hash_value:
            raise ContractError('duplicate or unretained registry source path')
        paths.add(path); ids.append(identity); dependencies.append((path, hash_value))
    if len(set(ids)) != len(ids):
        raise ContractError('duplicate source identity')
    return tuple(ids), dependencies


@dataclass(frozen=True)
class HouseholdSettingsState:
    workspace: Path
    pointer: tuple[str, str, int, str]
    settings: HouseholdSettings
    context: SettingsContext
    dependencies: tuple[tuple[str, str], ...]

    def prepare_edit(self, profile_raw: bytes, policies_raw: bytes) -> HouseholdSettingsEditPlan:
        # IDs are tombstoned by deactivation, never dropped from a retained
        # settings baseline. Additional historical refs remain explicit inputs.
        context = SettingsContext(self.context.registered_source_ids, self.context.currency_codes,
            tuple(set(self.context.referenced_member_ids) | {member.id for member in self.settings.members}),
            tuple(set(self.context.referenced_account_ids) | {account.id for account in self.settings.accounts}))
        candidate = decode_settings(profile_raw, policies_raw, context=context)
        return HouseholdSettingsEditPlan(self, candidate)


@dataclass(frozen=True)
class HouseholdSettingsEditPlan:
    baseline: HouseholdSettingsState
    candidate: HouseholdSettings

    def revalidate(self, paths: WorkspacePaths) -> HouseholdSettings:
        if paths.workspace != self.baseline.workspace:
            raise StateConflict('settings plan belongs to another workspace location')
        context = self.baseline.context
        current = read_settings_state(paths, currency_codes=context.currency_codes,
            referenced_member_ids=context.referenced_member_ids, referenced_account_ids=context.referenced_account_ids)
        if current.pointer != self.baseline.pointer or current.dependencies != self.baseline.dependencies:
            raise StateConflict('settings plan baseline changed')
        # This is a read-only check, not an atomic write grant. The real writer
        # must hold its gate across revalidation, staging and pointer CAS.
        return current.prepare_edit(self.candidate.profile_bytes, self.candidate.policies_bytes).candidate


def read_settings_state(paths: WorkspacePaths, *, currency_codes, referenced_member_ids, referenced_account_ids) -> HouseholdSettingsState:
    state = paths.resolve_active(verify_files=True)
    manifest_raw = _read(state.path('state-manifest.json'))
    if digest_bytes(manifest_raw) != state.state_manifest_hash:
        raise StateConflict('settings manifest changed while reading')
    files = _object(manifest_raw)['files']
    def pinned(path):
        if path not in files:
            raise ContractError('settings dependency absent from committed state: ' + path)
        raw = _read(state.path(path))
        if digest_bytes(raw) != _hash(files[path]):
            raise StateConflict('settings dependency changed while reading')
        return raw
    profile_raw, policies_raw, registry_raw = pinned(PROFILE), pinned(POLICIES), pinned(REGISTRY)
    source_ids, dependencies = _sources(registry_raw, files)
    context = SettingsContext(source_ids, _list(currency_codes), _list(referenced_member_ids), _list(referenced_account_ids))
    settings = decode_settings(profile_raw, policies_raw, context=context)
    # Committed settings have one byte representation; a reader never repairs it.
    if settings.profile_bytes != profile_raw or settings.policies_bytes != policies_raw:
        raise ContractError('committed settings must be canonical')
    dependencies += [(path, files[path]) for path in (PROFILE, POLICIES, REGISTRY)]
    pointer = (state.workspace_id, state.state_id, state.local_revision, state.state_manifest_hash)
    return HouseholdSettingsState(paths.workspace, pointer, settings, context, tuple(sorted(dependencies)))
