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
# §486 — режимы:
#   без аргументов и без LX_CONTRACT_SRC — ВОССТАНОВЛЕНИЕ app/contract из
#     коммита, записанного в contract.lock (поле source_sha). Зеркала и lock
#     не меняются.
#   LX_CONTRACT_SRC=<путь> или --to <sha> — БАМП: полная синхронизация из
#     рабочего дерева или указанного коммита лаунчера, пересчёт lock и зеркал.
#
# Идемпотентен: повторный бамп с тем же источником даёт тот же контент и
# пересчитанный (но при отсутствии изменений идентичный) sha256/synced_at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_DIR="$APP_DIR/contract"
LOCK_FILE="$APP_DIR/contract.lock"
ASSETS_DIR="$APP_DIR/assets/contract"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
DOCS_DIR="$REPO_DIR/docs/contract"

DEFAULT_LAUNCHER_REPO="${HOME}/projects/singbox-launcher"

MODE="restore"
BUMP_SHA=""
LX_CONTRACT_SRC_EXPLICIT=0

if [[ -n "${LX_CONTRACT_SRC:-}" ]]; then
  MODE="bump"
  LX_CONTRACT_SRC_EXPLICIT=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      MODE="bump"
      BUMP_SHA="${2:?sync_contract: --to требует аргумент <sha>}"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Использование:
  bash app/tool/sync_contract.sh              восстановить app/contract из lock
  bash app/tool/sync_contract.sh --to <sha>   бамп с коммита лаунчера
  LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh   бамп из каталога

Восстановление не трогает assets/contract, docs/contract и contract.lock.
Бамп пересобирает копию, lock и оба зеркала.
EOF
      exit 0
      ;;
    *)
      echo "sync_contract: неизвестный аргумент: $1" >&2
      exit 1
      ;;
  esac
done

_lock_field() {
  local key="$1"
  if [[ ! -f "$LOCK_FILE" ]]; then
    return 1
  fi
  grep "^${key}=" "$LOCK_FILE" | head -n1 | cut -d= -f2- || true
}

_tree_hash() {
  local dir="$1"
  find "$dir" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 cat \
    | shasum -a 256 \
    | awk '{print $1}'
}

_launcher_repo_from_src() {
  local src="$1"
  if [[ -d "$src/.git" ]]; then
    printf '%s\n' "$(cd "$src" && pwd)"
    return 0
  fi
  local parent
  parent="$(cd "$(dirname "$src")" && pwd)"
  if [[ -d "$parent/.git" ]]; then
    printf '%s\n' "$parent"
    return 0
  fi
  return 1
}

_restore_contract() {
  if [[ ! -f "$LOCK_FILE" ]]; then
    echo "sync_contract: нет $LOCK_FILE — сначала бамп: --to <sha> или LX_CONTRACT_SRC" >&2
    exit 1
  fi

  local source_sha launcher_repo
  source_sha="$(_lock_field source_sha)"
  # §487 worktree_bootstrap использует LX_CONTRACT_REPO; LX_LAUNCHER_REPO —
  # то же для явного бампа. Поле lock — если скрипт сам его записал.
  launcher_repo="${LX_CONTRACT_REPO:-${LX_LAUNCHER_REPO:-$(_lock_field launcher_repo)}}"
  if [[ -z "$launcher_repo" ]]; then
    launcher_repo="$DEFAULT_LAUNCHER_REPO"
  fi

  if [[ -z "$source_sha" ]]; then
    echo "sync_contract: в contract.lock нет source_sha — восстановление невозможно." >&2
    echo "  Выполните бамп: bash app/tool/sync_contract.sh --to <sha> лаунчера" >&2
    echo "  или LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh" >&2
    exit 1
  fi

  if [[ ! -d "$launcher_repo/.git" ]]; then
    echo "sync_contract: репозиторий лаунчера не найден: $launcher_repo" >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "sync_contract: восстановление $launcher_repo@$source_sha -> $DEST_DIR"
  git -C "$launcher_repo" archive "$source_sha" contract | tar -x -C "$tmp"

  if [[ ! -d "$tmp/contract" ]]; then
    echo "sync_contract: в коммите $source_sha нет каталога contract/" >&2
    exit 1
  fi

  rm -rf "$DEST_DIR"
  mkdir -p "$DEST_DIR"
  cp -R "$tmp/contract/." "$DEST_DIR/"

  local actual expected
  expected="$(_lock_field sha256)"
  actual="$(_tree_hash "$DEST_DIR")"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "sync_contract: восстановленное дерево не совпадает с contract.lock:" >&2
    echo "  в дереве: $actual" >&2
    echo "  в lock:   $expected" >&2
    exit 1
  fi

  echo "sync_contract: готово (восстановление, sha256=$actual)"
}

