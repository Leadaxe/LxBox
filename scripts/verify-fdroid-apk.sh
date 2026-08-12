#!/usr/bin/env bash
# §380 — сверка APK из сборки F-Droid с релизным APK из GitHub.
#
# Повторяет то, что делает их `check apk`: содержимое архива должно совпасть
# побитово, иначе версия не выйдет в каталог (режим reproducible builds
# включён — см. docs/FDROID.md).
#
# Проверяет ДВЕ вещи, и обе обязательны:
#
#   1. Файлы внутри zip — пофайловый SHA-256. `META-INF/` исключается: подписи
#      разными ключами сравнивать бессмысленно.
#
#   2. APK Signing Block — он лежит МЕЖДУ данными и Central Directory, то есть
#      вне zip-структуры, и пофайловое сравнение его не видит. На этом уже
#      обожглись: 455 файлов сходились, а `check apk` падал на 7185 байт
#      `DEPENDENCY METADATA` (блок AGP, гасится `dependenciesInfo` в
#      app/android/app/build.gradle.kts).
#
# Usage:
#   ./scripts/verify-fdroid-apk.sh <fdroid.apk> <github.apk>
#   ./scripts/verify-fdroid-apk.sh --blocks <apk>      # только блоки подписи
#
# Exit:
#   0 — совпадает
#   1 — расхождение или нет файла
#
# Зависимости: bash, python3, unzip, shasum.

set -uo pipefail

blocks() {
  python3 - "$1" <<'PY'
import struct, sys
p = sys.argv[1]
f = open(p, 'rb').read()
i = f.rfind(b'APK Sig Block 42')
if i < 0:
    print('  подписи нет (неподписанный APK)')
    sys.exit(0)
names = {
    0x7109871a: 'v2 signature',
    0xf05368c0: 'v3 signature',
    0x71777777: 'v3.1 signature',
    0x42726577: 'padding',
    0x504b4453: 'DEPENDENCY METADATA',
}
q = i + 16 - 8 - struct.unpack('<Q', f[i-8:i])[0] + 8
bad = False
while q < i - 8:
    ln = struct.unpack('<Q', f[q:q+8])[0]
    bid = struct.unpack('<I', f[q+8:q+12])[0]
    nm = names.get(bid, f'0x{bid:08x} (неизвестный)')
    print(f'  {nm:24} {ln:>8} байт')
    if bid == 0x504b4453 or bid not in names:
        bad = True
    q += 8 + ln
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" = "--blocks" ]; then
  A="${2:?нужен путь к APK}"
  [ -f "$A" ] || { echo "нет файла: $A" >&2; exit 1; }
  echo "=== блоки подписи: $(basename "$A") ==="
  blocks "$A" || { echo; echo "  ⚠ лишний блок — F-Droid такой APK отвергнет"; exit 1; }
  exit 0
fi

FD="${1:?нужен APK из F-Droid}"
GH="${2:?нужен APK из GitHub}"
for f in "$FD" "$GH"; do
  [ -f "$f" ] || { echo "нет файла: $f" >&2; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

echo "=== размеры ==="
printf '  F-Droid: %s байт\n' "$(size "$FD")"
printf '  GitHub : %s байт\n' "$(size "$GH")"
echo "  (разница нормальна: блок подписи у сторон разного размера)"
echo

unzip -q -o "$FD" -d "$TMP/fd"
unzip -q -o "$GH" -d "$TMP/gh"
rm -rf "$TMP/fd/META-INF" "$TMP/gh/META-INF"

hashes() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }
hashes "$TMP/fd" > "$TMP/fd.txt"
hashes "$TMP/gh" > "$TMP/gh.txt"

echo "=== состав ==="
printf '  файлов в F-Droid: %s\n' "$(wc -l < "$TMP/fd.txt" | tr -d ' ')"
printf '  файлов в GitHub : %s\n' "$(wc -l < "$TMP/gh.txt" | tr -d ' ')"
echo

awk '{print $2}' "$TMP/fd.txt" | sort > "$TMP/fd.names"
awk '{print $2}' "$TMP/gh.txt" | sort > "$TMP/gh.names"
ONLY_FD=$(comm -23 "$TMP/fd.names" "$TMP/gh.names")
ONLY_GH=$(comm -13 "$TMP/fd.names" "$TMP/gh.names")

[ -n "$ONLY_FD" ] && { echo "=== только в F-Droid ==="; echo "$ONLY_FD" | sed 's/^/  /'; echo; }
[ -n "$ONLY_GH" ] && { echo "=== только в GitHub ==="; echo "$ONLY_GH" | sed 's/^/  /'; echo; }

echo "=== файлы с разным содержимым ==="
DIFFS=$(join -j 2 <(sort -k2 "$TMP/fd.txt") <(sort -k2 "$TMP/gh.txt") \
        | awk '$2 != $3 {print $1}' | sort)
if [ -z "$DIFFS" ]; then
  echo "  нет — содержимое идентично"
else
  echo "$DIFFS" | while read -r f; do
    printf '  %-58s %s / %s байт\n' "$f" "$(size "$TMP/fd/$f")" "$(size "$TMP/gh/$f")"
  done
fi
echo

echo "=== блоки подписи (вне zip, пофайловое сравнение их не видит) ==="
echo "--- F-Droid ---"; blocks "$FD"; FD_BLOCKS=$?
echo "--- GitHub ---";  blocks "$GH"; GH_BLOCKS=$?
echo

echo "=== вердикт ==="
FAIL=0
[ -n "$DIFFS" ]   && { echo "  ✗ расходится содержимое: $(echo "$DIFFS" | grep -c .) файлов"; FAIL=1; }
[ -n "$ONLY_FD$ONLY_GH" ] && { echo "  ✗ разный набор файлов"; FAIL=1; }
[ "$GH_BLOCKS" -ne 0 ] && { echo "  ✗ релизный APK несёт лишний блок подписи — F-Droid его отвергнет"; FAIL=1; }
[ "$FD_BLOCKS" -ne 0 ] && { echo "  ✗ APK из F-Droid несёт лишний блок подписи"; FAIL=1; }
[ "$FAIL" -eq 0 ] && echo "  СОВПАДАЕТ"
exit $FAIL
