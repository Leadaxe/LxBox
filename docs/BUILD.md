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

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, `flutter build apk` (**debug** и **release**) и выкладывает артефакты **`android-apk-debug`** и **`android-apk-release`** (вкладка **Actions** → последний run → **Artifacts**).

### Подпись release (один ключ между сборками)

Без секретов release APK в CI подписывается **временным debug-keystore раннера** (подпись каждый раз другая → обновление «поверх» невозможно).

Чтобы артефакты с CI ставились как обновление одного и того же приложения, в репозитории GitHub → **Settings → Secrets and variables → Actions** задайте:

| Secret | Содержимое |
|--------|------------|
| `ANDROID_KEYSTORE_BASE64` | Содержимое `.jks` в base64 **одной строкой** (удобно: `openssl base64 -A -in upload-keystore.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища |
| `ANDROID_KEY_PASSWORD` | Пароль ключа |
| `ANDROID_KEY_ALIAS` | Alias ключа (как при `keytool -genkey`) |

Перед `flutter build apk --release` workflow создаёт `app/android/upload-keystore.jks` и `app/android/key.properties` (оба в `.gitignore`). Локально для релизной сборки положите свой `key.properties` и `.jks` в `app/android/` по тому же формату (см. [`app/android/.gitignore`](../app/android/.gitignore)).

Пример создания keystore (один раз):

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Файл `upload-keystore.jks` и пароли **не коммитить**.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
