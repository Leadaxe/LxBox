#!/usr/bin/env bash
# Локальная сборка release APK (arm64-v8a).
#
# Версия пишется в pubspec.yaml через `sync-pubspec-version.sh` (выводит её
# из git state — last tag + commits count). Никаких `--dart-define`-флагов
# для версии не передаём: PackageInfo читает напрямую из manifest.
#
# §125: `--split-per-abi` — точно как CI release. Flutter применяет
# ABI-множитель к versionCode (arm64 → 1000×2 + git-count), чтобы локальная
# сборка попадала в тот же диапазон 2xxx, что и релизный arm64-APK, и вставала
# поверх релиза через `adb install -r` без downgrade. Выход —
# `app-arm64-v8a-release.apk` (не `app-release.apk`).

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
# §125: НЕ ставим LXBOX_ABI_FILTER — `--split-per-abi` сам задаёт splits.abi
# filters, а они конфликтуют с ndk.abiFilters («Conflicting configuration:
# arm64-v8a in ndk abiFilters cannot be present when splits abi filters are
# set»). `--target-platform android-arm64` сужает split до одного arm64 →
# на выходе ровно `app-arm64-v8a-release.apk` (один ABI, без раздувания).
flutter build apk --release --split-per-abi --target-platform android-arm64 "$@"
