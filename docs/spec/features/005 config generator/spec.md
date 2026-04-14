# 005 — Генератор конфига (Wizard Template)

| Поле | Значение |
|------|----------|
| Статус | черновик |
| Задачи | [`tasks.md`](tasks.md) |
| План | [`plan.md`](plan.md) |
| Зависимости | [`004 subscription parser`](../004%20subscription%20parser/spec.md) |
| Референс | singbox-launcher `bin/wizard_template.json`, `core/config/outbound_generator.go` |

## 1. Цель

Встроить в приложение шаблон конфигурации (wizard template) и реализовать генерацию полного sing-box конфига из:
- **шаблона** (базовый скелет конфига, DNS, route rules);
- **переменных** (пользовательские настройки: log level, clash API, DNS);
- **подписок** (распарсенные ноды → outbounds и selectors).

## 2. Wizard Template

Файл `assets/wizard_template.json` — копия шаблона из лаунчера, адаптированная для мобильной платформы.

### 2.1 Структура шаблона

| Секция | Назначение |
|--------|------------|
| `parser_config` | Конфигурация парсера: outbounds (selectors), настройки reload |
| `vars` | Переменные: имя, тип, значение по умолчанию, UI-режим, tooltip |
| `config` | Базовый скелет sing-box конфига (log, dns, inbounds, outbounds, route, experimental) |
| `dns_options` | Варианты DNS-серверов и правил |
| `selectable_rules` | Готовые правила маршрутизации (ads, RU domains, games и т.д.) |

### 2.2 Переменные (vars)

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

### 2.3 Адаптация для мобильной платформы

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

## 3. Config Builder

### 3.1 Процесс генерации

1. **Загрузка шаблона** из Flutter asset
2. **Загрузка переменных** из хранилища (SharedPreferences / JSON-файл)
3. **Подстановка переменных** в секцию `config`: `@var_name` → значение
4. **Загрузка подписок** через Source Loader (фича 004)
5. **Генерация outbounds**: ноды + локальные selectors + глобальные selectors
6. **Сборка конфига**: merge inbounds, outbounds, route rules, DNS
7. **Валидация** и **сохранение** через `FlutterSingbox.saveConfig()`

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

Реализация: JSON-файл в `getApplicationDocumentsDirectory()` (чтобы хранить сложные структуры).

## 5. Нецели

- Визуальный редактор outbound selectors (wizard second tab из лаунчера) — сложный UI, не в первой версии.
- DNS tab с drag-and-drop серверов — упрощённо через vars.
- Автообновление подписок по таймеру.

## 6. Критерии приёмки

- [ ] Шаблон загружается из asset и парсится.
- [ ] Подстановка переменных работает для всех типов (`@var` → значение).
- [ ] Генерация outbounds из подписок создаёт валидный sing-box JSON.
- [ ] Selectors корректно ссылаются на ноды и друг на друга.
- [ ] Пустые selectors (0 нод) не попадают в конфиг.
- [ ] Selectable rules добавляют rule_set и rules при включении.
- [ ] Сгенерированный конфиг принимается ядром sing-box.
- [ ] Настройки сохраняются между запусками приложения.
