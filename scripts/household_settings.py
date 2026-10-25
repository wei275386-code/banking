"""Household settings qualification and scoped processor funding projection.

No configuration is inferred from the current operator, filenames or card tails.
State persistence, causal operations and decision application remain separate
owners. Processor row projections below do not confer a host or client role.
"""
from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata

if __package__:
    from .release_contracts import ContractError, canonical_json, parse_json, validate_contract
else:
    from release_contracts import ContractError, canonical_json, parse_json, validate_contract


_WHITESPACE = ''.join(chr(n) for n in [*range(9, 14), 32, 133, 160, 5760,
                                     *range(8192, 8203), 8232, 8233, 8239, 8287, 12288])
_LABELS = {'source_account_name', 'payment_channel'}
_SELECTOR_KEYS = {'platform', 'source_id', 'source_account_id', *_LABELS}
_FUNDING_KEYS = {'source_account_id', *_LABELS}
_MAX_DOCUMENT = 16 * 1024 * 1024


def _label(value):
    return unicodedata.normalize('NFC', value.strip(_WHITESPACE))


def _text(value, maximum=256, *, allow_empty=False):
    if not isinstance(value, str) or len(value) > maximum or (not allow_empty and not value.strip(_WHITESPACE)):
        raise ContractError('invalid settings text')
    try:
        value.encode('utf-8')
    except UnicodeError:
        raise ContractError('invalid settings Unicode') from None
    return value


@dataclass(frozen=True)
class SettingsContext:
    registered_source_ids: tuple[str, ...]
    currency_codes: tuple[str, ...]
    referenced_member_ids: tuple[str, ...]
    referenced_account_ids: tuple[str, ...]


@dataclass(frozen=True)
class FamilyMember:
    id: str
    display_name: str
    status: str


@dataclass(frozen=True)
class FundingAccount:
    id: str
    display_name: str
    owner_member_id: str | None
    currency: str
    status: str


@dataclass(frozen=True)
class FundingRule:
    id: str
    selector: tuple[tuple[str, str], ...]
    target_account_id: str | None
    confirmed: bool
    basis: str


@dataclass(frozen=True)
class FundingResolution:
    status: str
    account_id: str | None
    matched_rule_ids: tuple[str, ...]
    candidate_account_ids: tuple[str, ...]
    reason: str


@dataclass(frozen=True)
class HouseholdSettings:
    profile_bytes: bytes
    policies_bytes: bytes
    household_name: str
    members: tuple[FamilyMember, ...]
    accounts: tuple[FundingAccount, ...]
    routes: tuple[FundingRule, ...]
    aliases: tuple[FundingRule, ...]
    source_owners: tuple[tuple[str, str], ...]
    exclusion_member_ids: tuple[str, ...]

    def resolve_funding(self, funding: dict) -> FundingResolution:
        if not isinstance(funding, dict) or not set(funding) <= _SELECTOR_KEYS:
            raise ContractError('invalid funding input fields')
        values = {}
        for key, value in funding.items():
            if value is None:
                continue
            _text(value, 4096 if key in _LABELS else 256, allow_empty=True)
            values[key] = _label(value) if key in _LABELS else value
        if not values.get('platform') or not any(values.get(key) for key in _FUNDING_KEYS):
            return FundingResolution('needs_review', None, (), (), 'missing_funding_input')
        for tier, rules in (('route', self.routes), ('alias', self.aliases)):
            matched = [rule for rule in rules if rule.confirmed and all(
                values.get(key) and values[key] == value for key, value in rule.selector)]
            if not matched:
                continue
            ids = tuple(sorted(rule.id for rule in matched))
            targets = {rule.target_account_id for rule in matched}
            candidates = tuple(sorted(value for value in targets if value is not None))
            if len(targets) != 1:
                return FundingResolution('needs_review', None, ids, candidates, 'conflicting_rules')
            target = next(iter(targets))
            if target is None:
                return FundingResolution('non_funding', None, ids, (), 'non_funding_channel')
            account = next(account for account in self.accounts if account.id == target)
            if account.status != 'active':
                return FundingResolution('needs_review', None, ids, candidates, 'inactive_account')
            return FundingResolution('resolved', target, ids, candidates, 'matched_' + tier)
        return FundingResolution('needs_review', None, (), (), 'unmatched')


