# Задачи: 005 — Генератор конфига

Спека: [`spec.md`](spec.md) | План: [`plan.md`](plan.md)

## Чеклист

- [ ] Адаптировать и встроить `wizard_template.json` как Flutter asset
- [ ] Модели: `WizardTemplate`, `WizardVar`, `SelectableRule`, `ParserConfig`
- [ ] `settings_storage.dart`: хранилище переменных и подписок (JSON-файл)
- [ ] `config_builder.dart`: загрузка шаблона, подстановка переменных
- [ ] `outbound_generator.dart`: 3-pass генерация selectors из нод
- [ ] Интеграция selectable_rules (rule_set + route rules)
- [ ] Полный цикл: `generateAndSaveConfig()`
- [ ] Интеграция с home controller

## Статус

| Пункт | Статус |
|-------|--------|
| Template asset | — |
| Модели | — |
| Settings storage | — |
| Config builder | — |
| Outbound generator | — |
| Интеграция | — |
