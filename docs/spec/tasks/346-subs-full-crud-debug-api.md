# §346 — Debug API: полная настройка подписки (identity, on_update_action, import-rules CRUD)

| | |
|---|---|
| Статус | DEVICE-VERIFIED (эмулятор sdk_gphone64_arm64 / Android 14, 2026-08-03) |
| Дата | 2026-08-02 |
| Связанные | §031 (Debug API), §289 (per-subscription identity), §302/§307/§332 (import rules), §323 (on_update_action), §238 (folders sub-CRUD — образец роутов), §073 (тот же класс дефекта: поле модели не доехало до PATCH) |
| Повод | Подписка с HWID-гейтом (Remnawave-панель) не настраивается через Debug API: без `x-hwid` панель отдаёт заглушку `vless://0000…#App not supported` (§310), а включить HWID можно только глобально в UI |

## Проблема

`PATCH /subs/{id}` маппит подмножество полей подписки: `name`, `enabled`,
`tag_prefix`, `update_interval_hours`, четыре detour-поля, `url`. Три группы
персистентных настроек `SubscriptionServers` не имеют представления в API
вообще:

| поле | спека | что это |
|---|---|---|
| `identity` | §289 | per-subscription слепок идентичности фетча (UA + `x-hwid` + device-meta); `null` = Default (глобал), объект = Custom |
| `onUpdateAction` | §323 | реакция на успешное авто-обновление: `rebuild` / `reload` / `none` |
| `importRules` + `importRulesEnabled` | §302 | правила обработки узлов на импорте |

Это тот же дефект, что §073 (`replace_detour_chain` был пропущен в маппинге):
поле живёт в модели, персистится, правится в UI — но headless-путь его не
видит. Следствие для §289 предметное: единственный способ включить HWID из
Debug API — глобальный `PUT /settings/vars/subscription_send_hwid`, который
меняет поведение фетча **всех** подписок, тогда как в модели ровно для этого
есть per-subscription override.

Симметрично неполон и read-путь: `serializeSubEntry` не отдаёт ни одну из трёх
групп, поэтому даже прочитать текущее состояние нельзя.

## Решение

### 1. Read — `serializeSubEntry`

Добавить в shape sub-entry (только для `SubscriptionServers`; у `UserServer` /
`FolderServers` полей нет — ключи не кладём):

```jsonc
"on_update_action": "rebuild",
"identity": null,              // null = Default (глобальная идентичность)
"import_rules_enabled": true,
"import_rules_count": 0        // список — в /subs/{id}/rules
```

`identity` в режиме Custom — объект `SubscriptionIdentityOverride.toJson()`.
`hwid` — не секрет провайдера, а идентификатор устройства; маскированием под
`reveal` не закрываем (симметрия с `/state/storage`, где `subscription_hwid`
скраббером не режется).

Полный список правил в sub-entry не встраиваем: у подписки их может быть много,
а `/state/subs` — общий листинг. Правила читаются под-ресурсом.

### 2. PATCH `/subs/{id}` — плоские поля

Дописать в `_update` по образцу соседей:

| поле | тип | семантика |
|---|---|---|
| `on_update_action` | string | `rebuild` \| `reload` \| `none`; мусор → `BadRequest` (не молчаливый дефолт `fromJson`) |
| `import_rules_enabled` | bool | общий тумблер набора |
| `identity` | object \| null | тристейт, см. ниже |

**`identity` — тристейт.** У поля три состояния, и `??`-маппинг их не
выражает:

| body | результат |
|---|---|
| ключ отсутствует | не трогаем |
| `"identity": null` | Custom → Default (`disableCustomIdentity`) |
| `"identity": {...}` | Custom с наложением переданных полей |

Объект работает как **патч поверх слепка**: если Custom не активен, сначала
`enableCustomIdentity()` (инициализация копией глобальных, как в UI), затем
переданные ключи накладываются на слепок через `copyWith`. Значит
`{"identity":{"send_hwid":true,"hwid":"<uuid>"}}` — законченная операция
«включить HWID только этой подписке», а не «обнулить UA и device-meta».

Принимаемые ключи объекта: `user_agent`, `send_hwid`, `hwid`, `device_os`,
`ver_os`, `device_model`. Неизвестный ключ → `BadRequest` (иначе опечатка
`send_hardware_id` молча не сработает).

### 3. Под-CRUD `/subs/{id}/rules` — import rules (§302)

Список правил — упорядоченная коллекция без id (порядок значим: правила
применяются последовательно, последнее сработавшее enable/disable побеждает,
§332). Тот же профиль, что у членов папки в §238, поэтому и адресация та же —
**позиционный индекс**, с той же оговоркой: после `DELETE`/`reorder` индексы
съезжают, следующий вызов строить по свежему снапшоту из ответа.

| Endpoint | Метод | Body |
|---|---|---|
| `/subs/{id}/rules` | GET | — |
| `/subs/{id}/rules` | POST | `ImportRule.toJson()`-shape, 201; `?index=N` — вставка в позицию (по умолчанию в конец) |
| `/subs/{id}/rules/{idx}` | GET | — |
| `/subs/{id}/rules/{idx}` | PATCH | subset полей правила |
| `/subs/{id}/rules/{idx}` | DELETE | — |
| `/subs/{id}/rules/reorder` | POST | `{"order":[старые индексы]}` — перестановка (как members) |

Shape правила — ровно `ImportRule.toJson()` (`conditions[]`, `match`, `action`,
`target_path`, `replacement`, `replace_mode`, `substitute`, `enabled`), парс —
`ImportRule.fromJson`. Своего DTO не заводим: пара
`toJson`/`fromJson` уже канон (через неё едут backup и storage), второй маппинг
разошёлся бы с моделью на первой же правке.

