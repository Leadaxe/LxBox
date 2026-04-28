# 012 — VLESS `packetEncoding=none` крашит libbox.so на старте VPN

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-28 |
| Дата завершения | 2026-04-28 |
| Коммиты | (не закоммичено на момент написания отчёта; диф в `git status`) |
| Связанные spec'ы | [`026 parser v2`](../features/026%20parser%20v2/spec.md) |

## Проблема

Пользователь прислал скриншот HyperOS «Smart app assistant» с native crash report:

```
App: L×Box, Version: 1.4.0
Time: 2026-04-28 07:27:35
#00 pc 0000000000880dc8  /data/app/.../com.leadaxe.lxbox-.../lib/arm64/libbox.so
```

Симптом со слов пользователя: «при подключённом чёрном списке» — речь про первую публичную подписку из встроенного `public-servers-manifest.json` (`BLACK_VLESS_RUS_mobile.txt`). VPN не стартует — это native crash в libbox.so, не «не подключилось к серверу».

## Диагностика

Сначала пошёл в ложную сторону — искал «blacklist» в смысле routing-rule с `action: reject` (Block Ads preset, custom rule). После уточнения от пользователя стало ясно, что речь про публичную VLESS-подписку.

Параллельно от внешнего источника пришёл готовый баг-репорт из соседней кодобазы (Go-клиент того же sing-box) с воспроизведением:

```go
// sing-box, protocol/vless/outbound.go:76–90
switch *options.PacketEncoding {
case "":
case "packetaddr": outbound.packetAddr = true
case "xudp":       outbound.xudp = true
default:
    return nil, E.New("unknown packet encoding: ", options.PacketEncoding)
}
```

Триггер — `packet_encoding: "none"` в outbound JSON. У sing-box есть второй апстрим-баг: `E.New` принимает указатель `*string` вместо разыменованной строки, а `format.ToString` (`common/format/fmt.go`) не покрывает указатели свитчем по типам — попадает в `default: panic("unknown value")`. Ошибка вместо превращения в normal Go error становится паником и кладёт весь libbox целиком.

Откуда `none` в URI: xray-style подписки (xray-knife и ручные генераторы) кладут `packetEncoding=none` имея в виду «без специального encoding» — то есть семантический эквивалент omitted. У sing-box эта семантика выражается **отсутствием поля**, не литералом «none». Просто `none` — это xray-говор, его надо транслировать.

В нашем парсере [uri_parsers.dart:81-82](../../../app/lib/services/parser/uri_parsers.dart) был верботный copy:

```dart
if (q.containsKey('packetEncoding') && packetEncoding.isEmpty) {
    packetEncoding = q['packetEncoding']!;
}
```

→ `VlessSpec.packetEncoding = 'none'` → [node_spec_emit.dart:40](../../../app/lib/models/node_spec_emit.dart) → `out['packet_encoding'] = 'none'` → libbox panic при старте.

Аналогично в [json_parsers.dart:232](../../../app/lib/services/parser/json_parsers.dart) — sing-box JSON entry parser копировал `packet_encoding` верботно (Smart-Paste / редактор JSON).

