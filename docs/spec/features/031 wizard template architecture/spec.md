# 031 — Wizard Template Architecture

**Status:** Реализовано

## Контекст

Настройки по умолчанию были разбросаны по коду — часть в конфиг-билдере, часть в UI, часть в константах. Нужен единый источник истины для всех дефолтных настроек приложения.

## Реализация

### wizard_template.json — единый источник истины

Файл `assets/wizard_template.json` содержит ВСЕ дефолтные настройки приложения. Секции:

| Секция | Назначение |
|--------|-----------|
| `dns_options` | DNS серверы (`servers`) и правила (`rules`) по умолчанию |
| `ping_options` | URL пинга, timeout, пресеты (`presets`) |
| `speed_test_options` | Серверы спид-теста, потоки, ping URLs |
| `preset_groups` | Группы outbound (auto-proxy, manual-proxy и т.д.) |
| `vars` | Переменные для подстановки через `@var_name` |
| `selectable_rules` | Правила маршрутизации с выбором outbound |
| `config` | Скелет sing-box конфига (inbounds, dns, route, experimental) |

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

### Пользовательские переопределения

Пользовательские настройки хранятся в `boxvpn_settings.json` в application support directory. Содержит только то, что пользователь изменил — не полную копию шаблона.

```json
{
  "vars": {
    "dns_strategy": "ipv4_only",
    "urltest_interval": "3m"
  },
  "dns_options": {
    "servers": [...]
  },
  "rule_overrides": {
    "rule_tag": "selected_outbound"
  }
}
```

### Мерж в ConfigBuilder

`ConfigBuilder` при генерации конфига:

1. Загружает `wizard_template.json` (дефолты)
2. Загружает `boxvpn_settings.json` (переопределения)
3. Мержит: user overrides имеют приоритет над template defaults
4. Подставляет `@var_name` переменные в конфиг скелет
5. Добавляет outbounds из подписок в preset groups
6. Собирает финальный JSON конфиг

```dart
Map<String, dynamic> _mergeVars(WizardTemplate template, Map<String, dynamic>? userVars) {
  final merged = Map<String, dynamic>.from(template.vars);
  if (userVars != null) merged.addAll(userVars);
  return merged;
}
```

### SettingsStorage

`SettingsStorage` отвечает за чтение/запись `boxvpn_settings.json`:
- `loadSettings()` — загрузка переопределений
- `saveSettings(settings)` — сохранение
- `getVar(key)` / `setVar(key, value)` — работа с отдельными переменными
- `getDnsOptions()` / `saveDnsOptions(options)` — DNS настройки

## Файлы

| Файл | Изменения |
|------|-----------|
| `assets/wizard_template.json` | Единый шаблон со всеми секциями |
| `lib/models/parser_config.dart` | Модель WizardTemplate и вложенные модели |
| `lib/services/config_builder.dart` | Мерж template + user overrides при генерации |
| `lib/services/settings_storage.dart` | CRUD для boxvpn_settings.json |

## Критерии приёмки

- [x] wizard_template.json содержит все секции: dns_options, ping_options, speed_test_options, preset_groups, vars, selectable_rules, config
- [x] Модель WizardTemplate парсится из JSON asset
- [x] Пользовательские переопределения хранятся отдельно в boxvpn_settings.json
- [x] ConfigBuilder мержит template defaults с user overrides
- [x] Подстановка @var_name работает для всех переменных
- [x] SettingsStorage предоставляет API для чтения/записи настроек
