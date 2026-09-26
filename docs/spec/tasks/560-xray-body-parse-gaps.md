# 560 — старые пробелы разбора тел: корпус контракта `body_contract_test` и `contract_test` зелёные

| Поле | Значение |
|------|----------|
| Статус | Выполнено частично (ветка `task-560`): body_contract 28 → 7 красных, contract_test 5 → 5; остаток — «Нерешённое» |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 |
| Коммиты | `0e859194`, `25956874`, `ce7abdbc`, `a2b897ea`, + коммит документации |
| Связанные spec'ы | §472 (конвейер разбора), §480 (движок маппера), §556 (долг реестра 1.1.70), §454–§457 (origin/body) |

## Проблема

После бампа контракта 1.1.70 и волн §556 локальные тесты корпуса остаются
красными по старым пробелам модели, не связанным с бампом: `body_contract_test`
(28) и `contract_test` (5). Ожидания этих кейсов в корпусе лаунчера не
менялись между 1.1.56 и 1.1.70. Пока они красные, корпус не работает как
сигнал регрессий; на CI эти тесты не идут (нет `app/contract`).

Это потери данных при импорте, а не косметика: узел собирается не так, как
задал провайдер, и пользователь этого не видит.

## Диагностика

Группировка по отчёту §556 (уточнить прогоном по одному файлу):

- **Xray-тела** теряют `multiplex`, `udp_over_tcp`, `alter_id: 0` и dial-поля
  (`connect_timeout`, `tcp_fast_open`, …); повтор `tls.server_name`, равного
  `server`, у trojan.
- **socks**: `version` не пишется; ссылка `socks5://` даёт `scheme: socks`
  вместо `socks5`.
- **anytls**: `server_name` не берётся из label во фрагменте ссылки.
- **vmess/not_base64_rejected**: код `form_unrecognized` вместо `field_missing`.
- **DNS amnezia**: список печатается через `, ` вместо `,+`.
- Порядок кодов в `list_non_string_items`.
- `ref` в `dropped[]` у Xray и `selector` как `urltest` — известные дельты
  (см. §556 «Нерешённое»), их сначала проверить на override
  `.expected.lxbox.json`; если override нет и лаунчер прав — чинить.

### Итоговая группировка (прогон на контракте 1.1.72)

Старт: `body_contract_test` 28 красных, `contract_test` 5.

| Группа | Кейсы | Причина |
|---|---|---|
| A. Поля вне модели | mux_concurrency, shadowsocks_uot, dialer_tcp_keep_alive, outbound_array_tls_fields, wireguard_settings_full, ini_no_allowedips | Типизированная модель (`VlessSpec`, …) не держит `multiplex`, `udp_over_tcp`, dial-поля, `workers`/`listen_port`, `disable_sni:false`; `emit()` их терял |
| B. Модель дописывает лишнее | 7 xray-кейсов с `tls.server_name`, socks_version_absent/invalid | Откат `server_name` на адрес в `_tlsFromSingbox` (у Xray-блока реестра отката нет); `version: "5"` у socks из JSON |
| C. `alter_id` | vmess_tls, vmess_security_junk (xray, ждут `0`); 8 URI-кейсов vmess (ждут отсутствие) | Движок не исполнял `omit_default` записи на входе |
| D. Отбраковка | socks_settings_users, hysteria_version_3_unrecognized | Запрет §321 «socks только звеном» в обход реестра; непрочитанная запись не называлась в `dropped[]` |
| E. Порядок warnings | list_non_string_items, hysteria2_bandwidth_suffix_finalmask_obfs | Раннер: ранг `server_ports[0]` не находился; `json_field_unknown` маппера шёл после кодов тела вопреки CANON §6 |
| F. Не решено | см. «Нерешённое» | Расхождение нормы и корпуса либо дизайн LxBox |

## Решение

Волна одного Opus-исполнителя в worktree `task-560`. Правило кампании:
правило живёт в реестре (`registry/protocols/*.json`, `mappers`), в Dart —
общий движок маппера/санитайзера без имён схем и полей. Если кейс не
выражается данными реестра — сначала искать общий примитив, который реестр
уже описывает и движок не исполняет; отдельную функцию под протокол не
писать. Если норма реестра расходится с ожиданием корпуса — это вопрос
лаунчеру, записать в «Нерешённое» с кейсом, не подгонять код.

Читать лениво: кейс корпуса → параграф реестра → место в движке.

### Что сделано

1. **Дельта тела** (`models/body_delta.dart`, `parser/body_delta_builder.dart`). При
   разборе тела, прошедшего санитайзер, поля схемы реестра (`schemaFor(type)` с
   развёрнутыми `tls`/`multiplex`/`dialer`/транспортом), которых нет в `emit()`
   модели, запоминаются и накладываются на каждый `emit()`. Для тела в форме ядра
   (`singbox`) снимается ключ, который модель дописала сама, если он равен
   `default` поля в реестре (CANON §2.4). Поля `managed` (`detour`) не трогаются,
   пустые значения не переносятся (`empty: absent`), внутри вариантов транспорта
   дефолты не снимаются (форма закреплена снимками «до §480»). Параметры ссылки,
   которые реестр числит за другой стороной (`uri.query.<имя>.ext: desktop`), дельта
   не добавляет — ssh `private_key_path`/`client_version` остаются как в override.
   Имён протоколов и полей в коде нет.
2. Откат `tls.server_name` на адрес убран из модели: его объявляет реестр
   (`default_from: host` у `tls#uri`).
