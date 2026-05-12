#!/usr/bin/env bash
# Локальная сборка APK с пометкой "local" + git describe.
#
# Tag — единственный источник правды для версии (см. docs/RELEASE_PROCESS.md).
# Этот скрипт временно переписывает app/pubspec.yaml (`version:`) на
# `<last-tag>-dev.<commits-since-tag>+<commits-total>` перед `flutter build`,
# и восстанавливает на EXIT через `git checkout`. Никаких commit'ов в репо.
#
# CI-сборка в .github/workflows/ci.yml использует тот же подход через
# pubspec sed + git rev-list — pubspec.yaml в репо это всегда placeholder
# `0.0.0-dev+0`.

set -euo pipefail

# Ensure flutter / Android SDK are on PATH even when invoked from a clean
# shell (e.g. background tasks, IDEs). No-op if already configured.
if ! command -v flutter >/dev/null 2>&1; then
  export PATH="/Users/macbook/projects/flutter-sdk/bin:$PATH"
fi
: "${ANDROID_SDK_ROOT:=/usr/local/share/android-commandlinetools}"
export ANDROID_SDK_ROOT

cd "$(dirname "$0")/.."

GIT_DESC=$(git describe --tags --long --dirty 2>/dev/null || echo "no-tag")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
COMMITS_SINCE=$(
  if [ -n "$LAST_TAG" ]; then
    git rev-list "${LAST_TAG}..HEAD" --count 2>/dev/null || echo "0"
  else
    echo "0"
  fi
)
COMMITS_TOTAL=$(git rev-list HEAD --count 2>/dev/null || echo "0")
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M UTC")

# versionName / versionCode из git
LAST_VERSION="${LAST_TAG#v}"  # "v1.8.1" → "1.8.1"; "" если no tag
if [ -z "$LAST_VERSION" ]; then
  LAST_VERSION="0.0.0"
fi
if [ "$COMMITS_SINCE" = "0" ]; then
  # На самом tag — version = X.Y.Z (clean)
  VERSION_NAME="$LAST_VERSION"
else
  # Между тегами — version = X.Y.Z-dev.N
  VERSION_NAME="${LAST_VERSION}-dev.${COMMITS_SINCE}"
fi
VERSION_CODE="$COMMITS_TOTAL"

echo "─── Local build ───────────────────────────────────────"
echo "  git describe   : $GIT_DESC"
echo "  last tag       : ${LAST_TAG:-<none>}"
echo "  commits since  : $COMMITS_SINCE"
echo "  commits total  : $COMMITS_TOTAL"
echo "  short SHA      : $GIT_SHA"
echo "  built at       : $BUILD_TIME"
echo "  injecting ver  : $VERSION_NAME+$VERSION_CODE"
echo "───────────────────────────────────────────────────────"

# Restore pubspec.yaml on any exit (success / failure / Ctrl+C).
trap "git checkout -- app/pubspec.yaml 2>/dev/null || true" EXIT

# Inject version into pubspec.yaml (sed in-place, BSD/macOS compatible).
sed -i.bak -E "s/^version: .*/version: ${VERSION_NAME}+${VERSION_CODE}/" app/pubspec.yaml
rm -f app/pubspec.yaml.bak

cd app

export LXBOX_ABI_FILTER=arm64-v8a

flutter build apk --release \
  --target-platform android-arm64 \
  --dart-define=BUILD_LOCAL=true \
  --dart-define=BUILD_GIT_DESC="$GIT_DESC" \
  --dart-define=BUILD_GIT_SHA="$GIT_SHA" \
  --dart-define=BUILD_LAST_TAG="$LAST_TAG" \
  --dart-define=BUILD_COMMITS_SINCE_TAG="$COMMITS_SINCE" \
  --dart-define=BUILD_TIME="$BUILD_TIME" \
  "$@"
