"""Current JSON contracts, lossless encoding and processing invariants."""
from __future__ import annotations

import copy
import hashlib
import json
import math
import re
import uuid
from datetime import date, datetime
from decimal import Decimal
from functools import lru_cache
from pathlib import Path, PurePosixPath

SCHEMA_ROOT = Path(__file__).resolve().parents[1] / "schemas" / "release"


class ContractError(ValueError):
    """A malformed or unproven contract; never permission to rewrite data."""


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(raw: bytes | str):
    try:
        return json.loads(raw, object_pairs_hook=_pairs, parse_float=Decimal,
                          parse_constant=lambda value: (_ for _ in ()).throw(
                              ContractError(f"non-finite JSON number: {value}")))
    except (ValueError, UnicodeError) as error:
        raise ContractError(f"invalid JSON: {error}") from error


def _decimal_token(value: Decimal) -> str:
    if not value.is_finite():
        raise ContractError("non-finite canonical JSON number")
    sign, digits, exponent = value.as_tuple()
    digits = list(digits)
    if not any(digits):
        return "-0.0" if sign else "0.0"
    while len(digits) > 1 and digits[-1] == 0:
        digits.pop(); exponent += 1
    coefficient = "".join(str(digit) for digit in digits)
    position = len(coefficient) + exponent
    prefix = "-" if sign else ""
    # Bounded scientific notation avoids allocation proportional to exponent.
    if position > 21 or position <= -6:
        mantissa = coefficient[0] + "." + (coefficient[1:] or "0")
        return prefix + mantissa + "e" + str(position - 1)
    if position <= 0:
        return prefix + "0." + "0" * -position + coefficient
    if position >= len(coefficient):
        return prefix + coefficient + "0" * (position - len(coefficient)) + ".0"
    return prefix + coefficient[:position] + "." + coefficient[position:]


def canonical_json(value) -> bytes:
    """Frozen scalar-key UTF-8 codec; preserves integer/decimal kind and -0.0.

    parse_json uses Decimal for decimal/exponent tokens, avoiding binary64 loss.
    Strings and array order remain untouched. This is not RFC 8785/Foundation.
    """
    def encode(child):
        if child is None: return "null"
        if type(child) is bool: return "true" if child else "false"
        if type(child) is int: return str(child)
        if isinstance(child, Decimal): return _decimal_token(child)
        if type(child) is float:
            if not math.isfinite(child): raise ContractError("non-finite JSON number")
            return _decimal_token(Decimal(repr(child)))
        if isinstance(child, str):
            return json.dumps(child, ensure_ascii=False, separators=(",", ":"))
        if isinstance(child, list):
            return "[" + ",".join(encode(item) for item in child) + "]"
        if isinstance(child, dict):
            if not all(isinstance(key, str) for key in child):
                raise ContractError("canonical JSON keys must be strings")
            return "{" + ",".join(encode(key) + ":" + encode(child[key]) for key in sorted(child)) + "}"
        raise ContractError("unsupported canonical JSON value")
    try:
        return encode(value).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise ContractError(f"not canonical JSON: {error}") from error


