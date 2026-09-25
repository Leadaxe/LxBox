# 546 — эмиттеры без копий правил реестра

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-25 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | §545 (JSON-вход через санитайзер), §544 (сетка flow↔transport), §472 (конвейер разбора), §460 (реестр, гард сборки `registry_gate.dart`), §459/§416/§217 (xhttp-гейты эмита), §282/§469 (QUIC без uTLS/Reality), §358 (obfs hysteria2) |

## Проблема

После §545 модель узла на всех входах разбора строится по карте, которую
очистил санитайзер реестра: ссылка и Xray идут через конвейер
(`mappers/uri_pipeline.dart`), sing-box JSON через `_sanitizedEntry`
(`singbox_config.dart`). А на сборке гард реестра (`applyRegistryGate`,
`services/builder/registry_gate.dart`) ещё раз прогоняет через санитайзер
каждую запись перед ядром. Модель, собранную руками в редакторе, он тоже
видит.

Эмиттеры (`models/node_spec_emit.dart`, `TlsSpec.toSingbox`,
`TransportSpec.toSingbox`) тем не менее держат свои копии правил реестра:
фильтры допустимых значений, связи полей и коды предупреждений, которые
ставятся на эмите. Копии расходятся с реестром, как было с `flow` в §544, и
правка реестра не доходит до поведения без правки кода.

## Правило

Эмиттер **переводит модель в форму ядра**, и только. В нём остаётся:

- имена и вложенность ключей ядра, порядок ключей (golden, байт-паритет);
- неписание пустого или незаданного (CANON §2.4: дефолты не пишутся),
  включая маркеры «слоя нет» модели (`encryption` пустое или `none`);
- переменные шаблона (`TemplateVars`), dial-поля, `detour`;
- постоянные, которые ядро требует от формы, а не от значения
  (`quic_congestion_control: bbr` у naive+quic).

Уходит всё, что судит реестр:

- фильтр значения по enum или allowlist («пишем, только если X ∈ {…}»);
- связь полей (`conflicts`, `requires`, `forbidden_for`, «при A снять B»,
  «при A дописать B»);
- коды предупреждений, которые ставятся на эмите по правилу реестра.

## Инвентарь (найдено 25.09.2026)

| Место | Копия правила | Правило реестра |
|---|---|---|
| `emitVless` | `flow` пишется только при `== 'xtls-rprx-vision'` | `vless.flow` (values) |
| `emitHysteria2` | `obfs` пишется только при `salamander`/`gecko`; `min/max_packet_size` только при `gecko` | `hysteria2.obfs.type` (enum), `obfs.min/max_packet_size` `requires` type=gecko |
| `emitHysteria2`, `emitTuic` → `TlsSpec.toSingboxForQuic` | срез `utls`/`reality` на QUIC | `tls.json` `forbidden_for` |
| `XhttpTransport.toSingbox` → `putEnum` | `mode`, `session_placement`, `seq_placement`, `x_padding_placement`, `x_padding_method` вне enum снимаются с `XhttpParamResetWarning` | `transports.json` xhttp, `on_invalid` → `xhttp_param_reset` |
| `XhttpTransport.toSingbox` | `uplink_data_placement=header`: без `mode` дописать `packet-up` (`XhttpModeForcedPacketUpWarning`), при другом `mode` снять placement (`XhttpParamResetWarning`) | `transports.json` ~1365/~2058: `xhttp_mode_forced_packet_up`, `xhttp_param_reset` |

Исполнитель обязан досмотреть **все** `emit*` в `node_spec_emit.dart`,
`toSingbox` у `TlsSpec`/`RealitySpec`/всех `TransportSpec`, `Awg.writeInto`,
`tcpKeepAliveToSingbox`, `_kTlsEmitOrder`/`passthrough` в `tls_spec.dart`
и дописать сюда то, чего в таблице нет. Перед снятием каждого пункта нужно
убедиться, что правило в реестре (`app/assets/contract/registry/**`)
действительно есть и срабатывает на входах разбора. Если правила в реестре
нет, пункт не снимается, а записывается в «Нерешённое» (запрос лаунчеру).

## Решение

1. Снять копии из инвентаря. `toSingboxForQuic` удалить и звать
   `toSingbox`. `putEnum` заменить прямой записью непустого значения. Блок
   `uplink_data_placement` заменить прямой записью. `obfs` писать при
   непустом типе, размеры пакета — при заданных.
2. Классы `XhttpParamResetWarning`/`XhttpModeForcedPacketUpWarning` не
   удалять, если они ещё нужны разбору, корпусу или коду кода
   (`warning_codes.dart`). Если после снятия у класса не остаётся
   производителя, удалить класс вместе с его ветками в `switch`.
3. Тесты, которые проверяли правило **на эмите** (`XhttpTransport(...)
   .toSingbox`, `TlsSpec.toSingboxForQuic`, модель с мусором → `emit()`),
   переписать на путь разбора (ссылка, sing-box JSON через
   `parseSingboxConfigs`, Xray): правило обязано срабатывать там, через
   санитайзер. Тест, который проверяет только то, что эмиттер **больше не
   судит** (модель как есть → тело как есть), допустим.
4. Комментарии, ссылающиеся на снятое (`toSingboxForQuic` в
   `json_parsers.dart` и тестах, «сетка», «единственная воронка»),
   привести в соответствие.

Отказ без реестра: без загруженного реестра разбор ссылок не работает с
§480 (критерий 7), так что режим «эмиттер как последняя защита» не
поддерживается.

## Проверка

- Корпус контракта: `test/contract/contract_test.dart` — `+369 ~9 -6`
  (те же 6 красных, что в §529); `test/contract/body_contract_test.dart` —
  25 красных из списка §529/§545, новых нет.
- Эталон публичных подписок (`LX_CORPUS_PUBLIC=1 flutter test
  test/public_subscriptions`) не меняется.
- Затронутые тест-файлы зелёные.
