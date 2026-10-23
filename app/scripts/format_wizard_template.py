#!/usr/bin/env python3
"""Раскладка app/assets/wizard_template.json по docs/TEMPLATE.md → «Formatting style».

Запуск: python3 -I app/scripts/format_wizard_template.py [путь]
(без аргумента — шаблон приложения рядом со скриптом).

Форматтер не меняет семантику: порядок ключей и элементов сохраняется,
а перед записью результат разбирается заново и сравнивается с исходными
данными (с порядком ключей). При расхождении файл не пишется, код выхода 1.

Язык шаблона: канонические `#and`/`#or`/`#not`/`#value`/`#else` и старое
написание без решётки (`and`/`or`/`value`/`else`), короткий `#if: [cond, V, E]`,
`#if <метка>` как ключ map-spread, `#tpl`, `#do`, `#filter`, `for_each_node*`.
Конструкцию, которую форматтер не понимает, он пишет одной строкой
(`compact`) и сообщает путь до узла в stderr.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable

INDENT = "  "
WIDTH = 120

COND_KEYS = {"#and", "#or", "#not", "and", "or"}
VALUE_KEYS = {"#value", "value"}
ELSE_KEYS = {"#else", "else"}
# `#`-ключи, которые форматтер знает (остальное — предупреждение + compact).
KNOWN_HASH_KEYS = {
    "#if", "#and", "#or", "#not", "#value", "#else", "#eq", "#in", "#notIn",
    "#matches", "#tpl", "#do", "#filter", "#append", "#final", "#enable",
    "#on_change", "#set",
}

Lines = list[str]  # первая строка без отступа, остальные — с абсолютным отступом
Handler = Callable[[Any, int, str], Lines]

warnings: list[str] = []


def warn(path: str, msg: str) -> None:
    warnings.append(f"WARNING: {path}: {msg}")


def compact(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(", ", ": "))


def key(k: str) -> str:
    return json.dumps(k, ensure_ascii=False) + ": "


def pad(level: int) -> str:
    return INDENT * level


def is_scalar(v: Any) -> bool:
    return not isinstance(v, (dict, list))


def is_if_key(k: str) -> bool:
    return k == "#if" or k.startswith("#if ")


def unknown_hash_key(d: dict[str, Any]) -> str | None:
    for k in d:
        if k.startswith("#") and not is_if_key(k) and k not in KNOWN_HASH_KEYS:
            return k
    return None


def has_block(v: Any) -> bool:
    """Есть ли внутри конструкция, ради которой узел разворачивается (`#if`, `#do`)."""
    if isinstance(v, dict):
        return any(is_if_key(k) or k == "#do" or has_block(x) for k, x in v.items())
    if isinstance(v, list):
        return any(has_block(x) for x in v)
    return False


def is_flat(d: dict[str, Any]) -> bool:
    """Объект из литералов и списков литералов — одна строка при любой длине."""
    return all(is_scalar(x) or (isinstance(x, list) and all(is_scalar(y) for y in x)) for x in d.values())


def scalar_like(v: Any) -> bool:
    """Ветка `#if`, которая пишется в одну строку: не объект или `{"#op": …}`."""
    if has_block(v):
        return False
    if isinstance(v, dict):
        return len(v) == 1 and next(iter(v)).startswith("#")
    return True


def with_prefix(prefix: str, sub: Lines) -> Lines:
    return [prefix + sub[0]] + sub[1:]


def join_items(items: list[Lines], level: int) -> Lines:
    """Элементы по строке на каждый (уровень level), запятые между ними."""
    out: Lines = []
    for i, sub in enumerate(items):
        sub = with_prefix(pad(level), sub)
        if i < len(items) - 1:
            sub[-1] += ","
        out.extend(sub)
    return out


def flow(open_: str, items: list[tuple[str, Lines]], close: str) -> Lines:
    """Элементы подряд через «, »; многострочный элемент продолжает строку."""
    lines = [open_]
    for i, (prefix, sub) in enumerate(items):
        lines[-1] += ("" if i == 0 else ", ") + prefix + sub[0]
        lines.extend(sub[1:])
    lines[-1] += close
    return lines


# ---------------------------------------------------------------- generic


def fmt(v: Any, level: int, path: str, *, used: int = 0, wide: bool = False) -> Lines:
    try:
        return _fmt(v, level, path, used=used, wide=wide)
    except Exception as e:  # noqa: BLE001 — форматтер не падает на незнакомом узле
        warn(path, f"cannot lay out ({type(e).__name__}: {e}), written compact")
        return [compact(v)]


def _fmt(v: Any, level: int, path: str, *, used: int, wide: bool) -> Lines:
    if is_scalar(v) or not v:
        return [compact(v)]
    if isinstance(v, dict):
        bad = unknown_hash_key(v)
        if bad is not None:
            warn(path, f"unknown construct {bad!r}, written compact")
            return [compact(v)]
        if list(v) == ["#if"]:
            return if_element(v["#if"], level, path + ".#if")
        if not has_block(v) and (wide or is_flat(v) or used + len(compact(v)) <= WIDTH):
            return [compact(v)]
        return expanded_obj(v, level, path)
    # list
    if not has_block(v) and (wide or all(is_scalar(x) for x in v) or used + len(compact(v)) <= WIDTH):
        return [compact(v)]
    items = [fmt(x, level + 1, f"{path}[{i}]", used=len(pad(level + 1)), wide=wide) for i, x in enumerate(v)]
    return ["["] + join_items(items, level + 1) + [pad(level) + "]"]


def expanded_obj(d: dict[str, Any], level: int, path: str,
                 handlers: dict[str, Handler] | None = None,
                 default: Handler | None = None) -> Lines:
    """Объект по полю на строку; handlers — особая раскладка отдельных ключей."""
    if not d:
        return ["{}"]
    items: list[Lines] = []
    for k, v in d.items():
        p = f"{path}.{k}"
        kp = key(k)
        if handlers and k in handlers:
            sub = handlers[k](v, level + 1, p)
        elif is_if_key(k):
            sub = if_payload(v, level + 1, p)
        elif k == "#do" and isinstance(v, dict):
            sub = expanded_obj(v, level + 1, p)
        elif k in ("#filter", "#enable", "#tpl") or k in COND_KEYS:
            sub = [compact(v)]
        elif default is not None:
            sub = default(v, level + 1, p)
        else:
            sub = fmt(v, level + 1, p, used=len(pad(level + 1)) + len(kp))
        items.append(with_prefix(kp, sub))
    return ["{"] + join_items(items, level + 1) + [pad(level) + "}"]


# ---------------------------------------------------------------- #if


def branch(v: Any, level: int, path: str) -> Lines:
    """Ветка `#value`/`#else` или V/E короткой формы: объект — всегда развёрнут."""
    if scalar_like(v):
        return [compact(v)]
    if isinstance(v, dict):
        return expanded_obj(v, level, path)
    return fmt(v, level, path)


def if_payload(x: Any, level: int, path: str) -> Lines:
    """Значение ключа `#if` (длинная форма — объект, короткая — список)."""
    if isinstance(x, dict):
        bad = [k for k in x if k not in COND_KEYS | VALUE_KEYS | ELSE_KEYS]
        if bad:
            warn(path, f"unknown key(s) {bad} in #if, written compact")
            return [compact(x)]
        if all(scalar_like(v) for k, v in x.items() if k not in COND_KEYS):
            return [compact(x)]
        items = [
            (key(k), [compact(v)] if k in COND_KEYS else branch(v, level, f"{path}.{k}"))
            for k, v in x.items()
        ]
        return flow("{", items, "}")
    if isinstance(x, list) and len(x) in (2, 3):
        if all(scalar_like(v) for v in x[1:]):
            return [compact(x)]
        items = [("", [compact(x[0])])] + [
            ("", branch(v, level, f"{path}[{i + 1}]")) for i, v in enumerate(x[1:])
        ]
        return flow("[", items, "]")
    warn(path, "unrecognised #if shape, written compact")
    return [compact(x)]


def if_element(x: Any, level: int, path: str) -> Lines:
    """`{"#if": …}` — элемент массива или значение поля."""
    return flow('{"#if": ', [("", if_payload(x, level, path))], "}")


# ---------------------------------------------------------------- vars

SIMPLE_VAR_KEYS = {"name", "type", "default_value", "title", "tooltip", "wizard_ui", "required"}
VAR_BLOCK_KEYS = {"options", "#on_change", "on_change"}


def is_simple_var(v: dict[str, Any]) -> bool:
    return "ref" in v or set(v) <= SIMPLE_VAR_KEYS


def var_block(k: str, v: Any, level: int, path: str) -> Lines:
    if k == "options" and isinstance(v, list):
        if all(isinstance(o, str) for o in v) or not v:
            return [compact(v)]
        return ["["] + join_items([[compact(o)] for o in v], level + 1) + [pad(level) + "]"]
    if k in ("#on_change", "on_change") and isinstance(v, dict) and len(v) == 1:
        (sk, sv), = v.items()
        if sk in ("#set", "set") and isinstance(sv, dict) and sv:
            items = [with_prefix(key(n), fmt(x, level + 1, f"{path}.{sk}.{n}", wide=True)) for n, x in sv.items()]
            return ["{" + key(sk) + "{"] + join_items(items, level + 1) + [pad(level) + "}}"]
    return fmt(v, level, path, used=len(pad(level)) + len(key(k)))


def fmt_var(v: Any, level: int, path: str) -> Lines:
    """Заголовок (name/type/…/tooltip) — строка 1; default_value, options,
    #on_change — с новой строки. Порядок ключей не меняется."""
    if not isinstance(v, dict) or is_simple_var(v):
        return fmt(v, level, path, wide=True)
    lines = ["{ "]
    fresh, inline = True, True
    items = list(v.items())
    for i, (k, val) in enumerate(items):
        comma = "," if i < len(items) - 1 else ""
        kp = key(k)
        if k in VAR_BLOCK_KEYS or not is_scalar(val):
            sub = var_block(k, val, level + 1, f"{path}.{k}")
            if fresh:
                lines[-1] += kp + sub[0]
            else:
                lines.append(pad(level + 1) + kp + sub[0])
            lines.extend(sub[1:])
            inline = False
        elif k == "default_value" or not inline:
            text = kp + compact(val)
            if fresh:
                lines[-1] += text
            else:
                lines.append(pad(level + 1) + text)
            inline = True
        else:
            lines[-1] += ("" if fresh else " ") + kp + compact(val)
        lines[-1] += comma
        fresh = False
    lines.append(pad(level) + "}")
    return lines


