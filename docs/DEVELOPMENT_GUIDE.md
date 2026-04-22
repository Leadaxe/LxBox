# Руководство по разработке L×Box

## Философия проекта

L×Box разрабатывается по методологии **spec-driven vibe coding** — каждая возможность сначала описывается как спецификация, затем реализуется. Это обеспечивает:

- Прозрачность: любой разработчик видит что реализовано, что запланировано
- Контроль качества: критерии приёмки в каждой спеке
- Историю решений: почему сделано именно так
- Возможность параллельной работы с AI-ассистентами (Claude Code)

---

## Структура документации

```
docs/
  spec/
    features/
      001 mobile stack/spec.md      # Каждая фича — отдельная папка
      002 mvp scope/spec.md         # spec.md — основной документ
      ...                           # plan.md, tasks.md — опционально
      038 subscription detail/spec.md
    tasks/
      README.md                     # Когда и как вести task-лог
      NNN-kebab-title.md            # Конкретный рабочий цикл (баг, pass, рефакторинг)
  ARCHITECTURE.md                   # Архитектура проекта
  BUILD.md                          # Инструкции по сборке
  DEVELOPMENT_REPORT.md             # История разработки по этапам
  DEVELOPMENT_GUIDE.md              # Этот документ
  screenshots/                      # Скриншоты для README
README.md                           # Главная документация
CHANGELOG.md                        # Список изменений по версиям
```

### Формат спецификации фичи

Каждая спека содержит:
1. **Статус**: Реализовано / Спека / В работе
2. **Контекст**: зачем нужна фича, какую проблему решает
3. **Реализация**: как сделано (архитектура, модели, UI)
4. **Файлы**: таблица затронутых файлов
5. **Критерии приёмки**: чеклист с галочками

**Фичи vs задачи:** в `docs/spec/features/` — описание возможности («что это и как устроено»). В [`docs/spec/tasks/`](./spec/tasks/README.md) — журнал отдельных рабочих циклов: баг с нетривиальным root cause, perf-pass, рефакторинг с последствиями; формат и критерии — в `README` папки.

Актуальные спеки в `docs/spec/features/001 mobile stack/` … `029 haptic feedback/`. Крупные:
- **026** — Parser v2 (sealed `NodeSpec`, 3-слойный pipeline) — landmark-рефакторинг v1.3.0.
- **027** — Subscription auto-update (4 триггера + hard gates против спама).
- **028** — AntiDPI mixed-case SNI.
- **029** — Haptic feedback.

---

## Архитектурные принципы

### 1. Единый источник настроек: wizard_template.json

**Все** базовые значения приложения определяются в `assets/wizard_template.json`:

| Секция | Что хранит |
|--------|-----------|
| `dns_options` | DNS серверы (16 пресетов) + правила |
| `ping_options` | URL, timeout, пресеты для пинга |
| `speed_test_options` | Серверы, потоки, ping URLs |
| `preset_groups` | Proxy группы (auto/selector/vpn) |
| `vars` | Все конфигурационные переменные |
| `selectable_rules` | Правила маршрутизации с SRS |
| `config` | Каркас sing-box конфига |

**Правило**: если нужно добавить новый default — добавляй в wizard_template.json, не хардкодь в Dart.

Пользовательские override хранятся в `lxbox_settings.json` (через SettingsStorage).

### 2. Autosave вместо Apply

**Базовое правило:** на простых экранах настроек (списки переключателей, полей без «черновика») — debounce-таймер (500мс). При изменении:
1. `_scheduleSave()` отменяет предыдущий таймер и ставит новый
2. Через 500мс `_apply()` сохраняет в storage и пересобирает конфиг
3. Если VPN активен — показывает "Restart VPN to apply changes"

**Исключение — сложные формы** (много взаимосвязанных полей, высокий риск случайных правок или половины заполненного состояния): делаем **явное сохранение** (кнопка Save / Apply в панели действий или внизу экрана) и **диалог при уходе назад**, если есть несохранённые изменения («сбросить / остаться»). Пример в коде: редактор пользовательского правила (`custom_rule_edit_screen.dart` — `PopScope` + «Discard changes?»).

На таких экранах **не** полагаемся на debounce-autosave для каждого поля — пользователь подтверждает готовый набор параметров одним действием.

### 3. Offline-first