3. Движок маппера исполняет `omit_default` записи на входе.
4. Xray: socks-элемент — узел по секции реестра; запись, которую не опознала ни одна
   секция или ни одна форма, без соседа по элементу уходит в `dropped[]` кодом
   `protocol_unsupported`/`form_unrecognized` (с соседом — прежний
   `UnsupportedProtocolWarning` на нём, §404 P3).
5. Раннер корпуса: ранг пути без индекса элемента, коды `unknown_key` секции-маппера
   (по реестру) впереди кодов тела.
6. `kNotModelled` в `body_fields_roundtrip_test` сокращён с 80 записей до 7: круг
   гоняется по настоящему пути (`sanitizedFrom: singbox`). В
   `xray_pipeline_invariants_test` пять задокументированных `delta560` (тег прежний,
   меняется тело).

## Верификация

Только по одному файлу: `flutter test -j 2 test/contract/body_contract_test.dart`
и `test/contract/contract_test.dart` — цель 0 красных; регрессий нет в
`body_sanitizer_test`, `body_fields_roundtrip_test`, `parse_warnings_test`,
`registry_invariant_test`, parser-тестах identity (`vless_pipeline_invariants_test`,
`before_480_identity_snapshot_test`, `engine_emit_roundtrip_test`). Identity
(тег) узлов не меняется. Полный прогон — CI после слияния.

Прогоны по одному файлу, контракт 1.1.72:

| Тест | Итог |
|---|---|
| `test/contract/body_contract_test.dart` | 7 красных (было 28), все в «Нерешённом» |
| `test/contract/contract_test.dart` | 5 красных (было 5), все в «Нерешённом» |
| body_sanitizer, body_fields_roundtrip, parse_warnings, registry_invariant | зелёные |
| vless_pipeline_invariants, before_480_identity_snapshot, engine_emit_roundtrip | зелёные |
| xray_pipeline_invariants, json_parsers, singbox_config, socks/masque/tuic/ssh/wireguard/hysteria2/anytls/shadowsocks/naive pipeline_invariants, tcp_keep_alive, utls_fingerprint, tls_passthrough, round_trip, xray_multiprotocol, xray_dedup, awg, node_spec и прочие соседние парсер-тесты | зелёные |

Теги узлов не менялись ни в одном снимке.

## Нерешённое / follow-up

Код не подгонялся; каждое — вопрос лаунчеру или владельцу.

1. **uri/anytls/sni_label_falls_back_to_server** — корпус ждёт `server_name:
   "Germany"`, реестр (`on_invalid: {action: default_from}` у записи `sni`) велит
   адрес сервера. Комментарий кейса сам говорит, что ожидание зафиксировано по
   факту движка лаунчера, а не по норме. LxBox исполняет норму.
2. **uri/socks/socks5_base64_userinfo(_colon_password)** — отличие только в
   `scheme` конверта (`socks5` против нашего `socks`). Это задокументированная
   by-design разница (IDENTITY §4a-C), у соседних socks5-кейсов она закрыта
   `.expected.lxbox.json`; у этих двух override нет. Нужен override у лаунчера.
3. **uri/vmess/not_base64_rejected** — корпус ждёт `field_missing`, у нас
   `form_unrecognized`. CANON §4.1: «секция схему опознала, но ни одна её форма не
   прочитала пейлоад» — `form_unrecognized`; `vmess://not-base64` ни одной формой
   не читается.
4. **uri/wireguard/amneziawg_scheme_full_name** — `value` у `wgconf_dns_ignored`:
   корпус `1.1.1.1,+1.0.0.1`, у нас `1.1.1.1, 1.0.0.1`. Параметр `dns=` без
   `plus_literal`, по MAPPER_ENGINE §833 query-значение декодирует `+` в пробел.
   Похоже, у лаунчера значение `note`-кода идёт мимо `decodeValue`.
5. **body/xray/hysteria_v1_skipped** — корпус ждёт узел Hysteria v1, а протокол
   `hysteria` в реестре `extension: desktop`; у ожидания нет ни
   `meta.extension`, ни override.
6. **body/xray/vless_encryption_junk, vless_encryption_none_wrong_case_rejected** —
   `ref` в `dropped[]`: корпус `enc-junk`/`enc-upper` (тег узла, `reason:
   emit_error` — отбраковка на сборке), у нас `proxy` — тег outbound'а (D-088,
   отбраковка при разборе §477).
7. **body/xray/malformed_stream, unsupported_protocol** — `dropped[]` при живом
   соседе. У LxBox причина висит на соседе по элементу (§404 P3, тест
   `json_parsers_test` «носитель есть → warning висит на СОСЕДЕ, не в dropped»),
   корпус ждёт запись в `dropped[]` и пустые `warnings[]` соседа. Решение — за
   владельцем: канал показа отбраковок при непустой подписке.
8. **body/singbox/group_member_missing, body/xray/balancer_group** — тело группы:
   у нас `AutoSelectSpec` эмитит `urltest` с пустым `outbounds` (состав резолвится
   на сборке) и своими дефолтами, `selector` становится `urltest`. Известная дельта
   рода группы (§556 «Нерешённое»); правка — модель группы, не разбор тел.
9. Дельта тела живёт в памяти узла и пересчитывается при каждом разборе; узел,
   пересобранный конструктором вне разбора (правка в UI, WARP/MASQUE-генерация),
   её не несёт до следующего чтения из источника. INI-путь с эмодзи
   (`subscription_controller`) дельту переносит.
