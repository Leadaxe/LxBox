#!/usr/bin/env bash
# Генерация сертификатов участников закрытого тестирования из шаблона.
#
#   ./generate.sh recipients.tsv [outdir]
#
# recipients.tsv — TSV без заголовка: <номер><TAB><имя>
# Готовые PDF содержат имена участников, поэтому по умолчанию пишутся
# в localworkspace/ — он в .gitignore.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

TEMPLATE="$HERE/certificate.html"
RECIPIENTS="${1:-$HERE/recipients.tsv}"
OUTDIR="${2:-$REPO/localworkspace/certificates}"

# Подставляются в шаблон вместо {{VERSION}} / {{DATE}}.
VERSION="${CERT_VERSION:-v2.20.12}"
ISSUED="${CERT_DATE:-August 2026}"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

[[ -f "$TEMPLATE"   ]] || { echo "шаблон не найден: $TEMPLATE" >&2; exit 1; }
[[ -f "$RECIPIENTS" ]] || { echo "список не найден: $RECIPIENTS" >&2; exit 1; }
[[ -x "$CHROME"     ]] || { echo "Chrome не найден: $CHROME" >&2; exit 1; }

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

count=0
while IFS=$'\t' read -r num name; do
    # пустые строки и комментарии
    [[ -z "${num// }" ]] && continue
    [[ "$num" == \#* ]] && continue

    cert_id="$(printf 'LXB-CT-2026-%03d' "$num")"

    # slug для имени файла: кириллица транслитерируется, остальное — дефис
    slug="$(NAME="$name" python3 -c '
import os, re, unicodedata
RU = {
    "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z",
    "и":"i","й":"y","к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r",
    "с":"s","т":"t","у":"u","ф":"f","х":"kh","ц":"ts","ч":"ch","ш":"sh",
    "щ":"shch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya",
}
name = os.environ["NAME"].strip().lower()
out = "".join(RU.get(ch, ch) for ch in name)
out = unicodedata.normalize("NFKD", out).encode("ascii", "ignore").decode()
print(re.sub(r"-+", "-", re.sub(r"[^a-z0-9]", "-", out)).strip("-"))
')"
    [[ -z "$slug" ]] && slug="$(printf '%03d' "$num")"

    html="$TMP/$cert_id.html"
    pdf="$OUTDIR/${cert_id}_${slug}.pdf"

    NAME="$name" CERT_ID="$cert_id" DATE="$ISSUED" VERSION="$VERSION" \
    python3 - "$TEMPLATE" "$html" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
html = open(src, encoding='utf-8').read()
for key in ('NAME', 'CERT_ID', 'DATE', 'VERSION'):
    html = html.replace('{{%s}}' % key, os.environ[key])
open(dst, 'w', encoding='utf-8').write(html)
PY

    "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
        --print-to-pdf="$pdf" "$html" >/dev/null 2>&1

    echo "$cert_id  $name  →  $(basename "$pdf")"
    count=$((count + 1))
done < "$RECIPIENTS"

echo
echo "готово: $count шт. в $OUTDIR"
