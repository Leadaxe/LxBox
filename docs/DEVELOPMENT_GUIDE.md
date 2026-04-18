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

Все экраны настроек используют debounce-таймер (500мс). При изменении:
1. `_scheduleSave()` отменяет предыдущий таймер и ставит новый
2. Через 500мс `_apply()` сохраняет в storage и пересобирает конфиг
3. Если VPN активен — показывает "Restart VPN to apply changes"

**Никаких кнопок Apply/Save** — изменения применяются автоматически.

### 3. Offline-first

Приложение должно работать без интернета:
- Подписки кэшируются на диск (`sub_cache/`)
- Node filter читает из configRaw (уже сгенерированный конфиг)
- Конфиг генерируется из кэша при сетевой ошибке
- DNS серверы из шаблона доступны всегда

**Интернет нужен только для**: скачивания подписок (по кнопке refresh), SRS rule sets, speed test.

### 4. Config generation pipeline

```
SettingsStorage + WizardTemplate
        ↓
ConfigBuilder.generateConfig()
  1. Load template, substitute @vars
  2. Load subscriptions (с кэш-fallback)
  3. Filter excluded nodes (только urltest)
  4. Build preset groups (selector получает все ноды)
  5. Apply routing rules + app rules
  6. Apply DNS (user override или template defaults)
  7. Cache remote SRS
  8. → sing-box JSON
```

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

#### flutter analyze
Перед каждым коммитом:
```bash
cd app && flutter analyze lib/
```
**0 issues** — обязательно. Warnings тоже фиксить.

---

## Процесс разработки

### 1. Spec first
Перед реализацией — создать `docs/spec/features/NNN name/spec.md`. Даже для мелких фич. Это:
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
# Локальная сборка (по умолчанию, ~75 сек с кэшем)
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Релиз через тег
git tag v1.2.0
git push origin v1.2.0
# CI автоматически создаст GitHub Release с APK
```

### 4. Версионирование
- `pubspec.yaml`: `version: X.Y.Z+N`
- Git tag: `vX.Y.Z`
- X — мажор (breaking changes)
- Y — минор (новые фичи)
- Z — патч (фиксы)
- N — build number (инкремент)

---

## Работа с AI-ассистентом (Claude Code)

### CLAUDE.md
Файл `CLAUDE.md` в корне `app/` содержит контекст проекта для AI-сессий. Включён в `.gitignore`.

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

### Что такое detour-серверы

Detour-серверы — промежуточные (chained) прокси, через которые трафик идёт до конечного сервера. В UI отображаются с префиксом **⚙** (ранее `_jump_server`). Это outbound'ы типа SOCKS/VLESS/etc., на которые ссылаются основные ноды через поле `detour`.

### Per-subscription settings

Каждая подписка (ProxySource) имеет три настройки для управления detour-серверами:

| Настройка | Описание |
|-----------|----------|
| **Register** | Зарегистрировать detour-серверы из этой подписки как доступные для других подписок |
| **Use** | Использовать зарегистрированные detour-серверы для нод этой подписки |
| **Override** | Принудительно назначить конкретный detour для всех нод подписки (перезаписывает существующий detour) |

### Как ConfigBuilder обрабатывает detour

ConfigBuilder при генерации конфига:
1. Собирает все detour-серверы из подписок с `register = true`
2. Для подписок с `use = true` — подставляет зарегистрированные detour-серверы в поле `detour` нод
3. Для подписок с `override` — принудительно заменяет detour на указанный сервер

### 4 комбинации Register × Use

| Register | Use | Результат |
|----------|-----|-----------|
| ❌ | ❌ | Detour-серверы подписки не расшариваются и не используются чужие. Ноды используют свой родной detour (если есть) |
| ✅ | ❌ | Detour-серверы регистрируются для других подписок, но сама подписка не использует чужие detour |
| ❌ | ✅ | Подписка использует detour-серверы от других подписок (с register=true), но свои не расшаривает |
| ✅ | ✅ | Полная интеграция: подписка и расшаривает свои detour-серверы, и использует чужие |

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
