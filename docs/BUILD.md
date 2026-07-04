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

Каталог **`app/`** — проект L×Box. Зависимости подтягиваются через `flutter pub get`. Нативный VPN — `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/` (свой `BoxVpnService`, не Flutter plugin). libbox на Android — fork **[`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)** (ветка `lx-1.14`): AWG/AWG2 (AmneziaWG) + нативный XHTTP ([§097](spec/features/097%20awg2-amneziawg2/spec.md)) + MASQUE/idle-suspend/balancer. AAR подключается файлом `app/android/app/libs/libbox.aar` (в `build.gradle` — относительный `files("libs/libbox.aar")`), скачивание и пин версии — [§104](spec/tasks/104-libbox-fork-ci-fetch.md); см. раздел [«Ядро sing-box-lx (libbox)»](#ядро-sing-box-lx-libbox). История пина: стоковый `com.github.singbox-android:libbox:1.13.11` с JitPack ([task §060](spec/tasks/060-libbox-1-13-migration/spec.md)) ← `io.github.sagernet:libbox:1.12.12`.

Импорт конфига по кнопке **Read**: **JSON** или **JSON5/JSONC** (комментарии `//`, `/* */` — парсер `json5`), затем в ядро уходит канонический JSON; источник — буфер или системный диалог выбора файла.

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

### Локальная release-сборка

Скрипт [`scripts/build-local-apk.sh`](../scripts/build-local-apk.sh) — канонический способ собрать локальный release-APK (минимальный, arm64-only):

```bash
./scripts/build-local-apk.sh
```

| Что делает | Отметка |
|------------|---------|
| Версия в pubspec: build-number **запинен к последнему релизному тегу** (§186, см. ниже); versionName = `X.Y.Z` на теге, иначе `X.Y.Z-dev.<since>` | ✓ |
| `scripts/fetch-libbox.sh` — ядро sing-box-lx по пину `app/android/libbox.version`, идемпотентно (см. [«Ядро sing-box-lx»](#ядро-sing-box-lx-libbox)) | ✓ |
| `--split-per-abi --target-platform android-arm64` — APK только под arm64 (выход `app-arm64-v8a-release.apk`) | ✓ |
| `flutter build apk --release` (доп. аргументы — через `"$@"`) | ✓ |
| `--dart-define`-маркеры (`BUILD_LOCAL`, `BUILD_GIT_DESC`, …) | ✗ убраны в §065/§066: версия живёт в pubspec, About читает `PackageInfo` |

Требует `git` и JDK (для gradle); ядро `app/android/app/libs/libbox.aar` скрипт скачивает сам.

##### ⚠ Сборка виснет (CPU≈0) — memory-starvation stall

`app/android/gradle.properties` задаёт `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G …`. На машине с 16 ГБ RAM Gradle heap + metaspace + Kotlin/dex-воркеры не влезают → процесс уходит в своп, `assembleRelease` зависает с CPU≈0 (не компиляция, а stall).

| | |
|---|---|
| Симптом | `flutter build apk` стоит на `assembleRelease` минутами; `ps aux \| grep java` — CPU java-процессов <5% |
| Фикс | освободить RAM (закрыть тяжёлые приложения), снести залипший daemon (`pkill -f gradle` или `rm -rf ~/.gradle/daemon`), пересобрать с ограничением: `GRADLE_OPTS='-Dorg.gradle.jvmargs=-Xmx5G' ./scripts/build-local-apk.sh --no-daemon` + при желании `--max-workers=4` |
| Радикально | снизить `-Xmx` в `gradle.properties` под объём RAM машины |

#### versionCode — как считается и почему пинится к тегу ([§186](spec/tasks/186-local-build-vc-pin-to-tag.md))

**Кто что добавляет** (проверено `aapt dump badging` на собранном APK):

| Слой | Значение | Кто |
|------|----------|-----|
| `pubspec.yaml` `version: X.Y.Z+<build-number>` | build-number = **голый номер коммита** (`git rev-list --count`) | CI и локальный скрипт пишут это |
| ABI-множитель `+abiCode×1000` (arm64=2 → **+2000**) | добавляет **сам Flutter** при `--split-per-abi` (из коробки, `flutter.gradle`) | автоматически, одинаково CI и локально |
| Итог в манифесте APK | `versionCode = build-number + 2000` | — |

⚠ Поэтому ручной бамп `versionCode` НЕ нужен и НЕ применять — множитель Flutter общий для всех сборок.

**Почему пин к тегу (а не к HEAD):** релиз CI собирается на коммите тега → `build-number = count(tag)`. Локальная сборка на ветке разработки имеет коммитов БОЛЬШЕ → `count(HEAD) > count(tag)` → локальный vc обгонял бы релизный → релиз с интернета не вставал бы поверх (downgrade-блок, боль «не могу скачивать собственные релизы»). Скрипт пинит `build-number = git rev-list --count <last-vN.N.N-tag>` → локальный arm64 vc = **ровно релизный**. При равном vc `adb install -r` проходит в обе стороны (блок только на СТРОГО меньший vc).

| Случай | build-number | Поведение |
|--------|--------------|-----------|
| На ветке есть тег `vN.N.N` | `count(<last-tag>)` | локальный vc = релизный → релиз ставится поверх локалки и наоборот |
| Тега нет вовсе | `count(HEAD)` (fallback, `version: 0.0.0+<count>`) | downgrade-риск неактуален без релизов |
| После НОВОГО релиза (новый тег) | подтянется к новому тегу автоматически | самоподдерживается |

## Ядро sing-box-lx (libbox)

С §097 ядро приложения — fork **[`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)** (ветка `lx-1.14`), не стоковый sing-box.

| Что | Отметка |
|-----|---------|
| AWG/AWG2 (AmneziaWG) поля в `wireguard`-endpoint'е | ✓ build-тег `with_awg` |
| Нативный транспорт `type:"xhttp"` (Xray splithttp) | ✓ build-тег `with_xhttp` |
| Релиз на стоковом `com.github.singbox-android:libbox:1.13.11` | ⚠ **невозможен** — стоковое ядро отвергает конфиги с AWG-полями и `xhttp` |

Fork публикует артефакты в своих GitHub Releases (workflow `lx-release.yml`):

| Артефакт | Отметка |
|----------|---------|
| `libbox-<ver>.aar` (modern: minSdk 23, 4 ABI, ~73 MB) | ✓ наш вариант |
| `libbox-legacy-<ver>.aar` (minSdk 21) | ✗ не используем — у нас minSdk 24, modern-AAR (minSdk 23) достаточно |
| `SHA256SUMS` | ✓ верификация скачанного AAR |

Версию ядра отдаёт `Libbox.version()` (About/Debug), формат `1.14.0-lx.N` (текущий пин — `v1.14.0-lx.1`).

### Как ядро попадает в сборку ([§104](spec/tasks/104-libbox-fork-ci-fetch.md))

`app/android/app/libs/` в `.gitignore` (AAR ~73 MB не коммитится); `app/android/app/build.gradle.kts` подключает ядро файлом:

```kotlin
implementation(files("libs/libbox.aar"))
```

AAR кладёт [`scripts/fetch-libbox.sh`](../scripts/fetch-libbox.sh): скачивает `libbox-<ver>.aar` + `SHA256SUMS` из GH Releases fork'а, проверяет хеш и пишет маркер `.libbox.version` (повторный запуск той же версии — no-op). Пин версии — файл **`app/android/libbox.version`**, single source of truth для local и CI:

| Кто вызывает fetch | Отметка |
|--------------------|---------|
| `scripts/build-local-apk.sh` (локальная сборка) | ✓ автоматически |
| `ci.yml` → job `android` → шаг `Fetch sing-box-lx core (libbox.aar)` | ✓ автоматически |
| Вручную (свежий clone, `flutter build` без скрипта): `./scripts/fetch-libbox.sh`; override версии — `./scripts/fetch-libbox.sh v1.14.0-lx.N` | ○ |

Джобу `checks` AAR не нужен (`flutter analyze`/`test` — pure Dart).

Отвергнутые альтернативы доставки ядра в CI:

| Вариант | Отметка |
|---------|---------|
| **Скачивание из GH Releases fork'а + `files("libs/libbox.aar")`** | ✓ **выбранный путь**: репо публичный (curl без токена), `SHA256SUMS`-верификация, пин одним файлом `libbox.version` |
| JitPack (`com.github.Leadaxe.sing-box-lx:libbox:<tag>`) | ✗ JitPack собирает из исходников — `gomobile bind` (Go + NDK) на его билдерах не работает, готовые AAR из Releases он не раздаёт |
| GitHub Packages (Maven) | ✗ требует токен даже для public-пакетов (у каждого клона и в CI) + отдельный maven-publish шаг в `lx-release.yml` fork'а |

- ⚠ Обновление ядра = поднять пин в `app/android/libbox.version`, пересобрать локально (fetch сам перекачает AAR), прогнать smoke (Start/Stop, vless+wg+awg regression) и обновить раздел [«Версии»](#версии).

## Минимальный конфиг для проверки на телефоне

Файл **[`docs/examples/minimal_local_test.json`](examples/minimal_local_test.json)** — валидный sing-box JSON: только **tun** + **direct/block** в селекторе (без платного/чужого прокси). Подходит, чтобы убедиться, что **Read → Start** поднимает туннель и в UI появляются группа **proxy** и узлы **direct** / **block**. Интернет при этом идёт как обычно через direct (не «обход»).

⚠ Управление ядром — через **libbox CommandClient**, не Clash HTTP (Clash API выпилен в §122). Блок `experimental.clash_api` в конфиге на нашем ядре (собрано без `with_clash_api`) даёт **фатальный отказ старта** (`clash api is not included in this build`) — в конфиг для проверки его класть **нельзя**.

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); полный протокол релиза — [RELEASE_PROCESS.md](RELEASE_PROCESS.md).

| Событие | Что запускается |
|---------|-----------------|
| push / PR в `main`, `develop` | ✓ только `checks` (`flutter analyze`, `flutter test`) — без Java/Gradle |
| push tag `v*` | ✓ `meta` + `checks` + `android` + `release` + `publish-manifest` (полный релиз) |
| `workflow_dispatch`, `run_mode=checks` | ○ только `checks` |
| `workflow_dispatch`, `run_mode=build` | ○ `checks` + `android` (APK в artifacts, без релиза) |
| `workflow_dispatch`, `run_mode=release` | ○ полный релиз без тега (экстренные перевыпуски) |

Из терминала (`gh auth login`):

```bash
gh workflow run CI -f run_mode=checks   # ✓ analyze + test
gh workflow run CI -f run_mode=build    # ○ + APK в artifacts
```

Джоб `android` собирает **только release**-APK: universal (fat, все ABI) + 3 per-ABI через `--split-per-abi` (arm64-v8a / armeabi-v7a / x86_64). Debug-APK CI не собирает. Перед сборкой шаг `Fetch sing-box-lx core` скачивает fork-ядро по пину `app/android/libbox.version` (см. [«Ядро sing-box-lx»](#ядро-sing-box-lx-libbox)).

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
- Ядро — **sing-box-lx `v1.14.0-lx.1`** (ветка форка `lx-1.14`): пин в `app/android/libbox.version` (single source для local + CI, читает `scripts/fetch-libbox.sh`); локальный `app/android/app/libs/libbox.aar` должен совпадать с пином (fetch следит через маркер `.libbox.version`). Единственный источник правды по версии/build-тегам ядра — [KERNEL.md](KERNEL.md) + сам пин-файл. При обновлении — поднять пин, пересобрать локально, прогнать smoke и обновить эту строку.
