# §358 — Hysteria2 obfs `gecko` теряется при эмите конфига

| | |
|---|---|
| Тип | bugfix (нода молча не работает) |
| Статус | ✅ Реализовано — тесты зелёные (2761), analyze + 4 l10n-чекера чисты; DEVICE-PENDING (нет gecko-сервера под рукой) |
| Дата | 2026-08-03 |
| Связанные | [`#53`](https://github.com/leadaxe/LxBox/issues/53), [`281`](281-utls-fingerprint-normalize.md) (тот же паттерн: значение вне enum ядра нормализуется в парсере), [`169`](169-reality-pbk-validation.md) (отброс-не-подгон) |

## Проблема

Ядро `sing-box-lx` поддерживает два типа hysteria2-обфускации:
`option/hysteria2.go` — `enum:"salamander,gecko"`, у gecko свой блок
`Hysteria2ObfsGecko{MinPacketSize, MaxPacketSize}`.

`emitHysteria2` (`models/node_spec_emit.dart`) писал секцию `obfs`
**только** при `s.obfs == 'salamander'`. Узел с `obfs=gecko` терял секцию
целиком: ядро поднимало plain QUIC, сервер такие пакеты дропает — нода
«подключена», трафика нет. Диагностики нет: ни варнинга, ни лога.

Парсеры при этом принимали любой тип: URI-парсер клал `q['obfs']` как есть,
JSON-парсер — `obfs['type']`. То есть `gecko` доезжал до спеки и умирал
ровно на эмите.

`min_packet_size`/`max_packet_size` не читались и не хранились нигде.

### Почему тесты не поймали

`test/parser/round_trip_test.dart` — «Hysteria2 with obfs + alpn: all
preserved» — гоняет `parse → toUri → parse`. Обе стороны URI-слоя, эмит
JSON в этот путь не входит. Симметричная дыра: любой протокол, у которого
`toUri` сохраняет поле, а `emitRaw` его роняет, проходит такой тест зелёным.

## Решение

Значение обфускации нормализуется **в парсерах** (паттерн §281): в спеку
попадает только то, что ядро примет.

| слой | было | стало |
|---|---|---|
| `Hysteria2Spec` | `obfs`, `obfsPassword` | + `obfsMinPacketSize`, `obfsMaxPacketSize` (`int?`) |
| URI-парсер | `obfs = q['obfs']` как есть | `normalizeHysteria2Obfs` + чтение `obfs-min-packet-size` / `obfs-max-packet-size` |
| JSON-парсер | `obfs['type']` как есть | то же + `obfs['min_packet_size']` / `['max_packet_size']` |
| `emitHysteria2` | `if (obfs == 'salamander')` | `salamander` \| `gecko`; для gecko — плоские `min_packet_size`/`max_packet_size` внутри `obfs` |
| `toUriHysteria2` | `obfs`, `obfs-password` | + оба размера пакета |

Решения по месту:

| вопрос | решение |
|---|---|
| Неизвестный тип обфускации (`obfs=xyz` из кривой подписки) | Отбрасывается в парсере → `UnknownObfsWarning`, нода эмитится **без** `obfs`. Пропустить его в эмит нельзя: `Hysteria2Obfs.MarshalJSON` вернёт `unknown obfs type` — fatal ВСЕГО конфига, не одной ноды |
| `obfs` есть, `obfs-password` пуст | Тип сбрасывается в парсере → `MissingObfsPasswordWarning`. Ядро требует непустой пароль для любого типа (`outbound.go`: `missing obfs password`) — снова fatal всего конфига |
| Ключи размеров в URI | Своих де-факто ключей у hysteria2 нет (ядро читает gecko только из JSON). Берём `obfs-min-packet-size`/`obfs-max-packet-size` — симметрично существующему `obfs-password` |
| Размеры при `salamander` | Хранятся в спеке, но в JSON не эмитятся: `_Hysteria2Obfs` кладёт `GeckoOptions` только для gecko. В URI сохраняются (round-trip не теряет данные при смене типа) |
| Валидация min ≤ max | Не делаем: ядро само разруливает, а подгонять чужие числа — против §169 (отброс, не подгон) |

## Тесты

`test/parser/round_trip_test.dart` — группа §358:

- gecko + размеры переживают `parse → toUri → parse`;
- **`parse → emitRaw`** — новый инвариант, закрывающий дыру: `obfs.type`
  и оба размера доезжают до JSON;
- salamander: `emitRaw` не содержит `min_packet_size`/`max_packet_size`;
- неизвестный тип → варнинг + в JSON нет ключа `obfs`;
- obfs без пароля → варнинг + в JSON нет ключа `obfs`.

`test/parser/json_parsers_test.dart` — gecko-секция из sing-box JSON
читается вместе с размерами.
