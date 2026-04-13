# Сборка BoxVPN

## Flutter-приложение

Каталог **`app/`** — проект BoxVPN. Зависимости подтягиваются через `flutter pub get` (в т.ч. **`flutter_singbox_vpn`**, libbox на Android с [JitPack](https://jitpack.io) — репозиторий указан в `android/build.gradle.kts`). Импорт конфига по кнопке **Read**: **JSON** или **JSON5/JSONC** (комментарии `//`, `/* */` — парсер `json5`), затем в ядро уходит канонический JSON; источник — буфер или системный диалог выбора файла.

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

## Минимальный конфиг для проверки на телефоне

Файл **[`docs/examples/minimal_local_test.json`](examples/minimal_local_test.json)** — валидный sing-box JSON: только **tun** + **direct/block** в селекторе (без платного/чужого прокси), **Clash API** на `127.0.0.1:9090` без секрета. Подходит, чтобы убедиться, что **Read → Start** поднимает туннель и в UI появляются группа **proxy** и узлы **direct** / **block**. Интернет при этом идёт как обычно через direct (не «обход»).

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, **`flutter build apk --release`** и выкладывает артефакт **`android-apk-release`**. **Debug APK по умолчанию не собирается** (экономия времени CI).

Чтобы в том же workflow получить **debug**-APK, задайте **переменную репозитория** **`BUILD_DEBUG_APK`** = `true`:

- GitHub: **Settings → Secrets and variables → Actions → Variables** → New repository variable.
- CLI из клона: `gh variable set BUILD_DEBUG_APK -b true` (затем push или re-run workflow).

После прогона верните `false` или удалите переменную, чтобы снова не собирать debug на каждый push.

### Подпись release (один ключ между сборками)

Без секретов release APK в CI подписывается **временным debug-keystore раннера** (подпись каждый раз другая → обновление «поверх» невозможно).

#### Сделать всё автоматически (рекомендуется)

В корне клонированного репозитория (нужны **JDK** с `keytool`, **openssl**, **`gh auth login`**):

```bash
./scripts/bootstrap-android-signing-for-ci.sh
```

Скрипт при необходимости создаст **`app/android/upload-keystore.jks`** и **`app/android/key.properties`** (оба в [`.gitignore`](../app/android/.gitignore)), затем зальёт четыре секрета в GitHub Actions. Случайный пароль при генерации выводится в терминал — **сохраните его** (копия уже в `key.properties` локально).

Отдельные шаги:

```bash
./scripts/init-android-release-keystore.sh   # только keystore + key.properties
./scripts/setup-android-ci-secrets.sh        # только gh (пароли из key.properties)
```

Переопределить пароли при создании keystore: `ANDROID_SIGNING_PASSWORD='…' ./scripts/init-android-release-keystore.sh`. Пересоздать ключ: `FORCE=1 ./scripts/init-android-release-keystore.sh`.

#### Секреты в GitHub (ручная настройка)

| Secret | Содержимое |
|--------|------------|
| `ANDROID_KEYSTORE_BASE64` | `openssl base64 -A -in upload-keystore.jks` (одна строка) |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища |
| `ANDROID_KEY_PASSWORD` | Пароль ключа |
| `ANDROID_KEY_ALIAS` | Alias (например `upload`) |

Вручную через **`gh`** (если не используете скрипт выше):

```bash
./scripts/setup-android-ci-secrets.sh app/android/upload-keystore.jks
```

Другой репозиторий: `GH_REPO=owner/BoxVPN ./scripts/setup-android-ci-secrets.sh`.

Перед `flutter build apk --release` workflow на раннере создаёт временные `app/android/upload-keystore.jks` и `app/android/key.properties` из секретов. Локальный **`flutter build apk --release`** после bootstrap использует те же файлы в `app/android/`.

Файлы keystore и `key.properties` с секретами **не коммитить**.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
