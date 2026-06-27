#!/usr/bin/env bash
# Локальная сборка release APK (arm64-v8a).
#
# Версия пишется прямо в pubspec.yaml (см. ниже). Никаких `--dart-define`-флагов
# для версии не передаём: PackageInfo читает напрямую из manifest.
#
# §125: `--split-per-abi` — точно как CI release. Flutter применяет
# ABI-множитель к versionCode (arm64 → 1000×2 + build-number). Выход —
# `app-arm64-v8a-release.apk` (не `app-release.apk`).
#
# §186 — build-number (= база versionCode) пинится к ПОСЛЕДНЕМУ РЕЛИЗНОМУ ТЕГУ
# (count на коммите тега), а НЕ к растущему `git rev-list --count HEAD`. Иначе
# на ветке разработки (коммитов больше, чем было на момент тега) локальный vc
# обгоняет релизный → релиз с интернета не ставится поверх (downgrade-блок,
# боль юзера «не могу скачивать собственные релизы»). Пин к тегу → локальный
# arm64 vc = РОВНО релизный (2000 + count(tag)) → `install -r` проходит в обе
# стороны (равный vc не блокируется). versionName остаётся `-dev.<since>` —
# в About видно что это dev-сборка, а vc не выше релиза.

set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  export PATH="/Users/macbook/projects/flutter-sdk/bin:$PATH"
fi
: "${ANDROID_SDK_ROOT:=/usr/local/share/android-commandlinetools}"
export ANDROID_SDK_ROOT

cd "$(dirname "$0")/.."

# §186 — пишем версию в pubspec с build-number, ЗАПИНЕННЫМ к последнему
# релизному тегу (а не к HEAD-count), чтобы локальный vc не обгонял релизный.
# versionName = `X.Y.Z` (на теге) или `X.Y.Z-dev.<since>` (ушли от тега).
# build-number (versionCode-база) = count на коммите ТЕГА.
TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")
if [ -n "$TAG" ]; then
  TAG_COUNT=$(git rev-list --count "$TAG")
  SINCE=$(git rev-list "$TAG..HEAD" --count)
  VER="${TAG#v}"
  [ "$SINCE" != "0" ] && VER="$VER-dev.$SINCE"
  LINE="version: ${VER}+${TAG_COUNT}"
  sed -i.bak -E "s/^version: .*/${LINE}/" app/pubspec.yaml
  rm -f app/pubspec.yaml.bak
  echo "build-local: pinned $LINE (vc base = count($TAG)=$TAG_COUNT, не HEAD)"
else
  # Нет релизного тега на ветке — fallback на ПРОСТО НОМЕР КОММИТА (HEAD-count),
  # чтобы сборка не падала. Downgrade-риск неактуален без релизов.
  HEAD_COUNT=$(git rev-list --count HEAD)
  sed -i.bak -E "s/^version: .*/version: 0.0.0+${HEAD_COUNT}/" app/pubspec.yaml
  rm -f app/pubspec.yaml.bak
  echo "build-local: нет тега vN.N.N — version: 0.0.0+${HEAD_COUNT} (HEAD-count)"
fi

# §104 — ядро sing-box-lx: качаем пиненую версию AAR если ещё нет (идемпотентно).
./scripts/fetch-libbox.sh

cd app
# §125: НЕ ставим LXBOX_ABI_FILTER — `--split-per-abi` сам задаёт splits.abi
# filters, а они конфликтуют с ndk.abiFilters («Conflicting configuration:
# arm64-v8a in ndk abiFilters cannot be present when splits abi filters are
# set»). `--target-platform android-arm64` сужает split до одного arm64 →
# на выходе ровно `app-arm64-v8a-release.apk` (один ABI, без раздувания).
flutter build apk --release --split-per-abi --target-platform android-arm64 "$@"
