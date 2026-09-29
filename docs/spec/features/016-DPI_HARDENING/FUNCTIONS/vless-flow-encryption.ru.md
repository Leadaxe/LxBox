[English](vless-flow-encryption.md) · [Русский](vless-flow-encryption.ru.md)

# VLESS flow и encryption

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.ru.md) |
| Обещания | P14 P15 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Переносит два защитных слоя VLESS из подписки в конфиг так, как их
задал провайдер: XTLS Vision (`flow`) — маскировку TLS-в-TLS, и VLESS
Encryption (`encryption`) — постквантовое шифрование полезной нагрузки
поверх транспорта. Ничего не добавляет от себя и не снимает молча.

## Параметры

| Вход | Значение | Ключ ядра |
|---|---|---|
| `flow=xtls-rprx-vision` | как есть | `flow` |
| `flow=xtls-rprx-vision-udp443` | `xtls-rprx-vision` + `packet_encoding: xudp`; порт узла не меняется | `flow`, `packet_encoding` |
| `flow` пусто · `none` · устаревшие (`xtls-rprx-direct`, …) · мусор | ключа нет (устаревшее/мусор — код `flow_deprecated`) | — |
| `encryption=<грамматика ядра>` | дословно, края обрезаны | `encryption` |
| `encryption` пусто или точно `none` | слоя нет, кода нет | — |

## Входы / Выходы

**Входы:** ссылка VLESS; Xray-JSON (`users[].flow`, `users[].encryption`);
sing-box JSON.
**Выходы:** `flow`, `packet_encoding`, `encryption` в outbound'е; коды
`vision_with_transport` (info), `flow_deprecated`,
`vless_encryption_invalid` (узел отбракован).

## Правила и инварианты

- `flow` не навязывается: REALITY на голом TCP без `flow` в ссылке
  уходит без `flow`: сервер без Vision клиента с Vision не принимает.
- Vision несовместим с транспортом (ws, grpc, xhttp, …): при
  транспорте `flow` снимается с кодом `vision_with_transport`, узел
  живёт. Исключение — узел с заданным `encryption`: Vision тогда
  работает поверх слоя шифрования, транспорт ему не важен, `flow`
  остаётся без кода.
- «Задан `encryption`» = поле доедет до тела; пустое и точное `none` —
  не заданы и исключение не включают.
- Проверка `encryption`: декодировать → обрезать края → пусто/точное
  `none` → сверка с грамматикой ядра (`mlkem768x25519plus.<режим>.<rtt>.…`,
  ключ 32 или 1184 байта, padding-блоки). Пробел внутри сегмента законен.
- Негодная форма (три части, пустой сегмент, другой метод, метод в
  другом регистре, хвостовая точка, `None`) → **узел отбракован** с
  кодом и сырым значением: снять шифрование и оставить узел значило бы
  тихо понизить защиту, а без слоя сервер всё равно не примет клиента.
- Тело sing-box JSON судится тем же правилом, что и ссылка.
- Круг «ссылка → узел → ссылка» сохраняет `encryption`.

## Границы

- Работа Vision поверх `encryption` на стороне ядра — ядро
  (sing-box-lx#29); без него такой узел не поднимется и с `flow`.
- Слой `encryption` целиком — ядро (ядро: FEATURE 012-VLESS_ENCRYPTION).
- `packet_encoding` вообще (allow-list `xudp`/`packetaddr`) — разбор
  ссылок, [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [012](../../../tasks/012-vless-packet-encoding-libbox-panic.md) | — | `packet_encoding` из ссылки не роняет ядро |
| 2 | [115](../../../tasks/115-vless-flow-honor-link.md) | Code-complete в develop | `flow` по ссылке, Vision не навязывается, гасится при транспорте |
| 3 | [335](../../../tasks/335-vless-encryption-passthrough.md) | ✅ реализовано | `encryption` из подписки доезжает до конфига |
| 4 | [477](../../../tasks/477-vless-encryption-grammar.md) | Released v2.25.0 | Грамматика ядра; негодное значение отбраковывает узел |
| 5 | [544](../../../tasks/544-vless-vision-xhttp-with-encryption.md) | Done | Vision у узла с `encryption` не снимается из-за транспорта |
