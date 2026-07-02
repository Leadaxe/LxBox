#!/usr/bin/env bash
# One-command snapshot всего runtime-state'а L×Box на тестовом устройстве.
# Кладёт всё read-only в /tmp/lxbox-debug-<datetime>/.
#
# Зачем: до любой destructive op (reset-network, reload, restart, PUT config)
# обязательно нужен baseline для post-mortem. См. docs/DIAGNOSTICS.md.
#
# §122 (v2.5.0): Clash API выпилен. Соединения/DNS/цепочки берутся из
# профайлера (`/profiler/live`, §044/§180), proxies/groups — из `/state`
# (libbox CommandClient), ping — `/action/urltest`. Никакого Clash-порта.
#
# Usage:
#   ./scripts/lxbox-diag.sh                # по дефолту в /tmp/lxbox-debug-<ts>/
#   ./scripts/lxbox-diag.sh -o ./mydir     # custom output dir
#   ./scripts/lxbox-diag.sh --token ABC    # override Debug API token
#   ./scripts/lxbox-diag.sh --port 9270    # host adb-forward port (default 9269)
#   ./scripts/lxbox-diag.sh --no-profiler  # skip /profiler/live snapshot
#   ./scripts/lxbox-diag.sh --profiler-secs 30  # окно профайлера (default 60)
#   ./scripts/lxbox-diag.sh --ping         # запустить urltest (мутирует state!)
#   ./scripts/lxbox-diag.sh --no-adb       # skip device-side (если adb недоступен)
#
# Exit:
#   0 — snapshot собран (даже если часть источников недоступна)
#   1 — критическая ошибка (нет ни adb, ни Debug API)
#
# Зависимости: bash 4+, curl, jq (optional), adb, python3.

set -uo pipefail   # NB: -e не используем — фейл одного источника не должен убить остальные

# ─── defaults ───────────────────────────────────────────────────────

TS="$(date +%Y-%m-%d-%H%M%S)"
OUT_DIR="/tmp/lxbox-debug-$TS"
TOKEN="${LXBOX_DEBUG_TOKEN:-471592e5f676d0eddee669c0548b3edb}"   # rotated 2026-06-12; override через LXBOX_DEBUG_TOKEN / --token
LB_HOST_PORT="9269"   # форвард 1:1 (host==device); юзер форвардит 9269→9269. Override: --port
LB_DEVICE_PORT="9269" # debugPortDefault (SettingsStorage); см. project_dev_endpoints
PROFILER_SECS="60"    # окно /profiler/live (§048 inclusive observer)
SKIP_PROFILER=0
DO_PING=0             # §122 — urltest через CommandClient (мутирует state, OFF by default)
SKIP_ADB=0

# ─── arg parse ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)        OUT_DIR="$2"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --port)          LB_HOST_PORT="$2"; shift 2 ;;
    --no-profiler)   SKIP_PROFILER=1; shift ;;
    --profiler-secs) PROFILER_SECS="$2"; shift 2 ;;
    --ping)          DO_PING=1; shift ;;
    --no-adb)        SKIP_ADB=1; shift ;;
    -h|--help)       sed -n '2,26p' "$0" | sed 's|^# \?||'; exit 0 ;;
    *) echo "✗ Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── adb path bootstrap (§219 — общий helper) ──────────────────────

# shellcheck source=lib/ensure-adb.sh
. "$(dirname "$0")/lib/ensure-adb.sh"
if [ "$SKIP_ADB" -eq 0 ] && ! ensure_adb_path; then
  echo "⚠ adb not in PATH — skipping device-side commands" >&2
  SKIP_ADB=1
fi

# ─── prepare ────────────────────────────────────────────────────────

mkdir -p "$OUT_DIR"
echo "→ snapshot dir: $OUT_DIR"

LB_BASE="http://localhost:$LB_HOST_PORT"
HDR_AUTH="Authorization: Bearer $TOKEN"

