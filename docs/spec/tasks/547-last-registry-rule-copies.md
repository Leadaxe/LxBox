# 547 — последние копии правил реестра в коде

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-25 |
| Дата завершения | — |
| Коммиты | фаза A: `e98eb8e2` (код), docs — этот |
| Связанные spec'ы | §546 (эмиттеры без копий правил, «Нерешённое»), §545 (JSON-вход через санитайзер), §544 (`unless_set`, контракт 1.1.55), §457 (`key_share`), §358 (obfs hysteria2), §416 (xhttp placement↔mode), §472 (конвейер разбора) |

## Проблема

Принцип: правила полей судит только реестр (JSON контракта), код переводит
модель в форму ядра. После §545/§546 в коде осталось пять мест, где правило
написано руками рядом с реестром. Правка реестра до них не доходит, копии
расходятся (прецедент — `flow` в §544).

## Инвентарь

| # | Место | Что в реестре сейчас | Что делать |
|---|---|---|---|
| A1 | `kRealityKeyShares` (`models/tls_spec.dart`) + фильтр в `json_parsers.dart` (§457) | `tls.reality.key_share`: enum `""/hybrid/classical` в body и uri | снять копию, судит enum реестра |
| A2 | `normalizeHysteria2Obfs` / `kHysteria2ObfsTypes` (`services/parser/hysteria2_obfs.dart`, вызов в `json_parsers.dart`) | `hysteria2.obfs.type` enum + drop `obfs_unknown`; `obfs.password` required, код `obfs_password_missing` | снять копию; коды предупреждений должны прийти от санитайзера |
| A3 | `emitVless`: `encryption != 'none'` (`models/node_spec_emit.dart`) | `vless.encryption.absent_values: [none]` | снять сравнение с `none`, оставить только «пустое не пишем» |
| B1 | `emitShadowsocks`: `plugin_opts` пишется только при `plugin` | `plugin_opts` — голая строка, связи нет | запрос лаунчеру: `plugin_opts.requires: [plugin]` (движок умеет); после синка снять условие |
| B2 | `XhttpTransport.toSingbox`: `uplink_data_placement` ↔ `mode` (§416) | в body только enum; `impl` лаунчера: «до появления value-условия правило живёт в маппере» | запрос лаунчеру: связь по **значению** соседа в языке реестра (как `unless_set` в 1.1.55) + правило в body; движок санитайзера расширить; после синка снять ветку |

## Решение

**Фаза A (без лаунчера).** Снять A1–A3. Условие: на всех входах модель
строится по карте санитайзера (ссылка, Xray — конвейер §472; sing-box JSON —
§545; редактор — через гард сборки `applyRegistryGate`). Перед снятием
каждого места проверить grep-ом, что нет пути в модель мимо санитайзера;
найденный путь — описать здесь, не латать копией.

Коды предупреждений (`obfs_unknown`, `obfs_password_missing`) и тексты у
пользователя не должны измениться: если санитайзер ставит код с другими
`params`, это видно в корпусе — чинить сопоставление, не возвращать копию.

**Фаза B (после ответа лаунчера и синка контракта).** Снять B1, B2.
Поведение B2 сохраняется как сейчас, но из данных реестра:
- `header`/`cookie` и `mode` не задан → `mode: packet-up` дописывается;
- `header`/`cookie` и `mode` задан и не `packet-up` → placement снимается,
  код `xhttp_param_reset`.
Если язык реестра не даст выразить первую ветку (дописывание значения),
решение согласовать с лаунчером до правки кода.

## Проверка

- Точечно затронутые тест-файлы (`json_parsers_test`, `vless_test`,
  `hysteria2`-тесты, `transport_spec`-тесты, `node_spec_test`).
- Корпус тел и URI (`contract_test`, `body_contract_test`) — не хуже §545
  (`-6` / `-25`), эталон публичных подписок не меняется.
- Полный прогон — CI.

## Фаза A — сделано

**A1.** `kRealityKeyShares` (`models/tls_spec.dart`) снят. `_realityKeyShare`
в `json_parsers.dart` больше не фильтрует по enum и не нормализует регистр:
пустое — `null`, иначе значение как есть. Enum, `trim_lower` и код
`reality_key_share_invalid` — у реестра (`tls.json` →
`reality.key_share`). Раньше JSON-вход ронял негодное значение молча
(AppLog); код реестра ставил и тогда проход по дословной карте
(`annotateFromRawBody`), так что видимый набор кодов не изменился.

