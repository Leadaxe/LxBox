#!/usr/bin/env bash
# Синхронизация контракта (SPEC 103) из репозитория лаунчера в LxBox.
#
# Копирует каталог contract/ из singbox-launcher в app/contract/ (вендоренная
# копия, источник правды — репо лаунчера) и пишет пин с хешем дерева в
# app/contract.lock, чтобы было видно, с какого состояния источника снята
# копия и когда.
#
# §460 — плюс зеркало реестра в app/assets/contract/ (registry/** + VERSION).
# app/contract/ в git не идёт, а реестр бандлится в приложение: сборка без
# репозитория лаунчера (CI, F-Droid) обязана собираться, поэтому ровно те
# файлы, которые читает ContractRegistry, лежат в git как обычные assets.
# Зеркало РОВНО копия — руками не правят, обновляется только этим скриптом.
#
# §460 W2b — и второе зеркало: docs/generated/** копии едет в закоммиченный
# docs/contract/ в корне репозитория. Карточка предупреждения даёт ссылку
# «Learn more» на страницу кода, и ведёт она в НАШ репозиторий, а не в
# лаунчерский: релизный APK соответствует main, и страница обязана лежать
# там же. Свой генератор не заводится — страницы собирает gendocs лаунчера,
# сюда они приезжают байт в байт. Шапку скрипт в сами страницы не дописывает
# (иначе байт в байт бы не вышло) — происхождение названо в docs/contract/
# README.md, который скрипт генерирует.
#
# Источник настраивается через LX_CONTRACT_SRC (дефолт — сосед-репозиторий
# singbox-launcher рядом с LxBox).
#
# Идемпотентен: повторный запуск с тем же источником даёт тот же контент и
# пересчитанный (но при отсутствии изменений идентичный) sha256/synced_at.

set -euo pipefail

# Путь к contract/ в репозитории лаунчера — источник копии.
LX_CONTRACT_SRC="${LX_CONTRACT_SRC:-/Users/macbook/projects/singbox-launcher/contract}"

# Каталог этого скрипта → корень app/ (tool/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_DIR="$APP_DIR/contract"
LOCK_FILE="$APP_DIR/contract.lock"
# §460 — бандлируемое зеркало реестра (в git, читается через rootBundle).
ASSETS_DIR="$APP_DIR/assets/contract"
# §460 W2b — зеркало страниц документации (в git, в APK не едет).
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
DOCS_DIR="$REPO_DIR/docs/contract"

if [ ! -d "$LX_CONTRACT_SRC" ]; then
  echo "sync_contract: источник не найден: $LX_CONTRACT_SRC" >&2
  exit 1
fi

echo "sync_contract: $LX_CONTRACT_SRC -> $DEST_DIR"

# Полная пересборка каталога-назначения: идемпотентность и отсутствие
# «хвостов» от удалённых в источнике файлов важнее скорости rsync-подобного
# инкремента.
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
cp -R "$LX_CONTRACT_SRC/." "$DEST_DIR/"

# Хеш дерева: сортированный список файлов + их содержимое одним потоком в
# shasum. find выдаёт стабильный порядок через sort (LC_ALL=C — байтовый
# порядок, не зависит от локали машины).
TREE_HASH="$(
  find "$DEST_DIR" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 cat \
    | shasum -a 256 \
    | awk '{print $1}'
)"

# §460 — зеркало реестра в assets. Хеш дерева выше считается ДО него и только
# по contract/: assets — производная копия, в lock она не входит, иначе lock
# зависел бы сам от себя.
#
# Каталоги Flutter не рекурсивны, поэтому registry/ и registry/protocols/
# объявлены в pubspec по отдельности — состав зеркала обязан этому отвечать.
echo "sync_contract: зеркало реестра -> $ASSETS_DIR"
rm -rf "$ASSETS_DIR"
mkdir -p "$ASSETS_DIR/registry/protocols"
cp "$DEST_DIR/VERSION" "$ASSETS_DIR/VERSION"
cp "$DEST_DIR"/registry/*.json "$ASSETS_DIR/registry/"
cp "$DEST_DIR"/registry/protocols/*.json "$ASSETS_DIR/registry/protocols/"

SYNCED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$LOCK_FILE" <<EOF
source=$LX_CONTRACT_SRC
synced_at=$SYNCED_AT
sha256=$TREE_HASH
EOF

# §460 W2b — зеркало страниц документации. Полная пересборка, как у зеркала
# реестра: удалённая в источнике страница обязана исчезнуть и здесь, иначе
# ссылка «Learn more» вела бы на страницу, которой контракт уже не знает.
# README.md пишется ПОСЛЕ копирования — он не из источника, а про источник.
CONTRACT_VERSION="$(cat "$DEST_DIR/VERSION")"
if [ -d "$DEST_DIR/docs/generated" ]; then
  echo "sync_contract: зеркало документации -> $DOCS_DIR"
  rm -rf "$DOCS_DIR"
  mkdir -p "$DOCS_DIR"
  cp -R "$DEST_DIR/docs/generated/." "$DOCS_DIR/"
  cat > "$DOCS_DIR/README.md" <<EOF
# Contract documentation (mirror)

Эти страницы — копия \`contract/docs/generated/**\` из репозитория лаунчера,
байт в байт. Их собирает генератор \`contract/tools/gendocs\` по реестру
контракта; здесь они лежат для того, чтобы ссылка «Learn more» из карточки
предупреждения вела в наш репозиторий, а не в чужой.

| | |
|---|---|
| Версия контракта | \`$CONTRACT_VERSION\` |
| sha256 копии (\`app/contract.lock\`) | \`$TREE_HASH\` |
| Синхронизировано | \`$SYNCED_AT\` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: \`bash app/tool/sync_contract.sh\`. Ручная правка потеряется на
следующем прогоне, а тест-страж (\`app/test/contract/docs_mirror_test.dart\`)
поймает рассинхрон зеркала с реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
EOF
else
  echo "sync_contract: docs/generated в источнике нет — зеркало документации пропущено" >&2
fi

echo "sync_contract: готово, sha256=$TREE_HASH"