def validate_settings(profile, policies, *, context: SettingsContext) -> HouseholdSettings:
    """Qualify a pair against explicit authoritative source/currency/history sets.

    Currency codes must be supplied by product capabilities, not guessed by this
    validator. Callers must supply all current and retained historical references.
    A returned value owns immutable snapshots, never the caller's mutable dicts.
    """
    if not isinstance(context, SettingsContext):
        raise ContractError('settings validation context required')
    def context_values(values, maximum):
        if not isinstance(values, (tuple, list)) or len(values) > maximum:
            raise ContractError('invalid settings context collection')
        return tuple(_text(value) for value in values)
    sources = context_values(context.registered_source_ids, 100000)
    currencies = context_values(context.currency_codes, 1000)
    if len(set(sources)) != len(sources) or not currencies or len(set(currencies)) != len(currencies):
        raise ContractError('invalid settings context')
    if any(not isinstance(code, str) or not re.fullmatch('[A-Z]{3}', code) for code in currencies):
        raise ContractError('invalid currency context')
    source_ids = set(sources)
    required_members = set(context_values(context.referenced_member_ids, 100000))
    required_accounts = set(context_values(context.referenced_account_ids, 100000))
    validate_contract('family-profile', profile)
    validate_contract('account-policies', policies)
    profile_raw, policies_raw = canonical_json(profile), canonical_json(policies)
    if max(len(profile_raw), len(policies_raw)) > _MAX_DOCUMENT:
        raise ContractError('settings document too large')
    # Validate the same immutable snapshot used to construct the result.
    profile, policies = parse_json(profile_raw), parse_json(policies_raw)
    validate_contract('family-profile', profile)
    validate_contract('account-policies', policies)
    household = _text(profile['household_name'], allow_empty=True)
    members = tuple(FamilyMember(_text(row['id']), _text(row['display_name']), row['status']) for row in profile['members'])
    member_ids = {member.id for member in members}
    if len(member_ids) != len(members) or not required_members <= member_ids:
        raise ContractError('duplicate or missing referenced member')
    accounts = tuple(FundingAccount(_text(row['id']), _text(row['display_name'], 4096),
        row['owner_member_id'], row['currency'], row['status']) for row in policies['accounts'])
    account_ids = {account.id for account in accounts}
    if len(account_ids) != len(accounts) or not required_accounts <= account_ids:
        raise ContractError('duplicate or missing referenced account')
    for account in accounts:
        if account.owner_member_id is not None and account.owner_member_id not in member_ids:
            raise ContractError('dangling account owner')
        if account.currency not in currencies:
            raise ContractError('unsupported account currency')
    owners = tuple(policies['source_owners'].items())
    if any(_text(source) not in source_ids or owner not in member_ids for source, owner in owners):
        raise ContractError('dangling source owner')
    exclusions = tuple(policies['unknown_account_policy']['exclusion_member_ids'])
    if any(member not in member_ids for member in exclusions):
        raise ContractError('dangling exclusion permission')
    all_rule_ids = set()
    def rules(kind):
        result, seen = [], {}
        for row in policies[kind]:
            identity = _text(row['id'])
            if identity in all_rule_ids:
                raise ContractError('duplicate funding rule ID')
            all_rule_ids.add(identity)
            selector = tuple(sorted((key, _label(_text(value, 4096)) if key in _LABELS else _text(value))
                                    for key, value in row['source_selector'].items()))
            source = row['source_selector'].get('source_id')
            if source is not None and source not in source_ids:
                raise ContractError('dangling rule source')
            target = row['target_account_id']
            if target is not None and target not in account_ids:
                raise ContractError('dangling funding target')
            if selector in seen and seen[selector] != target:
                raise ContractError('identical selectors with conflicting targets')
            seen[selector] = target
            result.append(FundingRule(identity, selector, target, row['confirmed'], _text(row['basis'], 4096)))
        return tuple(result)
    routes, aliases = rules('routes'), rules('aliases')
    return HouseholdSettings(profile_raw, policies_raw, household, members, accounts, routes, aliases, owners, exclusions)


def decode_settings(profile_raw: bytes | str, policies_raw: bytes | str, *, context: SettingsContext) -> HouseholdSettings:
    for raw in (profile_raw, policies_raw):
        if not isinstance(raw, (bytes, str)):
            raise ContractError('settings JSON bytes required')
        try:
            size = len(raw.encode('utf-8')) if isinstance(raw, str) else len(raw)
        except UnicodeError:
            raise ContractError('invalid settings Unicode') from None
        if size > _MAX_DOCUMENT:
            raise ContractError('settings document too large')
    return validate_settings(parse_json(profile_raw), parse_json(policies_raw), context=context)


def load_processor_settings(root, *, read_bytes=None, referenced_member_ids=(), referenced_account_ids=()):
    """Read the actual processor input root; not a role or state qualification.

    The transaction owner supplies immutable staging. Currency capabilities and
    stable source IDs are explicit registry metadata, never inferred from tails
    or the current operator. Roots without either settings file stay
    unconfigured; a partial pair fails rather than silently selecting defaults.
    """
    from pathlib import Path
    root = Path(root)
    def disk(name):
        path = root / name
        if not path.exists(): return None
        if path.is_symlink() or not path.is_file() or path.stat().st_size > _MAX_DOCUMENT:
            raise ContractError('unsafe settings input')
        return path.read_bytes()
    read = read_bytes or disk
    profile, policies = read('config/family-profile.json'), read('config/account-policies.json')
    if profile is None and policies is None: return None, {}
    if profile is None or policies is None: raise ContractError('incomplete household settings pair')
    registry_raw = read('config/review-import-sources.json')
    if registry_raw is None: raise ContractError('settings source registry missing')
    registry = parse_json(registry_raw)
    pass
    sources, currencies = registry.get('sources'), registry.get('currency_codes')
    if not isinstance(sources, list) or not isinstance(currencies, list):
        raise ContractError('settings require stable source IDs and explicit currency capabilities')
    if not currencies or any(code != 'CNY' for code in currencies):
        raise ContractError('this processor supports CNY projections only; no implicit currency conversion')
    if __package__:
        from .release_contracts import validate_relative_path
    else:
        from release_contracts import validate_relative_path
    by_id, paths = {}, set()
    for row in sources:
        if not isinstance(row, dict): raise ContractError('invalid settings source')
        identity = _text(row.get('id')); path = validate_relative_path(_text(row.get('path'), 4096)); _text(row.get('platform'))
        if path in paths: raise ContractError('duplicate retained settings source path')
        paths.add(path)
        digest = row.get('sha256')
        if not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None or identity in by_id:
            raise ContractError('duplicate or unpinned settings source')
        by_id[identity] = row
    settings = decode_settings(profile, policies, context=SettingsContext(tuple(by_id), tuple(currencies),
        tuple(referenced_member_ids), tuple(referenced_account_ids)))
    return settings, by_id


