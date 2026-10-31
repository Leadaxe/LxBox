#!/usr/bin/env bash
# APK из CI как можно быстрее: ci.yml с run_mode=build-fast — один ABI, без
# checks, public-subs, прочих ABI и AAB; Play и релиз не трогаются (только тег).
#
#   ./scripts/ci-build-apk.sh [abi] [ref]
#
#   abi — arm64-v8a (по умолчанию) | armeabi-v7a | x86_64 | universal
#   ref — ветка или тег, по умолчанию develop. Собирается то, что ЗАПУШЕНО в
#         ref, а не локальное дерево. У build-fast своя concurrency-группа:
#         push-проверки той же ветки она не отменяет; две build-fast на одной
#         ветке подряд — остаётся последняя.
#
# Ждёт конец прогона и кладёт APK в app/build/ci-apk/<run id>/ (gitignored).
# Нужен `gh auth login`.
set -euo pipefail

ABI="${1:-arm64-v8a}"
REF="${2:-develop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$ABI" in
  arm64-v8a|armeabi-v7a|x86_64|universal) ;;
  *) echo "ci-build-apk: неизвестный abi '$ABI' (arm64-v8a | armeabi-v7a | x86_64 | universal)" >&2; exit 2 ;;
esac

# Запас 30 с на расхождение часов с GitHub: run ищется по времени создания.
SINCE="$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-30 sec' +%Y-%m-%dT%H:%M:%SZ)"

gh workflow run ci.yml --ref "$REF" -f run_mode=build-fast -f abi="$ABI"

# Запущенный run появляется в списке не сразу.
ID=""
for _ in $(seq 1 30); do
  ID="$(gh run list --workflow ci.yml --branch "$REF" --event workflow_dispatch -L 10 \
          --json databaseId,createdAt \
          -q "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | last | .databaseId // empty")"
  [ -n "$ID" ] && break
  sleep 2
done
if [ -z "$ID" ]; then
  echo "ci-build-apk: run не появился за минуту — смотри Actions на GitHub" >&2
  exit 1
fi
echo "ci-build-apk: $(gh run view "$ID" --json url -q .url)"

gh run watch "$ID" --compact --exit-status

OUT="$REPO_ROOT/app/build/ci-apk/$ID"
mkdir -p "$OUT"
gh run download "$ID" -n android-apks-release -D "$OUT"
ls -l "$OUT"/*.apk
