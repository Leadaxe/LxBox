# 012 — Xray JSON Array Parser + Chained Proxy (Jump)

## Problem

Some subscription providers return a JSON array of full Xray/v2ray configs instead of
base64-encoded URI links. Each element is a complete config with `outbounds`, `dns`,
`routing`, `remarks`. The proxy outbound uses Xray format (`protocol`/`vnext`/
`streamSettings`) rather than sing-box format.

Additionally, these configs often use **chained proxies** via `dialerProxy` in
`streamSettings.sockopt` — traffic goes through a SOCKS jump server first, then
through the VLESS outbound. BoxVPN currently has no support for either format.

## Solution

Port the Xray JSON Array parser from singbox-launcher (Go) to Dart:

1. **Detect** Xray JSON Array format in `SubscriptionDecoder`
2. **Parse** each array element: extract the main VLESS outbound + optional jump server
3. **Convert** Xray outbound fields to sing-box outbound format
4. **Generate** jump outbounds with `detour` field in `ConfigBuilder`

## Format Example

```json
[
  {
    "remarks": "🇨🇦Канада|Gemini bypass",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": { "vnext": [{ "address": "...", "port": 443, "users": [...] }] },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": { "serverName": "...", "publicKey": "...", "shortId": "..." },
          "sockopt": { "dialerProxy": "ru-upstream" }
        }
      },
      {
        "protocol": "socks",
        "tag": "ru-upstream",
        "settings": { "servers": [{ "address": "...", "port": 62531, "users": [...] }] }
      }
    ]
  }
]
```

## Files

| File | Change |
|------|--------|
| `lib/models/parsed_node.dart` | Add `ParsedJump` class, `jump` field to `ParsedNode` |
| `lib/services/xray_json_parser.dart` | **New** — Xray JSON Array → List<ParsedNode> |
| `lib/services/source_loader.dart` | Detect format, branch to xray parser |
| `lib/services/config_builder.dart` | Emit jump outbounds with `detour` |

## Acceptance

- [ ] Subscription returning Xray JSON Array is parsed into nodes with correct outbounds.
- [ ] SOCKS/VLESS jump servers produce separate outbound with `detour` reference.
- [ ] Nodes appear in proxy groups and are pingable.
- [ ] Non-Xray elements in the array are skipped gracefully.
- [ ] Existing base64/URI subscriptions continue to work unchanged.
