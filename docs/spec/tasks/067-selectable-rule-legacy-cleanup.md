# 067 — Cleanup legacy SelectableRule (no-preset-id) path

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-05-12 |
| Связанные | [§033 preset bundles](../features/033%20preset%20bundles/spec.md), [§011 sealed split](../features/011%20sealed%20customrule/spec.md). |
| Триггер | Аудит `SelectableRule` model: `presetId` имел default `''`, docstring описывал два режима — Legacy (1.4.x) и Bundle (1.5+). На самом деле legacy mode **не используется**: все 5 selectable_rules в `wizard_template.json` имеют `preset_id`, конвертер `selectableRuleToCustom` returns null для empty presetId. Mode = dead code. |

## Цель

Убрать упоминания и code-paths legacy режима (SelectableRule без preset_id). Сделать `preset_id` **обязательным** полем в шаблоне и в модели. Конвертер — non-nullable.

## Что было

| Место | Состояние до |
|---|---|
| `parser_config.dart::SelectableRule` | `presetId` default `''`. Docstring описывает два режима «Legacy (1.4.x)» и «Bundle (1.5+)». |
| `parser_config.dart::SelectableRule.fromJson` | `presetId: json['preset_id'] as String? ?? ''` — fallback на пустую строку. |
| `selectable_to_custom.dart::selectableRuleToCustom` | Return type `CustomRulePreset?`. `if (sr.presetId.isEmpty) return null;` — silent skip. |
| `routing_screen.dart::_copyPreset` | `if (cr == null) { snackbar "Cannot represent ..." }` — handle null case. |
| `routing_screen.dart::_migrateLegacyRules` | `if (cr != null) _customRules.add(cr);` — null check. |
| `selectable_to_custom_test.dart` | Test «без preset_id → null» проверяет fallback path. |

## Что стало

| Место | Состояние после |
|---|---|
| `SelectableRule` | `presetId` — `required`. Docstring упоминает только bundle-режим. |
| `SelectableRule.fromJson` | Throws `FormatException` если `preset_id` отсутствует или пуст. |
| `selectableRuleToCustom` | Returns `CustomRulePreset` (non-nullable). Никаких null path. |
| `routing_screen.dart` | Убраны null checks — конвертер всегда возвращает значение. |
| Test | Удалён test на null path. Schema-validation покрыт на parse-side. |

## Не в скопе

- `SelectableRule.vars`/`dnsRule`/`dnsServers` defaults — это legit fields для presets которые не используют типизированные переменные или DNS-аспекты. Оставлены.
- Миграция старых backup-файлов которые содержат selectable rules без preset_id — мы их не имеем, шаблон давно с preset_id. Если попадётся — `fromJson` бросит FormatException что correct.

---

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/parser_config.dart` | `presetId` required; убран docstring «Legacy (1.4.x)» mode; fromJson throws на missing preset_id |
| `app/lib/services/selectable_to_custom.dart` | Return non-nullable; убран early null return |
| `app/lib/screens/routing_screen.dart` | Убраны 2 null checks (line ~380, line ~623) |
| `app/test/services/selectable_to_custom_test.dart` | Удалён test «без preset_id → null» |
| `CHANGELOG.md` Unreleased | Запись Removed |

## Risks

| Риск | Митигация |
|---|---|
| Старый `wizard_template.json` без preset_id в каком-нибудь rule | Шаблон commit'нут с preset_id во всех 5 rules. Если кто-то fork'ал и удалил — `fromJson` бросит на load, видно сразу. |
| Custom subscription template без preset_id | Subscriptions не несут selectable_rules — это template-only field. Не affected. |

---

## Test plan

После landing'а — `flutter test` зелёный (минус один удалённый test). `flutter analyze` clean. На устройстве: open Routing → Rules → "+ Preset" → видишь все 5 пресетов из шаблона, любой можно добавить.
