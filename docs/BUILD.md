# Сборка L×Box

**Условные обозначения в этом файле**

| Значок | Смысл |
|--------|--------|
| ✓ | Есть / выполняется по умолчанию |
| ○ | Опционально или только при явном включении |
| ✗ | Нет / не делается по умолчанию |
| ⚠ | Запрет или важное предупреждение |

---

## Flutter-приложение

Каталог **`app/`** — проект L×Box. Зависимости подтягиваются через `flutter pub get`. Нативный VPN — `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/` (свой `BoxVpnService`, не Flutter plugin). libbox на Android — [JitPack](https://jitpack.io), пакет `io.github.sagernet:libbox:1.12.12`, репозиторий указан в `android/build.gradle.kts`.

Импорт конфига по кнопке **Read**: **JSON** или **JSON5/JSONC** (комментарии `//`, `/* */` — парсер `json5`), затем в ядро уходит канонический JSON; источник — буфер или системный диалог выбора файла.

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

### Локальная release-сборка с LOCAL BUILD маркером

Скрипт [`scripts/build-local-apk.sh`](../scripts/build-local-apk.sh) оборачивает `flutter build apk --release` с `--dart-define`'ами, которые подмешивают git describe:

```bash
./scripts/build-local-apk.sh
```

В About screen появится розовая плашка **«🧪 LOCAL BUILD · N commits since vX.Y.Z»** с git describe и временем сборки.

CI-сборки (через `flutter build apk --release` напрямую в `.github/workflows/ci.yml`) не передают эти defines → чистый релизный APK без маркера.

Передаваемые defines:

| `--dart-define` | Источник |
|-----------------|----------|
| `BUILD_LOCAL=true` | всегда (триггерит рендер плашки в About) |
| `BUILD_GIT_DESC` | `git describe --tags --long --dirty` |
| `BUILD_GIT_SHA` | `git rev-parse --short HEAD` |
| `BUILD_LAST_TAG` | `git describe --tags --abbrev=0` |
| `BUILD_COMMITS_SINCE_TAG` | `git rev-list <tag>..HEAD --count` |
| `BUILD_TIME` | `date -u +"%Y-%m-%d %H:%M UTC"` |

Скрипт требует `git` и JDK (для gradle). Остальные flutter-аргументы передаются через `"$@"`.

## Минимальный конфиг для проверки на телефоне

Файл **[`docs/examples/minimal_local_test.json`](examples/minimal_local_test.json)** — валидный sing-box JSON: только **tun** + **direct/block** в селекторе (без платного/чужого прокси), **Clash API** на `127.0.0.1:9090` без секрета. Подходит, чтобы убедиться, что **Read → Start** поднимает туннель и в UI появляются группа **proxy** и узлы **direct** / **block**. Интернет при этом идёт как обычно через direct (не «обход»).

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml): на **каждый push/PR в `main`** выполняется только джоб **`checks`** (`flutter analyze`, `flutter test`) — **без** сборки APK и без Java/Gradle (быстрее и дешевле).

| Что | Когда |
|-----|--------|
| `analyze` + `test` | ✓ каждый push/PR |
| `flutter build apk` + артефакты | ○ **не** на каждый коммит |

**Сборка APK** (джоб **`android`**) запускается, если:

- **Ручной запуск:** GitHub → **Actions** → **CI** → **Run workflow** → ветка **main** → при необходимости включить **«Собрать и выложить debug APK»** → **Run workflow**;
- или переменная репозитория **`BUILD_APK_ON_PUSH`** = `true` (тогда APK собирается и на push — как раньше на каждый коммит).

Из терминала (`gh auth login`):

```bash
gh workflow run CI                          # ✓ checks + release APK
gh workflow run CI -f build_debug_apk=true    # ○ + debug APK
```

Включить сборку APK на каждый push: `gh variable set BUILD_APK_ON_PUSH -b true` (потом выключить, если не нужно).

**Debug APK** — только в джобе **`android`** (см. выше). Если джоб не запускался (обычный push без **`BUILD_APK_ON_PUSH`**), debug не собирается.

| Способ | Отметка |
|--------|---------|
| Переменная **`BUILD_DEBUG_APK`** = `true` | ○ debug в каждом прогоне **`android`** (пока не выключите) |
| Ручной **`workflow_dispatch`** с **`build_debug_apk`** | ○ один раз |
| Иначе | ✗ только **release** APK |

Настройка **`BUILD_DEBUG_APK`:** веб **Variables** или `gh variable set BUILD_DEBUG_APK -b true`.

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

- ○ Другой репозиторий: `GH_REPO=owner/L×Box ./scripts/setup-android-ci-secrets.sh`

Перед `flutter build apk --release` workflow на раннере создаёт временные `app/android/upload-keystore.jks` и `app/android/key.properties` из секретов. Локальный **`flutter build apk --release`** после bootstrap использует те же файлы в `app/android/`.

- ⚠ Файлы keystore и `key.properties` с секретами **не коммитить**.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
