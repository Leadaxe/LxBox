#!/usr/bin/env bash
# Подготовка чистого git worktree к локальным тестам и сборке APK (§487).
#
# В worktree нет gitignored артефактов основного дерева: libbox.aar, ключи
# подписи, копия контракта. Без них сборка подписывается debug-ключом
# (INSTALL_FAILED_UPDATE_INCOMPATIBLE при install -r), а корпусные тесты
# молча скипаются.
#
# Скрипт идемпотентен. Симлинки и каталог app/contract/ в git не попадают.
# Зеркала app/assets/contract/, docs/contract/ и app/contract.lock не трогает.
#
#   ./tool/worktree_bootstrap.sh [--main <путь основного дерева>]
#   ./tool/worktree_bootstrap.sh --clean [--main <путь>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
LOCK_FILE="$APP_DIR/contract.lock"
CONTRACT_DIR="$APP_DIR/contract"
LAUNCHER_REPO="${LX_CONTRACT_REPO:-$HOME/projects/singbox-launcher}"

MAIN_TREE=""
MODE="bootstrap"

usage() {
  cat <<'EOF'
worktree_bootstrap — gitignored артефакты для worktree

  ./tool/worktree_bootstrap.sh [--main <путь>]
  ./tool/worktree_bootstrap.sh --clean [--main <путь>]

Опции:
  --main <путь>   Основное дерево (источник симлинков). По умолчанию — первая
                  запись `git worktree list --porcelain`.
  --clean         Снять симлинки и удалить восстановленный app/contract/.
  -h, --help      Эта справка.

Переменные:
  LX_CONTRACT_REPO   Репозиторий лаунчера (default: ~/projects/singbox-launcher).

Секреты (.keys/, key.properties) не копируются — только симлинки.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --main)
      shift
      MAIN_TREE="${1:-}"
      [ -n "$MAIN_TREE" ] || { echo "worktree_bootstrap: --main требует путь" >&2; exit 2; }
      shift
      ;;
    --clean)
      MODE="clean"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "worktree_bootstrap: неизвестный аргумент: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

resolve_main_tree() {
  if [ -n "$MAIN_TREE" ]; then
    MAIN_TREE="$(cd "$MAIN_TREE" && pwd)"
    return
  fi
  local wt
  wt="$(git -C "$REPO_ROOT" worktree list --porcelain | awk '/^worktree / {print $2; exit}')"
  if [ -z "$wt" ]; then
    echo "worktree_bootstrap: не удалось определить основное дерево — укажите --main" >&2
    exit 1
  fi
  MAIN_TREE="$(cd "$wt" && pwd)"
}

lock_field() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$LOCK_FILE"
}

tree_hash() {
  local dir="$1"
  find "$dir" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 cat \
    | shasum -a 256 \
    | awk '{print $1}'
}

ensure_symlink() {
  local target="$1" link="$2" label="$3"
  if [ ! -e "$target" ]; then
    echo "worktree_bootstrap: в основном дереве нет $label: $target" >&2
    return 1
  fi
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    echo "worktree_bootstrap: $label — уже симлинк"
    return 0
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "worktree_bootstrap: $label занят не-симлинком: $link (снимите вручную или --clean)" >&2
    return 1
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
  echo "worktree_bootstrap: $label -> $target"
}

remove_symlink() {
  local link="$1" label="$2"
  if [ -L "$link" ]; then
    rm -f "$link"
    echo "worktree_bootstrap: снят симлинк $label"
  elif [ -e "$link" ]; then
    echo "worktree_bootstrap: $label не симлинк, пропуск: $link" >&2
  fi
}

bootstrap_links() {
  local -a required_link_targets optional_link_targets
  required_link_targets=(
    "libbox AAR|$MAIN_TREE/app/android/app/libs|$APP_DIR/android/app/libs"
    "Android signing key.properties|$MAIN_TREE/app/android/key.properties|$APP_DIR/android/key.properties"
    "Android upload keystore|$MAIN_TREE/app/android/upload-keystore.jks|$APP_DIR/android/upload-keystore.jks"
    "Android local.properties|$MAIN_TREE/app/android/local.properties|$APP_DIR/android/local.properties"
  )
  optional_link_targets=(
    "Play publisher keys (.keys)|$MAIN_TREE/.keys|$REPO_ROOT/.keys"
  )

  local entry target link label
  for entry in "${required_link_targets[@]}"; do
    label="${entry%%|*}"
    target="${entry#*|}"
    target="${target%%|*}"
    link="${entry##*|}"
    ensure_symlink "$target" "$link" "$label"
  done
  for entry in "${optional_link_targets[@]}"; do
    label="${entry%%|*}"
    target="${entry#*|}"
    target="${target%%|*}"
    link="${entry##*|}"
    if [ -e "$target" ]; then
      ensure_symlink "$target" "$link" "$label"
    else
      echo "worktree_bootstrap: $label — нет в основном дереве, пропуск"
    fi
  done
}

clean_links() {
  local -a all_link_targets
  all_link_targets=(
    "libbox AAR|$MAIN_TREE/app/android/app/libs|$APP_DIR/android/app/libs"
    "Android signing key.properties|$MAIN_TREE/app/android/key.properties|$APP_DIR/android/key.properties"
    "Android upload keystore|$MAIN_TREE/app/android/upload-keystore.jks|$APP_DIR/android/upload-keystore.jks"
    "Android local.properties|$MAIN_TREE/app/android/local.properties|$APP_DIR/android/local.properties"
    "Play publisher keys (.keys)|$MAIN_TREE/.keys|$REPO_ROOT/.keys"
  )

  local entry link label
  for entry in "${all_link_targets[@]}"; do
    label="${entry%%|*}"
    link="${entry##*|}"
    remove_symlink "$link" "$label"
  done
}