**A2.** `services/parser/hysteria2_obfs.dart` удалён целиком
(`normalizeHysteria2Obfs`, `kHysteria2ObfsTypes`). Ветка hysteria2 в
`parseSingboxEntry` читает `obfs.type`/`obfs.password` из карты как есть
(пароль — только при непустом типе). Коды `obfs_unknown` (путь `obfs.type`,
значение) и `obfs_password_missing` (путь `obfs.password`,
`params.type`) ставит реестр: у ссылки — конвейер §472 (так было и раньше),
у JSON — `annotateFromRawBody`. Коды и `params` те же, что ждёт корпус.
Разница одна: у JSON-входа текст теперь из каталога реестра
(`warnings.json`), а не из рукописного класса, — тот же, что у ссылки уже
показывался. Классы `UnknownObfsWarning`/`MissingObfsPasswordWarning`
остались без производителей в `lib/` (см. «Нерешённое»).
Сверка allowlist `hysteria2_obfs` в `registry_sync_test` снята вместе с
константой: сверять больше нечего.

**A3.** `emitVless`: `encryption` пишется, если непусто. `none` снимает
`absent_values` реестра на разборе и гард сборки перед ядром.

**Пути мимо санитайзера (grep).** Модель узла строится только в
`parseSingboxEntry`; боевых вызовов три: конвейер ссылки/Xray
(`mappers/uri_pipeline.dart`) и два `_sanitizedEntry` в
`singbox_config.dart` (узел и звено detour). Других конструкторов
`Hysteria2Spec`/`RealitySpec` с внешним значением нет (копия в
`node_spec.dart` переносит уже построенную модель). Найден один обход — ниже,
в «Нерешённом», п. 1; копия под него не оставлена.

Тесты: `json_parsers_test` (§358 obfs), `reality_key_share_test`
(нормализация и enum) и `parse_warnings_test` (§469 п. 6) переведены на
полный путь JSON-входа (`parseSingboxConfigs` / `parseAll`). Фикстурам
добавлены `tls` у hysteria2 и `utls` у REALITY: без них санитайзер
возвращает `null` (корневое `required`) или снимает блок, и модель строилась
бы по сырой карте — это и есть обход п. 1. Тест дедупа W2a держится на
подсадке рукописного класса: живого производителя больше нет.

| Прогон | База (§545) | После A |
|---|---|---|
| `test/contract/contract_test.dart` | `-6` | `+369 ~9 -6` |
| `test/contract/body_contract_test.dart` | `-25` | `+123 ~1 -25` (красные те же; пять про obfs/key_share/encryption — `xray/*`, красные и на базе) |
| `LX_CORPUS_PUBLIC=1 test/public_subscriptions` | зелёный | `+3`, зелёный |
| `json_parsers_test`, `vless_test`, `reality_key_share_test`, `parse_warnings_test`, `registry_sync_test`, `hysteria2_pipeline_invariants_test`, `tls_passthrough_test`, `node_spec_test`, `xhttp_test`, `vless/xray_pipeline_invariants_test`, `emu_input_defects_test`, `node_warning_test` | — | зелёные |

`flutter analyze` по затронутым файлам — 0.

## Нерешённое / follow-up

1. **Тела нет — модель по сырой карте** (`_sanitizedEntry`, §545 п. 4).
   Если санитайзер вернул `body == null` (снято корневое `required`, напр.
   hysteria2 без `tls`), `parseSingboxEntry` получает сырой entry, и в модель
   попадает несуженное значение (`obfs.type: "wat"`, `key_share: "x"`,
   `encryption: "none"`). В ядро оно не доходит: гард сборки такую запись
   снимает целиком (то же корневое `required`), а `none` снимает
   `absent_values`. Но модель, экран узла и `toUri()` видят сырое значение.
   Решать вместе с §477 (снимать ли узел без обязательного поля при разборе),
   не копией правила.
2. **Реестр не загружен** — сырая карта на всех входах. Режим не
   поддерживается с §480 (критерий 7, см. §546), фиксируется для полноты.
3. `UnknownObfsWarning` / `MissingObfsPasswordWarning` без производителей в
   `lib/`: живут в `warning_codes.dart` (код и путь для дедупа) и как пример
   в тестах (`node_warning_test`, `ui_msg_test`, `node_notifications_test`,
   `locale_switch_simulation_test`). Снять вместе с l10n-ключами — отдельной
   чисткой.