# ---------------------------------------------------------------- presets


def fmt_rule_set(rs: Any, level: int, path: str) -> Lines:
    """Строка 1 — метаданные (tag/type/format/…), дальше `url` или `rules`."""
    if not isinstance(rs, dict) or has_block(rs):
        return fmt(rs, level, path, wide=True)
    ks = list(rs)
    split = next((i for i, k in enumerate(ks) if k in ("url", "rules")), None)
    if split is None:
        return [compact(rs)]
    head, body, tail = ks[:split], ks[split], ks[split + 1:]
    lines = ["{ " + ", ".join(key(k) + compact(rs[k]) for k in head) + "," if head else "{"]
    v = rs[body]
    if body == "rules" and isinstance(v, list) and v:
        items = [fmt(r, level + 2, f"{path}.rules[{i}]", wide=True) for i, r in enumerate(v)]
        sub = ["["] + join_items(items, level + 2) + [pad(level + 1) + "]"]
    else:
        sub = [compact(v)]
    lines.extend(with_prefix(pad(level + 1) + key(body), sub))
    if tail:
        lines[-1] += ","
        lines.append(pad(level + 1) + ", ".join(key(k) + compact(rs[k]) for k in tail))
    lines.append(pad(level) + "}")
    return lines


# ---------------------------------------------------------------- handlers


