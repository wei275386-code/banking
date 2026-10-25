"""Spending purpose stays in two-level categories; context lives in many tags."""
from __future__ import annotations

import html
import re
import unicodedata


def normalized(value):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", html.unescape(value or ""))).strip()


def clean_tags(values):
    def tag(value):
        return re.sub(r"\s+", " ", unicodedata.normalize("NFC", value)).strip()
    return sorted({tag(t) for t in values if isinstance(t, str) and tag(t)})


def merchant_key(value):
    text = normalized(value)
    text = re.sub(r"\s*订单详情$", "", text)
    return text.split(" · ", 1)[0].strip()


def merchant_is_complete(value):
    return not re.search(r"\*{2,}|\.{3}|…", normalized(value))


def confirmed_rule(text, rules):
    text = normalized(text)
    # Rules learnt from explicit confirmations retain the merchant/branch scope.
    for rule in sorted(rules, key=lambda r: len(r["merchant"]), reverse=True):
        merchant = normalized(rule["merchant"])
        if not merchant_is_complete(merchant): continue
        if text == merchant or text.startswith(merchant + " · ") or text.startswith(merchant + " 订单详情") or text.startswith(merchant + " | "):
            return rule
    return None


def purpose_category(primary, secondary, text="", *, policy=None):
    """Migrate old context categories without losing purpose or assuming a trip."""
    text = normalized(text)
    if policy is not None:
        matches = policy.matching("purpose", text=text, primary=primary, secondary=secondary)
        if matches:
            return matches[0]["primary"], matches[0]["secondary"]
    if secondary == "外卖餐饮":
        return primary, "餐饮"
    if secondary == "礼物首饰":
        return primary, "首饰配饰"
    if secondary == "人情请客":
        return "日常消费", "住宿" if "住宿请客" in text else "餐饮"
    if primary == "旅行" and secondary == "交通住宿":
        if re.search(r"铁路|火车票|12306|站[-–].*站|机票|AIRLINES", text, re.I):
            return "日常消费", "交通出行"
        # Generic booking/airline abbreviations still lack a specific purpose.
        # Their previous broader category is preserved until order details arrive.
    return primary, secondary


def inferred_tags(text, *, secondary=None, existing_category=None, platform=None, rules=(), policy=None):
    text = normalized(text)
    found = {}

    def add(tag, basis="商户或商品明示"):
        found[tag] = basis

    for pattern, tag in [(r"PINDUODUO|拼多多", "拼多多"), (r"JINGDONG|京东", "京东"),
                         (r"TAOBAO MERCHANT|淘宝订单|天猫", "淘宝"), (r"小红书", "小红书")]:
        if re.search(pattern, text, re.I):
            add(tag)
            if secondary in ("网购", "购物"): add("网购", "购物平台明示")
    if platform == "meituan" or re.search(r"MEITUAN|美团", text, re.I): add("美团")
    if re.search(r"淘宝闪购|ELEME|饿了么", text, re.I): add("淘宝闪购/饿了么")
    if re.search(r"外卖|宅急送", text): add("外卖")
    if re.search(r"代金券|次卡|套餐券", text): add("代金券/次卡")
    if re.search(r"7\W?ELEVEN|SEVEN.?ELEVEN|ELEVEN 7|711便利|赛壹便利|ローソン|罗森|美宜佳|便利店|松鼠便利", text, re.I): add("便利店")
    if re.search(r"ローソン|罗森", text): add("罗森")
    if re.search(r"7\W?ELEVEN|SEVEN.?ELEVEN|ELEVEN 7|711便利|赛壹便利", text, re.I): add("7-Eleven")
    if re.search(r"美宜佳", text): add("美宜佳")
    if re.search(r"铁路|火车票|12306|\bTL CHN CN\b|站[-–].*站", text, re.I): add("铁路")
    if re.search(r"高铁|动车", text): add("高铁/动车")
    if re.search(r"骑行|单车", text): add("骑行")
    if secondary == "交通出行" and re.search(r"地铁|港鐵|\bMTR\b", text, re.I): add("地铁")
    if existing_category == "请客" or secondary == "人情请客" or "请客" in text: add("请客", "已有用途确认")
    if re.search(r"生日礼物", text): add("生日礼物", "用户确认用途")
    if secondary == "礼物首饰" or re.search(r"首饰|CARTIER", text, re.I): add("首饰")
    # Trip context is supplied only by explicit user rules or per-record tags.
    if policy is not None:
        for effect in policy.matching("tags", text=text, secondary=secondary, existing_category=existing_category, platform=platform):
            for tag in effect["tags"]:
                add(tag, effect.get("basis", "家庭规则"))
    rule = confirmed_rule(text, rules)
    if rule:
        for tag in rule.get("tags", []): add(tag, "已确认商户规则")
    return clean_tags(found), found