def project_funding(rows, bank, settings, sources):
    """Resolve real parsed evidence using the qualified, two-tier matcher.

    Recompute every funding tag. A stored tag is not allowed to bypass current
    configuration. Source ownership needs an exact retained source hash; account
    ownership is never treated as the consumer of an individual transaction.
    """
    from dataclasses import asdict
    by_hash = {}
    for identity, source in sources.items(): by_hash.setdefault(source['sha256'], []).append(identity)
    owners = dict(settings.source_owners) if settings else {}
    accounts = {a.id: a for a in settings.accounts} if settings else {}
    for row, platform in [(r, r.get('platform')) for r in rows] + [(r, 'bank') for r in bank]:
        for key in ('funding_account_id', 'funding_account_name', 'funding_resolution'):
            row.pop(key, None)
        if settings is None:
            row['funding_resolution'] = {'status': 'needs_review', 'account_id': None, 'matched_rule_ids': [], 'candidate_account_ids': [], 'reason': 'settings_not_configured'}
            continue
        digest = row.get('file_sha256') or row.get('statement_sha256')
        source_id = row.get('source_id')
        if source_id not in sources or sources[source_id]['sha256'] != digest:
            choices = by_hash.get(digest, [])
            source_id = choices[0] if len(choices) == 1 else None
        if source_id in owners:
            row.update(owner_id=owners[source_id], profile_identity_verified=True,
                       ownership_basis='explicit household source owner', source_id=source_id)
        funding = {'platform': platform, 'source_id': source_id,
                   'source_account_id': row.get('account_number') if platform == 'bank' else row.get('source_account_id'),
                   'source_account_name': row.get('payment_method'), 'payment_channel': row.get('payment_channel')}
        resolution = settings.resolve_funding(funding)
        value = asdict(resolution)
        account = accounts.get(resolution.account_id)
        if account and resolution.status == 'resolved' and row.get('currency') == account.currency:
            row.update(funding_account_id=account.id, funding_account_name=account.display_name)
        elif account and resolution.status == 'resolved':
            value.update(status='needs_review', account_id=None, reason='currency_mismatch')
        row['funding_resolution'] = value


def project_household_records(records, settings, rows, banks, *, protected_ids=(), originals=()):
    """Project names/funding/exclusion capability without rewriting raw identity."""
    members = {m.id: m.display_name for m in settings.members} if settings else {}
    allowed = set(settings.exclusion_member_ids) if settings else set()
    evidence = {**rows, **banks}
    protected = set(protected_ids)
    previous = {r['id']: r for r in originals}
    for record in records:
        if record['id'] in protected: continue
        identity = record.get('user_id')
        if settings is None:
            record.setdefault('user_display_name', identity or '未确认')
            record.setdefault('review_exclusion_allowed', False)
            continue
        record['user_display_name'] = members.get(identity, identity or '未确认')
        record['review_exclusion_allowed'] = bool(identity and identity in allowed)
        # Preserve identity-only normalization against unchanged retained facts.
        # A changed consumer/evidence/event cannot borrow an older confirmation.
        import copy
        old = previous.get(record['id'])
        baseline = old if old and all(old.get(k) == record.get(k) for k in
            ('user_id', 'user_relation', 'events', 'evidence_keys')) else record
        if 'account_identity_before_consolidation' not in record:
            record['account_identity_before_consolidation'] = copy.deepcopy(
                baseline.get('account_identity_before_consolidation') or {k: baseline.get(k) for k in
                    ('user_id', 'user_relation', 'payment_accounts', 'payment_account_status', 'account_views')})
        accounts = {evidence[k]['funding_account_id']: evidence[k]['funding_account_name']
                    for k in record['evidence_keys'] if k in evidence and evidence[k].get('funding_account_id')}
        record['funding_account_ids'] = sorted(accounts)
        record['payment_accounts'] = sorted(set(accounts.values()))
        record['account_views'] = record['payment_accounts']
        record['payment_account_status'] = 'identified' if accounts else 'unresolved'
