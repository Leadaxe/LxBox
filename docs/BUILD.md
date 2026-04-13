# Сборка BoxVPN

**Условные обозначения в этом файле**

| Значок | Смысл |
|--------|--------|
| ✓ | Есть / выполняется по умолчанию |
| ○ | Опционально или только при явном включении |
| ✗ | Нет / не делается по умолчанию |
| ⚠ | Запрет или важное предупреждение |

---

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

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`**:

| Шаг | Отметка |
|-----|---------|
| `flutter analyze` | ✓ |
| `flutter test` | ✓ |
| `flutter build apk --release` | ✓ |
| Артефакт **`android-apk-release`** | ✓ |
| `flutter build apk --debug` + **`android-apk-debug`** | ✗ (см. ниже, как включить) |

**Запустить CI вручную:** GitHub → **Actions** → **CI** → **Run workflow** → ветка **main** → опция **«Собрать и выложить debug APK»** при необходимости → **Run workflow**.

Из терминала (`gh auth login`):

```bash
gh workflow run CI                          # ✓ release
gh workflow run CI -f build_debug_apk=true  # ○ + debug APK
```

**Debug APK** (на любом trigger: push / PR / ручной запуск):

| Способ | Отметка |
|--------|---------|
| Переменная репозитория **`BUILD_DEBUG_APK`** = `true` | ○ (включает debug на каждом прогоне, пока не выключите) |
| Ручной запуск с **`build_debug_apk`** (см. команду выше) | ○ (один раз) |
| По умолчанию без переменной и без галочки | ✗ debug не собирается |

Настройка переменной (достаточно одного способа):

- **Веб:** **Settings → Secrets and variables → Actions → Variables**
- **CLI:** `gh variable set BUILD_DEBUG_APK -b true`

После прогона верните `false` или удалите переменную, чтобы push/PR снова не тянули debug.

### Подпись release (один ключ между сборками)

| Ситуация | Отметка |
|----------|---------|
| Секреты **`ANDROID_*`** заданы в Actions | ✓ Один и тот же ключ между сборками CI, обновление APK «поверх» возможно |
| Секретов нет | ○ Release подписан временным ключом раннера; «поверх» без переустановки обычно **нельзя** |

#### Сделать всё автоматически (рекомендуется)

В корне клонированного репозитория (нужны **JDK** с `keytool`, **openssl**, **`gh auth login`**):

```bash
./scripts/bootstrap-android-signing-for-ci.sh
```

| Результат скрипта | Отметка |
|-------------------|---------|
| `app/android/upload-keystore.jks` + `app/android/key.properties` | ✓ создаются при отсутствии (в [`.gitignore`](../app/android/.gitignore)) |
| Секреты в GitHub | ✓ заливаются через `gh` |
| Пароль в терминале при генерации | ○ сохраните в менеджер паролей (копия в локальном `key.properties`) |

Отдельные шаги:

```bash
./scripts/init-android-release-keystore.sh   # ✓ только keystore + key.properties
./scripts/setup-android-ci-secrets.sh          # ✓ только gh (пароли из key.properties)
```

- ○ Переопределить пароли при создании keystore: `ANDROID_SIGNING_PASSWORD='…' ./scripts/init-android-release-keystore.sh`
- ○ Пересоздать ключ: `FORCE=1 ./scripts/init-android-release-keystore.sh`

#### Секреты в GitHub (ручная настройка)

| Secret | Содержимое | Отметка |
|--------|------------|---------|
| `ANDROID_KEYSTORE_BASE64` | `openssl base64 -A -in upload-keystore.jks` (одна строка) | ✓ обязателен для своей подписи |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища | ✓ |
| `ANDROID_KEY_PASSWORD` | Пароль ключа | ✓ |
| `ANDROID_KEY_ALIAS` | Alias (например `upload`) | ✓ |

Вручную через **`gh`** (если не используете скрипт выше):

```bash
./scripts/setup-android-ci-secrets.sh app/android/upload-keystore.jks
```

- ○ Другой репозиторий: `GH_REPO=owner/BoxVPN ./scripts/setup-android-ci-secrets.sh`

Перед `flutter build apk --release` workflow на раннере создаёт временные `app/android/upload-keystore.jks` и `app/android/key.properties` из секретов. Локальный **`flutter build apk --release`** после bootstrap использует те же файлы в `app/android/`.

- ⚠ Файлы keystore и `key.properties` с секретами **не коммитить**.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
