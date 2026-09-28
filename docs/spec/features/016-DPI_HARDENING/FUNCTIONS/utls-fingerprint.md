# Отпечаток uTLS

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.md) |
| Обещания | P7 P8 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Приводит отпечаток ClientHello, заданный подпиской (`fp`), к словарю
ядра и решает, что делать, если его нет. Ядро сверяет
`tls.utls.fingerprint` строго по словарю с учётом регистра, и
неизвестное значение роняет весь конфиг; подписки же пишутся под Xray,
который принимает сырые имена библиотеки и любой регистр.

## Параметры

Словарь ядра: `chrome`, `chrome_psk`, `chrome_psk_shuffle`,
`chrome_padding_psk_shuffle`, `chrome_pq`, `chrome_pq_psk`, `firefox`,
`edge`, `safari`, `360`, `qq`, `ios`, `android`, `random`, `randomized`.

Отпечаток по умолчанию (поля `fp` нет или пусто):

| Узел | Результат |
|---|---|
| VLESS, TLS | `random` (конвенция подписок, не дефолт ядра) |
| VLESS, REALITY | `chrome` с кодом `reality_fp_random_pinned` |
| Trojan, AnyTLS по ссылке | блока `utls` нет |
| sing-box JSON с пустым `fingerprint` | `utls.enabled` без отпечатка (ядро = `chrome`) |
| Xray-JSON REALITY с пустым `fingerprint` | `chrome` |

## Входы / Выходы

**Входы:** `fp`/`fingerprint` ссылки; `fingerprint` Xray; `tls.utls`
sing-box JSON.
**Выходы:** `tls.utls{enabled, fingerprint}`; коды `utls_fp_unknown`,
`reality_fp_not_chrome`, `reality_fp_random_pinned`,
`tls_not_applicable_quic`; строка сборки «Fingerprint replaced: outbound
"…" had unknown uTLS fingerprint "…" — using "chrome" instead.»

## Правила и инварианты

- Регистр и пробелы по краям снимаются молча (`QQ` → `qq`).
- Xray-псевдонимы по префиксу — молча, без кода: `hellochrome*` →
  `chrome`, `hellofirefox*` → `firefox`, аналогично edge/safari/360/qq/
  ios/android; `hellorandom*` → `random` (по ссылке `hellorandomized*` →
  `randomized`, см. отчёт о расхождениях).
- Неопознанное значение → `chrome` + `utls_fp_unknown` с сырым значением:
  отпечаток — клиентская маскировка, сервер о нём не знает, узел почти
  наверняка жив, выбрасывать его нельзя.
- REALITY требует uTLS: при REALITY без блока `utls` блок включается
  (без отпечатка). Явный `random` под REALITY → `chrome`.
- REALITY-сервер Xray ≥ v26.9.8 принимает только ClientHello с гибридным
  key share `X25519MLKEM768`. Его несут `chrome*`, `firefox`, `safari`
  (два последних — с ядра `v1.14.1-lx.3`). Остальные под REALITY
  (`edge`, `ios`, `android`, `360`, `qq`, `randomized`) уходят как есть,
  с предупреждением `reality_fp_not_chrome`: отпечаток выбрал провайдер,
  приложение его не переписывает.
- hysteria/hysteria2/tuic/MASQUE: `utls` и `reality` снимаются
  (`tls_not_applicable_quic`); `fp` в ссылку обратно не пишется.
- naive: `utls` запрещён схемой узла.
- Перед ядром — страховка: любой неизвестный отпечаток, дошедший мимо
  разбора, заменяется на `chrome` со строкой сборки; пробельный —
  снимается, `utls` остаётся включённым. У авторского JSON-тела замена
  выполняется (ядро отвергло бы его), мягкие правки — нет.

## Границы

- Выбор отпечатка руками — через JSON узла ([008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md));
  глобального «отпечатка по умолчанию» в настройках нет.
- Фильтр узлов по `tls.utls.fingerprint` — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- Сам ClientHello собирает ядро; набор с гибридом — зеркало ядра, при
  откате пина ниже `v1.14.1-lx.3` его надо сузить.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [281](../../../tasks/281-utls-fingerprint-normalize.md) | Реализовано | Неизвестный отпечаток → `chrome` вместо фатала, псевдонимы молча |
| 2 | [282](../../../tasks/282-utls-invalid-over-quic.md) | Реализовано | uTLS/REALITY поверх QUIC снимаются |
| 3 | [433](../../../tasks/433-reality-fp-not-chrome-naive-extra-headers-codes.md) | Done | Код `reality_fp_not_chrome`, явный `chrome` под REALITY |
| 4 | [444](../../../tasks/444-reality-fingerprint-no-override.md) | Done | Отпечаток подписки под REALITY не подменяется на сборке |
| 5 | [451](../../../tasks/451-reality-fp-firefox-safari-hybrid.md) | Реализовано | `firefox`/`safari` выходят из-под предупреждения |
| 6 | [463](../../../tasks/463-contract-w2c-corpus-conformance.md) | Released v2.25.0 | `hellorandom*` больше не уходит в `chrome` |
| 7 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Частично сделано | Пара REALITY ↔ uTLS — правило реестра (`random` → `chrome`) |
