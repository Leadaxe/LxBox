# 556 — долг реестра после бампа контракта 1.1.56 → 1.1.70 (§53–§66 `TASKS_LXBOX.md`)

| Поле | Значение |
|------|----------|
| Статус | Частично сделано (ветка `task-556`), остаток — в «Нерешённое» |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 (второй заход) |
| Коммиты | 00de8b9e, e96e251d, 9235987a, 94c6eac5, 726f0406, f2c3dfca, e61dc45c (+ merge develop 4713576c, d2637807); второй заход: e013c3ba, 78eaa954, d3781509, e2e29a64, 00be38cd, 539148e6 |
| Связанные spec'ы | §460 (реестр), §472 (конвейер разбора), §553 (разворот ссылок), §555 (язык шаблона — параллельная волна) |

## Проблема

Контракт бампнут одним шагом на 1.1.70 (коммит `6724ca6e`), встречные задачи
§53–§66 `app/contract/TASKS_LXBOX.md` в LxBox не делались. После бампа
красные: `body_contract_test` (34), `contract_test` (23),
`body_fields_roundtrip_test` (8), `registry_load_test` (2, литерал версии).
`template_contract_test` (3) — задача §555, здесь не трогать.

## Диагностика

Норма — параграфы §53–§66 `TASKS_LXBOX.md` и `docs/contract/*.md` (1.1.70).
Первичная группировка падений:

- `relation=ordered` (1.1.63) — санитайзер не знает вид связи набора;
  также `item_forbidden`, `normalize: cidr_masked`, `exit_capable_when`.
- `coerce_when` и `requires[].set` (1.1.61): `reality_fp_random_pinned`,
  `reality_utls_enabled` — крупнейший кластер vless (~14 кейсов).
- `on_invalid: unwrap` (1.1.57), `role` (1.1.59), `on_core_unsupported`/`levels`
  (1.1.60), `forbidden_for: masque` у TLS-полей и `value_map_case` (1.1.64),
  `default_when` (1.1.65), `YieldsTo` для `listen_port`/detour (1.1.65),
  коды 1.1.66–1.1.67 (`group_member_*`, `core_rejected` при импорте бэкапа).
- Разбор ссылок: `socks5://` должен сохранять `scheme: "socks5"`; `server_name`
  из fragment-label (anytls); эхо `tls.server_name == server` не эмитится.
- `tls.fragment`/`tls.record_fragment` объявлены, но не смоделированы; список
  `kNotModelled` в `body_fields_roundtrip_test` устарел (`masque.network`,
  `skip_cert_verify`, `sni`).

## Решение

Правило кампании владельца: **всё правило живёт в реестре, в Dart — общий
движок без имён схем и переменных**. Каждый новый примитив реализуется как
общий обход атрибута реестра, не как ветка под протокол. Порядок работы —
по параграфам §53→§66, после каждого параграфа коммит. Локальные копии
правил (хардкод имён полей/протоколов), которые контракт перевёл в данные,
снимать вместе с их тестами. Тихих отбраковок нет: каждая проверка ставит
код из `warnings.json` с параметрами.

Читать лениво: параграф `TASKS_LXBOX.md` → соответствующий корпусный кейс →
код. Не читать реестр целиком.

## Сделано по параграфам

- **§53 (1.1.57).** `on_invalid: unwrap` — общий обход атрибута в
  `body_sanitizer.dart` (`_invalid`): годный член `key` → значение + `code`,
  иначе снятие с `else_code` и скалярными членами объекта в параметрах, не
  объект — `type_invalid`. Тесты в `body_sanitizer_test` (hysteria `obfs`).
  Неизвестные ключи судятся по алфавиту (`masque_legacy_flat_keys`); из
  `kNotModelled` сняты плоские ключи masque.
- **§57 (1.1.61).** `requires[].set` и `coerce_when` — отложенные
  правила-починки, исполняются по готовому телу после связей тела, код
  встаёт на место обхода. Путь, который схема не допускает, — обычное
  снятие. REALITY-починка снята из `healUnknownUtlsFingerprints` (осталась
  канонизация мусора §281) и из `normalizeTlsFingerprint` (подстановка
  `chrome`); uTLS без отпечатка — `TlsSpec.fingerprint == ''`.
