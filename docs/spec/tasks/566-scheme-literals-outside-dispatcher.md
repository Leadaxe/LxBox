# 566 — литералы схем и протоколов вне диспетчера сняты: список файлов реестра, распознавание ссылки, обёртки парсеров

| Поле | Значение |
|------|----------|
| Статус | Готово (ветка `task-566`) |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 |
| Коммиты | `df444079` (состав протоколов из каталога), `69b3c138` (распознавание ввода), `658f903e` (обёртки парсеров), `c9d99880` (страж), + коммит документации |
| Связанные spec'ы | §562 (диспетчер схем из реестра), §480 (движок маппера), кампания «реестр важнее локальных правил» |

## Проблема

После §562 диспетчер схем ссылки читает реестр, но имена схем и протоколов
остались словами ещё в трёх местах:

1. `app/lib/services/contract/registry.dart` ~:1012 `_kProtocolFiles` — список
   файлов `registry/protocols/*.json`, которые грузятся. Новый протокол в
   реестре молча не загрузится, пока его не впишут в Dart.
2. `app/lib/services/subscription/input_helpers.dart` — проверка «текст похож
   на ссылку/подписку» по именам схем (10 литералов).
3. `app/lib/services/parser/uri_parsers/*_parser.dart` — обёртки над движком
   по одному файлу на протокол (anytls, http, hysteria2, masque, naive,
   shadowsocks, socks, ssh, trojan, tuic) и их выбор в `uri_parsers.dart`.

Решение владельца 26.09.2026: снимать и чистить, приоритет.

## Решение

1. **Список файлов реестра** — из данных: реестр знает свой состав
   (`registry/index.json`, `protocols.json` или перечень в `README`/схеме —
   найти, что даёт контракт; если перечня нет — читать каталог
   `registry/protocols/` из бандла ассетов через `AssetManifest`, а для
   `app/contract` — листингом каталога). Если контракт перечня не даёт и
   манифест ассетов неудобен — записать в «Нерешённое» запрос лаунчеру на
   `protocols/index.json`, временно оставив список с тестом «список равен
   содержимому каталога» (чтобы расхождение падало явно).
2. **Распознавание ссылки** в `input_helpers.dart` — через диспетчер §562
   (`detect.scheme_in` + `aliases`) и `source_kinds.json`; литералы снять.
3. **Обёртки парсеров** — если обёртка только вызывает движок для одной
   схемы, она снимается, вызывающие переводятся на общий вход движка по схеме
   реестра; если в обёртке есть логика, которой нет в реестре — вынести её
   как общий примитив или записать в «Нерешённое» с указанием, какое правило
   реестра её должно заменить. Тесты обёрток — переписать на общий вход или
   снять вместе с обёрткой.
4. **Страж** `engine_no_scheme_names_test` расширить на `registry.dart`,
   `input_helpers.dart`, `uri_parsers/**`. Разрешённые исключения перечислить
   в самом страже с причиной (например `awg`/`awg3` как род узла).
5. Документация: спека §480/§562 (диспетчер), `CHANGELOG.md` Unreleased.

Правило кампании: имён схем/протоколов в Dart не остаётся; тело и тег узлов
корпуса не меняются.

## Верификация

Итог (26.09.2026, по одному файлу): `contract_test` 378/0;
`body_contract_test` — красны только 2 известных (`group_member_missing`,
`balancer_group`, задача 565); `registry_load_test` 13/0 (новые кейсы:
состав из листинга каталога, `load()` с подменённым манифестом);
`input_helpers_test` 41/0, `parse_input_rejected_test` 13/0 (метка
`wireguard` у `.conf` теперь из реестра); `engine_no_scheme_names_test` 2/0;
`before_480_identity_snapshot_test` 14/0, `engine_emit_roundtrip_test` 26/0;
тесты снятых обёрток (переведены на `parseLinkAs<T>`) — `masque_spec`,
`naive_emit`, `contract_24_2_rules`, `masque_pipeline_invariants`,
`reality_key_share`, `reality_short_id`, `round_trip`, `tuic`, `uri_naive`,
`utls_fingerprint`, `vless`, `node_hash` — зелёные. `flutter analyze` по
затронутым каталогам — 0.

План проверки: `test/contract/contract_test.dart` (378/0),
`test/contract/body_contract_test.dart` (только 2 известных рода группы),
`test/contract/registry_load_test.dart`, `test/subscription/input_helpers_test.dart`,
`test/parser/engine_no_scheme_names_test.dart`, identity-снимки
(`before_480_identity_snapshot_test`, `engine_emit_roundtrip_test`), тесты
рядом с снятыми обёртками. Полный прогон — CI.

## Итог

1. `_kProtocolFiles` снят. `ContractRegistry.load()` берёт состав
   `registry/protocols/` из манифеста ассетов (`AssetManifest.listAssets()`,
   инъекция `lister` для тестов), `loadFromDirectory()` — листингом каталога.
   Контракт перечня протоколов не несёт (лаунчер грузит их `go:embed`-глобом),
   так что запроса `protocols/index.json` не понадобилось. Попутно
   `awgMtuCeilingByRegistry`/`awgMtuClampCodeByRegistry` ищут схему по типу
   тела узла (параметр), а не литералом.
2. `input_helpers.dart`: запасной `vpn://` у `isAmneziaVpnLink` снят (реестра
   нет — контейнера нет, как у диспетчера §562); метка `.conf` в шторке —
   тип секции вида источника (`source_kinds` → `mapper` → `typesFor`).
   `http(s)://` у `isSubscriptionUrl` оставлены явным исключением стража.
3. Двенадцать обёрток `uri_parsers/<схема>_parser.dart` сняты — ни в одной не
   было своей логики. Общий вход — `parseLinkViaPipeline` (`uri_pipeline.dart`,
   реэкспорт из `uri_parsers.dart`); вызов в контроллере (WARP MASQUE) и тесты
   переведены на него (тестовый помощник `test/parser/parse_link_as.dart`).
   `parseNaiveExtraHeaders` (вызывающих в `lib` не было) снят вместе с его
   тестами — пары `extra-headers` отсеивает правило реестра, кейсы D-105
   остались. `wireguard_parser.dart` остаётся (форма `ini`, §562).
4. Страж: `registry.dart`, `input_helpers.dart`, весь `uri_parsers/`; в
   запрещённые написания добавлены `http`, `https`, `chain`, `group`,
   `tailscale`; исключения — картой «файл → литерал» с причиной.

## Нерешённое / follow-up

- `isSubscriptionUrl`: `http://`/`https://` — транспорт скачивания подписки,
  реестр такого набора не объявляет. Если нужна полная чистота — запрос
  лаунчеру: объявить схемы URL подписки в `source_kinds.json` (например
  `subscription_url.schemes`); тогда исключение стража снимается.
- `isWireGuardConfig` сохраняет запасной признак `[Interface]` без реестра —
  это маркер формата, не имя схемы; снимать по тому же правилу «реестра нет —
  опознания нет», если владелец решит.
- `isValidNaiveHeaderName` (`uri_utils.dart`) после снятия naive-обёртки
  вызывающих в `lib` не имеет (только `naive_emit_test`) — кандидат на снятие.
- `parseWireguardUri` — форма `ini` вне движка (см. §562 «Нерешённое»).
