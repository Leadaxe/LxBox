#!/usr/bin/env bash
# One-command snapshot всего runtime-state'а L×Box на тестовом устройстве.
# Кладёт всё read-only в /tmp/lxbox-debug-<datetime>/.
#
# Зачем: до любой destructive op (reset-network, reload, restart, PUT config)
# обязательно нужен baseline для post-mortem. См. docs/DIAGNOSTICS.md.
#
# Usage:
#   ./scripts/lxbox-diag.sh                # по дефолту в /tmp/lxbox-debug-<ts>/
#   ./scripts/lxbox-diag.sh -o ./mydir     # custom output dir
#   ./scripts/lxbox-diag.sh --token ABC    # override Debug API token
#   ./scripts/lxbox-diag.sh --no-clash     # skip Clash API (если выключен)
#   ./scripts/lxbox-diag.sh --no-adb       # skip device-side (если adb недоступен)
#
# Exit:
#   0 — snapshot собран (даже если часть источников недоступна)
#   1 — критическая ошибка (нет ни adb, ни Debug API)
#
# Зависимости: bash 4+, curl, jq (optional, для friendly summary), adb,
# python3 (для ss/log парсинга).

set -uo pipefail   # NB: -e не используем — фейл одного источника не должен убить остальные

# ─── defaults ───────────────────────────────────────────────────────

TS="$(date +%Y-%m-%d-%H%M%S)"
OUT_DIR="/tmp/lxbox-debug-$TS"
TOKEN="${LXBOX_DEBUG_TOKEN:-357f5aacdf154419d2787ec61e3ad9f2}"
LB_HOST_PORT="9270"   # adb forward по умолчанию (см. install-apk.sh)
LB_DEVICE_PORT="9269"
CLASH_HOST_PORT="9091"
CLASH_DEVICE_PORT="63130"
SKIP_CLASH=0
SKIP_ADB=0

# ─── arg parse ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)        OUT_DIR="$2"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --no-clash)      SKIP_CLASH=1; shift ;;
    --no-adb)        SKIP_ADB=1; shift ;;
    -h|--help)       sed -n '1,25p' "$0" | sed 's|^# \?||'; exit 0 ;;
    *) echo "✗ Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── adb path bootstrap (то же что в ensure-wifi-adb.sh) ────────────

if [ "$SKIP_ADB" -eq 0 ] && ! command -v adb >/dev/null 2>&1; then
  export PATH="${ANDROID_SDK_ROOT:-/usr/local/share/android-commandlinetools}/platform-tools:$PATH"
  if ! command -v adb >/dev/null 2>&1; then
    echo "⚠ adb not in PATH — skipping device-side commands" >&2
    SKIP_ADB=1
  fi
fi

# ─── prepare ────────────────────────────────────────────────────────

mkdir -p "$OUT_DIR"
echo "→ snapshot dir: $OUT_DIR"

LB_BASE="http://localhost:$LB_HOST_PORT"
CLASH_BASE="http://localhost:$CLASH_HOST_PORT"
HDR_AUTH="Authorization: Bearer $TOKEN"

# Проверим что Debug API живой
PING="$(curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" 2>/dev/null || true)"
if [ -z "$PING" ]; then
  echo "⚠ Debug API на $LB_BASE недоступен — пробую adb forward..." >&2
  if [ "$SKIP_ADB" -eq 0 ]; then
    adb forward "tcp:$LB_HOST_PORT" "tcp:$LB_DEVICE_PORT" >/dev/null 2>&1 || true
    PING="$(curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" 2>/dev/null || true)"
  fi
fi
if [ -z "$PING" ]; then
  echo "✗ Debug API недоступен — нечего собирать. Проверь adb forward / token / приложение запущено?" >&2
  exit 1
fi

# Auto-forward Clash API если нужно
if [ "$SKIP_CLASH" -eq 0 ] && [ "$SKIP_ADB" -eq 0 ]; then
  adb forward "tcp:$CLASH_HOST_PORT" "tcp:$CLASH_DEVICE_PORT" >/dev/null 2>&1 || true
fi

# ─── parallel collect ───────────────────────────────────────────────

echo "→ собираю Debug API endpoints (parallel)..."

curl -s -H "$HDR_AUTH" "$LB_BASE/state"                              -o "$OUT_DIR/state.json"            &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/storage"                      -o "$OUT_DIR/storage.json"          &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/clash"                        -o "$OUT_DIR/state_clash.json"      &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/subs"                         -o "$OUT_DIR/state_subs.json"       &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/rules"                        -o "$OUT_DIR/state_rules.json"      &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/vpn"                          -o "$OUT_DIR/state_vpn.json"        &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/config_locked"                -o "$OUT_DIR/state_config_locked.json" &
curl -s -H "$HDR_AUTH" "$LB_BASE/device"                             -o "$OUT_DIR/device.json"           &
curl -s -H "$HDR_AUTH" "$LB_BASE/config"                             -o "$OUT_DIR/config.json"           &
curl -s -H "$HDR_AUTH" "$LB_BASE/logs?source=core&limit=500"         -o "$OUT_DIR/core_logs.json"        &
curl -s -H "$HDR_AUTH" "$LB_BASE/logs?source=app&limit=300"          -o "$OUT_DIR/app_logs.json"         &

