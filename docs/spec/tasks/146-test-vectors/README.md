# §146 — Test vectors (device-proven рабочий узел)

Артефакты для проверки крипто-слоя реализации QUIC Initial i1 (см. `../146-warp-quic-initial-fragmented-i1.md` §5A).

| Файл | Что |
|---|---|
| `i1_gosuslugi.hex` | Полный device-проверенный `i1` (QUIC Initial, 1250б), `id=gosuslugi.ru`. Прошёл реальный DPI на LTE (Clash delay PASS). |
| `clienthello_gosuslugi.hex` | Ожидаемый расшифрованный+реассемблированный ClientHello (294б). |
| `payload_decrypted_gosuslugi.hex` | Полный расшифрованный QUIC payload (виден frame-план: CRYPTO/PING/PADDING). |

## Как проверить крипту реализации

1. Прочитать `i1_gosuslugi.hex`, взять DCID = байты 6..13 (`e5cae90c22816e78`).
2. Вывести Initial-ключи (RFC 9001, INITIAL_SALT=38762cf7f55934b34d179ae6a4c80cadccbb7f0a; см. §3.3 спеки).
3. Снять header protection, AEAD-расшифровать → **должно совпасть с `payload_decrypted_gosuslugi.hex`** (тег обязан сойтись).
4. Frame-walk payload → CRYPTO-фреймы реассемблируются в `clienthello_gosuslugi.hex`.

## Инварианты (см. §3.2 спеки): первый wire-CRYPTO offset=236 (≠0), 6 CRYPTO offsets [0,236,266,275,283,290], 2 PING, PADDING-runs [176,647,72].

NB: это эталонный 294б CH с фиксированными offsets. В реализации точки разреза вычисляются от РЕАЛЬНОЙ длины CH (см. §5A NB про apteka.ru).
