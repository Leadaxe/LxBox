#!/usr/bin/env bash
# Install свежесобранный APK на устройство.
#
# Auto-detect device (предпочитает wifi если есть, иначе USB), force-stop,
# install -r, launch, восстанавливает adb-forward для Debug API (порт 9269).
#
# Usage:
#   ./scripts/install-apk.sh                    # release APK на auto-detected device
#   ./scripts/install-apk.sh --debug            # debug APK вместо release
#   ./scripts/install-apk.sh --apk <path>       # конкретный APK
#   ./scripts/install-apk.sh --device <id>      # конкретное устройство (если несколько)
#   ./scripts/install-apk.sh --no-launch        # не запускать app после install
#   ./scripts/install-apk.sh --no-forward       # не восстанавливать adb forward 9269
#   ./scripts/install-apk.sh --debug-port 9269  # custom debug-api port для forward
#
# Exit codes:
#   0  — install OK
#   1  — usage error / no device / install failed

set -euo pipefail

cd "$(dirname "$0")/.."

# ─── Args ──────────────────────────────────────────────────────────

APK=""
APK_KIND="release"
DEVICE=""
LAUNCH=1
FORWARD=1
DEBUG_PORT=9269

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)       APK_KIND="debug"; shift ;;
    --release)     APK_KIND="release"; shift ;;
    --apk)         APK="$2"; shift 2 ;;
    --device)      DEVICE="$2"; shift 2 ;;
    --no-launch)   LAUNCH=0; shift ;;
    --no-forward)  FORWARD=0; shift ;;
    --debug-port)  DEBUG_PORT="$2"; shift 2 ;;
    -h|--help)
      head -n 18 "$0" | sed 's|^# ||;s|^#||'
      exit 0
      ;;
    *)
      echo "✗ Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APK" ]; then
  APK="app/build/app/outputs/flutter-apk/app-${APK_KIND}.apk"
fi

if [ ! -f "$APK" ]; then
  echo "✗ APK not found: $APK" >&2
  echo "  Build it first:" >&2
  echo "    ./scripts/build-local-apk.sh        # release with LOCAL BUILD badge" >&2
  echo "    or:  flutter build apk --debug" >&2
  exit 1
fi

# ─── adb path bootstrap ────────────────────────────────────────────

if ! command -v adb >/dev/null 2>&1; then
  export PATH="${ANDROID_SDK_ROOT:-/usr/local/share/android-commandlinetools}/platform-tools:$PATH"
  if ! command -v adb >/dev/null 2>&1; then
    echo "✗ adb not found in PATH (or under ANDROID_SDK_ROOT/platform-tools)" >&2
    exit 1
  fi
fi

# ─── Device selection ─────────────────────────────────────────────

if [ -z "$DEVICE" ]; then
  # Список online устройств. Предпочтение — wifi (содержит ':' в id),
  # т.к. меньше шансов что юзер дёрнет кабель посреди install'а.
  # Используем while-loop для совместимости с bash 3.2 (mapfile есть с 4+,
  # default macOS — 3.2).
  DEVICES=()
  while IFS= read -r line; do
    [ -n "$line" ] && DEVICES+=("$line")
  done < <(adb devices | awk '/\tdevice$/ {print $1}')
  if [ "${#DEVICES[@]}" -eq 0 ]; then
    echo "✗ No devices attached." >&2
    echo "  Plug USB or run: ./scripts/ensure-wifi-adb.sh" >&2
    exit 1
  fi
  # Pick first wifi-style id (contains ':'), else first available
  for d in "${DEVICES[@]}"; do
    if [[ "$d" == *:* ]]; then DEVICE="$d"; break; fi
  done
  if [ -z "$DEVICE" ]; then
    DEVICE="${DEVICES[0]}"
  fi
  if [ "${#DEVICES[@]}" -gt 1 ]; then
    echo "ℹ Multiple devices found, using: $DEVICE"
    echo "  (Override with: --device <id>)"
  fi
fi

echo "→ Device: $DEVICE"
echo "→ APK:    $APK ($(du -h "$APK" | cut -f1))"

# ─── Install ──────────────────────────────────────────────────────

PKG="com.leadaxe.lxbox"

echo "→ Installing..."
INSTALL_OUTPUT=$(adb -s "$DEVICE" install -r "$APK" 2>&1)
echo "$INSTALL_OUTPUT" | tail -3

if ! echo "$INSTALL_OUTPUT" | grep -q "Success"; then
  echo "✗ Install failed" >&2
  if echo "$INSTALL_OUTPUT" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
    echo "  Signature mismatch — старый APK подписан другим ключом." >&2
    echo "  Варианты:" >&2
    echo "    1. adb -s $DEVICE uninstall $PKG  (потеряются настройки/подписки)" >&2
    echo "    2. Собери APK тем же ключом что установленный (release vs debug)" >&2
  fi
  exit 1
fi

# ─── Force-stop + launch ──────────────────────────────────────────

if [ "$LAUNCH" -eq 1 ]; then
  echo "→ Force-stopping app..."
  adb -s "$DEVICE" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  echo "→ Launching..."
  adb -s "$DEVICE" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 \
    >/dev/null 2>&1 || true
fi

# ─── Restore Debug API forward ────────────────────────────────────

if [ "$FORWARD" -eq 1 ]; then
  echo "→ adb forward tcp:$DEBUG_PORT tcp:$DEBUG_PORT"
  adb -s "$DEVICE" forward tcp:"$DEBUG_PORT" tcp:"$DEBUG_PORT" >/dev/null 2>&1 || \
    echo "  (forward failed — Debug API недоступен с хоста, но app работает)"
fi

echo "✅ Installed to $DEVICE"