Проверил по официальной документации sing-box ([VLESS](https://sing-box.sagernet.org/configuration/outbound/vless/), [VMess](https://sing-box.sagernet.org/configuration/outbound/vmess/)) — таблица допустимых значений:

| Encoding | Description |
|----------|-------------|
| (none) | Disabled |
| packetaddr | Supported by v2ray 5+ |
| xudp | Supported by xray |

«(none)» в скобках — это «omitted/empty», **не** литерал. JSON-пример: `"packet_encoding": ""`. Литеральная строка `"none"` невалидна.

Снапшот публичной подписки на 2026-04-28 12:13 MSK содержит только `packetEncoding=xudp` (4 в BLACK, 1 в WHITE) — триггерящих значений сейчас нет. Но генератор подписки upstream может в любой момент добавить узел с `packetEncoding=none`, и краш повторится. Защита превентивная.

## Решение

Allow-list нормализация на входе в парсер — три значения, всё остальное дропается.

### Helper в [uri_utils.dart](../../../app/lib/services/parser/uri_utils.dart)

```dart
String normalizePacketEncoding(String raw, {String? tag}) {
  final v = raw.trim().toLowerCase();
  if (v.isEmpty || v == 'none') return '';
  if (v == 'xudp' || v == 'packetaddr') return v;
  AppLog.I.warning(
    "unknown packetEncoding='$raw'${tag != null ? ' in $tag' : ''} — dropping",
  );
  return '';
}

String? queryParamCI(Map<String, String> q, String key) { /* ... */ }
```

Семантика:
- `xudp` / `XUDP` / `Xudp` → `xudp` (case-нормализация — sing-box принимает только lowercase)
- `PacketAddr` / `packetaddr` → `packetaddr`
- `none` (xray-говор) → `''` молча, без warning'а — это нормальный кейс
- любое другое → `''` + warning в лог (для триажа подписки)
- empty → `''`

Allow-list, не deny-list — если завтра sing-box добавит ещё одно валидное значение, оно отфильтруется как unknown пока не попадёт в whitelist. Лучше уронить новое значение, чем форвардить мусор.

### Применение

- [uri_parsers.dart:81-86](../../../app/lib/services/parser/uri_parsers.dart) — VLESS URI парсер; lookup ключа `packetEncoding` теперь case-insensitive (в подписках встречается `packetencoding` / `PacketEncoding` вперемешку, `Uri.queryParameters` по умолчанию case-sensitive).
- [json_parsers.dart:232](../../../app/lib/services/parser/json_parsers.dart) — sing-box JSON entry parser для VLESS; защита от Smart-Paste редактора с битой entry'ёй.

VMess не трогается: [node_spec_emit.dart:88-112](../../../app/lib/models/node_spec_emit.dart) `emitVmess` не пишет `packet_encoding` в outbound вообще, поле в `VmessSpec` мёртвый ход для sing-box. Если в будущем emit добавится — нормализацию надо повесить в `_xrayVmessToSpec` и в `case 'vmess'` json-parser entry, по тому же паттерну.

### Тесты

[vless_test.dart](../../../app/test/parser/vless_test.dart) — группа `VLESS packet_encoding allow-list`, 9 тестов:

| URI suffix | Ожидание |
|------------|----------|
| `packetEncoding=xudp` | `xudp`, в outbound `packet_encoding: xudp` |
| `packetEncoding=XUDP` | `xudp` (case-нормализация) |
| `packetEncoding=PacketAddr` | `packetaddr` |
| `packetEncoding=none` | `''`, поля нет в outbound |
| `packetEncoding=somethingweird` | `''`, поля нет в outbound, warning в логе |
| (без packetEncoding) | `''` |
| `packetencoding=xudp` (lowercase key) | `xudp` (CI-lookup) |
| `flow=xtls-rprx-vision-udp443&packetEncoding=none` | `xudp` (vision-udp443 quirk выигрывает) |
| Прямой вызов helper'а | все 8 кейсов поштучно |

### Документация

- [PROTOCOLS.md → VLESS → Parsed Parameters](../../../docs/PROTOCOLS.md) — обновлена строка таблицы (case-insensitive lookup, allow-list).
- [PROTOCOLS.md → packet_encoding allow-list](../../../docs/PROTOCOLS.md) — новая подсекция с таблицей маппинга и объяснением апстрим-бага.
- [CHANGELOG.md](../../../CHANGELOG.md) — `### Fixed` под `[1.6.0]`.

## Риски и edge cases

### Покрыто

- **`flow=xtls-rprx-vision-udp443` quirk** ставит `packetEncoding=xudp` до чтения query — если URI одновременно содержит `packetEncoding=none`, выигрывает quirk. Тест есть.
- **Case-insensitive query key** — `packetEncoding` / `packetencoding` / `PacketEncoding`. Все три ловятся через `queryParamCI`. Тест на lowercase есть; для остальных регистров поведение тривиально (тот же helper).
- **Round-trip share-URI** — emit читает `s.packetEncoding`, который теперь канонизирован. Если юзер импортировал URI с `packetEncoding=none` и шарит его дальше — в shared URI поля нет (правильно, sing-box default kicks in на принимающей стороне).
- **JSON-редактор / Smart-Paste sing-box entry** — тот же helper применяется в `parseSingboxEntry`.

### Не покрыто намеренно

- **VMess путь** — emit не пишет `packet_encoding`, нет вектора краша. Если когда-нибудь добавим — тест на VMess emit отсутствие поля покроет регрессию.
- **Защита на уровне `VlessSpec` / типизированного enum** — упомянуто в баг-репорте как «дополнительная защита». Текущее решение — фильтр на входе. Enum для `packet_encoding` потребует sealed-разреза или extension types и не даёт реального выигрыша против фильтра на парсе.
- **Unit-тест на реальном URI из `BLACK_VLESS_RUS_mobile.txt`** — в текущем снапшоте подписки нет `packetEncoding=none`. Синтетический URI в тестах покрывает кейс из баг-репорта; добавлять fixture с ручной анонимизацией UUID нет смысла.

## Верификация

- `flutter test` — **418/418** ✓ (было 408+ до изменения; +9 новых тестов в группе `VLESS packet_encoding allow-list`, +1 helper-direct).
- `dart analyze` — не запускался отдельно (не было правок outside того что покрыто тестом).
- Manual smoke на устройстве — **не проводился**. Триггерящего узла в текущем снапшоте подписки нет; для манульной проверки нужно либо дождаться когда upstream положит `packetEncoding=none`, либо добавить локальную тестовую подписку с таким узлом и убедиться что VPN стартует (а не падает с native crash).

## Нерешённое / follow-up

- **Апстрим-репорт в sing-box** — у нас не открыт. Соседняя кодобаза (Go-клиент) ведёт `SPEC 049-Q-O-SINGBOX_PACKET_ENCODING_PANIC`; стоит сослаться на него или открыть свой issue в [SagerNet/sing-box](https://github.com/SagerNet/sing-box/issues), чтобы починили `format.ToString` для указателей. Не блокирует наш фикс.
- **Manual smoke на реальном устройстве с триггерящим URI** — отдельный шаг при следующей релиз-валидации.
- **Расширить allow-list проверку на VMess** при появлении emit'а `packet_encoding` (если когда-нибудь добавится) — превентивно.