def wide(v: Any, level: int, path: str) -> Lines:
    return fmt(v, level, path, wide=True)


def per_line(elem: Handler) -> Handler:
    def h(v: Any, level: int, path: str) -> Lines:
        if not isinstance(v, list):
            return wide(v, level, path)
        if not v:
            return ["[]"]
        items = [elem(x, level + 1, f"{path}[{i}]") for i, x in enumerate(v)]
        return ["["] + join_items(items, level + 1) + [pad(level) + "]"]
    return h


def obj(handlers: dict[str, Handler] | None = None, default: Handler | None = None) -> Handler:
    def h(v: Any, level: int, path: str) -> Lines:
        if not isinstance(v, dict):
            return fmt(v, level, path)
        return expanded_obj(v, level, path, handlers, default)
    return h


def rules(v: Any, level: int, path: str) -> Lines:
    return per_line(wide)(v, level, path) if isinstance(v, list) else wide(v, level, path)


VARS = per_line(fmt_var)

PRESET = {
    "ui": wide,
    "vars": VARS,
    "rule_set": per_line(fmt_rule_set),
    "rule": rules,
    "rules": rules,
    "dns_rule": rules,
    "dns_rules": rules,
    "dns_servers": rules,
    "for_each_node": wide,
    "for_each_node_do": wide,
}

