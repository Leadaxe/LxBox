#!/usr/bin/env bash
# Локальная сборка APK с пометкой "local" + git describe.
# CI-сборка в .github/workflows/ci.yml зовёт `flutter build` напрямую без
# этих --dart-define'ов, поэтому release-APK из CI не помечается как local.

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
BUILD_TIME=$(date -u +"%Y-%m-%d %H:%M UTC")

echo "─── Local build ───────────────────────────────────────"
echo "  git describe : $GIT_DESC"
echo "  last tag     : ${LAST_TAG:-<none>}"
echo "  commits since: $COMMITS_SINCE"
echo "  short SHA    : $GIT_SHA"
echo "  built at     : $BUILD_TIME"
echo "───────────────────────────────────────────────────────"

cd app

flutter build apk --release \
  --target-platform android-arm64 \
  --dart-define=BUILD_LOCAL=true \
  --dart-define=BUILD_GIT_DESC="$GIT_DESC" \
  --dart-define=BUILD_GIT_SHA="$GIT_SHA" \
  --dart-define=BUILD_LAST_TAG="$LAST_TAG" \
  --dart-define=BUILD_COMMITS_SINCE_TAG="$COMMITS_SINCE" \
  --dart-define=BUILD_TIME="$BUILD_TIME" \
  "$@"