if [ "$SKIP_CLASH" -eq 0 ]; then
  # Clash secret вытащим из state/clash после fetching, но для скорости — параллельно с пустым auth
  # (Clash API в LxBox обычно без secret'а)
  curl -s -m 3 "$CLASH_BASE/connections"                             -o "$OUT_DIR/clash_connections.json" &
  curl -s -m 3 "$CLASH_BASE/proxies"                                 -o "$OUT_DIR/clash_proxies.json"     &
  curl -s -m 3 "$CLASH_BASE/rules"                                   -o "$OUT_DIR/clash_rules.json"       &
  curl -s -m 3 "$CLASH_BASE/version"                                 -o "$OUT_DIR/clash_version.json"     &
fi

if [ "$SKIP_ADB" -eq 0 ]; then
  adb shell ss -tnp                                  > "$OUT_DIR/device_ss_tcp.txt"        2>&1 &
  adb shell ss -unp                                  > "$OUT_DIR/device_ss_udp.txt"        2>&1 &
  adb shell ip route                                 > "$OUT_DIR/device_routes_main.txt"   2>&1 &
  adb shell ip route show table all                  > "$OUT_DIR/device_routes_all.txt"    2>&1 &
  adb shell ip rule                                  > "$OUT_DIR/device_ip_rule.txt"       2>&1 &
  adb shell ip -4 addr                               > "$OUT_DIR/device_addrs.txt"         2>&1 &
  adb shell getprop                                  > "$OUT_DIR/device_props.txt"         2>&1 &
  adb logcat -d -t 500                               > "$OUT_DIR/device_logcat.txt"        2>&1 &
fi

wait

echo "✓ все источники собраны"

# ─── tiny summary (jq optional, fallback на python) ─────────────────

echo
echo "─── snapshot summary ───────────────────────"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$OUT_DIR" << 'PYEOF'
import json, os, sys, glob
d = sys.argv[1]

def jr(p, k=None, default='?'):
    try:
        x = json.load(open(os.path.join(d, p)))
        if k is None: return x
        for kk in k.split('.'):
            x = x[kk] if isinstance(x, dict) and kk in x else default
        return x
    except Exception:
        return default

# State summary
print(f"tunnel:               {jr('state.json','tunnel')}")
print(f"selected_group:       {jr('state.json','selected_group')}")
print(f"active_in_group:      {jr('state.json','active_in_group')}")
print(f"active_connections:   {jr('state.json','traffic.active_connections')}")
last_err = jr('state.json','last_error') or '(none)'
print(f"last_error:           {last_err[:100]}")

# Errors / warns в core
try:
    cl = json.load(open(os.path.join(d, 'core_logs.json')))
    es = cl if isinstance(cl, list) else cl.get('entries', [])
    errs = [e for e in es if e.get('level') in ('error','warning','warn')]
    print(f"\ncore errors/warns:    {len(errs)}")
    for e in errs[:5]:
        print(f"  {e.get('ts','?')[11:23]} [{e.get('level')}] {e.get('message','')[:140]}")
    if len(errs) > 5: print(f"  ... +{len(errs)-5} more")
except Exception:
    pass

# App errors
try:
    al = json.load(open(os.path.join(d, 'app_logs.json')))
    es = al if isinstance(al, list) else al.get('entries', [])
    errs = [e for e in es if e.get('level') in ('error','warning','warn')]
    print(f"\napp errors/warns:     {len(errs)}")
    for e in errs[:5]:
        print(f"  {e.get('ts','?')[11:23]} [{e.get('level')}] {e.get('message','')[:140]}")
except Exception:
    pass

# Active proxies
try:
    p = json.load(open(os.path.join(d, 'clash_proxies.json')))
    pr = p.get('proxies', {})
    print('\nActive selectors:')
    for name in ['vpn-1','vpn-2','vpn-3','✨auto']:
        if name in pr:
            now = pr[name].get('now','?')
            t = pr[name].get('type','?')
            print(f"  {name:10} = {now} ({t})")
except Exception:
    pass

# TCP socket states
try:
    with open(os.path.join(d, 'device_ss_tcp.txt')) as f:
        states = {}
        for line in f:
            parts = line.split()
            if parts and parts[0] in ('ESTAB','SYN-SENT','SYN-RECV','FIN-WAIT-1','FIN-WAIT-2','LAST-ACK','CLOSE-WAIT','TIME-WAIT','CLOSING','State'):
                states[parts[0]] = states.get(parts[0], 0) + 1
        print('\nTCP socket states:')
        for s in sorted(states):
            if s == 'State': continue
            print(f"  {s:12} {states[s]}")
except Exception:
    pass

# Active Clash connections count
try:
    cc = json.load(open(os.path.join(d, 'clash_connections.json')))
    conns = cc.get('connections',[])
    print(f"\nClash active conns:   {len(conns)}")
except Exception:
    pass
PYEOF
fi

echo
echo "─── files ──────────────────────────────────"
ls -lh "$OUT_DIR"
echo
echo "✓ snapshot готов. Читай docs/DIAGNOSTICS.md → 'Common diagnostic flows'"
