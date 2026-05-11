#!/usr/bin/env bash
# §049 Phase G7 — pre-allocate 50 dummy Java->Go refs to push handler past 42.
# If crash STILL says "Unknown reference: 42" → 42 is libbox-internal, not our handler.
#
# Workflow:
#   1. Backup current PIW and BoxApplication
#   2. Apply patches: F12.3 enabled + dummy pre-allocation
#   3. Build, install, run, capture logcat
#   4. Restore originals
#   5. Build clean stable + reinstall
#
# CAUTION: this LEAVES the phone with stable build at the end. Safe.

set -euo pipefail

cd "$(dirname "$0")/../.."
DEVICE="${LXBOX_DEVICE:-192.168.1.71:5555}"

PIW_FILE=app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt
APP_FILE=app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt
PIW_BAK=$(mktemp)
APP_BAK=$(mktemp)

cleanup() {
  echo "── cleanup: restore originals ──"
  cp "$PIW_BAK" "$PIW_FILE"
  cp "$APP_BAK" "$APP_FILE"
  echo "Building stable v1.7.1 final + installing on $DEVICE..."
  bash scripts/build-local-apk.sh --build-number=10999 2>&1 | tail -3
  adb -s "$DEVICE" install -r app/build/app/outputs/flutter-apk/app-release.apk 2>&1 | tail -3
  rm -f "$PIW_BAK" "$APP_BAK"
}
trap cleanup EXIT

echo "── backup ──"
cp "$PIW_FILE" "$PIW_BAK"
cp "$APP_FILE" "$APP_BAK"

echo "── apply F12.3 enabled (provoke crash) ──"
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt")
src = p.read_text()
new_impl = '''
    /// Phase G7 diagnostic — F12.3 enabled to provoke crash.
    @Suppress("DEPRECATION")
    override fun readWIFIState(): WIFIState? {
        val wifiInfo = BoxApplication.wifiManager.connectionInfo ?: return null
        var ssid = wifiInfo.ssid
        if (ssid == "<unknown ssid>") return WIFIState("", "")
        if (ssid.startsWith("\\"") && ssid.endsWith("\\""))
            ssid = ssid.substring(1, ssid.length - 1)
        return WIFIState(ssid, wifiInfo.bssid ?: "")
    }
'''
import re
src = re.sub(
    r"override fun readWIFIState\(\): WIFIState\? = null",
    new_impl.strip(),
    src
)
p.write_text(src)
PYEOF

echo "── apply dummy pre-allocation in BoxApplication ──"
python3 - << 'PYEOF'
import pathlib
p = pathlib.Path("app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt")
src = p.read_text()
src = src.replace(
    "Seq.setContext(application)",
    """Seq.setContext(application)

        // Phase G7: pre-allocate 50 dummies to push handler refnum past 42.
        // Refnums 42..91 will be these. Real handler gets 92+.
        val dummyHandlers = (0 until 50).map { Object() }
        dummyHandlers.forEach { go.Seq.incRef(it) }
        android.util.Log.e("BoxApp", "[G7] reserved refnums 42..91 with 50 dummies")"""
)
p.write_text(src)
PYEOF

echo "── build ──"
bash scripts/build-local-apk.sh --build-number=10300 2>&1 | tail -3

echo "── install ──"
adb -s "$DEVICE" install -r app/build/app/outputs/flutter-apk/app-release.apk 2>&1 | tail -3

echo "── 5 trials ──"
for i in 1 2 3 4 5; do
  echo "─── Trial $i ───"
  adb -s "$DEVICE" logcat -c
  adb -s "$DEVICE" shell am force-stop com.leadaxe.lxbox
  sleep 2
  adb -s "$DEVICE" shell am start -n com.leadaxe.lxbox/.MainActivity > /dev/null
  sleep 12
  echo "[G7 marker]:"
  adb -s "$DEVICE" logcat -d 2>&1 | grep -E "G7" | head -2
  echo "[Crash]:"
  adb -s "$DEVICE" logcat -d 2>&1 | grep -E "Abort message" | head -1
  echo "[Process]:"
  adb -s "$DEVICE" shell "ps -A | grep leadaxe | head -1"
done

echo ""
echo "─────────────────────────────────────────"
echo "EXPECTED:"
echo "  - 'G7 marker' log shows refnums 42..91 reserved"
echo "  - If crash 'Unknown reference: 42' STILL → 42 is libbox-internal"
echo "  - If crash NOT 42 (e.g. 92+) → 42 was our handler all along"
echo "─────────────────────────────────────────"
