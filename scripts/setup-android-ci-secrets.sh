#!/usr/bin/env bash
# Загружает в GitHub Actions секреты для подписи release APK (см. docs/BUILD.md).
# Требуется: gh auth login, openssl, файл .jks.
# Пароли можно не вводить: читаются из app/android/key.properties, если есть.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

DEFAULT_KEYSTORE="$REPO_ROOT/app/android/upload-keystore.jks"
DEFAULT_PROPS="$REPO_ROOT/app/android/key.properties"

usage() {
  echo "Upload Android signing secrets for GitHub Actions (see docs/BUILD.md)."
  echo
  echo "Usage:"
  echo "  $0                                    # uses app/android/upload-keystore.jks + key.properties"
  echo "  $0 path/to/upload-keystore.jks"
  echo
  echo "Env (optional):"
  echo "  ANDROID_KEYSTORE_PATH  ANDROID_KEYSTORE_PASSWORD  ANDROID_KEY_PASSWORD"
  echo "  ANDROID_KEY_ALIAS      GH_REPO=owner/repo"
  echo
  echo "Or run end-to-end: ./scripts/bootstrap-android-signing-for-ci.sh   (after gh auth login)"
}

load_key_properties() {
  local f=$1
  [[ -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line//$'\r'/}
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    key=$(echo "$key" | tr -d '[:space:]')
    val=${val//$'\r'/}
    case "$key" in
      storePassword) KP_STORE_PW=$val ;;
      keyPassword) KP_KEY_PW=$val ;;
      keyAlias) KP_ALIAS=$val ;;
      storeFile) KP_STORE_FILE=$val ;;
    esac
  done <"$f"
  return 0
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

KP_STORE_PW=
KP_KEY_PW=
KP_ALIAS=
KP_STORE_FILE=

KEYSTORE=${ANDROID_KEYSTORE_PATH:-${1:-}}
if [[ -z "$KEYSTORE" ]]; then
  if [[ -f "$DEFAULT_KEYSTORE" ]]; then
    KEYSTORE=$DEFAULT_KEYSTORE
    echo "Using default keystore: $KEYSTORE"
  fi
fi

if [[ -z "$KEYSTORE" || ! -f "$KEYSTORE" ]]; then
  echo "ERROR: keystore not found."
  echo "Run: ./scripts/init-android-release-keystore.sh"
  echo "Or:  ANDROID_KEYSTORE_PATH=... $0"
  usage
  exit 1
fi

STORE_PW=${ANDROID_KEYSTORE_PASSWORD:-}
KEY_PW=${ANDROID_KEY_PASSWORD:-}
ALIAS=${ANDROID_KEY_ALIAS:-}

if [[ -f "$DEFAULT_PROPS" ]]; then
  load_key_properties "$DEFAULT_PROPS" || true
fi

if [[ -z "$STORE_PW" && -n "${KP_STORE_PW:-}" ]]; then
  STORE_PW=$KP_STORE_PW
fi
if [[ -z "$KEY_PW" && -n "${KP_KEY_PW:-}" ]]; then
  KEY_PW=$KP_KEY_PW
fi
if [[ -z "$ALIAS" && -n "${KP_ALIAS:-}" ]]; then
  ALIAS=$KP_ALIAS
fi
ALIAS=${ALIAS:-upload}

if [[ -z "$STORE_PW" ]]; then
  read -rsp "Keystore password (storePassword): " STORE_PW
  echo
fi
if [[ -z "$KEY_PW" ]]; then
  read -rsp "Key password (keyPassword): " KEY_PW
  echo
fi

if [[ -z "$STORE_PW" || -z "$KEY_PW" ]]; then
  echo "ERROR: passwords cannot be empty (create key.properties via init-android-release-keystore.sh)."
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
