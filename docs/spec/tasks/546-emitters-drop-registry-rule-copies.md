# 546 — эмиттеры без копий правил реестра

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-25 |
| Дата завершения | 2026-09-25 |
| Коммиты | этот коммит |
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
| `emitShadowsocks` | `plugin_opts` пишется только при непустом `plugin` | нет: в `shadowsocks.json` у `plugin_opts` нет `requires` |

Досмотр 25.09.2026 (исполнитель). Сверх таблицы копий правил реестра не
найдено. `emitVmess`, `emitTrojan`, `emitAnyTls`, `emitNaive`, `emitSsh`,
`emitSocks`, `emitHttp`, `emitWireguard`, `emitMasque`, `emitTailscale`,
`RealitySpec.toSingbox`, `WsTransport`/`GrpcTransport`/`HttpTransport`/
`HttpUpgradeTransport.toSingbox`, `Awg.writeInto` (это `addAll`) и
`tcpKeepAliveToSingbox` только раскладывают модель по ключам ядра и не
пишут пустое. `_kTlsEmitOrder` задаёт порядок ключей: typed-поля и
`kTlsPassthroughKeys` в нём целиком, значений он не судит. Безусловный
`tls` у anytls/naive и `quic_congestion_control: bbr` у naive+quic — это
форма ядра.

Итог по пунктам:

| Пункт | Итог | Проверено на разборе |
|---|---|---|
| `vless.flow` | снят: пишется непустой `flow` | sing-box JSON (`none`, `xtls-rprx-direct`) → поля нет; ссылка → `flow_deprecated` |
| hysteria2 `obfs` | снят: `obfs` при непустом типе, размеры пакета при заданных | JSON `type: bogus` → блока нет; salamander + `min_packet_size` → размер снят; ссылка → `obfs_unknown` |
| QUIC utls/reality | снят: `toSingboxForQuic` удалён, hysteria2/tuic зовут `toSingbox` | JSON hysteria2/tuic с utls/reality → блоков нет; ссылка → `tls_not_applicable_quic` |
| xhttp enum (`putEnum`) | снят: непустое пишется как есть | JSON и ссылка по пяти полям → значение вне enum снято, у ссылки `xhttp_param_reset` |
| xhttp `uplink_data_placement` ↔ `mode` | **оставлен** | ссылка — правило есть; sing-box JSON — нет (с временно снятой веткой `header` + `stream-one` доезжал до тела) |
| ss `plugin_opts` ↔ `plugin` | **оставлен** | правила в реестре нет |

Классы `XhttpParamResetWarning` и `XhttpModeForcedPacketUpWarning` остаются:
их по-прежнему ставит ветка `uplink_data_placement`.

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

5. Probe-конфиг (решение владельца 25.09.2026) проходит гард реестра так
   же, как боевая сборка (`build_config.dart` → `applyRegistryGate`). Без
   этого после снятия копий probe остался бы единственным путём в ядро мимо
   реестра.
   - Гард идёт по записям каждого узла в `_buildOne`
     (`services/probe/probe_config.dart`) до раскладки по батчам. Тело
     переписывается на месте.
   - Запись снята гардом → узел в конфиг не идёт, `brokenByIndex[i] =
     'invalid: <тег записи>: <коды реестра>'`. Если снят детур, узел не
     тестируется целиком: main ссылался бы на отсутствующий тег.
   - Версия ядра для `min_core` берётся там же, где у боевой сборки:
     `CoreVersionCache.ensure(getCoreVersion)` (`core_chain_capability.dart`,
     кэш на сессию, из него же `BuildSettings.coreVersion` в
     `subscription_controller.dart`). `ProbeRunner.run` и
     `NodeDiagnosticsRunner._runProbe` передают её в
     `buildProbeBatches`/`buildProbeConfig`.
   - Вход тела — `BodySource.other`, не `bodySourceOf(node)`: тело в probe
     всегда из `emit()`, а сборка метит `singbox` только дословное тело
     UserServer/члена папки. Узел JSON-подписки у сборки идёт как `other`,
     `bodySourceOf` дал бы ему `singbox`. Цена: AWG-узел UserServer/папки с
     `mtu` выше потолка `max_when` (`except_sources: singbox`) в probe
     получит потолок, а в боевом конфиге сохранит своё значение.
   - Реестр не загружен → гард снимает только запись без `type`, остальное
     как раньше.
   - Перф: 2000 узлов vless (vision + ws + utls) на хосте (JIT) — сборка
     батчей 34 мс без гарда, 213 мс с гардом, около 90 мкс на узел.
     Реестр повторно не грузится (гард проверяет `isLoaded` и зовёт
     санитайзер по уже загруженным данным).

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

