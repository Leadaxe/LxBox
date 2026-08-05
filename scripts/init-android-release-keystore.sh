#!/usr/bin/env bash
# Создаёт app/android/upload-keystore.jks и app/android/key.properties (в .gitignore).
# Нужны: keytool (JDK 17+), openssl (для случайного пароля при необходимости).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ANDROID_DIR="$REPO_ROOT/app/android"
KEYSTORE="$ANDROID_DIR/upload-keystore.jks"
PROPS="$ANDROID_DIR/key.properties"
ALIAS=${ANDROID_KEY_ALIAS:-upload}

usage() {
  echo "Create local Android release keystore + key.properties (not committed)."
  echo
  echo "Usage: $0"
  echo
  echo "Optional env:"
  echo "  ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD — явные пароли"
  echo "  ANDROID_SIGNING_PASSWORD — один пароль на store и key"
  echo "  ANDROID_KEY_ALIAS — alias (default: upload)"
  echo "  FORCE=1 — пересоздать, если .jks уже есть"
  echo "  ASSUME_YES=1 — пропустить подтверждение создания НОВОГО ключа"
  echo
  echo "Then: ./scripts/setup-android-ci-secrets.sh   (gh auth login first)"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v keytool >/dev/null 2>&1; then
  echo "ERROR: keytool not found. Install JDK 17 (e.g. brew install temurin@17)."
  exit 1
fi

mkdir -p "$ANDROID_DIR"

if [[ -f "$KEYSTORE" && "${FORCE:-}" != "1" ]]; then
  echo "ERROR: $KEYSTORE already exists. Set FORCE=1 to replace (old key will be lost)."
  exit 1
fi

if [[ -f "$KEYSTORE" && "${FORCE:-}" == "1" ]]; then
  rm -f "$KEYSTORE" "$PROPS"
fi

STORE_PW=${ANDROID_KEYSTORE_PASSWORD:-}
KEY_PW=${ANDROID_KEY_PASSWORD:-}
if [[ -n "${ANDROID_SIGNING_PASSWORD:-}" ]]; then
  STORE_PW=$ANDROID_SIGNING_PASSWORD
  KEY_PW=$ANDROID_SIGNING_PASSWORD
fi

if [[ -z "$STORE_PW" || -z "$KEY_PW" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: set ANDROID_SIGNING_PASSWORD or install openssl to generate a password."
    exit 1
  fi
  # hex — без спецсимволов, удобно для gh / Gradle
  GEN=$(openssl rand -hex 16)
  STORE_PW=$GEN
  KEY_PW=$GEN
  echo "Generated passwords (save in a password manager):" >&2
  echo "  $GEN" >&2
fi

# Скрипт генерирует НОВУЮ ключевую пару. Восстановить существующий релизный
# ключ он не может — совпадающий -dname даёт другой сертификат и другой
# отпечаток, потому что ключевая пара каждый раз случайная.
cat >&2 <<'WARN'

=============================== ВНИМАНИЕ ===============================
Это создаст НОВЫЙ ключ, а не восстановит существующий.

Релизный ключ LxBox (выпущен 14.04.2026):
  SHA256 7987AEC41D6521B56BDEEC202E383EDCFF27963918B109B69791BF1F6636C1C4

APK, подписанный новым ключом, НЕ установится поверх уже установленного
(INSTALL_FAILED_UPDATE_INCOMPATIBLE) и разорвёт цепочку обновлений в
F-Droid. Пользователям придётся удалять приложение с потерей данных.

Единственный способ вернуть релизный ключ — восстановить upload-keystore.jks
из бэкапа. Секрет ANDROID_KEYSTORE_BASE64 в GitHub Actions прочитать нельзя.

Продолжайте только если поднимаете отдельную сборочную линию (форк, тестовая
подпись) либо сознательно переходите на новый ключ.
========================================================================

WARN

if [[ -t 0 && "${ASSUME_YES:-}" != "1" ]]; then
  read -r -p "Type 'new key' to continue: " CONFIRM
  if [[ "$CONFIRM" != "new key" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
elif [[ "${ASSUME_YES:-}" != "1" ]]; then
  echo "ERROR: non-interactive run. Set ASSUME_YES=1 to confirm new key creation." >&2
  exit 1
fi

echo "Creating keystore: $KEYSTORE"
keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storetype JKS \
  -storepass "$STORE_PW" \
  -keypass "$KEY_PW" \
  -dname "CN=BoxVPN, OU=Dev, O=Leadaxe, L=Moscow, ST=Moscow, C=RU"

umask 077
cat >"$PROPS" <<EOF
storePassword=$STORE_PW
keyPassword=$KEY_PW
keyAlias=$ALIAS
storeFile=upload-keystore.jks
EOF

echo "Wrote $PROPS (gitignored)."
echo "Next: gh auth login && ./scripts/setup-android-ci-secrets.sh"
