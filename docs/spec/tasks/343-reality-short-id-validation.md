# §343 — REALITY short_id: нечётный/переполненный hex роняет весь конфиг

| | |
|---|---|
| Статус | Released v2.19.2 — тесты зелёные (2678); девайс-проверка не требуется (чистый парсинг + post-step) |
| Дата | 2026-08-02 |
| Связанные | [§169](169-reality-pbk-validation.md) (тот же класс: битый pbk = fatal всего конфига), [§281](281:utls-fingerprint-normalize) (паттерн heal-страховки мимо парсера), [§172](172) (принцип «одна битая нода не роняет VPN»), [§302](302) (import rules патчат emit-JSON мимо парсера) |
| Триггер | Полевой краш: `initialize outbound[1543]: decode short_id: encoding/hex: odd length hex string` — VPN не стартует целиком из-за одной ноды подписки |

## Проблема

Ядро декодирует `tls.reality.short_id` как hex в фиксированный `[8]byte`
(`common/tls/reality_client.go`): нечётное число hex-символов = ошибка
`hex.Decode`, длина >16 символов = `invalid short_id`. Оба случая — fatal
**всего конфига** на старте, как §169 с pbk. Xray-core валидирует идентично
(`infra/conf/transport_security.go`: `len(s) > 16` → error, `hex.Decode` →
error), т.е. нечётный sid не работает нигде в экосистеме — это мусор по
определению. Паддинг в REALITY существует только на уровне байтов: короткий
**чётный** sid легален (добивается нулями справа при декоде), «дополнить»
нечётный нельзя — получится другой идентификатор.

Дыры на нашей стороне (две, независимые):

1. **Парсер.** `normalizeRealityShortId` (uri_utils.dart) фильтрует non-hex
   символы и **обрезает** хвост >16 — но не проверяет чётность. `sid=abc` →
   `abc` → ядро fatal. Обрезка >16 — тот же дефект в другую сторону: даёт
   валидную форму при неверном содержимом (тихая порча, анти-паттерн
   §277/§278). Функция родилась в parser v2 (0851662c) без спеки на эти
   ветки; §169 «Заодно» подключил её к JSON-путям ради «мусора/пробелов»,
   но чётность не проверил.

2. **Билдер.** Пути мимо парсера — raw sing-box JSON узлы, §302 import
   rules (Replace патчит emit-JSON), Debug API — доносят произвольный
   `short_id` до конфига. Валидатор `short_id` не проверяет вообще; ядро
   ругается безымянным `outbound[1543]`.

## Решение

Принцип §169, зафиксированный решением юзера 2026-06-26: **битое значение
отбрасывается целиком, не подгоняется**. Пустой `short_id` для REALITY
легален (клиент шлёт нулевой, сервер без shortIds принимает).

1. **Парсер**: `normalizeRealityShortId` — после чистки символов нечётная
   длина ИЛИ >16 → `''` (вместо обрезки). Нода остаётся REALITY-нодой с
   пустым sid: если сервер принимает пустой — работает; нет — не
   подключится одна нода, конфиг жив.

2. **Билдер, heal-шаг** `healInvalidReality` (страховка мимо парсера, как
   §281): walk по `outbounds[].tls.reality`:
   - `short_id` невалиден (non-hex / нечёт / >16) → `''` + warning с тегом
     ноды;
   - `public_key` не декодируется в 32 байта → снять `reality`-блок
     (деградация до plain TLS, зеркало §169 на последнем рубеже) + warning.
   Вызов сразу после `healUnknownUtlsFingerprints`, до `validateConfig`.

Валидатор-fatal НЕ добавляем: философия проекта для subscription-мусора —
heal с warning (§172/§281), fatal — для структурных ошибок юзера (§254/§312).

## Файлы

- `app/lib/services/parser/uri_utils.dart` — normalizeRealityShortId
- `app/lib/services/builder/post_steps/heal_invalid_reality.dart` — новый
- `app/lib/services/builder/post_steps.dart` — part + import uri_utils
- `app/lib/services/builder/build_config.dart` — вызов + emitWarnings
- `app/test/parser/reality_short_id_test.dart` — юниты нормализатора (их
  не было вовсе — потому баг и дожил до прода)
- `app/test/builder/heal_invalid_reality_test.dart` — heal-шаг

## Ограничение

Конкретную ноду-виновника краша по бэкапу не найти: узлы подписок в бэкап
не сохраняются. После фикса битый sid перестаёт быть fatal — нода
деградирует, VPN стартует, warning называет тег.
