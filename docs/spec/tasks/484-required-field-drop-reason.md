# §484 — причина отбраковки узла по обязательному полю маппера

| | |
|---|---|
| **Статус** | **Реализовано** |
| **Дата** | 2026-09-19 |
| **Источник** | фича 480 (остаток после W1–W5: `required` ронял узел молча), лаунчер, `warnings.json` → `field_missing` |
| **Связанные** | фича 480, фича 472, §477 (`drop_node` через `dropped[]`) |

## Проблема

Движок секций после проходов записей проверял `required`: отсутствие
обязательного значения давало `return null`, и узел исчезал из подписки без
слова. Лаунчер на том же контракте называл причину: код `field_missing`,
`path` — путь поля, `{field}` — `desc_en` записи, если объявлен.

Так падали ссылка без `address`, Xray-элемент без `port`, `.conf` с `[Peer]`
без `Endpoint` и прочие записи с `required: true` у маппера.

## Решение

Тот же канал, что у `on_invalid: drop_node` санитайзера: `XrayDropVerdict`
наружу из конвейера, запись в `dropped[]` подписки (`parse_all`,
`parseXrayElement`, `parseUri`).

В интерпретаторе при провале `required` (и у `userinfo.required`):

- код `field_missing` из `warnings.json` (`params: field`);
- `path` — первый обязательный путь тела (`maps_to` / `extract.into` / …);
- `params.field` — `desc_en` записи реестра, иначе путь.

Класс `XrayDropVerdict` вынесен в `drop_verdict.dart`, чтобы движок не
импортировал конвейер.

## Критерии приёмки

- [x] Ссылка без `server` → узла нет, `dropped`/`verdict` несёт `field_missing`, `path: server`.
- [x] Xray vless без `port` → узла нет, `field_missing`, `path: server_port`, `field` = `desc_en` записи `port`.
- [x] `.conf` `[Peer]` без `Endpoint` → узла нет, `field_missing`, `path: peers[].address`.
- [x] Identity-снимки и golden не переписывались; живые узлы не меняются.
- [x] `flutter analyze` без новых issues; точечные тесты зелёные.
