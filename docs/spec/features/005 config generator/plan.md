# План: 005 — Генератор конфига

## Этапы

### 1. Wizard Template Asset

- Адаптировать `wizard_template.json` из лаунчера для мобильной платформы
- Поместить в `app/assets/wizard_template.json`
- Зарегистрировать в `pubspec.yaml` как asset

### 2. Модель ParserConfig

Создать `lib/models/parser_config.dart`:
- `ParserConfig` (proxies, outbounds, parser settings)
- `WizardVar` (name, type, default_value, wizard_ui, options, title, tooltip, if/if_or conditions)
- `SelectableRule` (label, description, default, rule_set, rule)
- `WizardTemplate` (parser_config, vars, config, dns_options, selectable_rules)

### 3. Settings Storage

Создать `lib/services/settings_storage.dart`:
- Загрузка/сохранение JSON-файла с настройками
- API: `getVar(name)`, `setVar(name, value)`, `getProxySources()`, `saveProxySources()`
- API: `getEnabledRules()`, `setEnabledRules()`

### 4. Config Builder

Создать `lib/services/config_builder.dart`:
- `loadTemplate()` — из asset
- `substituteVars(config, vars)` — рекурсивная подстановка `@var_name`
- `generateOutbounds(parserConfig, nodes)` — 3-pass алгоритм
- `buildConfig(template, vars, nodes, rules)` — финальная сборка
- `generateAndSaveConfig()` — полный цикл: load → build → save

### 5. Outbound Generator

Создать `lib/services/outbound_generator.dart`:
- Порт логики из `outbound_generator.go`
- `filterNodesForSelector(nodes, filters)` — фильтрация по tag/host/scheme
- `buildOutboundsInfo()` — pass 1
- `computeOutboundValidity()` — pass 2
- `generateSelectorJSONs()` — pass 3

### 6. Интеграция

- Подключить config builder к home controller
- При изменении подписок или настроек — перегенерация конфига
- Если VPN запущен — предложить рестарт

## Зависимости

- Feature 004 (парсер подписок) — для загрузки нод
- Пакет `path_provider` — для `getApplicationDocumentsDirectory()`