- **§59 (1.1.63).** `relations.kind: ordered` с `drop`/`drop_node`,
  `item_forbidden`, normalize `cidr_masked`. Тест conf-секции допускает
  источник `context.*`.
- **§60 (1.1.64).** Сосед связи без точки, которого нет в своём объекте,
  ищется в корне (`tls.fragment` ↔ `vhttp`), у схемы без поля связь молчит;
  то же в генераторе тел `body_field_generator`. Коды `conflicts`/`requires`
  встают сразу за кодами своего поля (порядок `masque_tls_owner_rules`).
  `MasqueSpec.tlsExtra` несёт прочие ключи `tls{}` как есть; пустой `vhttp`
  не дописывается. Раннер тел сверяет `warnings[]` узлов с одной подписью
  по порядку появления.
- **§61 (1.1.65).** `ssh_user_default` через `default_when` — кейс корпуса
  зелёный без правок кода.
- Сортировка кодов корпуса (`corpus_warnings.dart`) видит записи общих
  блоков с `maps_to: null` (`tls.json` `blocks.uri.ech`) как потерю разбора.

## Второй заход

- **Эталоны parser-тестов (e013c3ba).** Красный CI после первого захода —
  следствие нормы, а не регрессия: REALITY с неявным (D-009) или явным
  `random` несёт в теле `chrome` (1.1.61, корпус `uri/vless` 17 кейсов +
  `alpn_multiply_encoded`), поэтому пересняты содержательные хеши
  (`legacyNodeIdentityHash`) и тела 18 кейсов снимков vless + 2 кейса b480;
  теги (identity) не менялись. Пустой отпечаток под REALITY законен (enum
  реестра, ядро читает как chrome) — uTLS эмитится `{enabled: true}`.
  Masque без `vhttp` остаётся без него (default реестра `auto`, корпус
  `masque_tls_owner_rules`). Публичный корпус (PublicSubsCorpus,
  continue-on-error): 537 узлов ушли в `dropped.duplicate` — ссылки,
  различавшиеся только `fp=random`/`fp=chrome`/без fp под REALITY, теперь
  дают байтово равные тела (D-086); плюс счётчики
  `reality_fp_random_pinned`. Эталон `expected.json` не обновлялся —
  отдельным коммитом по решению человека.
- **§59 (78eaa954).** Движок маппера: источники `context.*` и
  `ref.<as>.*`, `deref {key, as}` (слой до `when`), `substitute`, оператор
  `type_of`. Xray-элемент отдаёт движку массив `outbounds`;
  `fragment_via_dialer` ставит `tls.fragment` тому, кто ходит через
  freedom (у звена — самому звену), рукописная `_xrayApplyFreedomFragment`
  снята, freedom у звена завершает цепочку (раньше цепочка отбраковывалась
  целиком). `exit_capable_when` — общий суд условия по готовому телу
  (`exitCapableByRegistry`) в пуле Направлений, `TailscaleSpec.hasExitNode`
  снят. `mapIniViaEngine` принимает `context`.
- **§60 (d3781509).** `fieldAllowedOn` — «оставил бы санитайзер поле при
  этом теле»; `applyTlsFragment` без своих исключений naive/masque.
  `value_map_case: sensitive` у Xray-входа vless `encryption` уже
  исполнялся движком.
- **§61 (e2e29a64).** `yieldToManaged` + post-step `applyDetourYields`:
  связи `conflicts {with: detour}` по готовому телу после сборки,
  `listen_port` уступает с кодом `detour_with_listen_port` в отчёт сборки.
  `body_dialect_unrecognized` в коде не заводился — снимать нечего.
- **§62/§63 (00be38cd).** `warnings` у `kind: auto` пишутся и читаются как
  есть (`FolderMember.auto(warnings:)`); `group_member_missing` уже стоял на
  узле-группе. `core_rejected`: экспорт сервера/члена папки как есть с
  `enabled: false`, подписка — `disabled{}` без причины; импорт снимает
  запись, выключение из файла сохраняет (прежняя норма §489 включала узел).
