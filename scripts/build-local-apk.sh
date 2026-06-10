#!/usr/bin/env bash
# Локальная сборка release APK (arm64-v8a).
#
# Версия пишется в pubspec.yaml через `sync-pubspec-version.sh` (выводит её
# из git state — last tag + commits count). Никаких `--dart-define`-флагов
# для версии не передаём: PackageInfo читает напрямую из manifest.

set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  export PATH="/Users/macbook/projects/flutter-sdk/bin:$PATH"
fi
: "${ANDROID_SDK_ROOT:=/usr/local/share/android-commandlinetools}"
export ANDROID_SDK_ROOT

cd "$(dirname "$0")/.."

# Гарантия что pubspec версия = git state. Hook это делает на commit, но мы
# можем билдить из uncommited state (например, после edit) — sync на всякий.
./scripts/sync-pubspec-version.sh

# §104 — ядро sing-box-lx: качаем пиненую версию AAR если ещё нет (идемпотентно).
./scripts/fetch-libbox.sh

cd app
export LXBOX_ABI_FILTER=arm64-v8a
flutter build apk --release --target-platform android-arm64 "$@"
