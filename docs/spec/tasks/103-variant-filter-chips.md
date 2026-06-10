# 103 — Eager-лейблы ConfigNode + variant-фильтр (transport/security чипы)

**Дата:** 2026-06-10 · **Статус:** DONE
**Запрос:** (1) вычислять transport/security лейблы §102 один раз в
`ParsedConfig.parse`; (2) в фильтре под протоколами — вторая строка чипов с
transport- и security-тегами вперемешку.

## 1. Eager-лейблы

`ConfigNode.transportLabel`/`securityLabel` — теперь `final`-поля, деривятся
в `ParsedConfig.parse` (проход 2) статиками `_deriveTransport`/`_deriveSecurity`.
Вся derivation в одном месте; itemBuilder читает готовые поля. Семантика §102
не менялась (таблицы там).

## 2. Variant-фильтр (§096-семантика, как у протоколов)

Словарь тегов = объединение transport- и security-слотов §102:
`tcp/ws/grpc/h2/httpupgrade/quic/xhttp` + `TLS/TLS+Vision/Reality/
Reality+Vision/awg/awg2`.

| Слой | Файл | Изменение |
|---|---|---|
| view-model | `node_filter_view_model.dart` | `enabledVariants`+`variantsInvert`, `toggleVariant`/`toggleVariantsInvert`, `variantActive`, в `isActive`; per-channel capture/restore |
| снимок | `channel_filters.dart` | поля `variants`/`variantsInvert` (+`isEmpty`) |
| predicate | `node_filter.dart` | `variants`/`variantsInvert`/`variantsOf`; member = пересечение тегов ноды с выбором; fail при `member == invert`; unknown (пустой Set) при active → non-matching (locked decision #12) |
| presenter | `node_list_presenter.dart` | `variantsOfTag` (тот же urltest-fallback, что `protocolOfTag`); `availableVariants` из pool, канонический порядок `_variantOrder` (транспорты → security, незнакомое в конец) |
| UI | `filter_panel.dart` | Protocol-таб: вторая `MultiSelectChipsRow` под протоколами (свой `!`-negate); summary-чипы `!xhttp`; точка на табе = `protocolActive \|\| variantActive` |

Лейблы чипов — теги как есть (без protoLabel-маппинга).

## Тесты

- `node_filter_test.dart` — группа §103: no-filter/выбор/микс-OR/invert/unknown.
- `node_filter_view_model_test.dart` — per-channel variants+invert, toggle.
- `channel_filters_test.dart` — isEmpty c variants/variantsInvert.
- `config_node_test.dart` — §102-группа работает без изменений (поля vs геттеры).
