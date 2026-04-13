#!/usr/bin/env bash
# Полная настройка: создать keystore при отсутствии и залить секреты в GitHub Actions.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

KEYSTORE="$REPO_ROOT/app/android/upload-keystore.jks"

if [[ ! -f "$KEYSTORE" ]]; then
  echo "No keystore at app/android/upload-keystore.jks — creating..."
  "$SCRIPT_DIR/init-android-release-keystore.sh"
fi

echo "Uploading secrets to GitHub..."
exec "$SCRIPT_DIR/setup-android-ci-secrets.sh" "$KEYSTORE"