def digest_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def digest_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Hash materials with bounded memory; never read a whole video into RAM."""
    if chunk_size < 1:
        raise ContractError("chunk_size must be positive")
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_uuid(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError) as error:
        raise ContractError("invalid UUID") from error


@lru_cache(maxsize=None)
def _schema(name):
    path = SCHEMA_ROOT / name
    return parse_json(path.read_bytes())


class SchemaDefinitionError(ContractError):
    """Unsupported/malformed schemas are never an anyOf value mismatch."""


_SCHEMA_KEYWORDS = {"$schema", "$id", "$defs", "$ref", "title", "description", "type", "required",
                    "properties", "additionalProperties", "anyOf", "const", "enum", "format", "pattern",
                    "minimum", "uniqueItems", "minLength", "maxLength", "minItems", "maxItems",
                    "minProperties", "maxProperties", "propertyNames", "items"}


def _schema_reference(reference, filename, loader):
    if not isinstance(reference, str):
        raise SchemaDefinitionError("schema ref must be a string")
    file, _, pointer = reference.partition("#")
    target_file = file or filename
    if (not target_file or "/" in target_file or "\\" in target_file or ".." in target_file
            or (pointer and not pointer.startswith("/"))):
        raise SchemaDefinitionError("schema ref must remain in release schema directory")
    try:
        target = loader(target_file)
        for part in pointer[1:].split("/") if pointer else []:
            if re.search(r"~(?![01])", part):
                raise SchemaDefinitionError("invalid JSON Pointer escape")
            target = target[part.replace("~1", "/").replace("~0", "~")]
    except (KeyError, TypeError, IndexError, OSError) as error:
        raise SchemaDefinitionError("schema ref cannot be resolved") from error
    return target, target_file, (target_file, pointer)


def _check_schema_graph(schema, filename, loader):
    # Inspect every schema position before seeing input values, including unused
    # branches/definitions. Bound traversal and reject recursive references; the
    # supported release schemas describe finite documents, not recursive types.
    work = 0
    def visit(node, file, depth, references):
        nonlocal work
        work += 1
        if depth > 64 or work > 10000:
            raise SchemaDefinitionError("schema graph exceeds resource limit")
        if not isinstance(node, dict) or set(node) - _SCHEMA_KEYWORDS:
            raise SchemaDefinitionError("unsupported schema keyword")
        if "type" in node:
            kinds = node["type"] if isinstance(node["type"], list) else [node["type"]]
            if not kinds or any(not isinstance(k, str) or k not in
                                {"object", "array", "string", "integer", "number", "boolean", "null"} for k in kinds):
                raise SchemaDefinitionError("unsupported schema type")
        for key in ("minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"):
            if key in node and (type(node[key]) is not int or node[key] < 0):
                raise SchemaDefinitionError("invalid schema bound")
        if "format" in node and node["format"] not in ("uuid", "date", "date-time"):
            raise SchemaDefinitionError("unsupported schema format")
        if "pattern" in node:
            try:
                re.compile(node["pattern"])
            except (TypeError, re.error) as error:
                raise SchemaDefinitionError("invalid schema pattern") from error
        for key in ("properties", "$defs"):
            if key in node:
                if not isinstance(node[key], dict) or any(not isinstance(k, str) for k in node[key]):
                    raise SchemaDefinitionError("invalid schema map")
                for child in node[key].values():
                    visit(child, file, depth + 1, references)
        for key in ("items", "propertyNames"):
            if key in node:
                visit(node[key], file, depth + 1, references)
        if "additionalProperties" in node and type(node["additionalProperties"]) is not bool:
            visit(node["additionalProperties"], file, depth + 1, references)
        if "anyOf" in node:
            if not isinstance(node["anyOf"], list) or not node["anyOf"]:
                raise SchemaDefinitionError("invalid schema alternatives")
            for child in node["anyOf"]:
                visit(child, file, depth + 1, references)
        if "$ref" in node:
            target, target_file, identity = _schema_reference(node["$ref"], file, loader)
            if identity in references:
                raise SchemaDefinitionError("recursive schema reference")
            visit(target, target_file, depth + 1, references | {identity})
    visit(schema, filename, 0, {(filename, "")})


def _validate(schema, value, path, filename, schema_loader=None):
    loader = schema_loader or _schema
    _check_schema_graph(schema, filename, loader)
    _validate_value(schema, value, path, filename, loader)


def _validate_value(schema, value, path, filename, schema_loader):
    if not isinstance(schema, dict) or set(schema) - _SCHEMA_KEYWORDS:
        raise SchemaDefinitionError(f"{path}: unsupported schema keyword")
    loader = schema_loader
    if "$ref" in schema:
        target, target_file, _ = _schema_reference(schema["$ref"], filename, loader)
        _validate_value(target, value, path, target_file, schema_loader)
    if "anyOf" in schema:
        for variant in schema["anyOf"]:
            try:
                _validate_value(variant, value, path, filename, schema_loader)
                break
            except SchemaDefinitionError:
                raise
            except ContractError:
                pass
        else:
            raise ContractError(f"{path}: no schema alternative matches")
    types = schema.get("type")
    if types:
        types = [types] if isinstance(types, str) else types
        matches = {"object": isinstance(value, dict), "array": isinstance(value, list),
                   "string": isinstance(value, str), "integer": type(value) is int,
                   "number": (type(value) in (int, float) and (type(value) is int or math.isfinite(value))) or (isinstance(value, Decimal) and value.is_finite()),
                   "boolean": type(value) is bool, "null": value is None}
        if not any(matches.get(kind, False) for kind in types):
            raise ContractError(f"{path}: expected {types}")
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise ContractError(f"{path}: wrong constant")
    if "enum" in schema and not any(type(value) is type(item) and value == item for item in schema["enum"]):
        raise ContractError(f"{path}: unsupported value")
    if isinstance(value, dict):
        for required in schema.get("required", []):
            if required not in value:
                raise ContractError(f"{path}: missing {required}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, child in value.items():
            if not isinstance(key, str):
                raise ContractError(f"{path}: JSON key must be string")
            if "propertyNames" in schema:
                _validate_value(schema["propertyNames"], key, f"{path}/@key", filename, schema_loader)
            if key in properties:
                _validate_value(properties[key], child, f"{path}/{key}", filename, schema_loader)
            elif additional is False:
                raise ContractError(f"{path}: unexpected {key}")
            elif isinstance(additional, dict):
                _validate_value(additional, child, f"{path}/{key}", filename, schema_loader)
        if len(value) < schema.get("minProperties", 0):
            raise ContractError(f"{path}: too few properties")
        if "maxProperties" in schema and len(value) > schema["maxProperties"]:
            raise ContractError(f"{path}: too many properties")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise ContractError(f"{path}: too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ContractError(f"{path}: too many items")
        if schema.get("uniqueItems") and len({canonical_json(item) for item in value}) != len(value):
            raise ContractError(f"{path}: duplicate item")
        for index, child in enumerate(value):
            _validate_value(schema.get("items", {}), child, f"{path}/{index}", filename, schema_loader)
    if isinstance(value, str):
        if (len(value) < schema.get("minLength", 0)
                or ("maxLength" in schema and len(value) > schema["maxLength"])
                or ("pattern" in schema and not re.search(schema["pattern"], value))):
            raise ContractError(f"{path}: invalid string")
        format = schema.get("format")
        try:
            if format == "uuid" and normalized_uuid(value) != value:
                raise ValueError("UUID must be lowercase canonical")
            if format == "date" and (len(value) != 10 or date.fromisoformat(value).isoformat() != value):
                raise ValueError("invalid ISO date")
            if format == "date-time":
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
                    raise ValueError("expected timezone-qualified RFC3339")
                datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise ContractError(f"{path}: {error}") from error
    if (type(value) in (int, float) or isinstance(value, Decimal)) and "minimum" in schema and value < schema["minimum"]:
        raise ContractError(f"{path}: below minimum")


def validate_contract(name: str, document: dict, *, schema_loader=None) -> dict:
    """Validate schema and cross-field invariants, returning the unchanged input.

    Optional schema_loader(filename) returns a parsed schema dictionary, including
    for all local $refs. Release tools can read pinned commit blobs without
    executing code from that commit or mixing in mutable working-tree schemas.
    """
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        raise ContractError("invalid schema name")
    filename = name + ".schema.json"
    _validate((schema_loader or _schema)(filename), document, "$", filename, schema_loader)
    _invariants(name, document)
    return document


def _range_pair(document, first, last):
    start, end = document[first], document[last]
    if (start is None) != (end is None) or (start is not None and start > end):
        raise ContractError(f"invalid range {first}/{last}")


def _invariants(name, d):
    if name == "coverage":
        basis_kind = d["basis"]["kind"]
        allowed = {"empty": ["no-reliable-dates"], "automatic": ["reliable-observations"],
                   "explicit": ["user-confirmed"]}
        if basis_kind not in allowed[d["mode"]]:
            raise ContractError("coverage basis does not match mode")
        for start, end in [("from", "to"), ("observed_from", "observed_to"), ("pending_from", "pending_to")]:
            _range_pair(d, start, end)
        if d["mode"] == "empty" and any(d[key] is not None for key in ("from", "to", "observed_from", "observed_to", "pending_from", "pending_to")):
            raise ContractError("empty coverage cannot have dates")
        if d["mode"] != "empty" and d["from"] is None:
            raise ContractError("active coverage needs a range")
        if d["mode"] != "explicit" and d["pending_from"] is not None:
            raise ContractError("only explicit coverage has pending suggestions")
        if d["mode"] == "automatic" and d["observed_from"] is not None and (d["from"] > d["observed_from"] or d["to"] < d["observed_to"]):
            raise ContractError("automatic range must include observed range")
    if name == "revision":
        if d["id"] in (d.get("parents") or []):
            raise ContractError("revision cannot parent itself")
    if name == "revision-origin":
        if d["revision_id"] in d["parents"]:
            raise ContractError("origin cannot parent itself")
    if name == "revision-inventory":
        entries = d["entries"]
        identities = set()
        for entry in entries:
            _invariants("revision-origin", entry)
            identity = (entry["source_binding_id"], entry["revision_id"])
            if identity in identities:
                raise ContractError("duplicate revision identity in inventory")
            identities.add(identity)
        # Membership declares the complete causal closure, including conflict heads.
        by_revision = {}
        for identity in identities:
            by_revision.setdefault(identity[1], []).append(identity)
        edges = {}
        for entry in entries:
            identity = (entry["source_binding_id"], entry["revision_id"])
            edges[identity] = []
            for parent_id in entry["parents"]:
                candidates = by_revision.get(parent_id, [])
                if len(candidates) != 1:
                    raise ContractError("inventory ancestor missing or ambiguous across bindings")
                edges[identity].append(candidates[0])
        pending = [(identity, False) for identity in edges]
        visiting, done = set(), set()
        while pending:
            identity, exiting = pending.pop()
            if exiting:
                visiting.discard(identity); done.add(identity)
            elif identity not in done:
                if identity in visiting:
                    raise ContractError("cyclic revision ancestry")
                visiting.add(identity)
                pending.append((identity, True))
                pending.extend((parent, False) for parent in edges[identity])
    if name == "state-manifest":
        parent = d.get("parent_pointer")
        if parent is not None:
            validate_contract("active-state", parent)
            if (parent["workspace_id"] != d["workspace_id"] or
                    parent["state_id"] == d["state_id"] or
                    parent["local_revision"] + 1 != d["local_revision"]):
                raise ContractError("state manifest parent must be the exact preceding workspace revision")
        for path in d["files"]:
            validate_relative_path(path)
    if name == "family-snapshot":
        if d["sequence"] == 1 and d["parent_generation"] is not None:
            raise ContractError("sequence one cannot have a published ancestor")
    if name in ("operation", "result"):
        phase, outcome = d["phase"], d["outcome"]
        if phase != "published" and d["result_generation"] is not None:
            raise ContractError("unpublished operation cannot name cloud result generation")
        if phase == "published" and d["result_generation"] is None:
            raise ContractError("published operation requires source cloud generation")
        if name == "result" and phase == "published":
            raise ContractError("publication belongs in receipt, not immutable result ledger")
        if phase in ("committed", "published"):
            if outcome not in ("success", "partial") or not d.get("state_id") or not d.get("result_digest"):
                raise ContractError("committed result requires state and success/partial digest")
        elif outcome in ("success", "partial"):
            raise ContractError("uncommitted operation cannot claim a business result")
        if phase == "failed" and outcome != "failed":
            raise ContractError("failed phase requires failed outcome")
        if phase == "cancelled" and outcome != "cancelled":
            raise ContractError("cancelled phase requires cancelled outcome")
        if phase == "needsReview" and outcome != "unknown":
            raise ContractError("needsReview requires unknown outcome")
        if phase in ("queued", "processing", "prepared") and outcome is not None:
            raise ContractError("in-progress outcome must be null")
        ids = [item["input_id"] for item in d["inputs"]]
        if len(ids) != len(set(ids)):
            raise ContractError("duplicate input identity")
        if outcome in ("success", "partial"):
            pending = [item for item in d["inputs"] if item["outcome"] != "success"]
            if outcome == "success" and pending:
                raise ContractError("success requires all inputs complete")
            if outcome == "partial" and not pending:
                raise ContractError("partial requires pending extraction")
            for item in pending:
                if item["kind"] != "video" or item["required_financial"] or item["outcome"] != "pending" or item.get("reason") not in ("unsupported_video_layout", "unconfirmed_video_fields"):
                    raise ContractError("partial is limited to saved pending video extraction")
        if name == "result" and phase in ("committed", "published"):
            if not d["membership"]:
                raise ContractError("committed result needs effect membership")
            if d["result_digest"] != business_result_digest(d):
                raise ContractError("business result digest mismatch")
            effect_keys = [item["key"] for item in d["membership"]]
            if len(effect_keys) != len(set(effect_keys)):
                raise ContractError("duplicate effect membership")
    if name == "request-results":
        requests, operations = set(), set()
        for result in d["results"]:
            validate_contract("result", result)
            if result["phase"] != "committed":
                raise ContractError("result ledger must retain committed business membership")
            if result["request_id"] in requests or result["operation_id"] in operations:
                raise ContractError("duplicate result ledger identity")
            requests.add(result["request_id"]); operations.add(result["operation_id"])


def business_result_digest(result: dict) -> str:
    """Digest a business result without its own digest or publication identity.

    phase is lifecycle metadata. Everything else (including unknown metadata,
    inputs, effects, IDs and recovery attempt) remains part of the digest.
    """
    return digest_bytes(canonical_json({key: value for key, value in result.items()
                                      if key not in ("result_digest", "result_generation", "phase")}))


def validate_relative_path(path: str) -> str:
    if not isinstance(path, str) or not path or "\\" in path or "\x00" in path or ":" in path:
        raise ContractError("unsafe relative path")
    parsed = PurePosixPath(path)
    if parsed.is_absolute() or any(part in ("", ".", "..") for part in path.split("/")):
        raise ContractError("unsafe relative path")
    return path


def stable_input_stage_key(request_id: str, input_id: str, stage: str) -> str:
    """Unambiguous stable subtask key; no delimiter concatenation collisions."""
    if not all(isinstance(value, str) and value for value in (request_id, input_id, stage)):
        raise ContractError("subtask identity fields must be nonempty strings")
    return digest_bytes(canonical_json([request_id, input_id, stage]))


def evolve_coverage(previous: dict, reliable_dates: list[str]) -> dict:
    """Compute coverage from the complete current set of reliable observations.

    Callers supply only parsed unambiguous official/bank dates or saved human
    confirmations, excluding revoked confirmations. This cannot infer dates
    from filenames, mtime, videos or the system clock. Changes belong in the
    same staging commit as the corresponding processor state.
    """
    validate_contract("coverage", previous)
    for value in reliable_dates:
        _validate(_schema("common.schema.json")["$defs"]["date"], value,
                  "$/reliable_dates", "common.schema.json")
    current = copy.deepcopy(previous)
    observed_from = min(reliable_dates) if reliable_dates else None
    observed_to = max(reliable_dates) if reliable_dates else None
    current.update(observed_from=observed_from, observed_to=observed_to)
    if current["mode"] == "empty" and observed_from is not None:
        current.update(mode="automatic", **{"from": observed_from, "to": observed_to})
        current["basis"]["kind"] = "reliable-observations"
    elif current["mode"] == "automatic" and observed_from is not None:
        current["from"] = min(current["from"], observed_from)
        current["to"] = max(current["to"], observed_to)
    elif current["mode"] == "explicit":
        outside = observed_from is not None and (observed_from < current["from"] or observed_to > current["to"])
        current["pending_from"] = min(current["from"], observed_from) if outside else None
        current["pending_to"] = max(current["to"], observed_to) if outside else None
    if current != previous:
        current["revision"] += 1
    return validate_contract("coverage", current)


def validate_operation_transition(previous: dict, updated: dict) -> None:
    """Enforce journal lifecycle without undoing a committed operation.

    This is a contract check, not a durable journal writer or permission to retry
    ambiguous unfinished work. Recovery confirmation remains a coordinator action.
    """
    validate_contract("operation", previous)
    validate_contract("operation", updated)
    for key in ("workspace_id", "operation_id", "request_id", "input_hash", "algorithm_version"):
        if previous[key] != updated[key]:
            raise ContractError("operation identity/input/version cannot change across transition")
    transitions = {
        "queued": {"queued", "processing", "cancelled", "failed", "needsReview"},
        "processing": {"processing", "prepared", "cancelled", "failed", "needsReview"},
        "prepared": {"prepared", "committed", "cancelled", "failed"},
        "committed": {"committed", "published"}, "published": {"published"},
        "cancelled": {"cancelled", "queued"}, "failed": {"failed", "queued"},
        "needsReview": {"needsReview", "queued"},
    }
    if updated["phase"] not in transitions[previous["phase"]]:
        raise ContractError("illegal operation phase transition")
    input_identity = lambda document: [(item["input_id"], item["sha256"], item["kind"], item["required_financial"])
                                      for item in document["inputs"]]
    if input_identity(previous) != input_identity(updated):
        raise ContractError("operation input membership cannot change across transition")
    if previous["phase"] in ("committed", "published"):
        for key in ("state_id", "outcome", "result_digest", "inputs"):
            if previous[key] != updated[key]:
                raise ContractError("committed business result cannot change during publication")
        if previous["phase"] == "published" and previous["result_generation"] != updated["result_generation"]:
            raise ContractError("published receipt generation cannot be retargeted")


def validate_active_state(pointer: dict, manifest: dict) -> None:
    """Verify pointer tuple against a staged immutable manifest, not only state ID.

    The caller must additionally verify every referenced file's actual bytes and
    hold the fixed workspace maintenance gate before switching the pointer.
    """
    validate_contract("active-state", pointer)
    validate_contract("state-manifest", manifest)
    if any(pointer[key] != manifest[key] for key in ("workspace_id", "state_id", "local_revision")):
        raise ContractError("active state pointer tuple mismatch")
    if pointer["state_manifest_hash"] != digest_bytes(canonical_json(manifest)):
        raise ContractError("active state manifest digest mismatch")