**Валидация на входе.** `fromJson` толерантен намеренно (мусор в storage не
должен ронять загрузку), но для API это плохо: `{"action":"replase"}` молча
станет `replace`. Поэтому в хендлере — строгая проверка до парса: enum-значения
из закрытых списков, `conditions` — массив объектов. Правило, которое парсится,
но нежизнеспособно (`isUsable == false` — например Replace без `target_path`),
принимается с предупреждением `"usable": false` в ответе: это легальное
промежуточное состояние в UI-редакторе, запрещать его в API незачем.

Правила вступают в силу на следующем refresh — существующие ноды на месте не
переразбираются (поведение §302, здесь не меняется). Отсюда же следствие:
`?rebuild=true` на rules-write'ах смысла имеет мало (конфиг соберётся из старых
нод), но принимается для единообразия — как на всех write'ах Debug API.

### 4. `/help`

Дописать новые роуты и поля в обе ветки (`text` и `json`) — иначе
самодокументируемость §031 расходится с поверхностью.

## Файлы

| файл | что |
|---|---|
| `app/lib/services/debug/serializers/subs.dart` | +4 поля в `serializeSubEntry`; `serializeImportRule` |
| `app/lib/services/debug/handlers/subs.dart` | `_update`: 3 поля; роутинг `/rules`; `_rulesList/_rulesCreate/_rulesSingle/_rulesUpdate/_rulesDelete/_rulesReorder` |
| `app/lib/services/debug/handlers/help.dart` | новые роуты/поля |
| `docs/api/debug-api-reference.md` | секция `/subs/{id}/rules`, новые поля PATCH, снятая quirk-строка про пропущенные поля |
| `app/test/services/debug/subs_rules_handler_test.dart` | новый — под-CRUD + тристейт identity |

Контроллер не трогаем: `SubscriptionEntry` уже несёт
`enableCustomIdentity` / `disableCustomIdentity` / `updateIdentity` /
`updateImportRules` / `importRulesEnabled` / `onUpdateAction` — хендлер идёт
через них (правило §031: не дёргать `SettingsStorage` напрямую), затем
`persistSources()`.

## Решения по месту

| вопрос | решение |
|---|---|
| `identity` объектом или плоскими полями `identity_hwid` и т.п.? | объектом — плоские поля не выражают тристейт Default/Custom и разъезжаются со слепком §289 |
| частичный объект `identity` — патч или полная замена? | патч поверх слепка: цель API — «включить HWID», а не «переписать всю идентичность»; полная замена требовала бы от клиента сначала читать глобал |
| import-rules полем в PATCH? | нет: список целиком в каждом запросе — потеря правки при гонке двух клиентов, и нет адресации к одному правилу |
| id у правил вместо индекса? | нет: модель без id, добавление id — миграция storage ради headless-пути; §238 уже задал прецедент позиционной адресации |
| строгая валидация enum'ов? | да: толерантность `fromJson` — свойство загрузчика storage, для API она превращает опечатку в тихо другое поведение |
| `disabled_hashes` (§283) в этой таске? | нет: это состояние per-node disable, не настройка подписки; отдельный роут при необходимости |

## Проверка

Хост: `flutter analyze` (весь проект) чисто; `flutter test` — 2705 зелёных, из
них 14 новых в `subs_rules_handler_test.dart`; все четыре l10n-чекера строгие —
OK.

Устройство: эмулятор `sdk_gphone64_arm64` / Android 14 (не CPH2411 — на нём
живые подписки юзера), Debug API проброшен `adb forward tcp:9270 tcp:9269`.
Тестовая подписка на реальной Remnawave-панели с HWID-гейтом, удалена после
прогона. Проверено через HTTP (роутер + query, чего unit-тесты не покрывают):

| # | сценарий | результат |
|---|---|---|
| 1 | `GET /subs/{id}` сразу после добавления | новые поля на месте: `identity:null`, `on_update_action:"rebuild"`, `import_rules_enabled:true`, `import_rules_count:0`; `nodes_count=1` (заглушка) |
| 2 | `PATCH {"identity":{"send_hwid":true,"hwid":"<uuid>"}}` | Custom включён; `device_os/ver_os/device_model` подтянулись из снапшота глобальных (`android`/`14`/`sdk_gphone64_arm64`) — подтверждает патч-семантику, а не полную замену |
| 3 | глобальные `subscription_send_hwid`/`subscription_hwid` после (2) | не изменились (обе `null`) — ради этого таска и делалась |
| 4 | `refresh` + `rebuild-config` под Custom | в конфиге `Main Server` и `Ru direct` → `balancer.infomir.net` |
| 5 | `PATCH {"identity":null}` + refresh + rebuild | обратно `App not supported` → `0.0.0.0`; тристейт работает в обе стороны |
| 6 | rules: POST ×2, POST `?index=0`, GET | 201; вставка в позицию 0; порядок `enable/disable/replace` |
| 7 | `PATCH rules/1 {"enabled":false}` | `usable:false`, прочие поля целы |
| 8 | `reorder {"order":[2,0,1]}`, `DELETE rules/0`, `GET rules/0` | порядок применён; индексы пересчитаны |
| 9 | 9 ошибочных путей | битый enum `action`/`op` → 400; неизвестное поле правила/identity → 400; мусор в `on_update_action` → 400; rules на UserServer → 409; индекс вне диапазона и нечисловой → 404; неполный reorder → 400 |
| 10 | `force-stop` + рестарт приложения | identity, `on_update_action:none`, `import_rules_enabled:false`, оба правила с их `enabled` — на месте |

Не покрыто: применение правил к телу подписки на refresh (движок §302 — своя
тестовая база); проверялось только что правила доезжают до модели и персистятся.
