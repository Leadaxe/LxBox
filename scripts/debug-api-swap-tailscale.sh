#!/usr/bin/env bash
# Через Debug API: добавить новый узел Tailscale с auth key, выключить старый,
# пересобрать конфиг и перезапустить VPN. Ключ вводится с клавиатуры (не
# попадает в историю shell и в аргументы процесса).
#
#   scripts/debug-api-swap-tailscale.sh <старый-id> [hostname] [exit_node]
#
# Окружение: LXBOX_DEVICE (emulator-5554), LXBOX_PORT (9269), LXBOX_TOKEN
# (Debug API token из App Settings → Diagnostics).
set -euo pipefail

OLD_ID="${1:?id старого узла (GET /subs)}"
HOSTNAME_NEW="${2:-lxbox-emu-api}"
EXIT_NODE="${3:-}"
DEV="${LXBOX_DEVICE:-emulator-5554}"
PORT="${LXBOX_PORT:-9269}"
TOKEN="${LXBOX_TOKEN:?LXBOX_TOKEN не задан}"
B="http://127.0.0.1:$PORT"
H="Authorization: Bearer $TOKEN"

adb -s "$DEV" forward "tcp:$PORT" tcp:9269 >/dev/null

read -rsp "Tailscale auth key: " KEY; echo
[[ "$KEY" == tskey-* ]] || { echo "ключ должен начинаться с tskey-" >&2; exit 1; }

BODY=$(KEY="$KEY" HN="$HOSTNAME_NEW" EN="$EXIT_NODE" python3 -c '
import json, os
node = {"type": "tailscale", "tag": "🕸️ tailscale api",
        "auth_key": os.environ["KEY"], "hostname": os.environ["HN"]}
if os.environ["EN"]:
    node["exit_node"] = os.environ["EN"]
print(json.dumps({"input": json.dumps(node, ensure_ascii=False)}, ensure_ascii=False))')
unset KEY

echo "→ POST /subs (новый узел)"
NEW=$(curl -sf -m 15 -X POST -H "$H" -H 'Content-Type: application/json' -d "$BODY" "$B/subs")
unset BODY
NEW_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$NEW")
echo "  новый id: $NEW_ID"

echo "→ PATCH /subs/$OLD_ID enabled=false"
curl -sf -m 10 -X PATCH -H "$H" -H 'Content-Type: application/json' -d '{"enabled":false}' "$B/subs/$OLD_ID" >/dev/null

echo "→ PATCH /subs/$NEW_ID enabled=true"
curl -sf -m 10 -X PATCH -H "$H" -H 'Content-Type: application/json' -d '{"enabled":true}' "$B/subs/$NEW_ID" >/dev/null

echo "→ rebuild-config + reload-vpn"
curl -sf -m 30 -X POST -H "$H" "$B/action/rebuild-config" >/dev/null
curl -sf -m 30 -X POST -H "$H" "$B/action/reload-vpn" >/dev/null

echo "→ ждём Tailscale (15 с)"
sleep 15
curl -sf -m 5 -H "$H" "$B/state" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  tunnel:", d.get("tunnel"))
for tag, st in (d.get("tailscale") or {}).items():
    print("  %s: %s, devices %s" % (tag, st.get("backend_state"), st.get("devices")))'
curl -sf -m 5 -H "$H" "$B/subs" | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    print("  sub", s["id"], s.get("kind"), "enabled" if s.get("enabled") else "disabled")'
