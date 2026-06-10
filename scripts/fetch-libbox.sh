#!/usr/bin/env bash
# §104 — скачивает ядро sing-box-lx (libbox.aar) из GitHub Releases форка
# Leadaxe/sing-box-lx с проверкой SHA256.
#
# Версия пинится в app/android/libbox.version (single source of truth для
# local + CI). Override: ./scripts/fetch-libbox.sh v1.13.13-lx.N
#
# Идемпотентен: если в libs/ уже лежит AAR той же версии (маркер
# .libbox.version) — выходит сразу. Используется build-local-apk.sh и CI
# (ci.yml → android job → "Fetch sing-box-lx core").

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="Leadaxe/sing-box-lx"
VER="${1:-$(tr -d '[:space:]' < app/android/libbox.version)}"
DEST="app/android/app/libs"
AAR="libbox-${VER#v}.aar"
BASE_URL="https://github.com/$REPO/releases/download/$VER"

if [ -f "$DEST/libbox.aar" ] && [ -f "$DEST/.libbox.version" ] \
   && [ "$(cat "$DEST/.libbox.version")" = "$VER" ]; then
  echo "✓ libbox.aar уже $VER — skip"
  exit 0
fi

echo "→ Fetching $AAR ($REPO @ $VER)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 3 -o "$TMP/$AAR" "$BASE_URL/$AAR"
curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$BASE_URL/SHA256SUMS"

# sha256sum (linux/CI) или shasum -a 256 (macOS).
if command -v sha256sum >/dev/null 2>&1; then
  SHACMD="sha256sum"
else
  SHACMD="shasum -a 256"
fi
(
  cd "$TMP"
  grep -E "  ?$AAR\$" SHA256SUMS > expected.sum
  $SHACMD -c expected.sum
)

mkdir -p "$DEST"
mv "$TMP/$AAR" "$DEST/libbox.aar"
printf '%s' "$VER" > "$DEST/.libbox.version"
echo "✅ $DEST/libbox.aar ← $VER"