Приложение должно работать без интернета:
- Подписки кэшируются на диск (`sub_cache/`)
- Node filter читает из configRaw (уже сгенерированный конфиг)
- Конфиг генерируется из кэша при сетевой ошибке
- DNS серверы из шаблона доступны всегда

**Интернет нужен только для**: скачивания подписок (по кнопке refresh), SRS rule sets, speed test.

### 4. Config generation pipeline (Parser v2)

```
SettingsStorage (server_lists) + WizardTemplate
        ↓
buildConfig(lists, settings)  ─  spec 026
  1. Load template, substitute @vars
  2. For each ServerList: list.build(ctx: EmitContext)
      ├─ per-node emit(vars) → SingboxEntry (Outbound | Endpoint)
      ├─ allocateTag with tagPrefix
      └─ apply detour policy (register/use/override)
  3. Post-steps (ordered):
      ├─ applyTlsFragment       — first-hop only, skip on detour
      ├─ applyMixedCaseSni      — randomise server_name case (spec 028)
      ├─ applyCustomDns         — user DNS override or template defaults
      ├─ applySelectableRules   — routing rule_sets + rules
      └─ applyAppRules          — package_name routing
  4. Cache remote SRS (parallel)
  5. validator → ValidationResult{ fatal[], warnings[] }
  6. → BuildResult{ config, configJson, validation, emitWarnings }
```

HTTP-fetch подписок **не** происходит в этом пайплайне — за это отвечает `AutoUpdater` (spec 027). Rebuild config — чисто локальная сборка из уже-загруженных nodes.

---

## На что обращать внимание

### Критические риски

#### 1. sing-box dependency resolution
sing-box при старте проверяет что все outbound'ы, на которые ссылаются группы, существуют. Если `auto-proxy-out` пустой (или не создан потому что Include Auto off), а `vpn-1` на него ссылается — **краш**. Поэтому в `_buildPresetOutbounds` при пустой urltest-группе делается `continue`, а у selector-групп `default` удаляется, если указывает на несуществующий tag (`options.remove('default')`).

**Что делать:**
- Пустые urltest группы не создавать (`continue`)
- Selector группы при пустых нодах получают `direct-out` fallback
- Валидировать `knownTags` перед добавлением в `addOutbounds`
- Тестировать: отключить все подписки → запустить VPN → не должно падать

#### 2. local.properties sdk.dir
Flutter перезаписывает `sdk.dir` при каждом запуске. Нужно:
- `ANDROID_HOME` и `ANDROID_SDK_ROOT` в `~/.zprofile`
- Или `sed` перед сборкой: `sed -i '' 's|sdk.dir=.*|sdk.dir=/usr/local/share/android-commandlinetools|'`

#### 3. Подпись APK
Debug и release APK имеют разные подписи. `adb install -r` не сработает при смене подписи — нужен `adb uninstall` + `adb install`. При этом **теряются все настройки**.

#### 4. VPN permissions
Android требует подтверждения VPN permission при первом запуске. Если пользователь отказал — `onRevoke` в VpnService. Нужно корректно обрабатывать этот случай.

#### 5. Clash API порт
Clash API слушает на рандомном порту (49152-65535). При перезапуске sing-box порт может измениться. ClashEndpoint парсится из configRaw при каждом старте.

### Частые ошибки

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `dependency not found for outbound` | Пустая группа или ссылка на несуществующий outbound | Валидация knownTags, fallback direct-out |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Смена debug/release | `adb uninstall` перед install |
| `Failed to start service` | Старый libbox ресурс не очищен | Cleanup stale resources before start |
| Бесконечный loading | `_loading = true` при initState без загрузки | Установить `_loading = false` или вызвать load |
| Node filter пустой | configRaw пустой (первый запуск) | Показать "Generate config first" |
| Подписка не обновляется | `enabled = false` | Проверять enabled перед fetch |

### Тестирование

#### Обязательные сценарии перед релизом
1. **Чистая установка**: uninstall → install → Get Free VPN → Start → работает
2. **Обновление**: install -r (та же подпись) → настройки сохранились
3. **Offline**: выключить интернет → открыть приложение → конфиг из кэша → node filter работает
4. **Все подписки disabled**: отключить все → Start → не крашится (vpn-1 с direct-out fallback)
5. **Все ноды excluded**: убрать все в node filter → auto-proxy-out не создаётся → vpn-1 работает
5a. **Include Auto off**: выключить галку → секция `auto-proxy-out` не генерируется, `vpn-*` не содержат её в add_outbounds, default у vpn-1 сбрасывается
6. **Speed test**: VPN включен → speed test → показывает прокси, результат > 0
7. **DNS settings**: изменить серверы → перезапустить VPN → DNS резолвит
8. **App routing**: создать группу → добавить приложения → трафик идёт через outbound