Итог прогона 25.09.2026 (по одному файлу):

| Проверка | Результат |
|---|---|
| `flutter analyze --fatal-infos` по изменённым файлам lib и test | 0 замечаний |
| `test/probe/probe_test.dart` (новая группа §546: flow снят гардом, снятая запись → `brokenByIndex`, снятый детур → узел не тестируется), `node_diagnostics_runner_test` | зелёные |
| `xhttp_test`, `utls_fingerprint_test`, `hysteria2_pipeline_invariants_test`, `tuic_pipeline_invariants_test`, `reality_key_share_test`, `heal_unknown_utls_fingerprints_test`, `node_warning_test`, `parse_warnings_test`, `vless_test`, `json_parsers_test`, `round_trip_test`, `node_spec_test` | зелёные |
| URI-раннер `contract_test` | `+369 ~9 -6`, те же 6 красных, что в §529 |
| раннер тел `body_contract_test` | `+123 ~1 -25`, те же 25 красных, что после §545 |
| эталон публичных подписок | зелёный (`+3`), файлы эталона не менялись |

Тесты, проверявшие правило на эмите, переписаны на путь разбора:
enum-гейт xhttp — sing-box JSON и ссылка (`xhttp_test`); QUIC-срез —
`parseSingboxConfigs` вместо `parseSingboxEntry` (`utls_fingerprint_test`,
пары uri↔body в `hysteria2_/tuic_pipeline_invariants_test`,
`reality_key_share_test`). Добавлен тест «модель как есть → тело как есть»
для xhttp-эмиттера.

## Риски и edge cases

- Probe-конфиг до этой задачи гард не проходил: `applyRegistryGate`
  вызывался только из `build_config.dart`. Проверено 25.09: всё, что
  доходит до probe, построено разбором (ссылка и Xray через
  `uri_pipeline`, sing-box JSON через `_sanitizedEntry`). Мастер добавления
  (`add_server_wizard_screen.dart`) собирает в памяти только socks/http,
  контроллер — только masque/wireguard; снятых копий они не касаются.
  `patchedJson` правил импорта (§302) эмиттер не трогал и раньше. Теперь
  гард стоит и в probe (п. 5 «Решения»).
- Два деградированных пути, где модель строится по сырой карте, а копии
  эмиттера раньше страховали ядро:
  (а) реестр не загрузился на старте (`main.dart` ловит исключение
  `ContractRegistry.I.load()` и продолжает). Ссылки и Xray тогда не
  разбираются вовсе (§480), sing-box JSON идёт по сырой карте, гарда на
  сборке нет;
  (б) `_sanitizedEntry` получил `body == null` (снято обязательное поле,
  §477). Модель строится по сырой карте, узел снимает гард — на сборке и,
  после п. 5 «Решения», в probe.
  Путь (а) остаётся: мусорное значение (flow, obfs, xhttp-enum,
  utls/reality на QUIC) уходит в ядро как есть, и ядро отвергает конфиг или
  probe-батч целиком. Решение принято: это поломка, штатным входом она не
  является. Путь (б) закрыт гардом.

## Нерешённое

- **xhttp `uplink_data_placement` ↔ `mode` на входе sing-box JSON** (запрос
  лаунчеру). Связь есть только в блоках `uri`/`xray` маппера
  (`uplinkDataPlacement`: `when` по `transport.mode` с `not_in`, `implies`
  packet-up, `on_implies_written`/`on_when_false`). В схеме тела
  (`body.variants.xhttp.uplink_data_placement`) только enum, поэтому узел
  из JSON-подписки или редактора с `header` вне packet-up санитайзер
  пропускает. Ветка в `XhttpTransport.toSingbox` остаётся, пока связь не
  появится в схеме тела (`requires`/`conflicts` по `mode` или аналог
  `implies`).
- **shadowsocks `plugin_opts` без `plugin`** (запрос лаунчеру): в
  `shadowsocks.json` нет `requires` у `plugin_opts`. Эмиттер пишет
  `plugin_opts` только при `plugin`, пока правила нет.
- Вне эмиттеров, для следующей задачи: у разбора остались свои копии
  правил реестра — `kRealityKeyShares` (`json_parsers.dart`, key_share) и
  `normalizeHysteria2Obfs` (`hysteria2_obfs.dart`, тип и пароль obfs).