_bump_contract() {
  local launcher_repo contract_src source_sha

  if [[ -n "$BUMP_SHA" ]]; then
    launcher_repo="${LX_CONTRACT_REPO:-${LX_LAUNCHER_REPO:-$DEFAULT_LAUNCHER_REPO}}"
    if [[ ! -d "$launcher_repo/.git" ]]; then
      echo "sync_contract: репозиторий лаунчера не найден: $launcher_repo" >&2
      exit 1
    fi
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git -C "$launcher_repo" archive "$BUMP_SHA" contract | tar -x -C "$tmp"
    contract_src="$tmp/contract"
    source_sha="$BUMP_SHA"
  else
    contract_src="${LX_CONTRACT_SRC:-$DEFAULT_LAUNCHER_REPO/contract}"
    if [[ ! -d "$contract_src" ]]; then
      echo "sync_contract: источник не найден: $contract_src" >&2
      exit 1
    fi
    launcher_repo="$(_launcher_repo_from_src "$contract_src" || true)"
    if [[ -z "$launcher_repo" ]]; then
      launcher_repo="$DEFAULT_LAUNCHER_REPO"
    fi
    if [[ -d "$launcher_repo/.git" ]]; then
      source_sha="$(git -C "$launcher_repo" rev-parse HEAD)"
    else
      source_sha=""
    fi
  fi

  echo "sync_contract: $contract_src -> $DEST_DIR"

  rm -rf "$DEST_DIR"
  mkdir -p "$DEST_DIR"
  cp -R "$contract_src/." "$DEST_DIR/"

  local tree_hash synced_at
  tree_hash="$(_tree_hash "$DEST_DIR")"
  synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "sync_contract: зеркало реестра -> $ASSETS_DIR"
  rm -rf "$ASSETS_DIR"
  mkdir -p "$ASSETS_DIR/registry/protocols"
  cp "$DEST_DIR/VERSION" "$ASSETS_DIR/VERSION"
  cp "$DEST_DIR"/registry/*.json "$ASSETS_DIR/registry/"
  cp "$DEST_DIR"/registry/protocols/*.json "$ASSETS_DIR/registry/protocols/"

  cat > "$LOCK_FILE" <<EOF
source=$contract_src
launcher_repo=$launcher_repo
source_sha=$source_sha
synced_at=$synced_at
sha256=$tree_hash
EOF

  local contract_version
  contract_version="$(cat "$DEST_DIR/VERSION")"
  if [[ -d "$DEST_DIR/docs/generated" ]]; then
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
| Версия контракта | \`$contract_version\` |
| sha256 копии (\`app/contract.lock\`) | \`$tree_hash\` |
| Синхронизировано | \`$synced_at\` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: \`bash app/tool/sync_contract.sh --to <sha>\` или
\`LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh\`. Ручная правка
потеряется на следующем прогоне, а тест-страж
(\`app/test/contract/docs_mirror_test.dart\`) поймает рассинхрон зеркала с
реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
EOF
  else
    echo "sync_contract: docs/generated в источнике нет — зеркало документации пропущено" >&2
  fi

  echo "sync_contract: готово, sha256=$tree_hash"
}

if [[ "$MODE" == "restore" ]]; then
  _restore_contract
else
  _bump_contract
fi
