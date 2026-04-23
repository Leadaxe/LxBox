#!/usr/bin/env bash
# Старт ночной автономной сессии — precondition check + branch + tag +
# скопированный report-skeleton + baseline-commit.
#
# Usage:
#   ./docs/spec/processes/night-work/scripts/session-start.sh [BUDGET_HOURS]
#
# По умолчанию бюджет 10 часов. Скрипт:
# 1. Fail если working tree dirty.
# 2. Fail если текущая ветка — уже night/* (двойной старт).
# 3. Создаст ветку night/autonomous-YYYY-MM-DD (дата — today, MSK).
# 4. Скопирует report-template.md в sessions/YYYY-MM-DD.md с подставленными
#    плейсхолдерами ({{DATE}}, {{BASELINE_COMMIT}}, {{BUDGET_HOURS}}).
# 5. Закоммитит пустой отчёт как baseline.
# 6. Создаст тег night-baseline-YYYY-MM-DD на этот коммит.
# 7. Распечатает инструкцию: "open startup-prompt.md и запусти агента".
#
# Ничего не push'ит и ничего не mergeит.

set -euo pipefail

BUDGET_HOURS="${1:-10}"
DATE=$(date +%Y-%m-%d)
BRANCH="night/autonomous-${DATE}"
TAG="night-baseline-${DATE}"

cd "$(git rev-parse --show-toplevel)"

SPEC_ROOT="docs/spec/processes/night-work"
TEMPLATE="${SPEC_ROOT}/report-template.md"
SESSION_FILE="${SPEC_ROOT}/sessions/${DATE}.md"

# ─── Preconditions ─────────────────────────────────────────────────

if [ ! -f "$TEMPLATE" ]; then
  echo "✗ Template not found: $TEMPLATE"
  exit 1
fi

if [ -f "$SESSION_FILE" ]; then
  echo "✗ Session file already exists: $SESSION_FILE"
  echo "  Already started today? Remove manually or pick another day."
  exit 1
fi

DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
  echo "✗ Working tree not clean. Commit or stash first."
  echo
  git status --short
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == night/* ]]; then
  echo "✗ Already on a night branch: $CURRENT_BRANCH"
  echo "  Checkout main (or wherever you want to branch from) first."
  exit 1
fi

if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "✗ Branch already exists: $BRANCH"
  echo "  Delete it or pick a different date:"
  echo "     git branch -D $BRANCH"
  exit 1
fi

if git rev-parse --verify "$TAG" >/dev/null 2>&1; then
  echo "✗ Tag already exists: $TAG"
  echo "  Delete it or pick a different date:"
  echo "     git tag -d $TAG"
  exit 1
fi

# ─── Create branch ────────────────────────────────────────────────

BASELINE_COMMIT=$(git rev-parse --short HEAD)

echo "→ Creating branch $BRANCH from $(git branch --show-current)@$BASELINE_COMMIT"
git checkout -b "$BRANCH"

# ─── Copy template → session file ─────────────────────────────────

mkdir -p "${SPEC_ROOT}/sessions"

# Подставляем плейсхолдеры. sed -i отличается на BSD/Linux; используем
# portable form c tmp-файлом.
sed \
  -e "s/{{DATE}}/${DATE}/g" \
  -e "s/{{BASELINE_COMMIT}}/${BASELINE_COMMIT}/g" \
  -e "s/{{BUDGET_HOURS}}/${BUDGET_HOURS}/g" \
  "$TEMPLATE" > "$SESSION_FILE"

# Убираем первую строку-пометку ("> ⚠ Это skeleton...") из скопированного
# файла — она нужна только в template, не в конкретной сессии.
awk '
  BEGIN { skip = 0 }
  /^> ⚠ Это \*\*skeleton\*\*/ { skip = 1; next }
  skip && /^> / { next }
  skip && /^$/ { skip = 0; next }
  { print }
' "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

echo "→ Created session report: $SESSION_FILE"

# ─── Baseline commit ──────────────────────────────────────────────

git add "$SESSION_FILE"
git commit -m "chore(night): session ${DATE} baseline

Budget: ${BUDGET_HOURS}h
Baseline commit: ${BASELINE_COMMIT}
Agent prompt: docs/spec/processes/night-work/startup-prompt.md

Refs: night-work/sessions/${DATE}.md"

# ─── Tag baseline ─────────────────────────────────────────────────

git tag "$TAG" HEAD~0
echo "→ Tagged baseline: $TAG"

# ─── Report ──────────────────────────────────────────────────────

NEW_COMMIT=$(git rev-parse --short HEAD)
cat <<EOF

✅ Night session ready.

   Branch:   $BRANCH
   Tag:      $TAG (on ${BASELINE_COMMIT})
   Report:   $SESSION_FILE
   Baseline: ${NEW_COMMIT}
   Budget:   ${BUDGET_HOURS}h

Now launch the agent with the prompt at:
   docs/spec/processes/night-work/startup-prompt.md

To abort and roll back:
   git checkout main && git branch -D $BRANCH && git tag -d $TAG

EOF
