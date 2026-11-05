#!/usr/bin/env bash
# Сторож сборки F-Droid (задача 719): смотрит head_pipeline самого нового
# открытого MR com.leadaxe.lxbox* в fdroiddata; при failed — комментарий в
# issue FDROID_WATCH_ISSUE (переоткрыть, если закрыт), один раз на пайплайн.
#
# Переменные:
#   FDROID_WATCH_ISSUE  номер issue-носителя (обязателен)
#   FDROID_WATCH_MR     iid MR вместо автоматического выбора (любой state)
#   GITHUB_REPOSITORY   owner/repo (по умолчанию Leadaxe/LxBox)
#   DRY_RUN=1           ничего не писать в GitHub, только печатать
#
# Код возврата: 0 — проверка выполнена (в том числе с тревогой);
# ≠ 0 — проверку выполнить не удалось (GitLab, разбор ответа, gh).
set -euo pipefail

GITLAB_API="https://gitlab.com/api/v4"
FDROIDDATA_PROJECT=36528
BRANCH_PREFIX="com.leadaxe.lxbox"
REPO="${GITHUB_REPOSITORY:-Leadaxe/LxBox}"
ISSUE="${FDROID_WATCH_ISSUE:?FDROID_WATCH_ISSUE is required}"
DRY_RUN="${DRY_RUN:-}"

log() { printf '%s\n' "$*"; }

gitlab_get() {
  curl -sS --fail --max-time 30 --retry 2 --retry-delay 5 --retry-all-errors \
    "$GITLAB_API/$1"
}

# --- выбор MR ---
if [[ -n "${FDROID_WATCH_MR:-}" ]]; then
  mr_iid="$FDROID_WATCH_MR"
  log "MR: !$mr_iid (FDROID_WATCH_MR)"
else
  list="$(gitlab_get "projects/$FDROIDDATA_PROJECT/merge_requests?state=opened&per_page=100&search=Box&in=title")"
  mr_iid="$(jq -r --arg p "$BRANCH_PREFIX" \
    '[.[] | select(.source_branch | startswith($p)) | .iid] | max // empty' <<<"$list")"
  if [[ -z "$mr_iid" ]]; then
    log "No open $BRANCH_PREFIX MR in fdroiddata, nothing to check."
    exit 0
  fi
  log "MR: !$mr_iid (newest open $BRANCH_PREFIX*)"
fi

mr="$(gitlab_get "projects/$FDROIDDATA_PROJECT/merge_requests/$mr_iid")"
mr_url="$(jq -er '.web_url' <<<"$mr")"
mr_title="$(jq -r '.title' <<<"$mr")"
pl_id="$(jq -r '.head_pipeline.id // empty' <<<"$mr")"
pl_status="$(jq -r '.head_pipeline.status // empty' <<<"$mr")"
pl_project="$(jq -r '.head_pipeline.project_id // empty' <<<"$mr")"
pl_url="$(jq -r '.head_pipeline.web_url // empty' <<<"$mr")"

log "  $mr_title"
log "  $mr_url"

if [[ -z "$pl_id" ]]; then
  log "No head pipeline yet, no verdict."
  exit 0
fi
log "Pipeline $pl_id: $pl_status ($pl_url)"

case "$pl_status" in
  success)
    log "Build passed, nothing to do."
    exit 0
    ;;
  failed) ;;
  *)
    log "No verdict yet, next run tomorrow."
    exit 0
    ;;
esac

# --- тревога ---
jobs="$(gitlab_get "projects/$pl_project/pipelines/$pl_id/jobs?scope[]=failed&per_page=100")"
job_lines="$(jq -r '.[] | "- `\(.name)`: \(.web_url)"' <<<"$jobs")"
[[ -n "$job_lines" ]] || job_lines="- (no failed jobs listed)"
log "Failed jobs:"
log "$job_lines"

marker="<!-- fdroid-watch pipeline:$pl_id -->"
issue_json="$(gh issue view "$ISSUE" --repo "$REPO" --json state,comments)"
issue_state="$(jq -er '.state' <<<"$issue_json")"
if jq -e --arg m "$marker" 'any(.comments[]; .body | contains($m))' <<<"$issue_json" >/dev/null; then
  log "Issue #$ISSUE already has the alert for pipeline $pl_id, nothing to do."
  exit 0
fi

body="F-Droid build failed for $mr_url

Pipeline: $pl_url
Failed jobs:
$job_lines

$marker"

if [[ -n "$DRY_RUN" ]]; then
  log "DRY_RUN: issue #$ISSUE is $issue_state."
  [[ "$issue_state" == "CLOSED" ]] && log "DRY_RUN: would reopen issue #$ISSUE."
  log "DRY_RUN: would comment on issue #$ISSUE:"
  log "-----"
  log "$body"
  log "-----"
  exit 0
fi

if [[ "$issue_state" == "CLOSED" ]]; then
  gh issue reopen "$ISSUE" --repo "$REPO"
  log "Reopened issue #$ISSUE."
fi
gh issue comment "$ISSUE" --repo "$REPO" --body "$body"
log "Commented on issue #$ISSUE."
