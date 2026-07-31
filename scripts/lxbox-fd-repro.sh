#!/usr/bin/env bash
# §329 — репро-серия для поимки триггера §047 (кто закрывает fd листенера).
#
# Цикл: POST /action/reconnect → пауза → TCP-проба с устройства. Красная проба =
# мгновенный refused по TCP при живом UDP/DNS — сигнатура мёртвого acceptLoop
# в system-стеке sing-tun (см. docs/spec/tasks/329-fd-close-trigger-dynamic-capture.md).
# На первой красной итерации снимает logcat и останавливается.
#
# ВАЖНО — «грязный» процесс: статистика ядровой сессии 3 поломки на 108
# рестартов, кластеризуются на процессе с fd-churn. Перед запуском погоняй
# телефон руками (браузер, мессенджеры) 15-20 минут. На свежезапущенном
# процессе серия даёт ложноотрицательный результат.
#
# Отрицательная серия НЕ доказывает отсутствие бага: при 3/108 сотня итераций
# вполне может пройти чисто. Это ограничение метода, не признак починки.
#
# Usage:
#   ./scripts/lxbox-fd-repro.sh                 # 120 итераций, интервал 4.5с
#   ./scripts/lxbox-fd-repro.sh -n 200          # длиннее серия
#   ./scripts/lxbox-fd-repro.sh --interval 4    # другой интервал
#   ./scripts/lxbox-fd-repro.sh --keep-going    # не останавливаться на красной
#   ./scripts/lxbox-fd-repro.sh --token ABC     # override Debug API token
#   ./scripts/lxbox-fd-repro.sh --port 9270     # host adb-forward port (default 9269)
#
# Exit:
#   0 — серия отработала, поломок нет
#   2 — поймана поломка (артефакты в output-каталоге)
#   1 — не смогли начать (нет adb / Debug API / устройства)
#
# Зависимости: bash 4+, curl, adb.

set -uo pipefail   # -e не используем: фейл одной пробы не должен убить серию

# ─── defaults ───────────────────────────────────────────────────────

TS="$(date +%Y-%m-%d-%H%M%S)"
OUT_DIR="/tmp/lxbox-fd-repro-$TS"
TOKEN="${LXBOX_DEBUG_TOKEN:-471592e5f676d0eddee669c0548b3edb}"   # override через LXBOX_DEBUG_TOKEN / --token
LB_HOST_PORT="9269"
LB_DEVICE_PORT="9269"
ITERATIONS=120
INTERVAL=4.5          # 4-5с — окно из ядровой сессии (Stopping→Started ~600мс)
KEEP_GOING=0
TCP_TARGET="1.1.1.1"  # проба: заведомо живой, не зависит от DNS
TCP_PORT=443
DNS_TARGET="one.one.one.one"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--iterations) ITERATIONS="$2"; shift 2 ;;
    --interval)      INTERVAL="$2"; shift 2 ;;
    --keep-going)    KEEP_GOING=1; shift ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --port)          LB_HOST_PORT="$2"; shift 2 ;;
    -o|--out)        OUT_DIR="$2"; shift 2 ;;
    -h|--help)       sed -n '2,31p' "$0" | sed 's|^# \?||'; exit 0 ;;
    *) echo "✗ Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── adb path bootstrap (§219 — общий helper) ──────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ensure-adb.sh
source "$SCRIPT_DIR/lib/ensure-adb.sh"

if ! ensure_adb_path; then
  echo "✗ adb не найден. Поставь platform-tools или задай ANDROID_SDK_ROOT." >&2
  exit 1
fi

if ! adb get-state >/dev/null 2>&1; then
  echo "✗ Устройство не подключено (adb get-state). USB надёжнее wifi при работающем VPN." >&2
  exit 1
fi

LB_BASE="http://127.0.0.1:$LB_HOST_PORT"
HDR_AUTH="Authorization: Bearer $TOKEN"

if ! curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" >/dev/null 2>&1; then
  echo "⚠ Debug API недоступен — пробую adb forward $LB_HOST_PORT→$LB_DEVICE_PORT..." >&2
  adb forward "tcp:$LB_HOST_PORT" "tcp:$LB_DEVICE_PORT" >/dev/null 2>&1 || true
  if ! curl -sf -m 2 -H "$HDR_AUTH" "$LB_BASE/ping" >/dev/null 2>&1; then
    echo "✗ Debug API недоступен. Проверь: приложение запущено, токен свежий (App Settings → Diagnostics)." >&2
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"

# ─── пробы ──────────────────────────────────────────────────────────

# TCP через tun. Красное = мгновенный refused (~16мс). Отличаем от таймаута:
# при мёртвом acceptLoop ядро ОС отвечает RST сразу, а не молчит.
probe_tcp() {
  adb shell "nc -w 3 -z $TCP_TARGET $TCP_PORT >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null | tr -d '\r'
}

