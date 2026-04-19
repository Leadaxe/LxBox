# 005 — Генератор конфига (Wizard Template)

> ⚠️ **Шаги сборки и post-processing заменены §3.4 спеки [`026 parser v2`](../026%20parser%20v2/spec.md)** (2026-04-18).
> Шаблон (`wizard_template.json`) и переменные — остаются. `config_builder.dart` удаляется в Фазе 4 спеки 026.

| Поле | Значение |
|------|----------|
| Статус | Частично заменено (сборка — 026, шаблон — остаётся) |
| Зависимости | [`004 subscription parser`](../004%20subscription%20parser/spec.md), [`026 parser v2`](../026%20parser%20v2/spec.md) |
| Референс | singbox-launcher `bin/wizard_template.json`, `core/config/outbound_generator.go` |

## 1. Цель

Встроить в приложение шаблон конфигурации (wizard template) и реализовать генерацию полного sing-box конфига из:
- **шаблона** (базовый скелет конфига, DNS, route rules);
- **переменных** (пользовательские настройки: log level, clash API, DNS);
- **подписок** (распарсенные ноды → outbounds и selectors).

## 2. Wizard Template Architecture

**Status:** Реализовано

### wizard_template.json — единый источник истины

Файл `assets/wizard_template.json` содержит ВСЕ дефолтные настройки приложения. Секции:

| Секция | Назначение |
|--------|-----------|
| `parser_config` | Конфигурация парсера: outbounds (selectors), настройки reload |
| `vars` | Переменные: имя, тип, значение по умолчанию, UI-режим, tooltip |
| `config` | Базовый скелет sing-box конфига (log, dns, inbounds, outbounds, route, experimental) |
| `dns_options` | DNS серверы (`servers`) и правила (`rules`) по умолчанию |
| `ping_options` | URL пинга, timeout, пресеты (`presets`) |
| `speed_test_options` | Серверы спид-теста, потоки, ping URLs |
| `preset_groups` | Группы outbound (auto-proxy, manual-proxy и т.д.) |
| `selectable_rules` | Правила маршрутизации с выбором outbound |

### Модель WizardTemplate

```dart
class WizardTemplate {
  final ParserConfig parserConfig;
  final List<PresetGroup> presetGroups;
  final Map<String, dynamic> vars;
  final Map<String, dynamic> config;
  final List<SelectableRule> selectableRules;
  final DnsOptions dnsOptions;
  final PingOptions pingOptions;
  final SpeedTestOptions speedTestOptions;

  factory WizardTemplate.fromJson(Map<String, dynamic> json) => ...;
}
```

Загружается из asset при старте приложения и хранится в памяти.

### 2.1 Переменные (vars)

Типы переменных:
- `bool` — переключатель (true/false)
- `text` — текстовое поле
- `enum` — выбор из списка
- `secret` — текст с кнопкой генерации случайного значения

UI-режимы:
- `edit` — показывать в настройках
- `fix` — скрывать (не для пользователя), но использовать при генерации
- `hidden` — полностью скрытая

Подстановка: `@var_name` в шаблоне config → значение переменной.

### 2.2 Адаптация для мобильной платформы

Из шаблона лаунчера убираются или скрываются:
- TUN-related vars (TUN уже управляется нативным VPN-сервисом)
- proxy-in (не актуально для мобильного)
- Платформенные params для windows/linux/darwin

Остаются доступными для редактирования:
- `log_level` — уровень логирования
- `clash_api` — адрес Clash API
- `clash_secret` — секрет Clash API
- `dns_strategy` — стратегия DNS
- `resolve_strategy` — стратегия резолва маршрутов
- `auto_detect_interface` — автоопределение интерфейса

### 2.3 Пользовательские переопределения

Пользовательские настройки хранятся в `lxbox_settings.json` в application support directory. Содержит только то, что пользователь изменил — не полную копию шаблона.

## 3. Config Builder

### 3.1 Процесс генерации

1. **Загрузка шаблона** из Flutter asset
2. **Загрузка переменных** из хранилища (lxbox_settings.json)
3. **Мерж**: user overrides имеют приоритет над template defaults
4. **Подстановка переменных** в секцию `config`: `@var_name` → значение
5. **Загрузка подписок** через Source Loader (фича 004)
6. **Генерация outbounds**: ноды + локальные selectors + глобальные selectors
7. **Сборка конфига**: merge inbounds, outbounds, route rules, DNS
8. **Валидация** и **сохранение** через `FlutterSingbox.saveConfig()`

### 3.2 Генерация outbounds (порт outbound_generator)

Три прохода (как в лаунчере):
1. **Build info** — для каждого selector: отфильтрованные ноды, начальный count
2. **Compute validity** — топологическая сортировка по addOutbounds, подсчёт валидных
3. **Generate JSON** — только для валидных selectors с отфильтрованными addOutbounds

Фильтрация нод для selectors: `filters.tag` поддерживает literal, `/regex/i`, `!literal`, `!/regex/i`.

### 3.3 Selectable Rules

Пользователь может включать/выключать предустановленные правила маршрутизации:
- Block Ads, Russian domains direct, BitTorrent direct, Games direct и т.д.
- Каждое правило может добавлять `rule_set` (remote или inline) и `rule` в `route.rules`

## 4. Хранилище настроек

`SettingsStorage` — абстракция для сохранения:
- Значений переменных (vars)
- Списка подписок (ProxySource[])
- Включённых selectable_rules
- Последнего времени обновления подписок

Реализация: JSON-файл в `getApplicationDocumentsDirectory()`.

## 5. Нецели

- Визуальный редактор outbound selectors (wizard second tab из лаунчера) — сложный UI, не в первой версии.
- DNS tab с drag-and-drop серверов — упрощённо через vars.
- Автообновление подписок по таймеру.

## 6. Файлы

| Файл | Изменения |
|------|-----------|
| `assets/wizard_template.json` | Единый шаблон со всеми секциями |
| `lib/models/parser_config.dart` | Модель WizardTemplate и вложенные модели |
| `lib/services/config_builder.dart` | Мерж template + user overrides при генерации |
| `lib/services/settings_storage.dart` | CRUD для lxbox_settings.json |

## 7. Критерии приёмки

- [x] Шаблон загружается из asset и парсится.
- [x] Подстановка переменных работает для всех типов (`@var` → значение).
- [x] Генерация outbounds из подписок создаёт валидный sing-box JSON.
- [x] Selectors корректно ссылаются на ноды и друг на друга.
- [x] Пустые selectors (0 нод) не попадают в конфиг.
- [x] Selectable rules добавляют rule_set и rules при включении.
- [x] Сгенерированный конфиг принимается ядром sing-box.
- [x] Настройки сохраняются между запусками приложения.
- [x] Пользовательские переопределения хранятся отдельно в lxbox_settings.json.
- [x] ConfigBuilder мержит template defaults с user overrides.