# Проверим что Debug API живой
PING="$(curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" 2>/dev/null || true)"
if [ -z "$PING" ]; then
  echo "⚠ Debug API at $LB_BASE unreachable — trying adb forward..." >&2
  if [ "$SKIP_ADB" -eq 0 ]; then
    adb forward "tcp:$LB_HOST_PORT" "tcp:$LB_DEVICE_PORT" >/dev/null 2>&1 || true
    PING="$(curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" 2>/dev/null || true)"
  fi
fi
if [ -z "$PING" ]; then
  echo "✗ Debug API unreachable — nothing to collect. Check adb forward / token / app running?" >&2
  exit 1
fi

# Auth-check: /ping не требует токена (unauthenticatedPaths), поэтому живой ping
# ещё НЕ значит что токен верный. Дёргаем защищённый /state — если 401, токен
# протух/неверный, и иначе снапшот молча соберёт unauthorized-envelope'ы и
# покажет «?» везде (выглядит как «приложение не запущено»). Не падаем —
# adb-сбор всё равно ценен, — но громко предупреждаем.
AUTH_CODE="$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H "$HDR_AUTH" "$LB_BASE/state" 2>/dev/null || echo 000)"
if [ "$AUTH_CODE" = "401" ] || [ "$AUTH_CODE" = "403" ]; then
  echo "⚠ Debug API returned $AUTH_CODE on /state — token stale/invalid (or Host != 127.0.0.1)." >&2
  echo "  Pass a fresh one: --token <TOKEN> or LXBOX_DEBUG_TOKEN=... (see App Settings → Diagnostics)." >&2
fi

# Профайлер (§048 inclusive observer) живёт за тем же Debug API (тот же порт) —
# отдельный adb forward не нужен. Но system-wide rolling-buffer по умолчанию
# выключен: без предшествующего live/start `/profiler/live` вернёт пустое окно.
# Кикаем запись, чтобы буфер начал копить события (см. profiler.dart _liveStart).
if [ "$SKIP_PROFILER" -eq 0 ]; then
  curl -sf -m 2 -X POST -H "$HDR_AUTH" "$LB_BASE/profiler/live/start" \
    -o "$OUT_DIR/profiler_live_state.json" 2>/dev/null || \
    echo "⚠ profiler/live/start did not respond — buffer may be empty" >&2
fi

# §122 — ping = mass urltest активной группы через CommandClient (был Clash
# /proxies/<name>/delay). МУТИРУЕТ runtime-state (роняет/пересортировывает
# ноды), поэтому OFF by default — снапшот read-only. Результат не в ответе
# (fire-and-forget), а в /state.last_delay, который соберётся ниже. См.
# action.dart _urltest. Даём ~3с на завершение перед сбором /state.
if [ "$DO_PING" -eq 1 ]; then
  echo "→ --ping: running urltest for all nodes of the active group (mutates state)..."
  curl -sf -m 4 -X POST -H "$HDR_AUTH" "$LB_BASE/action/urltest?all=true" \
    -o "$OUT_DIR/action_urltest.json" 2>/dev/null || \
    echo "⚠ urltest did not start (tunnel not up?)" >&2
  sleep 3
fi

# ─── parallel collect ───────────────────────────────────────────────

echo "→ collecting Debug API endpoints (parallel)..."

curl -s -H "$HDR_AUTH" "$LB_BASE/state"                              -o "$OUT_DIR/state.json"            &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/storage"                      -o "$OUT_DIR/storage.json"          &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/subs"                         -o "$OUT_DIR/state_subs.json"       &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/rules"                        -o "$OUT_DIR/state_rules.json"      &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/vpn"                          -o "$OUT_DIR/state_vpn.json"        &
curl -s -H "$HDR_AUTH" "$LB_BASE/state/config_locked"                -o "$OUT_DIR/state_config_locked.json" &
curl -s -H "$HDR_AUTH" "$LB_BASE/device"                             -o "$OUT_DIR/device.json"           &
curl -s -H "$HDR_AUTH" "$LB_BASE/config"                             -o "$OUT_DIR/config.json"           &
curl -s -H "$HDR_AUTH" "$LB_BASE/logs?source=core&limit=500"         -o "$OUT_DIR/core_logs.json"        &
curl -s -H "$HDR_AUTH" "$LB_BASE/logs?source=app&limit=300"          -o "$OUT_DIR/app_logs.json"         &