restore_contract() {
  if [ ! -f "$LOCK_FILE" ]; then
    echo "worktree_bootstrap: нет $LOCK_FILE — контракт не восстанавливается" >&2
    return 1
  fi

  local expected_sha source_sha
  expected_sha="$(lock_field sha256)"
  if [ -z "$expected_sha" ]; then
    echo "worktree_bootstrap: в $LOCK_FILE нет поля sha256" >&2
    return 1
  fi

  if [ -d "$CONTRACT_DIR" ]; then
    local actual_sha
    actual_sha="$(tree_hash "$CONTRACT_DIR")"
    if [ "$actual_sha" = "$expected_sha" ]; then
      echo "worktree_bootstrap: app/contract/ совпадает с contract.lock ($expected_sha)"
      return 0
    fi
    echo "worktree_bootstrap: app/contract/ есть, но sha256 не совпадает с lock — пересобираю"
  fi

  source_sha="$(lock_field source_sha)"
  if [ -z "$source_sha" ]; then
    cat >&2 <<EOF
worktree_bootstrap: в $LOCK_FILE нет поля source_sha= — app/contract/ не восстановлен.

Найдите коммит репозитория лаунчера с деревом contract/, чей sha256 совпадает
с lock ($expected_sha), и восстановите вручную:

  git -C $LAUNCHER_REPO archive <commit> contract | tar -x -C /tmp/wt-contract
  rm -rf $CONTRACT_DIR
  cp -a /tmp/wt-contract/contract $CONTRACT_DIR

Либо добавьте source_sha=<commit> в contract.lock при следующей синхронизации
контракта (app/tool/sync_contract.sh).
EOF
    return 1
  fi

  if [ ! -d "$LAUNCHER_REPO/.git" ]; then
    echo "worktree_bootstrap: репозиторий лаунчера не найден: $LAUNCHER_REPO" >&2
    return 1
  fi

  if ! git -C "$LAUNCHER_REPO" cat-file -e "${source_sha}^{commit}" 2>/dev/null; then
    echo "worktree_bootstrap: коммит $source_sha не найден в $LAUNCHER_REPO" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "worktree_bootstrap: git archive $source_sha contract -> app/contract/"
  git -C "$LAUNCHER_REPO" archive "$source_sha" contract | tar -x -C "$tmp"
  if [ ! -d "$tmp/contract" ]; then
    echo "worktree_bootstrap: archive $source_sha не содержит каталог contract/" >&2
    return 1
  fi

  rm -rf "$CONTRACT_DIR"
  cp -a "$tmp/contract" "$CONTRACT_DIR"

  local actual_sha
  actual_sha="$(tree_hash "$CONTRACT_DIR")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "worktree_bootstrap: восстановленный контракт не совпадает с lock:" >&2
    echo "  в дереве: $actual_sha" >&2
    echo "  в lock:   $expected_sha" >&2
    return 1
  fi

  echo "worktree_bootstrap: app/contract/ восстановлен ($actual_sha)"
}

clean_contract() {
  if [ -d "$CONTRACT_DIR" ]; then
    rm -rf "$CONTRACT_DIR"
    echo "worktree_bootstrap: удалён $CONTRACT_DIR"
  fi
}

assert_tracked_clean() {
  local paths=(
    app/assets/contract
    docs/contract
    app/contract.lock
  )
  local dirty=""
  for p in "${paths[@]}"; do
    if ! git -C "$REPO_ROOT" diff --quiet -- "$p" 2>/dev/null \
      || [ -n "$(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "$p")" ]; then
      dirty="${dirty}  $p"$'\n'
    fi
  done
  if [ -n "$dirty" ]; then
    echo "worktree_bootstrap: затронуты отслеживаемые файлы (откат):" >&2
    printf '%s' "$dirty" >&2
    git -C "$REPO_ROOT" checkout -- app/assets/contract docs/contract app/contract.lock 2>/dev/null || true
    exit 1
  fi
}

resolve_main_tree

if [ "$MAIN_TREE" = "$REPO_ROOT" ]; then
  echo "worktree_bootstrap: основное дерево совпадает с текущим — ничего не делаю" >&2
  exit 0
fi

if [ ! -d "$MAIN_TREE/.git" ] && ! git -C "$MAIN_TREE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "worktree_bootstrap: $MAIN_TREE не похоже на git-дерево LxBox" >&2
  exit 1
fi

contract_ok=0

if [ "$MODE" = "clean" ]; then
  clean_links
  clean_contract
else
  bootstrap_links
  if restore_contract; then
    contract_ok=1
  fi
fi

assert_tracked_clean

if [ "$MODE" = "bootstrap" ] && [ "$contract_ok" -eq 0 ]; then
  exit 1
fi

# Автор коммитов в worktree — noreply-адрес GitHub: коммит с личным e-mail
# отклоняется push'ем (GH007 «would publish a private email»), см. 24.09.2026.
git config user.email "247031499+Leadaxe@users.noreply.github.com"
git config user.name "Leadaxe"

echo "worktree_bootstrap: готово"
