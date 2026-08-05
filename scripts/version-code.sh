#!/usr/bin/env bash
# §379 — расчёт Android versionCode из версии.
#
# Единственный источник формулы. Потребители: .github/workflows/ci.yml,
# scripts/build-local-apk.sh, метаданные F-Droid (сверка вручную).
# Дублировать арифметику в потребителях НЕЛЬЗЯ: разошедшиеся коды между CI и
# локальной сборкой ломают `install -r` в обе стороны (§186).
#
#   versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
#
#   21908512
#    2  19  08  51  2
#    │   │   │   │  └── ABI    0=universal 1=arm32 2=arm64 4=x86_64
#    │   │   │   └───── PRE    01-49=rc.N, 50=релиз, 51-98=hotfixN
#    │   │   └───────── patch
#    │   └───────────── minor
#    └───────────────── major
#
# Usage:
#   version-code.sh <version> <abi>
#
#   <version>  2.19.8 | 2.19.8-rc.1 | 2.19.8-hotfix1 | v2.19.8 (v- срезается)
#              Суффикс -dev.N игнорируется: dev-сборка пинится к коду тега (§186).
#   <abi>      universal | armeabi-v7a | arm64-v8a | x86_64
#              (либо готовая цифра 0/1/2/4)
#
# Печатает versionCode в stdout. При нераспознанной версии — падает с
# диагностикой в stderr, а не подставляет мусорный код (отброс-не-подгон, §169).

set -euo pipefail

die() { echo "version-code: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: version-code.sh <version> <abi>"

VERSION="${1#v}"
ABI_RAW="$2"

# --- ABI ---------------------------------------------------------------------
# Universal = 0: он ставится на любую архитектуру, поэтому в рамках одной
# версии наименее специфичен. Обновления это не ломает — шаг версии (10000)
# на два порядка больше разницы ABI (максимум 4).
case "$ABI_RAW" in
  universal|0)    ABI=0 ;;
  armeabi-v7a|1)  ABI=1 ;;
  arm64-v8a|2)    ABI=2 ;;
  x86_64|4)       ABI=4 ;;
  *) die "неизвестный ABI '$ABI_RAW' (universal|armeabi-v7a|arm64-v8a|x86_64)" ;;
esac

# --- разбор версии -----------------------------------------------------------
# Хвост -dev.N срезаем ДО разбора: локальная сборка получает код своего тега.
VERSION="${VERSION%%-dev.*}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(.+))?$ ]]; then
  die "версия '$1' не разбирается как X.Y.Z[-suffix]"
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
SUFFIX="${BASH_REMATCH[5]:-}"

# --- PRE ---------------------------------------------------------------------
# Порядок стадий: rc.N (01-49) < релиз (50) < hotfixN (51-98).
case "$SUFFIX" in
  "")
    PRE=50
    ;;
  rc.*)
    N="${SUFFIX#rc.}"
    [[ "$N" =~ ^[0-9]+$ ]] || die "rc-номер '$N' не число (ожидается -rc.N)"
    [ "$N" -ge 1 ] && [ "$N" -le 49 ] || die "rc-номер $N вне 1..49"
    PRE=$((N))
    ;;
  hotfix*)
    N="${SUFFIX#hotfix}"
    [[ "$N" =~ ^[0-9]+$ ]] || die "hotfix-номер '$N' не число (ожидается -hotfixN)"
    [ "$N" -ge 1 ] && [ "$N" -le 48 ] || die "hotfix-номер $N вне 1..48"
    PRE=$((50 + N))
    ;;
  *)
    die "неизвестный суффикс '-$SUFFIX' (ожидается -rc.N или -hotfixN)"
    ;;
esac

# --- границы -----------------------------------------------------------------
# major >213 переполняет int32 (Android отвергает); minor/patch >99 залезли бы
# в соседний разряд и сломали монотонность.
[ "$MAJOR" -le 213 ] || die "major $MAJOR > 213 — versionCode выйдет за int32"
[ "$MINOR" -le 99 ]  || die "minor $MINOR > 99 — разряд переполнен"
[ "$PATCH" -le 99 ]  || die "patch $PATCH > 99 — разряд переполнен"

echo "$(( ((MAJOR * 10000 + MINOR * 100 + PATCH) * 100 + PRE) * 10 + ABI ))"
