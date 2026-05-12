#!/usr/bin/env bash
# Sync `app/pubspec.yaml` `version:` line с current git state.
#
# - versionName = "${last_tag#v}" если HEAD на tag commit'е (clean release).
#   Иначе "${last_tag#v}-dev.${commits_since_last_tag}".
# - versionCode = git rev-list --count HEAD (monotonic с commits).
#
# Запускается:
#   • .githooks/pre-commit — auto, на каждый `git commit` (если hook включён
#     через `git config core.hooksPath .githooks`, см. scripts/setup-hooks.sh).
#   • scripts/build-local-apk.sh — defensive перед build'ом.
#   • Вручную при необходимости.
#
# Не зависит от --dart-define, не трогает Dart-код. Single source = pubspec.

set -euo pipefail

cd "$(dirname "$0")/.."

TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
SINCE=$(git rev-list "$TAG..HEAD" --count 2>/dev/null || echo "0")
TOTAL=$(git rev-list HEAD --count 2>/dev/null || echo "1")
VER="${TAG#v}"
if [ "$SINCE" != "0" ]; then
  VER="$VER-dev.$SINCE"
fi
# +1 учитывает текущий commit (для pre-commit hook — он добавит commit после нас).
LINE="version: ${VER}+$((TOTAL + 1))"

CURRENT=$(grep -E "^version:" app/pubspec.yaml || echo "")
if [ "$CURRENT" = "$LINE" ]; then
  exit 0
fi

sed -i.bak -E "s/^version: .*/${LINE}/" app/pubspec.yaml
rm -f app/pubspec.yaml.bak
echo "sync-pubspec-version: $LINE"