def annotate(primary, secondary, text, *, existing_category=None, platform=None, rules=(), override=None, policy=None):
    override = override or {}
    old_secondary = secondary
    purpose = text + " " + override.get("purpose", "")
    tags, bases = inferred_tags(purpose, secondary=old_secondary, existing_category=existing_category, platform=platform, rules=rules, policy=policy)
    primary, secondary = purpose_category(primary, secondary, purpose, policy=policy)
    # An explicit list is a complete human tag set, including the empty list.
    # This allows removing an inferred tag and prevents reappearance on import.
    if "tags" in override:
        tags = clean_tags(override["tags"])
        bases = {tag: override.get("tag_basis", {}).get(tag, "人工标签") for tag in tags}
    return primary, secondary, tags, bases


class InferencePolicy:
    """Private rule data; no Python code or filesystem access.

    Ordered category/purpose rules use first match. Every matching tag rule adds
    context. Explicit merchant confirmations and per-record edits remain higher
    priority. An absent policy means a new household uses public defaults.
    """
    def __init__(self, document=None):
        self.groups = {phase: [] for phase in ('category', 'purpose', 'tags', 'title')}
        if document is None:
            return
        if not isinstance(document, dict) or set(document) != {'rules'}:
            raise ValueError('Unsupported inference policy')
        if not isinstance(document['rules'], list) or len(document['rules']) > 1000:
            raise ValueError('Invalid inference rule list')
        identities = set()
        for rule in document['rules']:
            if not isinstance(rule, dict) or set(rule) != {'id', 'phase', 'when', 'effect'}:
                raise ValueError('Invalid inference rule')
            identity, phase = rule['id'], rule['phase']
            if not isinstance(identity, str) or not identity or identity in identities or phase not in self.groups:
                raise ValueError('Invalid inference rule identity or phase')
            identities.add(identity)
            self._validate_condition(rule['when'])
            effect = rule['effect']
            required = {'primary', 'secondary'} if phase in ('category', 'purpose') else {'tags'} if phase == 'tags' else {'prefix'}
            if not isinstance(effect, dict) or not required <= set(effect) or set(effect) - required - {'basis'}:
                raise ValueError('Invalid inference rule effect')
            for key, value in effect.items():
                if key == 'tags':
                    if not isinstance(value, list) or not value or not all(isinstance(t, str) and t.strip() for t in value):
                        raise ValueError('Invalid inference tags')
                elif not isinstance(value, str) or not value.strip():
                    raise ValueError('Invalid inference effect value')
            self.groups[phase].append(rule)

    @classmethod
    def _validate_condition(cls, condition, depth=0):
        if not isinstance(condition, dict) or depth > 8:
            raise ValueError('Invalid inference condition')
        if set(condition) in ({'all'}, {'any'}):
            children = next(iter(condition.values()))
            if not isinstance(children, list) or not children or len(children) > 100:
                raise ValueError('Invalid compound inference condition')
            for child in children:
                cls._validate_condition(child, depth + 1)
            return
        if set(condition) not in ({'field', 'equals'}, {'field', 'pattern'}):
            raise ValueError('Invalid inference predicate')
        if condition['field'] not in {'text', 'category_text', 'existing_category', 'primary', 'secondary', 'platform', 'source_kind'}:
            raise ValueError('Unsupported inference field')
        value = condition.get('equals', condition.get('pattern'))
        if not isinstance(value, str) or not value or len(value) > 4096:
            raise ValueError('Invalid inference predicate value')
        if 'pattern' in condition:
            try:
                re.compile(value, re.I)
            except re.error as error:
                raise ValueError("Invalid inference regex") from error

    @classmethod
    def _matches(cls, condition, context):
        if 'all' in condition:
            return all(cls._matches(c, context) for c in condition['all'])
        if 'any' in condition:
            return any(cls._matches(c, context) for c in condition['any'])
        value = context.get(condition['field']) or ''
        return value == condition['equals'] if 'equals' in condition else bool(re.search(condition['pattern'], value, re.I))

    def matching(self, phase, **context):
        return [rule['effect'] for rule in self.groups[phase] if self._matches(rule['when'], context)]