#### flutter analyze + tests
Перед каждым коммитом:
```bash
cd app && flutter analyze lib/ test/
cd app && flutter test
```
**0 issues** в analyze и **все тесты зелёные** — обязательно.

Сейчас 128 тестов:
- `test/models/` — sealed hierarchies (NodeSpec, NodeWarning, ServerList JSON)
- `test/parser/` — URI/JSON/INI парсеры + round-trip (parseUri → toUri → parseUri)
- `test/builder/` — build_config, validator, mixed-case SNI
- `test/subscription/` — sources (UrlSource/InlineSource/QrSource/File), content-disposition, inline headers
- `test/migration/` — proxy_sources → server_lists one-shot
- `test/services/` — haptic_service
- `test/pipeline_e2e_test.dart` — full InlineSource → parseFromSource → buildConfig

---

## Процесс разработки

### 1. Spec first
Перед реализацией — создать `docs/spec/features/NNN name/spec.md`. Даже для мелких фич. Для нетривиальных багфиксов и одноразовых работ (без новой «фичи» в продуктовом смысле) — при необходимости завести отчёт в `docs/spec/tasks/NNN-title.md` по шаблону из [`docs/spec/tasks/README.md`](./spec/tasks/README.md). Это:
- Фиксирует решение до написания кода
- Даёт контекст для AI-ассистента
- Служит документацией после реализации

### 2. Инкрементальные коммиты
Каждый коммит — одна логическая единица:
- `feat:` — новая фича
- `fix:` — баг-фикс
- `refactor:` — рефакторинг без изменения поведения
- `docs:` — документация
- `ci:` — CI/CD
- `release:` — версия

### 3. Сборка и деплой
```bash
# Локальная релизная сборка с LOCAL BUILD badge (рекомендуется для dev)
./scripts/build-local-apk.sh
adb install -r app/build/app/outputs/flutter-apk/app-release.apk

# Релизная сборка без маркера (как CI)
cd app && flutter build apk --release
```

### 4. Процесс релиза

CI workflow (`.github/workflows/ci.yml`) при push тега `v*` собирает release APK и создаёт GitHub Release с телом из `RELEASE_NOTES.md`. Нужно:

1. **Обновить `app/pubspec.yaml`** — `version: X.Y.Z+N` (bump patch/minor, +build number).
2. **Обновить `app/lib/screens/about_screen.dart`** — `static const _version = 'X.Y.Z';` (hardcoded — хочется поменять на `package_info_plus`, но пока так).
3. **Добавить секцию в `CHANGELOG.md`** `## [X.Y.Z] — YYYY-MM-DD` — вверху, под `# Changelog`.
4. **Создать `docs/releases/vX.Y.Z.md`** — подробные release notes (EN видимые + RU под `<details>`, см. v1.3.0/v1.3.1 как эталон).
5. **Синхронизировать `RELEASE_NOTES.md`** ← `docs/releases/vX.Y.Z.md` (CI читает корневой файл для тела GitHub release).
6. **Коммит + tag + push:**
   ```bash
   git add -A
   git commit -m "release: vX.Y.Z"
   git tag -a vX.Y.Z -m "vX.Y.Z — short description"
   git push origin main
   git push origin vX.Y.Z
   ```
7. CI автоматически собирает APK и публикует Release.

**Не забыть:** если `RELEASE_NOTES.md` осталось со старой версии — тело автоматического релиза будет неправильным. Для таких случаев — `gh release edit vX.Y.Z --notes-file docs/releases/vX.Y.Z.md` (было с v1.3.0, v1.3.1).

### 5. Версионирование
- `pubspec.yaml`: `version: X.Y.Z+N`
- Git tag: `vX.Y.Z`
- X — мажор (breaking changes)
- Y — минор (новые фичи)
- Z — патч (фиксы)
- N — build number (инкремент)

---

## Работа с AI-ассистентом (Claude Code)

