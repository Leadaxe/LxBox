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
  echo "✓ libbox.aar already $VER — skipping"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Ветка core-1.15 (стенд ядра 1.15 без тега): если рядом с пином лежит
# app/android/libbox.run (`<run_id> <artifact> <sha256 libbox.aar>`), AAR
# берётся из артефакта прогона on-demand сборки ядра (lx-build.yml) через
# `gh run download`, а не из релиза. Нужен GH_TOKEN (в CI — github.token).
RUN_PIN="app/android/libbox.run"
if [ -z "${1:-}" ] && [ -f "$RUN_PIN" ]; then
  read -r RUN_ID ART SHA < "$RUN_PIN"
  echo "→ Fetching libbox.aar from $REPO run $RUN_ID (artifact $ART)"
  gh run download "$RUN_ID" -R "$REPO" -n "$ART" -D "$TMP/art"
  if command -v sha256sum >/dev/null 2>&1; then
    GOT="$(sha256sum "$TMP/art/libbox.aar" | cut -d' ' -f1)"
  else
    GOT="$(shasum -a 256 "$TMP/art/libbox.aar" | cut -d' ' -f1)"
  fi
  [ "$GOT" = "$SHA" ] || { echo "✗ sha256 mismatch: $GOT != $SHA" >&2; exit 1; }
  mkdir -p "$DEST"
  mv "$TMP/art/libbox.aar" "$DEST/libbox.aar"
  printf '%s' "$VER" > "$DEST/.libbox.version"
  echo "✅ $DEST/libbox.aar ← run $RUN_ID ($VER)"
  exit 0
fi

echo "→ Fetching $AAR ($REPO @ $VER)"

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
