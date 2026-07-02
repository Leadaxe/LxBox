#!/usr/bin/env bash
# Post-crash quick capture для build 10222.
#
# Запускать СРАЗУ после crash'а (пока ring-buffer logcat'a не overwrite'нулся).
# Захватывает:
#   - logcat -d -t 5000 (последние 5000 строк, всё что есть в ring)
#   - dropbox crash entries (ANR / native_crash / system_app_crash)
#   - tombstones list (даты, размеры — без contents т.к. permission)
#   - dumpsys для нашего пакета (process state, memory, services)
#   - tun0 / route table state (если VPN ещё активен)
#   - device info (versionCode проверка)
#
# Output: /tmp/lxbox-crash-<ts>/
#
# Usage:
#   ./scripts/diag/post-crash-capture.sh
#   ./scripts/diag/post-crash-capture.sh --device 192.168.1.71:5555  # explicit adb target

set -uo pipefail

TS="$(date +%Y-%m-%d-%H%M%S)"
OUT_DIR="/tmp/lxbox-crash-$TS"
DEVICE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_ARG="-s $2"; shift 2 ;;
    -o|--out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '1,25p' "$0" | sed 's|^# \?||'; exit 0 ;;
    *) echo "✗ Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# adb path bootstrap (§219 — общий helper)
# shellcheck source=../lib/ensure-adb.sh
. "$(dirname "$0")/../lib/ensure-adb.sh"
if ! ensure_adb_path; then
  echo "✗ adb not in PATH" >&2; exit 1
fi

# Wait for device (max 30s) — крэш-захват может потребовать reconnect
echo "→ waiting for adb device..."
for i in 1 2 3 4 5 6; do
  if adb $DEVICE_ARG get-state >/dev/null 2>&1; then
    break
  fi
  # Try reconnect to phone via wifi if no usb
  if [ -z "$DEVICE_ARG" ]; then
    adb connect 192.168.1.71:5555 >/dev/null 2>&1 || true
  fi
  sleep 5
done

if ! adb $DEVICE_ARG get-state >/dev/null 2>&1; then
  echo "✗ adb device unreachable" >&2; exit 1
fi

mkdir -p "$OUT_DIR"
echo "→ snapshot dir: $OUT_DIR"

# 1. Device + app version
echo "→ device.txt"
{
  echo "=== ts: $(date) ==="
  echo "=== getprop ==="
  adb $DEVICE_ARG shell getprop | grep -iE "ro.product.model|ro.build.version|ro.product.cpu.abi" | head -10
  echo
  echo "=== dumpsys package com.leadaxe.lxbox | head ==="
  adb $DEVICE_ARG shell "dumpsys package com.leadaxe.lxbox 2>/dev/null | head -30"
} > "$OUT_DIR/device.txt" 2>&1

# 2. Logcat dump — последние 5000 строк всего (без filter — фильтруем потом grep'ом)
echo "→ logcat-all.txt (5000 lines)"
adb $DEVICE_ARG logcat -d -t 5000 > "$OUT_DIR/logcat-all.txt" 2>&1

# Прицельный фильтр на наш TAG + crash signatures
echo "→ logcat-lxbox.txt (filtered)"
grep -E "BoxVpnService|libbox|VpnPlugin|BoxApplication|sing-box|FATAL|SIGABRT|tombstone|com.leadaxe.lxbox|libc|DEBUG.*pid" \
  "$OUT_DIR/logcat-all.txt" > "$OUT_DIR/logcat-lxbox.txt" 2>&1 || true

# 3. Native crash dropbox (если есть)
echo "→ dropbox.txt"
{
  echo "=== dropbox entries last 24h ==="
  adb $DEVICE_ARG shell "dumpsys dropbox --print 2>/dev/null | head -200"
} > "$OUT_DIR/dropbox.txt" 2>&1

# 4. tombstones list (без чтения — нужен root для contents)
echo "→ tombstones.txt"
adb $DEVICE_ARG shell "ls -la /data/tombstones/ 2>/dev/null" > "$OUT_DIR/tombstones.txt" 2>&1 || true

# 5. dumpsys для нашего сервиса
echo "→ dumpsys-service.txt"
{
  echo "=== dumpsys activity service com.leadaxe.lxbox/.vpn.BoxVpnService ==="
  adb $DEVICE_ARG shell "dumpsys activity service com.leadaxe.lxbox/.vpn.BoxVpnService 2>/dev/null"
  echo
  echo "=== dumpsys meminfo ==="
  adb $DEVICE_ARG shell "dumpsys meminfo com.leadaxe.lxbox 2>/dev/null | head -50"
} > "$OUT_DIR/dumpsys-service.txt" 2>&1

# 6. tun0 / network state (если VPN жив)
echo "→ network.txt"
{
  echo "=== ip a show tun0 ==="
  adb $DEVICE_ARG shell "ip a show tun0 2>/dev/null"
  echo
  echo "=== ip route ==="
  adb $DEVICE_ARG shell "ip route 2>/dev/null"
  echo
  echo "=== ip rule ==="
  adb $DEVICE_ARG shell "ip rule 2>/dev/null"
} > "$OUT_DIR/network.txt" 2>&1

# 7. Краткое summary в stdout
echo
echo "=== SUMMARY ==="
echo "snapshot: $OUT_DIR"
echo
if grep -qE "FATAL|SIGABRT" "$OUT_DIR/logcat-all.txt" 2>/dev/null; then
  echo "✗ FATAL/SIGABRT обнаружено в logcat:"
  grep -E "FATAL|SIGABRT|signal|fault addr|Abort message" "$OUT_DIR/logcat-all.txt" | head -10
else
  echo "○ нет FATAL/SIGABRT в logcat"
fi
echo
if [ -s "$OUT_DIR/logcat-lxbox.txt" ]; then
  echo "Last 20 BoxVpnService events:"
  grep BoxVpnService "$OUT_DIR/logcat-lxbox.txt" | tail -20
else
  echo "○ нет BoxVpnService events в captured logcat"
fi