# UDP/DNS — listener-free путь, при этом баге обязан жить. Если красный и он,
# значит упал весь туннель, а не acceptLoop — другой диагноз.
probe_dns() {
  adb shell "ping -c 1 -W 3 $DNS_TARGET >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null | tr -d '\r'
}

capture() {
  local iter="$1" tcp="$2" dns="$3"
  local dir="$OUT_DIR/broken-iter-$iter"
  mkdir -p "$dir"
  echo "iteration=$iter tcp=$tcp dns=$dns at=$(date -Iseconds)" > "$dir/summary.txt"

  # logcat без фильтра по приоритету: `[vpn] onDestroy` логируется на Log.d.
  adb logcat -d -v time '*:D' > "$dir/logcat-full.txt" 2>&1 || true

  # Выжимка: номера fd (§329), маркеры teardown-путей, warn ядра о acceptLoop.
  grep -aE '\[fd §329\]|doForceStop ENTER|Timeout in |\[vpn\] onDestroy|accept loop' \
    "$dir/logcat-full.txt" > "$dir/markers.txt" 2>/dev/null || true

  curl -sf -m 5 -H "$HDR_AUTH" "$LB_BASE/state" > "$dir/state.json" 2>/dev/null || true
  adb shell "ss -tn" > "$dir/ss-tn.txt" 2>&1 || true

  echo "  → артефакты: $dir"
  if [[ -s "$dir/markers.txt" ]]; then
    echo "  ─── маркеры ───"
    sed 's/^/  /' "$dir/markers.txt" | tail -30
  fi
}

# ─── серия ──────────────────────────────────────────────────────────

echo "§329 репро: $ITERATIONS итераций, интервал ${INTERVAL}с → $OUT_DIR"
echo "Процесс должен быть «грязным» (fd-churn). Ctrl-C прерывает."
echo

# Чистим буфер, чтобы logcat на красной итерации содержал только эту серию.
adb logcat -c >/dev/null 2>&1 || true

BROKEN=0
for ((i = 1; i <= ITERATIONS; i++)); do
  RECONNECT_HTTP="$(curl -s -m 15 -o /dev/null -w '%{http_code}' \
    -X POST -H "$HDR_AUTH" "$LB_BASE/action/reconnect" 2>/dev/null || echo 000)"

  sleep "$INTERVAL"

  TCP="$(probe_tcp)"
  if [[ "$TCP" == "OK" ]]; then
    printf '  %3d/%d  reconnect=%s  tcp=OK\n' "$i" "$ITERATIONS" "$RECONNECT_HTTP"
    continue
  fi

  # TCP красный — проверяем UDP/DNS, он разделяет два диагноза.
  DNS="$(probe_dns)"
  printf '  %3d/%d  reconnect=%s  tcp=FAIL dns=%s  ← ПОЛОМКА\n' \
    "$i" "$ITERATIONS" "$RECONNECT_HTTP" "$DNS"
  BROKEN=$((BROKEN + 1))
  capture "$i" "$TCP" "$DNS"

  if [[ "$DNS" != "OK" ]]; then
    echo "  ⚠ DNS тоже красный — похоже упал весь туннель, а не acceptLoop." >&2
    echo "    Проверь, поднялся ли VPN вообще (state.json в артефактах)." >&2
  fi

  if [[ $KEEP_GOING -eq 0 ]]; then
    echo
    echo "Останов на первой поломке (--keep-going чтобы продолжать)."
    break
  fi
done

echo
if [[ $BROKEN -eq 0 ]]; then
  echo "✓ $ITERATIONS итераций чисто. При статистике 3/108 это не опровержение —"
  echo "  погоняй телефон руками подольше и повтори серию."
  exit 0
fi

echo "✗ Поймано поломок: $BROKEN. Артефакты: $OUT_DIR"
echo
echo "Что смотреть (docs/spec/tasks/329-fd-close-trigger-dynamic-capture.md, шаги 3-4):"
echo "  1. errno в warn'е ядра «accept loop died» — называет путь убийства:"
echo "     ErrNetClosing ⇒ закрытие через Go-объект; EBADF/ENOTSOCK ⇒ голый close."
echo "  2. [fd §329] — совпал ли номер fd из close(<путь>) с номером openTun."
echo "  3. Маркеры doForceStop ENTER / Timeout in / [vpn] onDestroy: их ОТСУТСТВИЕ"
echo "     подтверждает выводы аудита (рестарт шёл штатно)."
echo
echo "Снять полный snapshot: ./scripts/lxbox-diag.sh"
exit 2
