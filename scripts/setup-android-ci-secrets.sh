#!/usr/bin/env bash
# Загружает в GitHub Actions секреты для подписи release APK (см. docs/BUILD.md).
# Требуется: gh auth login, openssl, файл .jks.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

usage() {
  echo "Upload Android signing secrets for GitHub Actions (see docs/BUILD.md)."
  echo
  echo "Usage:"
  echo "  ANDROID_KEYSTORE_PATH=./upload-keystore.jks \\"
  echo "  ANDROID_KEYSTORE_PASSWORD='store-pass' ANDROID_KEY_PASSWORD='key-pass' \\"
  echo "  ANDROID_KEY_ALIAS=upload \\"
  echo "  $0"
  echo
  echo "Or pass keystore path as first argument; missing passwords are prompted (hidden)."
  echo "Optional: GH_REPO=owner/repo  (if not in a git clone with origin)"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Install GitHub CLI: https://cli.github.com/  (macOS: brew install gh)"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Run: gh auth login   (needs repo scope to set secrets)"
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found (needed for base64 -A)"
  exit 1
fi

KEYSTORE=${ANDROID_KEYSTORE_PATH:-${1:-}}
if [[ -z "$KEYSTORE" ]]; then
  echo "ERROR: set ANDROID_KEYSTORE_PATH or pass path to .jks as first argument."
  usage
  exit 1
fi
if [[ ! -f "$KEYSTORE" ]]; then
  echo "ERROR: keystore not found: $KEYSTORE"
  exit 1
fi

STORE_PW=${ANDROID_KEYSTORE_PASSWORD:-}
KEY_PW=${ANDROID_KEY_PASSWORD:-}
ALIAS=${ANDROID_KEY_ALIAS:-upload}

if [[ -z "$STORE_PW" ]]; then
  read -rsp "Keystore password (storePassword): " STORE_PW
  echo
fi
if [[ -z "$KEY_PW" ]]; then
  read -rsp "Key password (keyPassword): " KEY_PW
  echo
fi

if [[ -z "$STORE_PW" || -z "$KEY_PW" ]]; then
  echo "ERROR: passwords cannot be empty."
  exit 1
fi

GH_ARGS=()
if [[ -n "${GH_REPO:-}" ]]; then
  GH_ARGS=(--repo "$GH_REPO")
fi

echo "Setting ANDROID_KEYSTORE_BASE64 (from $KEYSTORE)..."
openssl base64 -A -in "$KEYSTORE" | gh secret set ANDROID_KEYSTORE_BASE64 "${GH_ARGS[@]}"

echo "Setting ANDROID_KEYSTORE_PASSWORD..."
gh secret set ANDROID_KEYSTORE_PASSWORD --body "$STORE_PW" "${GH_ARGS[@]}"

echo "Setting ANDROID_KEY_PASSWORD..."
gh secret set ANDROID_KEY_PASSWORD --body "$KEY_PW" "${GH_ARGS[@]}"

echo "Setting ANDROID_KEY_ALIAS..."
gh secret set ANDROID_KEY_ALIAS --body "$ALIAS" "${GH_ARGS[@]}"

echo "Done. Push to main (or re-run workflow) so CI picks up release signing."
gh secret list "${GH_ARGS[@]}" | grep ANDROID_ || true