TOP: dict[str, Handler] = {
    "parser_config": obj(),
    "dns_options": obj({"servers": per_line(obj({"vars": VARS, "server": wide}))}),
    "ping_options": obj({"presets": per_line(wide)}),
    "speed_test_options": obj({"servers": per_line(wide)}),
    "group_templates": obj({
        "magic_nodes": obj(default=wide),
        "direction": obj({"options": obj()}),
        "auto": obj({"options": obj()}),
    }),
    "default_directions": per_line(wide),
    "sections": per_line(obj({"vars": VARS})),
    "config": obj({
        "log": obj(),
        "dns": obj(),
        "inbounds": per_line(wide),
        "endpoints": per_line(wide),
        "outbounds": per_line(wide),
        "route": obj(),
        "experimental": obj({"cache_file": obj()}),
        "services": per_line(wide),
    }),
    "selectable_rules": per_line(obj(PRESET)),
}


def format_template(data: Any) -> str:
    if not isinstance(data, dict):
        return compact(data)
    return "\n".join(expanded_obj(data, 0, "$", TOP))


# ---------------------------------------------------------------- invariant


def first_diff(a: Any, b: Any, path: str = "$") -> str | None:
    """Путь до первого расхождения (типы, значения, порядок ключей) или None."""
    if type(a) is not type(b):
        return f"{path}: type {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, dict):
        ka, kb = list(a), list(b)
        for i in range(max(len(ka), len(kb))):
            x = ka[i] if i < len(ka) else None
            y = kb[i] if i < len(kb) else None
            if x != y:
                return f"{path}: key #{i} {x!r} != {y!r}"
        for k in ka:
            d = first_diff(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: length {len(a)} != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    return None if a == b else f"{path}: {a!r} != {b!r}"


def main() -> None:
    path = Path(__file__).resolve().parents[1] / "assets" / "wizard_template.json"
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    original = json.loads(source)
    formatted = format_template(original) + "\n"
    try:
        reparsed = json.loads(formatted)
    except json.JSONDecodeError as e:
        print(f"ERROR: formatter produced invalid JSON ({e}); {path} not written", file=sys.stderr)
        sys.exit(1)
    diff = first_diff(original, reparsed)
    if diff is None and compact(original) != compact(reparsed):
        diff = "$: serialized forms differ"
    for w in warnings:
        print(w, file=sys.stderr)
    if diff is not None:
        print(f"ERROR: semantic mismatch after format at {diff}; {path} not written", file=sys.stderr)
        sys.exit(1)
    if formatted == source:
        print(f"Unchanged {path}")
        return
    path.write_text(formatted, encoding="utf-8")
    print(f"Formatted {path}")


if __name__ == "__main__":
    main()
