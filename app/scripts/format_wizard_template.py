#!/usr/bin/env python3
"""Format wizard_template.json per singbox-launcher TEMPLATE_REFERENCE §10."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

INDENT = "  "


def compact(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(", ", ": "))


def pad(level: int) -> str:
    return INDENT * level


def is_at(s: Any) -> bool:
    return isinstance(s, str) and s.startswith("@")


def if_cond(d: dict[str, Any]) -> str:
    return compact({k: d[k] for k in ("and", "or") if k in d})


def strip_trailing_commas(text: str) -> str:
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r",(\s*[\]\}])", r"\1", text)
    return text


def is_simple_var(v: dict[str, Any]) -> bool:
    if "ref" in v:
        return True
    allowed = {"name", "type", "default_value", "title", "tooltip", "wizard_ui", "required"}
    return set(v.keys()) <= allowed and "options" not in v and "on_change" not in v


def format_var(v: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    if is_simple_var(v):
        line = pad(level) + compact(v)
        return [line + ("," if trailing_comma else "")]

    header_keys = ["name", "type", "wizard_ui", "title", "tooltip", "required"]
    header = ", ".join(f'"{k}": {json.dumps(v[k], ensure_ascii=False)}' for k in header_keys if k in v)
    lines = [pad(level) + "{ " + header + ","]

    if "default_value" in v:
        lines.append(pad(level + 1) + f'"default_value": {json.dumps(v["default_value"], ensure_ascii=False)},')

    if "options" in v:
        opts = v["options"]
        if opts and all(isinstance(o, str) for o in opts):
            lines.append(pad(level + 1) + f'"options": {compact(opts)},')
        else:
            lines.append(pad(level + 1) + '"options": [')
            for i, o in enumerate(opts):
                lines.append(pad(level + 2) + compact(o) + ("," if i < len(opts) - 1 else ""))
            lines.append(pad(level + 1) + "],")

    if "on_change" in v:
        oc = v["on_change"]
        lines.append(pad(level + 1) + '"on_change": { "set": {')
        set_obj = oc["set"]
        keys = list(set_obj.keys())
        for i, sk in enumerate(keys):
            tc = "," if i < len(keys) - 1 else ""
            lines.append(pad(level + 3) + f'{json.dumps(sk, ensure_ascii=False)}: {format_if_scalar(set_obj[sk]["#if"])}{tc}')
        lines.append(pad(level + 1) + "}},")

    lines[-1] = lines[-1].rstrip(",")
    lines.append(pad(level) + "}" + ("," if trailing_comma else ""))
    return lines


def format_var_array(vars: list[dict[str, Any]], level: int, *, key: str = "vars") -> list[str]:
    lines = [pad(level) + f'"{key}": [']
    for i, v in enumerate(vars):
        lines.extend(format_var(v, level + 1, trailing_comma=i < len(vars) - 1))
    lines.append(pad(level) + "],")
    return lines


def format_dns_server(entry: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    lines = [
        pad(level) + "{",
        pad(level + 1) + f'"description": {json.dumps(entry["description"], ensure_ascii=False)},',
        pad(level + 1) + f'"enabled": {json.dumps(entry["enabled"])},',
    ]
    if "vars" in entry:
        lines.extend(format_var_array(entry["vars"], level + 1))
    lines.append(pad(level + 1) + f'"server": {compact(entry["server"])}')
    lines.append(pad(level) + "}" + ("," if trailing_comma else ""))
    return lines


def format_if_scalar(ifd: dict[str, Any]) -> str:
    return compact({"#if": ifd})


def format_if_element(obj: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    ifd = obj["#if"]
    val = ifd.get("value")
    if isinstance(val, (str, int, float, bool)) or (
        isinstance(val, dict)
        and len(val) <= 4
        and not any(is_at(x) for x in val.values() if isinstance(x, str))
        and "inbound" not in val
    ):
        return [pad(level) + format_if_scalar(ifd) + ("," if trailing_comma else "")]

    cond_key = "and" if "and" in ifd else "or"
    lines = [
        pad(level)
        + '{"#if": {'
        + f'"{cond_key}": '
        + compact(ifd[cond_key])
        + ', "value": {'
    ]
    for k, v in val.items():
        if k == "inbound" and isinstance(v, list):
            lines.append(pad(level + 2) + '"inbound": [')
            for j, item in enumerate(v):
                tc = "," if j < len(v) - 1 else ""
                if isinstance(item, str):
                    lines.append(pad(level + 3) + json.dumps(item, ensure_ascii=False) + tc)
                else:
                    lines.append(pad(level + 3) + format_if_scalar(item["#if"]) + tc)
            lines.append(pad(level + 2) + "],")
        elif k == "#if":
            sub = v
            lines.append(
                pad(level + 2) + '"#if": ' + compact(sub) + ","
            )
        elif k == "address" and isinstance(v, list):
            lines.append(pad(level + 2) + '"address": [')
            for j, item in enumerate(v):
                tc = "," if j < len(v) - 1 else ""
                if isinstance(item, str):
                    lines.append(pad(level + 3) + json.dumps(item, ensure_ascii=False) + tc)
                else:
                    lines.append(pad(level + 3) + format_if_scalar(item["#if"]) + tc)
            lines.append(pad(level + 2) + "],")
        elif is_at(v):
            lines.append(pad(level + 2) + f'"{k}": {json.dumps(v, ensure_ascii=False)},')
        else:
            lines.append(pad(level + 2) + f'"{k}": {json.dumps(v, ensure_ascii=False)},')
    lines[-1] = lines[-1].rstrip(",")
    lines.append(pad(level + 1) + "}")
    if "else" in ifd:
        lines.append(pad(level + 1) + f'"else": {json.dumps(ifd["else"], ensure_ascii=False)}')
    lines.append(pad(level) + "}}" + ("," if trailing_comma else ""))
    return lines


def format_if_object_wrapper(ifd: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    return format_if_element({"#if": ifd}, level, trailing_comma=trailing_comma)


def format_rule_set(rs: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    if rs.get("type") == "inline":
        meta = ", ".join(f'"{k}": {json.dumps(rs[k], ensure_ascii=False)}' for k in ("tag", "type") if k in rs)
        lines = [pad(level) + "{ " + meta + ",", pad(level + 1) + '"rules": [']
        for i, rule in enumerate(rs["rules"]):
            lines.append(pad(level + 2) + compact(rule) + ("," if i < len(rs["rules"]) - 1 else ""))
        lines.append(pad(level + 1) + "]")
        lines.append(pad(level) + "}" + ("," if trailing_comma else ""))
        return lines

    meta_keys = ["tag", "enabled", "type", "format", "update_interval"]
    meta = ", ".join(f'"{k}": {json.dumps(rs[k], ensure_ascii=False)}' for k in meta_keys if k in rs)
    lines = [pad(level) + "{ " + meta + ","]
    if "url" in rs:
        lines.append(pad(level + 1) + f'"url": {json.dumps(rs["url"], ensure_ascii=False)}')
    lines.append(pad(level) + "}" + ("," if trailing_comma else ""))
    return lines


def format_dns_server_flat(s: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    return [pad(level) + compact(s) + ("," if trailing_comma else "")]


def format_preset(p: dict[str, Any], level: int, *, trailing_comma: bool) -> list[str]:
    lines = [
        pad(level) + "{",
        pad(level + 1) + f'"preset_id": {json.dumps(p["preset_id"], ensure_ascii=False)},',
        pad(level + 1) + '"ui": ' + compact(p["ui"]) + ",",
    ]
    if "vars" in p:
        lines.extend(format_var_array(p["vars"], level + 1))

    if "rule_set" in p:
        lines.append(pad(level + 1) + '"rule_set": [')
        for i, rs in enumerate(p["rule_set"]):
            lines.extend(format_rule_set(rs, level + 2, trailing_comma=i < len(p["rule_set"]) - 1))
        lines.append(pad(level + 1) + "],")

    if "rule" in p:
        r = p["rule"]
        if isinstance(r, list):
            lines.append(pad(level + 1) + '"rule": [')
            for i, rule in enumerate(r):
                if "#if" in rule:
                    lines.extend(format_if_element(rule, level + 2, trailing_comma=i < len(r) - 1))
                else:
                    lines.append(pad(level + 2) + compact(rule) + ("," if i < len(r) - 1 else ""))
            lines.append(pad(level + 1) + "],")
        else:
            lines.append(pad(level + 1) + '"rule": ' + compact(r) + ",")

    if "rules" in p:
        lines.append(pad(level + 1) + '"rules": [')
        for i, rule in enumerate(p["rules"]):
            if "#if" in rule:
                lines.extend(format_if_element(rule, level + 2, trailing_comma=i < len(p["rules"]) - 1))
            else:
                lines.append(pad(level + 2) + compact(rule) + ("," if i < len(p["rules"]) - 1 else ""))
        lines.append(pad(level + 1) + "],")

    if "dns_rules" in p:
        lines.append(pad(level + 1) + '"dns_rules": [')
        for i, dr in enumerate(p["dns_rules"]):
            if "#if" in dr:
                lines.append(pad(level + 2) + format_if_scalar(dr["#if"]) + ("," if i < len(p["dns_rules"]) - 1 else ""))
            else:
                lines.append(pad(level + 2) + compact(dr) + ("," if i < len(p["dns_rules"]) - 1 else ""))
        lines.append(pad(level + 1) + "],")

    if "dns_servers" in p:
        lines.append(pad(level + 1) + '"dns_servers": [')
        for i, s in enumerate(p["dns_servers"]):
            lines.extend(format_dns_server_flat(s, level + 2, trailing_comma=i < len(p["dns_servers"]) - 1))
        lines.append(pad(level + 1) + "],")

    lines[-1] = lines[-1].rstrip(",")
    lines.append(pad(level) + "}" + ("," if trailing_comma else ""))
    return lines


def format_template(data: dict[str, Any]) -> str:
    out: list[str] = ["{"]

    out.append(pad(1) + '"parser_config": {')
    out.append(pad(2) + f'"version": {data["parser_config"]["version"]},')
    out.append(pad(2) + f'"parser": {compact(data["parser_config"]["parser"])}')
    out.append(pad(1) + "},")

    out.append(pad(1) + '"dns_options": {')
    out.append(pad(2) + '"servers": [')
    servers = data["dns_options"]["servers"]
    for i, s in enumerate(servers):
        out.extend(format_dns_server(s, 3, trailing_comma=i < len(servers) - 1))
    out.append(pad(2) + "],")
    out.append(pad(2) + f'"rules": {compact(data["dns_options"]["rules"])}')
    out.append(pad(1) + "},")

    po = data["ping_options"]
    out.append(pad(1) + '"ping_options": {')
    out.append(pad(2) + f'"url": {json.dumps(po["url"], ensure_ascii=False)},')
    out.append(pad(2) + f'"timeout_ms": {po["timeout_ms"]},')
    out.append(pad(2) + '"presets": [')
    for i, p in enumerate(po["presets"]):
        out.append(pad(3) + compact(p) + ("," if i < len(po["presets"]) - 1 else ""))
    out.append(pad(2) + "]")
    out.append(pad(1) + "},")

    sto = data["speed_test_options"]
    out.append(pad(1) + '"speed_test_options": {')
    out.append(pad(2) + '"servers": [')
    servers = sto["servers"]
    for i, s in enumerate(servers):
        out.append(pad(3) + compact(s) + ("," if i < len(servers) - 1 else ""))
    out.append(pad(2) + "],")
    out.append(pad(2) + f'"stream_options": {compact(sto["stream_options"])},')
    out.append(pad(2) + f'"default_streams": {sto["default_streams"]}')
    out.append(pad(1) + "},")

    # §267 — group_templates (magic_nodes реестр + channel/auto шаблоны) +
    # top-level default_channels. Заменили плоский preset_groups.
    gt = data["group_templates"]
    out.append(pad(1) + '"group_templates": {')
    # magic_nodes: role → {title, source, tag?, tpl?} — по строке на роль.
    nodes = gt["magic_nodes"]
    node_keys = list(nodes.keys())
    out.append(pad(2) + '"magic_nodes": {')
    for i, role in enumerate(node_keys):
        out.append(pad(3) + f'{json.dumps(role, ensure_ascii=False)}: {compact(nodes[role])}' + ("," if i < len(node_keys) - 1 else ""))
    out.append(pad(2) + "},")
    # channel: type + include (роли) + options.
    ch = gt["channel"]
    out.append(pad(2) + '"channel": {')
    out.append(pad(3) + f'"type": {json.dumps(ch["type"], ensure_ascii=False)},')
    out.append(pad(3) + f'"include": {compact(ch["include"])},')
    out.append(pad(3) + '"options": {')
    ch_opts = ch["options"]
    ch_opt_keys = list(ch_opts.keys())
    for j, ok in enumerate(ch_opt_keys):
        out.append(pad(4) + f'"{ok}": {json.dumps(ch_opts[ok], ensure_ascii=False)}' + ("," if j < len(ch_opt_keys) - 1 else ""))
    out.append(pad(3) + "}")
    out.append(pad(2) + "},")
    # auto: type + options (сырой urltest-шаблон с @var).
    au = gt["auto"]
    out.append(pad(2) + '"auto": {')
    out.append(pad(3) + f'"type": {json.dumps(au["type"], ensure_ascii=False)},')
    out.append(pad(3) + '"options": {')
    au_opts = au["options"]
    au_opt_keys = list(au_opts.keys())
    for j, ok in enumerate(au_opt_keys):
        out.append(pad(4) + f'"{ok}": {json.dumps(au_opts[ok], ensure_ascii=False)}' + ("," if j < len(au_opt_keys) - 1 else ""))
    out.append(pad(3) + "}")
    out.append(pad(2) + "}")
    out.append(pad(1) + "},")

    out.append(pad(1) + '"default_channels": [')
    dchs = data["default_channels"]
    for i, dc in enumerate(dchs):
        out.append(pad(2) + compact(dc) + ("," if i < len(dchs) - 1 else ""))
    out.append(pad(1) + "],")

    out.append(pad(1) + '"sections": [')
    sections = data["sections"]
    for si, sec in enumerate(sections):
        out.append(pad(2) + "{")
        if "id" in sec:  # §279 — stable machine-id (l10n overlay address)
            out.append(pad(3) + f'"id": {json.dumps(sec["id"], ensure_ascii=False)},')
        out.append(pad(3) + f'"name": {json.dumps(sec["name"], ensure_ascii=False)},')
        out.append(pad(3) + f'"chapter": {json.dumps(sec["chapter"], ensure_ascii=False)},')
        out.append(pad(3) + f'"description": {json.dumps(sec["description"], ensure_ascii=False)},')
        out.extend(format_var_array(sec["vars"], 3))
        out.append(pad(2) + "}" + ("," if si < len(sections) - 1 else ""))
    out.append(pad(1) + "],")

    cfg = data["config"]
    out.append(pad(1) + '"config": {')
    out.append(pad(2) + '"log": {')
    out.append(pad(3) + f'"level": {json.dumps(cfg["log"]["level"], ensure_ascii=False)},')
    out.append(pad(3) + f'"timestamp": {json.dumps(cfg["log"]["timestamp"])}')
    out.append(pad(2) + "},")
    out.append(pad(2) + '"dns": {')
    out.append(pad(3) + '"servers": [],')
    out.append(pad(3) + '"rules": [],')
    out.append(pad(3) + f'"final": {json.dumps(cfg["dns"]["final"], ensure_ascii=False)},')
    out.append(pad(3) + f'"strategy": {json.dumps(cfg["dns"]["strategy"], ensure_ascii=False)}')
    out.append(pad(2) + "},")
    out.append(pad(2) + '"inbounds": [')
    inbounds = cfg["inbounds"]
    for i, ib in enumerate(inbounds):
        out.extend(format_if_element(ib, 3, trailing_comma=i < len(inbounds) - 1))
    out.append(pad(2) + "],")
    out.append(pad(2) + '"endpoints": [],')
    out.append(pad(2) + '"outbounds": [')
    obs = cfg["outbounds"]
    for i, ob in enumerate(obs):
        out.append(pad(3) + compact(ob) + ("," if i < len(obs) - 1 else ""))
    out.append(pad(2) + "],")
    rt = cfg["route"]
    out.append(pad(2) + '"route": {')
    out.append(pad(3) + f'"find_process": {json.dumps(rt["find_process"])},')
    out.append(pad(3) + f'"default_domain_resolver": {json.dumps(rt["default_domain_resolver"], ensure_ascii=False)},')
    out.append(pad(3) + '"rules": [],')
    out.append(pad(3) + f'"final": {json.dumps(rt["final"], ensure_ascii=False)},')
    out.append(pad(3) + f'"auto_detect_interface": {json.dumps(rt["auto_detect_interface"], ensure_ascii=False)}')
    out.append(pad(2) + "},")
    cf = cfg["experimental"]["cache_file"]
    out.append(pad(2) + '"experimental": {')
    out.append(pad(3) + '"cache_file": {')
    out.append(pad(4) + f'"enabled": {json.dumps(cf["enabled"])},')
    out.append(pad(4) + f'"path": {json.dumps(cf["path"], ensure_ascii=False)},')
    out.append(pad(4) + f'"store_fakeip": {json.dumps(cf["store_fakeip"])}')
    out.append(pad(3) + "}")
    out.append(pad(2) + "}")
    out.append(pad(1) + "},")

    out.append(pad(1) + '"selectable_rules": [')
    presets = data["selectable_rules"]
    for i, p in enumerate(presets):
        out.extend(format_preset(p, 2, trailing_comma=i < len(presets) - 1))
    out.append(pad(1) + "]")
    out.append("}")
    return strip_trailing_commas("\n".join(out))


def main() -> None:
    path = Path(__file__).resolve().parents[1] / "assets" / "wizard_template.json"
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
    original = json.loads(path.read_text(encoding="utf-8"))
    formatted = format_template(original)
    reparsed = json.loads(formatted)
    if original != reparsed:
        print("ERROR: semantic mismatch after format", file=sys.stderr)
        sys.exit(1)
    path.write_text(formatted + "\n", encoding="utf-8")
    print(f"Formatted {path}")


if __name__ == "__main__":
    main()