- **§55 (539148e6).** `fieldByRole`, `carriesPrivateKeyByRegistry` (Copy
  link, Debug API `/nodes/link`) вместо переопределений
  `linkCarriesPrivateKey`; `credentialByRegistry`.

## Верификация

По одному файлу, второй заход: `body_sanitizer_test` 84/84,
`registry_invariant_test` 160 (17 skip), `body_fields_roundtrip_test` 28/28,
`parse_warnings_test` 33/33, `backup_corpus_test` 31/31, `lx_backup_test`
92/92, `core_reject_backup_test` 15/15, `engine_primitives_test` 57/57,
`tailscale_sections_test` 15/15, `node_sections_build_test` 15/15,
`masque_tls_fragment_test` 8/8, `detour_yields_test` 2/2,
`build_config_test` 17/17, `copy_node_uri_private_key_test` 14/14,
`utls_fingerprint_test`, `json_parsers_test`,
`vless_pipeline_invariants_test`, `before_480_identity_snapshot_test`,
`engine_emit_roundtrip_test`, `engine_w4_reconcile_test` — зелёные.
`body_contract_test` — 28 красных, `contract_test` — 5 (старые пробелы, см.
ниже).

Первый заход: `registry_load_test` 11/11, `preset_expand_test` 67/67,
`mapper_sections_w4_test` 25/25, `heal_unknown_utls_fingerprints_test` 13/13,
`reality_fingerprint_build_test` 8/8.

## Нерешённое / follow-up

Следствие бампа, не сделано:

- **§56** `on_core_unsupported`/`levels`: общий гейт узла на сборке и
  подпись уровня AWG из реестра не сделаны. Гейт Tailscale у нас — по
  версии (`kTailscaleMinCoreVersion`), реестр гейтит по `build_tag`, строки
  `Tags:` у нас нет — свести значит снять гейт; подпись уровня
  (`config_node.dart _deriveAwgLevel`) — UI.
- **§54** форма цепочки из `strip.order`/`default`, подпись транспорта;
  **§57** `on_hop_required` и `ChainIssueCode.stripUtlsOnReality` — UI.
- **§59** распаковщик Amnezia по-прежнему вписывает MTU и DNS в текст INI:
  текст — `rawSource`, источник истины при повторном разборе, а контекст не
  хранится; записи `mtu_container`/`dns.substitute` исполняются, но на
  подготовленном тексте ничего не меняют.
- **§60** `xray/vless_encryption_*`: код верный, `ref` — тег outbound'а
  (`proxy`), у лаунчера — имя элемента (известная дельта бухгалтерии
  `dropped[]`, spec 480).
- **§62** кейс `body/singbox/group_member_missing`: код на группе стоит,
  тело расходится — selector у нас узел-группа urltest (дельта рода группы).
- **§63** `group_member_dropped` в отчёте сборки не ставится: отчёт пишет
  свои строки о выбывшем члене, смена текста — UI, контракт не обязывает.
- **§60** создание блока `tls{}` у masque в `applyTlsFragment` осталось
  структурной веткой по типу (у схемы нет признака «TLS без выключателя»).
- Эталон PublicSubsCorpus (`expected.json`) — переснять отдельным
  коммитом.

Старые пробелы (корпус не менялся, follow-up): Xray-тела теряют
`multiplex`, `udp_over_tcp`, `alter_id: 0`, dial-поля (`network_strategy` и
др.); эхо `tls.server_name == server` у Xray trojan (кейсы
`dialer_chain_vless_relay`, `dialer_chain_hop_freedom_fragment` — остальное
в них уже верно); `socks` `version` по умолчанию; порядок кодов элементов
списков (`list_non_string_items`); `anytls` server_name из fragment-label;
`socks5://` → `scheme: socks5`; `vmess/not_base64_rejected`
(`form_unrecognized` вместо `field_missing`); DNS amnezia `, ` вместо `,+`.
