# 010 — Preset bundles (spec 033)

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-04-21 |
| Связанный spec | [`033 preset bundles`](../features/033%20preset%20bundles/spec.md) |
| Лэндинг | v1.5.0 |

## Контекст

В 1.4 selectable-пресет — это `label + rule_set + rule`, при `Copy to Rules` разворачивается в `CustomRule(kind: inline)` — **копия**. Минусы:

- Список русских TLD обновится в репо — у пользователей останется старый снапшот.
- Пресет не может нести «свой» DNS-сервер, который появлялся бы в конфиге только при активации правила.
- Расширение пресета новыми параметрами = руками в коде + миграция данных.

## Решение

`CustomRule(kind: preset)` = тонкая ссылка `{presetId, varsValues}`. Пресет в шаблоне становится self-contained bundle'ом (`rule_set` + `dns_rule` + `rule` + `dns_servers`) с типизированными переменными (`@out`, `@dns_server`). Expansion — pure function в builder post-step.

Полный дизайн → [`033 preset bundles/spec.md`](../features/033%20preset%20bundles/spec.md).

## План

### Модель

- [x] `SelectableRule` расширить: `presetId`, `vars`, `dnsRule`, `dnsServers` (все опциональные, legacy работает).
- [x] `WizardVar` → добавить поле `required: bool = true`, парсинг; новые типы `outbound`, `dns_servers`.
- [x] `WizardOption` — структура `{title, value}` для `options` с legacy-совместимостью (строка-литерал ≡ `{title: s, value: s}`). `WizardVar.options: List<WizardOption>`. Адаптирован `template_var_list.dart` (enum dropdown + text suggestions), custom_rule_edit_screen (preset enum).
- [x] `CustomRuleKind.preset` + `CustomRule.presetId` + `CustomRule.varsValues`.
- [x] `CustomRule.toJson/fromJson/copyWith` — поддержка новых полей.

### Builder

- [x] `preset_expand.dart` — pure expansion (`expandPreset`) + merger (`mergeFragments`) с identical-skip/first-wins-with-warn.
- [x] Интеграция в `applyCustomRules`: preset-правила отдельной веткой, `extra_dns_servers` / `extra_dns_rules` возвращаются из post-step.
- [x] `applyCustomDns` принимает `extraServers` / `extraRules`, мерджит перед template-данными (bundle before fallback).
- [x] `RuleSetRegistry.tryRegister` — identical-skip по deep-equal для bundle-rule-set'ов.

### UI

- [x] `CustomRuleEditScreen` — ветка для `kind == preset`: "Based on preset" badge + form (через типизированные widget'ы: OutboundPicker для `outbound`, Dropdown для `dns_servers` с опцией "—" при `required: false`) + JSON preview expanded bundle + broken-preset fallback.
- [x] `routing_screen.dart` — display карточки preset-правила: subtitle = preset.label + var summary + **иконка замочка** `Icons.lock_outline` слева (отличает bundle от inline/srs). OutboundPicker в строке для preset-правил маппится на `varsValues['out']`, не на `target`.
- [x] **Presets-каталог: existing-check по `presetId`, а не по `label`** (было: `_customRules.any((c) => c.name == rule.label)` → стало: для bundle `c.kind == preset && c.presetId == rule.presetId`, для legacy осталось по label). Иначе переименованное preset-правило давало "Copy to Rules" второй раз → дубль.
- [x] "Copy to Rules" в Presets: если `preset_id` есть → создать `CustomRule(kind: preset)` через расширенный `selectableRuleToCustom`.
- [x] Seed fresh-install: существующие пресеты мигрируют через `_migrateLegacyPresets` + `selectableRuleToCustom` (теперь возвращает `kind: preset` для bundle-пресетов). Флаг `presets_migrated` защищает от повторного запуска; пользователи 1.4.x остаются со своими inline-правилами, для перехода на bundle — Delete + Copy to Rules.

### Шаблон

- [x] `wizard_template.json` → `Russian domains direct` переписан в bundle-формат.
- [x] Удалить теперь-ненужные top-level DNS-серверы Yandex/`yandex_*` и `ru-domains` inline-rule_set в `route.rule_set`; оставить только то что действительно глобальное.
- [x] Итоговый пресет: три vars — `out` (outbound, default `direct-out`), `dns_server` (dns_servers, default `yandex_doh`, optional), `dns_ip` (enum с 10 опциями Safe/Base/Family IP/IPv6, default `77.88.8.88`). Три bundle-сервера: `yandex_doh` и `yandex_dot` хардкод на `77.88.8.88` + `tls.server_name: safe.dot.dns.yandex.net`; `yandex_udp` через `@dns_ip`. Обоснование: DoH/DoT требуют согласованной пары (IP, SNI) — разнести на две var'а без nested-lookup в substitution не получится, для Base/Family — отдельные пресеты если потребуются.

### Тесты

- [x] `test/services/builder/preset_expand_test.dart` — expansion кейсы.
- [x] `test/services/builder/bundle_merge_test.dart` — merger.
- [x] `test/services/builder/custom_rules_test.dart` — обновить на preset-интеграцию.
- [x] `test/services/selectable_to_custom_test.dart` — preset-case.
- [x] `test/builder/build_config_preset_test.dart` — integration через `buildConfig`.

### Docs

- [x] `CHANGELOG.md` — Unreleased section (Added/Changed).
- [x] `README.md` / `README_RU.md` — рядом с Russian TLD отметить bundle-подход.
- [x] `docs/DEVELOPMENT_REPORT.md` — обновить таблицу пресетов и колонку "Источник" (inline → bundle).

### Релиз

- [x] `flutter test` — всё зелёное.
- [x] `flutter build apk --debug` + `adb install`.
- [x] Smoke-check на устройстве (CE8XX48PCI79U4XG).

## Риски

- **Broken preset** после апгрейда приложения — spec предусматривает broken-card + skip при сборке.
- **Конфликт тегов** `yandex_doh` между двумя bundle-правилами с разным `@out` — first-wins + warning. Не ломает, но юзер должен понимать.
- **User-override DNS rules** → bundle-rules игнорируются. Документировать в tooltip DNS-rules-редактора? (Opt-in future).
