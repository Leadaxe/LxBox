# 556 — долг реестра после бампа контракта 1.1.56 → 1.1.70 (§53–§66 `TASKS_LXBOX.md`)

| Поле | Значение |
|------|----------|
| Статус | В работе (ветка `task-556`) |
| Дата старта | 2026-09-26 |
| Дата завершения | — |
| Коммиты | — |
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

## Верификация

Только по одному файлу: `flutter test -j 2 test/contract/<файл>` для
`body_contract_test`, `contract_test`, `body_fields_roundtrip_test`,
`registry_load_test`, `body_sanitizer_test`, `registry_invariant_test`.
Полный прогон — CI после слияния.

## Нерешённое / follow-up

Заполняется исполнителем.
