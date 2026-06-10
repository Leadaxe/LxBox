# 093 — Detour hide-фильтр по `isDetour` (структурно), ⚙ → визуал

| Поле | Значение |
|------|----------|
| Тип | logic-rewrite (§090 **G2**) — завершение §091-арки |
| Решение юзера | «detour по факту ссылок (`isDetour`); ⚙ — только визуальный сахар при парсинге подписок» |

## G2a — DONE ✅

Detour-hide фильтр на главном (`NodeListPresenter.splitNodes` /
`computeListData`) теперь скрывает ноды **структурно**: `ConfigNode.isDetour`
(`detourRefCount > 0` — на ноду ссылаются как на detour-таргет через поле
`detour`), а не по ⚙-метке (`TagResolver.isDetourMarker`).

- Корректнее: «detour-сервер» = тот, через кого реально ходят (релей/hop),
  а не просто помеченный руками.
- `TagResolver.isDetourMarker` остаётся (билдер ⚙ + `ConfigNode.isMarkedDetour`).
- Self-consistent: builder-detour (main-as-detour) ссылается → `isDetour=true`
  → прячется как раньше; ⚙-нода без ссылок больше не прячется (она и не detour).
- analyze + 805 тестов green. (Device-verify toggle «Show detour» — на юзере.)

## G2b — БЫЛ ОТКРЫТ → РЕШЁН ✅ (см. ниже)

Ручной toggle **«Mark as detour server»** в `node_settings_screen` —
**не чисто визуальный**: он (1) красит тег ⚙, (2) гейтит policy-тогглы
`entry.registerDetourServers` / `registerDetourInAuto`, которые **читает
билдер** (⚙-сервер по умолчанию прячется из selector'а + ✨auto, ведёт себя как
звено цепочки).

Полное «⚙ только при парсинге подписок» ⇒ убрать ручной toggle ⇒ надо решить
**куда деть registerDetour-политики** (видимость detour-сервера в selector'е):
- (a) убрать политики совсем (detour-сервер всегда скрыт, если на него ссылаются);
- (b) перенести на subscription-level (DetourPolicy у подписки);
- (c) оставить, но привязать к `isDetour` вместо ⚙.

→ UX-развязка, **согласовать с юзером** перед реализацией.

### G2b — РЕШЕНО ✅ (§096, 2026-06): политики ОСТАВЛЯЕМ (вариант b)

Юзер обосновал кейсом «добавить свой detour, но не заменять детуры подписки»
(= режим **Add detour + APPEND**, §073, Replace выкл): нативные детуры подписки
остаются в цепочке, поэтому `registerDetourServers` / `registerDetourInAuto`
**нужны и имеют смысл**. Решение: политики живут на subscription-level
(`DetourPolicy`, как и сейчас — вариант b), НЕ убираем.

UX-доработка (§096): register-тоглы в `subscription_settings_tab` теперь
показываются не только под **Use**, но и под **Add detour** при APPEND
(Replace выкл) — там нативные детуры в игре. Прячутся при REPLACE / None.
Флаги хранятся независимо от режима (переключение Use↔Add detour их не теряет).

Ручной per-node toggle «Mark as detour» уже убран (§094); `isMainAsDetour`
(⚙-префикс) теперь только из парсинга/`TagResolver`. (Комментарий в
`server_list_build.dart` про node_settings-toggle обновлён — ссылается
на §094; долг снят.)
