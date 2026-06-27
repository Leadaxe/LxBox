# §191 — Выпил Clash API из VPN Settings → Core

**Тип:** cleanup (мёртвый рудимент после §122)
**Статус:** ✅ Выполнено. Секция удалена из темплейта; JSON валиден; builder+parser
+3 clash-упоминающих теста зелёные. Clash-код был мёртв с §122 — убран UI-рудимент.
**Связано:** §122 (CommandClient-миграция — отказ от Clash API)

## Зачем

§122 убрал Clash API из ядра (rc.3 собран без `with_clash_api`; блок
`experimental.clash_api` в конфиге даёт ФАТАЛЬНЫЙ отказ старта). Билдер уже НЕ
инжектит `clash_api` (`build_config.dart:114` — `_ensureClashApiDefaults` удалён).
Но в UI **VPN Settings → Core** осталась секция «Clash API» с полями Address +
Secret (`wizard_template.json` ноды `clash_api`/`clash_secret`) — мёртвый
рудимент, который юзер видит и может править впустую (значения никуда не идут).

## Что есть сейчас (прочитано)

- **Темплейт** `assets/wizard_template.json` — секция `{name:"Clash API",
  chapter:"core", vars:[clash_api, clash_secret]}` (~строки 241-262).
- **UI** `settings_screen.dart` рендерит core data-driven: `varsFor('core')` +
  `sectionsFor('core')`. Удаление секции из темплейта → исчезает из UI
  автоматически.
- **Билдер** — clash уже НЕ инжектится (§122). Потребителей `clash_api`/
  `clash_secret` в рантайме НЕТ.
- Упоминания в комментариях (`build_config.dart`, `if_engine.dart`,
  `settings_storage.dart`, `subscription_controller.dart`) — историческая
  трассировка §122, не код.

## Что делаю

1. **Удалить секцию «Clash API»** (ноды `clash_api` + `clash_secret`) из
   `wizard_template.json`. Секция исчезает из Core UI.
2. **Проверить** что `_configVarKeys` / валидаторы / тесты темплейта не
   ссылаются на эти ноды жёстко (fail-fast `_node()` в vpn_mode_tab резолвит
   только proxy_*, не clash — безопасно).
3. **Подчистить** stale-комментарии, если упоминают как «живые» (исторические
   §122-заметки про «больше не инжектится» — ОСТАВИТЬ, они объясняют почему).

## Границы

- НЕ трогать §122-комментарии-объяснения (почему clash_api фатален) — они
  ценны для истории.
- legacy-значения `clash_api`/`clash_secret`, сохранённые в storage у старых
  юзеров — безвредны (билдер их игнорит, §122). Чистить storage НЕ нужно.
- TemplateLoader.validateIfConstructs — проверить что не падает без этих нод.