### CLAUDE.md
Файл `app/CLAUDE.md` содержит контекст проекта для AI-сессий (build commands, paths, gradle quirks, spec layout). **В `.gitignore`** — каждый разработчик/агент поддерживает свою копию локально. В репозитории эталонного файла нет. Если нужен шаблон — смотри какой у других dev'ов через `@` or generate via `/init` в Claude Code.

### Memory
Persistent memory в `~/.claude/projects/` хранит:
- Настройки сборки (SDK paths, ADB)
- Предпочтения (локальные сборки, не CI)
- Контекст текущей сессии

### Remote Control
Для работы с телефона:
```
/remote-control
```
Открыть ссылку в браузере телефона — полный доступ к сессии.

### Эффективные паттерны
- Сборка в фоне (`run_in_background`) пока работаешь над другим
- Мониторинг CI и локальной сборки параллельно
- Автоустановка APK после сборки через ADB
- `flutter analyze` перед каждым коммитом
- Спеки создавать через Agent для параллельной записи

---

## Detour Server Management

Полная спецификация: [018 detour server management](./spec/features/018%20detour%20server%20management/spec.md).

### Что такое detour-серверы

Detour-серверы — промежуточные (chained) прокси, через которые трафик идёт до конечного сервера. В UI отображаются с префиксом **⚙**. В Parser v2 это NodeSpec'и, привязанные через поле `chained` (полный вложенный spec) или через `overrideDetour` на уровне `ServerList.detourPolicy`.

### Per-subscription settings (`ServerList.detourPolicy`)

| Настройка | Поле | Описание |
|-----------|------|----------|
| **Register** | `registerDetourServers` | Добавить ⚙ ноды в selector-группы (видны в списке) |
| **Register in Auto** | `registerDetourInAuto` | Добавить ⚙ ноды в auto-proxy-out urltest |
| **Use** | `useDetourServers` | Использовать `chained` цепочки нод этой подписки; если off — detour удаляется |
| **Override** | `overrideDetour` | Principиально назначить tag detour для всех нод подписки — перезаписывает main.map['detour'] |

Defaults: `registerDetourServers=false`, `useDetourServers=true`, остальные false/empty (v1.3.0).

### Как builder обрабатывает detour (Parser v2)

`ServerList.build(ctx)` в [`services/builder/server_list_build.dart`](../app/lib/services/builder/server_list_build.dart):

1. `skipDetour = !useDetourServers || overrideDetour.isNotEmpty`
2. `server.getEntries(ctx, skipDetour)` — если skip, в `NodeEntries.detours` пусто.
3. Детуры первыми (allocateTag с префиксом) → main.
4. **Detour policy** на main:
   - `overrideDetour.isNotEmpty` → `main.map['detour'] = overrideDetour`
   - `!useDetourServers` → `main.map.remove('detour')`
   - `detours.isNotEmpty` → `main.map['detour'] = detours.first.tag`
   - иначе — оставляем как emit'нулось (может быть из `NodeSpec.chained`).
5. Регистрация: main → selector + auto; детуры — по `registerDetourServers` / `registerDetourInAuto`.

### Persistent detour reference для single-node UserServer

Для `UserServer` (один добавленный сервер) detour задаётся через dropdown в `NodeSettingsScreen` → пишет в `entry.detourPolicy.overrideDetour` (не в JSON ноды!) → `persistSources` → builder применяет.

Почему не в JSON: `parseSingboxEntry` не восстанавливает поле `detour` при save → reparse, оно бы терялось. Исправлено в v1.3.1.

---

## Зависимости и обновления

### Критические зависимости

| Зависимость | Версия | Где | Риск обновления |
|------------|--------|-----|----------------|
| sing-box (libbox) | 1.12.12 | JitPack | API может измениться, тестировать native код |
| Flutter | 3.41.6 | SDK | Обычно безопасно, проверять deprecated |
| Gradle | 8.14 | wrapper | Совместимость с AGP |
| AGP | 8.11.1 | build.gradle.kts | Совместимость с Gradle и Flutter |
| Java | 17 | Temurin | Не менять без причины |

### При обновлении libbox
1. Проверить API changes в sing-box changelog
2. Обновить `android/app/build.gradle.kts` (JitPack dependency)
3. Проверить native код в `vpn/` — методы могут измениться
4. Полное тестирование: start/stop, Clash API, connections
