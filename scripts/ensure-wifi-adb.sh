#!/usr/bin/env bash
# Гарантирует что wifi-adb работает: проверка → если уже OK, выходит;
# если нет — поднимает с USB-подключения (tcpip 5555 + connect <ip>:5555).
#
# Usage:
#   ./scripts/ensure-wifi-adb.sh             # auto: check, поднять если надо
#   ./scripts/ensure-wifi-adb.sh --check     # только проверка, exit 0/1, ничего не меняет
#   ./scripts/ensure-wifi-adb.sh --port 5555 # custom TCP port (default 5555)
#
# Exit:
#   0  — wifi-adb работает (был или подняли)
#   1  — невозможно поднять (нет USB / tcpip failed / connect failed)

set -euo pipefail

CHECK_ONLY=0
PORT=5555

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  CHECK_ONLY=1; shift ;;
    --port)   PORT="$2"; shift 2 ;;
    -h|--help) head -n 14 "$0" | sed 's|^# ||;s|^#||'; exit 0 ;;
    *) echo "✗ Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── adb path bootstrap ─────────────────────────────────────────────

if ! command -v adb >/dev/null 2>&1; then
  export PATH="${ANDROID_SDK_ROOT:-/usr/local/share/android-commandlinetools}/platform-tools:$PATH"
  if ! command -v adb >/dev/null 2>&1; then
    echo "✗ adb not found in PATH" >&2
    exit 1
  fi
fi

# ─── Step 1: уже подключено по wifi? ────────────────────────────────

WIFI_DEVICE=$(adb devices | awk '/\tdevice$/ && /:/ {print $1; exit}')

if [ -n "$WIFI_DEVICE" ]; then
  echo "✅ Wifi-adb уже работает: $WIFI_DEVICE"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "✗ Wifi-adb не подключён."
  exit 1
fi

# ─── Step 2: ищем USB-устройство для bootstrap'а ────────────────────

USB_DEVICE=$(adb devices | awk '/\tdevice$/ && !/:/ {print $1; exit}')

if [ -z "$USB_DEVICE" ]; then
  echo "✗ Ни USB, ни wifi устройства не найдено." >&2
  echo "  Подключи USB-кабель и повтори." >&2
  exit 1
fi

echo "→ USB device: $USB_DEVICE — bootstrap'аю wifi-adb"

# ─── Step 3: tcpip + connect ────────────────────────────────────────

echo "→ adb -s $USB_DEVICE tcpip $PORT"
adb -s "$USB_DEVICE" tcpip "$PORT" >/dev/null 2>&1
sleep 2  # adbd needs a moment to rebind

# IP from wlan0
IP=$(adb -s "$USB_DEVICE" shell ip -4 addr show wlan0 2>/dev/null \
      | grep -oE 'inet [0-9.]+' | awk '{print $2}')

if [ -z "$IP" ]; then
  echo "✗ Не получилось определить IP wlan0 устройства." >&2
  echo "  Wifi выключен / устройство не в сети?" >&2
  exit 1
fi

echo "→ adb connect $IP:$PORT"
CONNECT_OUT=$(adb connect "$IP:$PORT" 2>&1)
echo "  $CONNECT_OUT"

if ! echo "$CONNECT_OUT" | grep -q "connected"; then
  echo "✗ adb connect failed." >&2
  exit 1
fi

# ─── Sanity check ──────────────────────────────────────────────────

sleep 1
WIFI_DEVICE=$(adb devices | awk '/\tdevice$/ && /:/ {print $1; exit}')
if [ -z "$WIFI_DEVICE" ]; then
  echo "✗ Connect прошёл, но устройство не появилось в списке." >&2
  adb devices >&2
  exit 1
fi

echo "✅ Wifi-adb up: $WIFI_DEVICE"
echo "   Можешь отключать USB."
