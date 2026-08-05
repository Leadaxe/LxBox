#!/usr/bin/env bash
# Локальная сборка release APK (arm64-v8a).
#
# Версия пишется прямо в pubspec.yaml (см. ниже). Никаких `--dart-define`-флагов
# для версии не передаём: PackageInfo читает напрямую из manifest.
#
# §379: versionCode считается ИЗ ВЕРСИИ (scripts/version-code.sh — та же
# формула, что в CI), последняя цифра = ABI. `--split-per-abi` УБРАН: он
# домножал бы ABI×1000 поверх нашего числа. Выход — `app-release.apk`,
# переименовываем в `app-arm64-v8a-release.apk` для совместимости с
# install-apk.sh и привычными путями.
#
# §186 — код пинится к ПОСЛЕДНЕМУ РЕЛИЗНОМУ ТЕГУ, а не к HEAD. Иначе на ветке
# разработки локальный vc обгоняет релизный → релиз с интернета не ставится
# поверх (downgrade-блок, боль юзера «не могу скачивать собственные релизы»).
# Пин к тегу → локальный arm64 vc = РОВНО релизный код этой версии →
# `install -r` проходит в обе стороны (равный vc не блокируется). versionName
# остаётся `-dev.<since>` — в About видно, что это dev-сборка, а vc не выше
# релиза.
#
# ВАЖНО: скрипт и CI обязаны считать код одной формулой. Если один останется
# на `rev-list`, коды разойдутся (1606 против 21907502) и install -r сломается.
#
# pubspec в репо — фиксированный placeholder `0.0.0+1` (версия не хранится в git,
# git-хуков нет). Этот скрипт переписывает `version:` строку перед build'ом, а на
# выходе (trap EXIT — даже при ошибке сборки) ВОЗВРАЩАЕТ pubspec к закоммиченному
# состоянию через `git checkout`. Итог: сборка не оставляет diff в рабочем дереве.

set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  export PATH="/Users/macbook/projects/flutter-sdk/bin:$PATH"
fi
: "${ANDROID_SDK_ROOT:=/usr/local/share/android-commandlinetools}"
export ANDROID_SDK_ROOT

cd "$(dirname "$0")/.."

# Восстанавливаем pubspec к закоммиченному placeholder'у на любом выходе, чтобы
# вычисленная на время сборки `version:` не оставалась в рабочем дереве.
# `git checkout` возвращает ровно то, что в HEAD (устойчиво к смене placeholder'а).
trap 'git checkout -- app/pubspec.yaml 2>/dev/null || true' EXIT

# §186/§379 — пишем версию в pubspec с кодом, ЗАПИНЕННЫМ к последнему релизному
# тегу, чтобы локальный vc не обгонял релизный.
# versionName = `X.Y.Z` (на теге) или `X.Y.Z-dev.<since>` (ушли от тега).
# versionCode = код ТЕГА для arm64 (version-code.sh срезает хвост -dev.N).
TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")
if [ -n "$TAG" ]; then
  SINCE=$(git rev-list "$TAG..HEAD" --count)
  VER="${TAG#v}"
  CODE=$(./scripts/version-code.sh "$VER" arm64-v8a)
  [ "$SINCE" != "0" ] && VER="$VER-dev.$SINCE"
  LINE="version: ${VER}+${CODE}"
  sed -i.bak -E "s/^version: .*/${LINE}/" app/pubspec.yaml
  rm -f app/pubspec.yaml.bak
  echo "build-local: pinned $LINE (vc = код $TAG для arm64, не HEAD-count)"
else
  # Нет релизного тега на ветке — fallback на 0.0.0, чтобы сборка не падала.
  # Downgrade-риск неактуален без релизов.
  CODE=$(./scripts/version-code.sh 0.0.0 arm64-v8a)
  sed -i.bak -E "s/^version: .*/version: 0.0.0+${CODE}/" app/pubspec.yaml
  rm -f app/pubspec.yaml.bak
  echo "build-local: no tag vN.N.N — version: 0.0.0+${CODE}"
fi

# §104 — ядро sing-box-lx: качаем пиненую версию AAR если ещё нет (идемпотентно).
./scripts/fetch-libbox.sh

cd app
# §379: без `--split-per-abi` конфликта splits.abi ↔ ndk.abiFilters больше нет,
# поэтому сужаем native libs из AAR через LXBOX_ABI_FILTER (иначе gradle тянет
# libbox под все 3 ABI и APK раздувается до ~76 MB). `--target-platform`
# сужает flutter engine + Dart AOT.
LXBOX_ABI_FILTER=arm64-v8a \
  flutter build apk --release --target-platform android-arm64 "$@"

# Без сплита Flutter пишет `app-release.apk`. Переименовываем в привычное
# per-ABI имя — на него смотрят scripts/install-apk.sh и мышечная память.
OUT=build/app/outputs/flutter-apk
mv "$OUT/app-release.apk" "$OUT/app-arm64-v8a-release.apk"
echo "build-local: $OUT/app-arm64-v8a-release.apk"
