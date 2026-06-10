# 112 — AWG ranged magic headers: `h1`–`h4` как «число-или-диапазон»

| Поле | Значение |
|------|----------|
| Статус | In progress — код и тесты готовы, девайс-smoke pending |
| Дата старта | 2026-06-11 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/097 (AWG2), tasks/110 (vpn://-импорт; реальный конфиг, вскрывший проблему), sing-box-lx `SPECS/005` (core-часть) |

## Проблема

Живые awg2-экспорты (вскрыто при §110, конфиг с поля) несут `H1`–`H4` в
новом формате AWG 2.0 — **диапазон**: `H1 = 43613244-384550127`. Наша
`Awg`-модель (§097) держит h-поля как `int`: `int.tryParse('N-M')` → null
→ поле **молча выпадает** на парсе (URI/INI/JSON — везде). Нода выглядит
валидной (`awg2`-лейбл по `s3`/`s4`/`i*`), но в handshake уходят
WG-дефолтные типы пакетов 1–4 — сервер с ranged headers их отбрасывает,
коннект не поднимается, ошибки нет. Худший вид отказа: тихий.

## Core-часть (готова)

sing-box-lx `v1.13.13-lx.6` (SPECS/005): JSON-поля `h1`–`h4` endpoint'а
принимают **number** (как раньше) и **string** `"N"` / `"N-M"`; одиночное
эмитится числом, диапазон — строкой. Vendored wireguard-go диапазоны умел
всегда (uapi `h1=N-M`). Валидация (uint32, start ≤ end, непересечение
диапазонов между h1–h4) — на стороне ядра, с явной ошибкой при старте.

## Решение (app)

Вся правка — внутри класса `Awg` ([node_spec.dart](../../app/lib/models/node_spec.dart)):

1. Новый набор `headerKeys = {h1, h2, h3, h4}` (остаются и в `numKeys` —
   их consumers: роутинг INI-ключей в `ini_parser`, `securityLabel` в
   `config_node` — проверяют **наличие** ключа и не должны менять
   поведение).
2. `fromQuery` / `fromJson`: для `headerKeys` значение валидируется
   regex'ом `^\d+(-\d+)?$`; без дефиса → нормализуем в `int`
   (type-fidelity §097: `"5"` ≡ `5`), с дефисом → храним `String` как
   есть; не подошло → поле пропущено (как `jc=abc`).
3. Emit не меняется: `writeInto` кладёт `int` → JSON number / `String` →
   JSON string (ровно контракт ядра); `writeQuery` — `toString()`, дефис
   в query легален.
4. **Глубже не валидируем** (start ≤ end, uint32, непересечение): ядро
   даёт явную ошибку при старте VPN — она всплывёт юзеру. Молчаливый drop
   на парсе — повторение исходного бага, его избегаем сознательно.

Плюс перепин ядра: [libbox.version](../../app/android/libbox.version)
`v1.13.13-lx.5` → `v1.13.13-lx.6` (AAR со старым ядром молча примет
строку? — нет: старое ядро на `"h1": "N-M"` упадёт с unmarshal-ошибкой
конфига, поэтому перепин обязателен в том же коммите).

## Затронутые входы (бесплатно через Awg)

- `wireguard://`/`wg://`/`awg://` URI query — `Awg.fromQuery`;
- WG INI `[Interface]` — `ini_parser` гонит значение строкой в query →
  тот же `fromQuery`;
- sing-box JSON endpoint — `Awg.fromJson` (JSON-редактор, Smart-Paste);
- Amnezia `vpn://` (§110) — внутри тот же INI-путь.

## Риски и edge cases

- `"5"` строкой в JSON → нормализуется в `int 5`, эмит остаётся числом —
  round-trip стабилен (нет дрожания типов).
- `"10-"`, `"a-b"`, `"-5"` → drop поля (regex), как прочие битые числа.
- `"9-5"` (start > end) и пересечения — **пропускаем к ядру**, оно даёт
  явную ошибку старта (см. решение п.4).
- Старые персисты не затронуты: одиночные h — те же `int`.
- `securityLabel` (`config_node.dart:84-86`) — `containsKey`, типов не
  касается.

## Верификация

- Unit [awg_test.dart](../../app/test/parser/awg_test.dart): URI с
  `h1=N-M` → `String` в fields; `"5"`→`int`; битые формы → drop; INI с
  ranged H (структура реального awg2-экспорта) end-to-end; JSON
  endpoint со строковым `h1` (`fromJson`); emit: одиночное → number,
  диапазон → string; round-trip URI/INI/JSON без потерь. ✅
- Unit [amnezia_link_test.dart](../../app/test/parser/amnezia_link_test.dart):
  vpn:// с ranged-INI → поля доехали. ✅
- `flutter analyze` чистый, полный `flutter test` — 953 passed. ✅
- `fetch-libbox.sh` тянет `v1.13.13-lx.6` (SHA256 ок), сборка release
  APK проходит. ✅
- Smoke на устройстве с конфигом Seliv'а — pending (vc-вопрос, §110).

## Нерешённое / follow-up

- UI-подсказка при ошибке ядра «headers must not overlap» — humanize при
  старте VPN, если будут жалобы.
