# 556 — долг реестра после бампа контракта 1.1.56 → 1.1.70 (§53–§66 `TASKS_LXBOX.md`)

| Поле | Значение |
|------|----------|
| Статус | Частично сделано (ветка `task-556`), остаток — в «Нерешённое» |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 (первый заход) |
| Коммиты | 00de8b9e, e96e251d, 9235987a, 94c6eac5, 726f0406, f2c3dfca, e61dc45c (+ merge develop 4713576c, d2637807) |
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

## Верификация

По одному файлу (после второго merge develop, d2637807):
`registry_load_test` 11/11, `body_fields_roundtrip_test` 28/28,
`body_sanitizer_test` 84/84, `registry_invariant_test` 160 (17 skip),
`preset_expand_test` 67/67, `mapper_sections_w4_test` 25/25,
`heal_unknown_utls_fingerprints_test` 13/13, `reality_fingerprint_build_test`
8/8. `body_contract_test` — 28 красных (было 34), `contract_test` — 5
красных (было 23).

## Нерешённое / follow-up

Корпус тел и URI на CI не гоняется (там только зеркало `app/assets/contract`),
поэтому часть красного — старые пробелы модели, не следствие бампа: ожидания
этих кейсов между 1.1.56 и 1.1.70 не менялись.

Следствие бампа, не сделано:

- **§62** `group_member_missing` на узле-группе (кейс
  `body/singbox/group_member_missing`), импорт `warnings` у `kind: auto` из
  бэкапа; **§63** снятие `core_rejected` при импорте бэкапа.
- **§59 маппер:** `context.*`, `deref`/`ref.*`, `substitute`, `type_of` в
  движке маппера (кейс `xray/dialer_chain_hop_freedom_fragment`; `mtu_container`
  и подстановка DNS amnezia пока своим кодом); `exit_capable_when`
  (гейт `server_list_build.dart`).
- **§60** `value_map_case: sensitive` у Xray-входа vless `encryption`
  (кейс `xray/vless_encryption_none_wrong_case_rejected`); вопрос сборки
  «оставил бы санитайзер поле» перед анти-DPI трансформами
  (`post_steps/tls_transforms.dart`).
- **§54/§55/§56** данными реестра не пользуемся: форма цепочки из
  `strip.order`/`default`, подпись транспорта, `role` (credential /
  private_key вместо `linkCarriesPrivateKey`), `on_core_unsupported`/`levels`
  (гейт и подпись уровня AWG). §57 `on_hop_required` у цепочки и находка
  `ChainIssueCode.stripUtlsOnReality` — это UI, молча не менялось.
- **§61** `YieldsTo` (`listen_port` уступает detour на сборке) и снятие
  `body_dialect_unrecognized`; форма обфускации AWG всё ещё проверяет
  jmin ≤ jmax сама (§59) — UI.

Старые пробелы (корпус не менялся): Xray-тела теряют `multiplex`,
`udp_over_tcp`, `alter_id: 0`, dial-поля (`network_strategy` и др.);
`socks` `version` по умолчанию; порядок кодов элементов списков
(`list_non_string_items`); `anytls` server_name из fragment-label;
`socks5://` → `scheme: socks5`; `vmess/not_base64_rejected`
(`form_unrecognized` вместо `field_missing`); DNS amnezia `, ` вместо `,+`.