if [ "$SKIP_PROFILER" -eq 0 ]; then
  # §122 — Clash API выпилен; «где идёт трафик сейчас» снимается профайлером.
  # system-wide rolling buffer за окно PROFILER_SECS: TCP/UDP open/close +
  # DNS resolve/fail всех packages, с routing-цепочкой (§181) per event.
  # Требует предшествующий live/start (см. выше). Тот же $HDR_AUTH, что и /state.
  curl -s -m 5 -H "$HDR_AUTH" "$LB_BASE/profiler/live?seconds=$PROFILER_SECS" \
                                                                     -o "$OUT_DIR/profiler_live.json"     &
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

echo "✓ all sources collected"

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

# Groups / selectors (§122 — заменил clash_proxies.json «Active selectors»;
# дерево групп теперь в /state из libbox CommandClient, CcChannel.groups).
try:
    st = jr('state.json')
    groups = st.get('groups', []) if isinstance(st, dict) else []
    active = st.get('active_in_group')
    delays = st.get('last_delay', {}) or {}
    if groups:
        print('\nGroups:')
        for g in groups:
            mark = ' ←active' if g == st.get('selected_group') else ''
            print(f"  {g}{mark}")
    if active:
        # last_delay ключуется по tag ноды (совпадает с active_in_group).
        # Значения: >0 = ms, 0 = timeout, -1 = ещё не пинговалось (mass urltest
        # не гонялся; запусти с --ping). None = ключа нет.
        dly = delays.get(active)
        if isinstance(dly, int) and dly > 0:
            dtxt = f"{dly}ms"
        elif dly == 0:
            dtxt = 'timeout'
        elif dly == -1:
            dtxt = 'not pinged'
        else:
            dtxt = '?'
        print(f"active node:           {active} ({dtxt})")
except Exception:
    pass

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

# Profiler live events (§122 — заменил clash_proxies/connections snapshot)
try:
    pl = json.load(open(os.path.join(d, 'profiler_live.json')))
    evs = pl.get('events', [])
    win = pl.get('window_seconds', '?')
    print(f"\nProfiler live ({win}s window): {len(evs)} events")
    if evs:
        # Разбивка по kind (dnsResolve/dnsFail/tcpOpen/tcpClose/udpOpen).
        by_kind = {}
        for e in evs:
            k = e.get('kind', '?')
            by_kind[k] = by_kind.get(k, 0) + 1
        for k in sorted(by_kind):
            print(f"  {k:12} {by_kind[k]}")
        # Топ процессов по числу событий (нет process = unattributed).
        by_proc = {}
        for e in evs:
            pr = e.get('process') or '(unattributed)'
            by_proc[pr] = by_proc.get(pr, 0) + 1
        print('  top processes:')
        for name, n in sorted(by_proc.items(), key=lambda kv: -kv[1])[:5]:
            print(f"    {n:4} {name}")
        # DNS-сбои — самый частый диагностический сигнал (§177).
        fails = [e for e in evs if e.get('kind') == 'dnsFail']
        if fails:
            print(f"  dnsFail: {len(fails)}")
            for e in fails[:5]:
                print(f"    {e.get('domain','?')} (rule={e.get('rule','?')})")
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
PYEOF
fi

echo
echo "─── files ──────────────────────────────────"
ls -lh "$OUT_DIR"
echo
echo "✓ snapshot ready. See docs/DIAGNOSTICS.md → 'Common diagnostic flows'"
