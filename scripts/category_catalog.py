"""Persistent category identities; JSON is the committed cross-device export.

Only initial catalog creation reads the public taxonomy. SQLite transactions serialize writers across Python
and Swift; a stale JSON export is hydrated before any edit. Raw ledgers stay intact.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import sqlite3
import tempfile
import unicodedata
import uuid
from pathlib import Path

MAX_BYTES = 8_000_000
PENDING = ("待分类", "待分类")
SCHEMA = """
CREATE TABLE IF NOT EXISTS category_primaries(id TEXT PRIMARY KEY,name TEXT NOT NULL,position INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS category_secondaries(id TEXT PRIMARY KEY,primary_id TEXT NOT NULL REFERENCES category_primaries(id),name TEXT NOT NULL,position INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS category_aliases(primary_name TEXT NOT NULL,secondary_name TEXT NOT NULL,target_id TEXT NOT NULL REFERENCES category_secondaries(id),reassigned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(primary_name,secondary_name));
CREATE TABLE IF NOT EXISTS category_catalog_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload_json TEXT NOT NULL);
"""


def clean(name):
    if not isinstance(name, str):
        raise ValueError("分类名称须为文字")
    value = unicodedata.normalize("NFC", name.strip())
    if not value or len(value) > 40 or value == "全部分类" or any(unicodedata.category(c) == "Cc" for c in value):
        raise ValueError("名称须为1–40字，不能使用全部分类或控制字符")
    return value


def key(name):
    return unicodedata.normalize("NFC", name).lower()


def path_key(primary, secondary):
    return key(primary.strip()), key(secondary.strip())


def stable(prefix, value):
    return prefix + hashlib.sha256(value.encode()).hexdigest()


def seed_taxonomy():
    """New projections use the public defaults, never a private seed file."""
    path = Path(__file__).resolve().parents[1] / "release/default-config.json"
    return json.loads(path.read_text())["defaults"]["taxonomy"]


class Catalog:
    def __init__(self, document):
        self.document = copy.deepcopy(document)
        for alias in self.document.get("aliases", []):
            alias.setdefault("reassigned", False)
        self.validate()
        self._index()

    @classmethod
    def from_taxonomy(cls, taxonomy, records=()):
        document = {"primaries": [], "secondaries": [], "aliases": []}
        parents, leaves = {}, set()

        def add(primary, secondary=None):
            try:
                primary = clean(primary)
                secondary = clean(secondary) if secondary is not None else None
            except ValueError:
                return
            pk = key(primary)
            if pk not in parents:
                parents[pk] = {"id": stable("p-", primary), "name": primary}
                document["primaries"].append(parents[pk])
            p = parents[pk]
            if secondary is not None and (pk, key(secondary)) not in leaves:
                leaf = {"id": stable("s-", p["name"] + "\x1f" + secondary), "primaryID": p["id"], "name": secondary}
                document["secondaries"].append(leaf)
                document["aliases"].append({"primary": p["name"], "secondary": secondary, "targetID": leaf["id"], "reassigned": False})
                leaves.add((pk, key(secondary)))
        if isinstance(taxonomy, dict):
            taxonomy = [{"primary": p, "secondaries": ss} for p, ss in taxonomy.items()]
        for p in taxonomy:
            add(p["primary"])
            for s in p["secondaries"]:
                add(p["primary"], s)
        for record in records:
            for c in record.get("components", []):
                add(c.get("primary"), c.get("secondary"))
        add(*PENDING)
        return cls(document)

    def validate(self):
        d = self.document
        if not all((isinstance(d.get(k), list) for k in ('primaries', 'secondaries', 'aliases'))):
            raise ValueError("分类目录格式不正确")
        if len(d["primaries"]) > 10_000 or len(d["secondaries"]) > 50_000 or len(d["aliases"]) > 100_000:
            raise ValueError("分类目录过大")
        parents, leaves, names, paths, history = {}, {}, set(), set(), {}
        for p in d["primaries"]:
            if not isinstance(p["id"], str) or not p["id"] or p["id"] in parents or clean(p["name"]) != p["name"] or key(p["name"]) in names:
                raise ValueError("一级分类名称或ID重复、不规范")
            parents[p["id"]] = p["name"]
            names.add(key(p["name"]))
        for s in d["secondaries"]:
            k = (s["primaryID"], key(s["name"]))
            if not isinstance(s["id"], str) or not s["id"] or s["id"] in leaves or s["primaryID"] not in parents or clean(s["name"]) != s["name"] or k in paths:
                raise ValueError("二级分类无有效父级、名称或ID重复")
            leaves[s["id"]] = (parents[s["primaryID"]], s["name"])
            paths.add(k)
        if PENDING not in leaves.values():
            raise ValueError("待分类必须保留")
        for a in d["aliases"]:
            k = path_key(a["primary"], a["secondary"])
            if a["targetID"] not in leaves or k in history or clean(a["primary"]) != a["primary"] or clean(a["secondary"]) != a["secondary"] or not isinstance(a["reassigned"], bool):
                raise ValueError("历史路径无效或重复")
            history[k] = a["targetID"]
        for sid, pair in leaves.items():
            if history.get(path_key(*pair), sid) != sid:
                raise ValueError("名称已被历史分类使用")
        return self

    def _index(self):
        parents = {p["id"]: p["name"] for p in self.document["primaries"]}
        self.leaves = {s["id"]: (parents[s["primaryID"]], s["name"]) for s in self.document["secondaries"]}
        self.current = {path_key(*pair): sid for sid, pair in self.leaves.items()}
        self.history = {path_key(a["primary"], a["secondary"]): (a["targetID"], a["reassigned"]) for a in self.document["aliases"]}
        self.pending_id = self.current[PENDING]

    @property
    def taxonomy(self):
        return [{"primary": p["name"], "secondaries": [s["name"] for s in self.document["secondaries"] if s["primaryID"] == p["id"]]} for p in self.document["primaries"]]

    def contains(self, primary, secondary):
        return isinstance(primary, str) and isinstance(secondary, str) and (path_key(primary, secondary) in self.current or path_key(primary, secondary) in self.history)

    def resolve_details(self, primary, secondary):
        k = path_key(primary, secondary)
        if k in self.current:
            sid, reassigned = self.current[k], False
        else:
            sid, reassigned = self.history.get(k, (self.pending_id, True))
        return (*self.leaves[sid], sid, reassigned)

    def resolve(self, primary, secondary):
        return self.resolve_details(primary, secondary)[:2]

    def _edit(self, action):
        d = copy.deepcopy(self.document)
        # Imported catalogs may omit aliases for active paths; capture them before
        # any rename/delete so the first edit preserves their raw history too.
        current_parents = {p["id"]: p["name"] for p in d["primaries"]}
        history = {path_key(a["primary"], a["secondary"]) for a in d["aliases"]}
        for leaf in d["secondaries"]:
            primary = current_parents[leaf["primaryID"]]
            if path_key(primary, leaf["name"]) not in history:
                d["aliases"].append({"primary": primary, "secondary": leaf["name"], "targetID": leaf["id"], "reassigned": False})
        action(d)
        parents = {p["id"]: p["name"] for p in d["primaries"]}
        existing = {path_key(a["primary"], a["secondary"]) for a in d["aliases"]}
        for s in d["secondaries"]:
            if s["primaryID"] not in parents:
                raise ValueError("父级不存在")
            p = parents[s["primaryID"]]
            k = path_key(p, s["name"])
            if k not in existing:
                d["aliases"].append({"primary": p, "secondary": s["name"], "targetID": s["id"], "reassigned": False})
                existing.add(k)
        next_catalog = Catalog(d)
        self.document = next_catalog.document
        self._index()

    def add_primary(self, name):
        pid = str(uuid.uuid4()).upper()
        self._edit(lambda d: d["primaries"].append({"id": pid, "name": clean(name)}))
        return pid

    def add_secondary(self, primary_id, name):
        sid = str(uuid.uuid4()).upper()
        self._edit(lambda d: d["secondaries"].append({"id": sid, "primaryID": primary_id, "name": clean(name)}))
        return sid

    def rename_primary(self, pid, name):
        def action(d):
            p = next((p for p in d["primaries"] if p["id"] == pid), None)
            if not p or p["name"] == PENDING[0]:
                raise ValueError("待分类不可修改，或一级分类不存在")
            p["name"] = clean(name)
        self._edit(action)

    def rename_secondary(self, sid, name, primary_id):
        def action(d):
            s = next((s for s in d["secondaries"] if s["id"] == sid), None)
            if not s or sid == self.pending_id:
                raise ValueError("待分类不可修改，或二级分类不存在")
            s.update(name=clean(name), primaryID=primary_id)
        self._edit(action)

    def delete_secondary(self, sid, replacement_id):
        def action(d):
            if sid == self.pending_id or sid == replacement_id or sid not in self.leaves or replacement_id not in self.leaves:
                raise ValueError("删除或迁移目标不正确")
            for a in d["aliases"]:
                if a["targetID"] == sid:
                    a.update(targetID=replacement_id, reassigned=True)
            d["secondaries"] = [s for s in d["secondaries"] if s["id"] != sid]
        self._edit(action)

    def delete_primary(self, pid, replacement_id):
        def action(d):
            p = next((p for p in d["primaries"] if p["id"] == pid), None)
            target = next((s for s in d["secondaries"] if s["id"] == replacement_id), None)
            if not p or p["name"] == PENDING[0] or not target or target["primaryID"] == pid:
                raise ValueError("待分类不可删除；迁移目标须属于其他一级分类")
            ids = {s["id"] for s in d["secondaries"] if s["primaryID"] == pid}
            for a in d["aliases"]:
                if a["targetID"] in ids:
                    a.update(targetID=replacement_id, reassigned=True)
            d["secondaries"] = [s for s in d["secondaries"] if s["primaryID"] != pid]
            d["primaries"] = [p for p in d["primaries"] if p["id"] != pid]
        self._edit(action)

    def applying(self, component):
        p, s, _, reassigned = self.resolve_details(component["primary"], component["secondary"])
        component.update(primary=p, secondary=s)
        confirmation = component.get("completion_confirmation")
        if reassigned:
            component.pop("completion_confirmation", None)
        elif confirmation:
            draft = confirmation["draft"]
            dp, ds, _, redirect = self.resolve_details(draft["primary"], draft["secondary"])
            if redirect:
                component.pop("completion_confirmation", None)
            else:
                draft.update(primary=dp, secondary=ds)
        return component


def _encode(catalog):
    catalog.validate()
    data = json.dumps(catalog.document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    if len(data) > MAX_BYTES:
        raise ValueError("分类目录过大")
    return data


def _transport(root):
    path = root / "category-catalog.json"
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError("分类目录文件不安全或过大")
    return path.read_bytes()


def _atomic(path, data):
    descriptor, staged = tempfile.mkstemp(prefix=".category-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


def _database(root):
    db = sqlite3.connect(root / "financial-review.sqlite3", timeout=5)
    try:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(SCHEMA)
    except BaseException:
        db.close()
        raise
    return db


def _read(db):
    row = db.execute("SELECT payload_json FROM category_catalog_state WHERE singleton=1").fetchone()
    if row is None:
        return None
    if len(row[0].encode()) > MAX_BYTES:
        raise ValueError("数据库分类目录过大")
    return Catalog(json.loads(row[0]))


def _persist(db, catalog, data):
    db.execute("DELETE FROM category_aliases")
    db.execute("DELETE FROM category_secondaries")
    db.execute("DELETE FROM category_primaries")
    db.executemany("INSERT INTO category_primaries VALUES(?,?,?)", [(p["id"], p["name"], i) for i, p in enumerate(catalog.document["primaries"])])
    db.executemany("INSERT INTO category_secondaries VALUES(?,?,?,?)", [(s["id"], s["primaryID"], s["name"], i) for i, s in enumerate(catalog.document["secondaries"])])
    db.executemany("INSERT INTO category_aliases VALUES(?,?,?,?)", [(a["primary"], a["secondary"], a["targetID"], int(a["reassigned"])) for a in catalog.document["aliases"]])
    db.execute("INSERT INTO category_catalog_state VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET payload_json=excluded.payload_json", (data.decode(),))


def load(root, taxonomy=(), records=()):
    root = Path(root)
    db = _database(root)
    wrote = False
    try:
        db.execute("BEGIN IMMEDIATE")
        original = _transport(root)
        previous = _read(db)
        selected = Catalog(json.loads(original)) if original is not None else previous or Catalog.from_taxonomy(taxonomy, records)
        if previous is None or selected.document != previous.document:
            _persist(db, selected, _encode(selected))
        if original is None:
            _atomic(root / "category-catalog.json", _encode(selected)); wrote = True
        db.commit()
        return selected
    except BaseException:
        db.rollback()
        if wrote:
            (root / "category-catalog.json").unlink()
        raise
    finally:
        db.close()


def save(catalog, root, expected):
    root = Path(root)
    data = _encode(catalog)
    db = _database(root)
    wrote = False
    original = None
    try:
        db.execute("BEGIN IMMEDIATE")
        original = _transport(root)
        current = Catalog(json.loads(original)) if original is not None else _read(db)
        expected = expected.document if isinstance(expected, Catalog) else Catalog(expected).document
        if current is None or current.document != expected:
            raise ValueError("分类已在其他入口更新，请刷新分类后重试")
        _persist(db, catalog, data)
        _atomic(root / "category-catalog.json", data); wrote = True
        db.commit()
    except BaseException:
        db.rollback()
        if wrote:
            if original is None:
                (root / "category-catalog.json").unlink()
            else:
                _atomic(root / "category-catalog.json", original)
        raise
    finally:
        db.close()
