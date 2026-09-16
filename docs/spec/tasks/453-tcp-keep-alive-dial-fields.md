# 453 — TCP keep-alive: dial-поля sing-box на узле

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-16 |
| Ядро | `disable_tcp_keep_alive` / `tcp_keep_alive` / `tcp_keep_alive_interval` — dial-поля sing-box с 1.13.0 (`option/outbound.go:97-99` в форке, применение `common/dialer/default.go:160-178`); в пине `v1.14.1-lx.3` есть |
| Связанные | §269 (AnyTLS — прецедент sing-box-only полей в URI), §302 (правила над emit-JSON), §283 (identity-хеш), §404 (Xray `sockopt`) |

## Проблема

Владелец хочет задать узлу свой TCP keep-alive (дефолт ядра: первая проба
через 5 мин, дальше каждые 75 с — `constant/timeout.go`). Ядро поля принимает,
приложение их не знает нигде:

- вкладка «Outbound JSON» на Save прогоняет текст через `parseSingboxEntry`
  ([`json_parsers.dart:986`](../../../app/lib/services/parser/json_parsers.dart)),
  каждый `case` собирает spec из фиксированного набора ключей, незнакомые
  выбрасываются молча;
- эмиттер ([`node_spec_emit.dart`](../../../app/lib/models/node_spec_emit.dart))
  их не пишет;
- правила §302 работают только над подписками; для ручного узла обхода нет.

Итог: пользователь вписывает поля, нажимает Save, вкладка показывает JSON уже
без них. Тихая потеря на ровном месте.

## Решение

Поля становятся частью модели узла и ходят по всем трём формам, которыми узел
хранится и передаётся: sing-box JSON, share-URI, Xray JSON. Хранение узла —
это текст (`rawBody` = URI или JSON), spec пересобирается парсером; поэтому
без URI-формы поле терялось бы на любом пересохранении через `toUri()`
(`subscription_controller.dart:618, 691, 734, 924, 1560`,
`add_server_wizard_screen.dart:201`).

### 1. Модель — `TcpKeepAliveSpec`, поле базового `NodeSpec`

Новый файл [`app/lib/models/tcp_keep_alive_spec.dart`](../../../app/lib/models/tcp_keep_alive_spec.dart)
(соседи: `tls_spec.dart`, `transport_spec.dart`):

```dart
/// §453 — TCP keep-alive dial-поля sing-box (ядро ≥ 1.13).
final class TcpKeepAliveSpec {
  /// `disable_tcp_keep_alive`.
  final bool disabled;
  /// `tcp_keep_alive` — Go-duration («30s»), '' = дефолт ядра.
  final String idle;
  /// `tcp_keep_alive_interval` — Go-duration, '' = дефолт ядра.
  final String interval;
  const TcpKeepAliveSpec({this.disabled = false, this.idle = '', this.interval = ''});
  bool get isEmpty => !disabled && idle.isEmpty && interval.isEmpty;
  // ==, hashCode, toString — по трём полям.
}
```

В `NodeSpec` (sealed, [`node_spec.dart:38`](../../../app/lib/models/node_spec.dart)) —
`final TcpKeepAliveSpec? tcpKeepAlive;`, необязательный параметр конструктора.
`null` = поля не заданы, эмит ничего не пишет. Это dial-поле, общее для всех
outbound'ов с dialer'ом, а не свойство протокола — потому база, а не копия
в каждом `*Spec`.

**Носители** (у кого в ядре `DialerOptions` и TCP-дозвон): `VlessSpec`,
`VmessSpec`, `TrojanSpec`, `AnyTlsSpec`, `ShadowsocksSpec`, `NaiveSpec`,
`SshSpec`, `SocksSpec`, `HttpSpec` — 9 типов. Их конструкторы прокидывают
`super.tcpKeepAlive`; `withChained` ([`node_spec.dart:1341`](../../../app/lib/models/node_spec.dart))
копирует поле в этих 9 ветках.

**Не носители:** `Hysteria2Spec`, `TuicSpec`, `WireguardSpec`, `MasqueSpec`
(QUIC/UDP — keep-alive TCP-сокета не к чему применить; ядро поля проглотит,
но они пустые по смыслу), `TailscaleSpec` (тело как есть), `AutoSelectSpec`
(группа). У них поле остаётся `null`; парсеры для них ключи не читают.

### 2. Разбор и запись — один модуль на все формы

Новый файл [`app/lib/services/parser/tcp_keep_alive.dart`](../../../app/lib/services/parser/tcp_keep_alive.dart)
(слой парсера, как `transport.dart` с `transportToQuery`):

| Функция | Вход → выход |
|---|---|
| `tcpKeepAliveFromSingbox(Map entry)` | ключи `disable_tcp_keep_alive` (bool), `tcp_keep_alive`, `tcp_keep_alive_interval` → `TcpKeepAliveSpec?` (`null`, если `isEmpty`) |
| `tcpKeepAliveToSingbox(Map out, TcpKeepAliveSpec? s)` | пишет только непустое: `disabled` → `true`, duration'ы — если не пустые |
| `tcpKeepAliveFromQuery(Map<String,String> q)` | те же имена ключей в query; `disable_tcp_keep_alive` ∈ {`1`, `true`} |
| `tcpKeepAliveToQuery(TcpKeepAliveSpec? s)` | обратно; `disabled` → `disable_tcp_keep_alive=1` |
| `tcpKeepAliveFromXraySockopt(Map? sockopt)` | `tcpKeepAliveIdle` / `tcpKeepAliveInterval` — целые секунды Xray; `> 0` → `'${n}s'`; **любое отрицательное → `disabled: true`** (Xray ставит `SO_KEEPALIVE=0`, `sockopt_linux.go:143`); `0` = не задано |

Имена query-параметров = имена ключей sing-box. Стандарта у share-URI нет;
это расширение L×Box по прецеденту AnyTLS (`idle_session_timeout=…`,
§269 / PROTOCOLS.md 5.6). Чужие клиенты неизвестные параметры игнорируют.

**Нормализация duration (guard, слой 1/2):** через `normalizeSingboxDuration`
(голое число → секунды, D-024), затем проверка на Go-duration
`^(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$`. Не прошло — поле **отбрасывается
молча**, остальные два живут. Иначе `badoption.Duration` уронит разбор
всего конфига. Без нового `NodeWarning`: путь power-user (как §358 для
hysteria2 obfs), новый тип предупреждения тянет строки и l10n-гейты трёх
языков.

### 3. Точки касания

| Слой | Файл | Что |
|---|---|---|
| sing-box JSON → spec | `json_parsers.dart` `parseSingboxEntry` | `final ka = tcpKeepAliveFromSingbox(entry);` один раз перед `switch`; передаётся в конструкторы 9 носителей |
| Xray JSON → spec | `json_parsers.dart` `_xrayVlessToSpec`, `_xrayTrojanToSpec`, `_xrayVmessToSpec`, `_xraySsToSpec` | `tcpKeepAlive: tcpKeepAliveFromXraySockopt(stream['sockopt'])` (`is Map`-проверка, не каст — `streamSettings` бывает строкой) |
| URI → spec | `uri_parsers/{vless,trojan,anytls,shadowsocks,naive,ssh,socks,http}_parser.dart` | `tcpKeepAlive: tcpKeepAliveFromQuery(q)` |
| URI → spec, VMess | `uri_parsers/vmess_parser.dart` | base64-JSON: ключи читаются из `cfg` (`cfg['tcp_keep_alive']`…); query-вариант (`:131`) — из `q` |
| spec → sing-box | `node_spec_emit.dart` `_addDetour` | переименовать в `_addDialFields(out, s)`: `detour` + `tcpKeepAliveToSingbox(out, s.tcpKeepAlive)`. Одна точка на все 13 вызовов; у не-носителей поле `null` — ничего не пишется |
| spec → URI | `node_spec_emit.dart` `toUri{Vless,Trojan,AnyTls,Shadowsocks,Naive,Ssh,Socks,Http}` | `q.addAll(tcpKeepAliveToQuery(s.tcpKeepAlive))` |
| spec → URI, VMess | `toUriVmess` | ключи в JSON-объект v2rayN (`tcp_keep_alive`, `tcp_keep_alive_interval`, `disable_tcp_keep_alive: true`), только непустые |

Что **не** трогаем:
- UI — полей в форме нет, только JSON-вкладка и импорт (владелец: видимых
  изменений без вопроса не делать).
- identity-хеш §283 — считается от emit; у узлов без полей emit не меняется,
  хеши старых узлов на месте. У узла с полями хеш меняется ровно как от
  любой правки сути.
- backup allowlist §221 — узел хранится текстом, новых ключей хранения нет.
- parity-тесты `test/parity/` — эмит без полей байт-в-байт прежний.

### 4. Порядок ключей в JSON

`_addDialFields` дописывает в конец map: `…, "detour": …, "tcp_keep_alive": …`.
Вкладка показывает поля после протокольных, как `detour` сейчас.

## Проверка

Тесты — в конце, одним проходом (режим владельца 14.09):

- `test/parser/tcp_keep_alive_test.dart`: sing-box vless с тремя полями →
  spec → emit равен входу (round-trip); `"tcp_keep_alive": 30` (число) →
  `"30s"`; `"abc"` → поле отброшено, соседние живы; `disable_tcp_keep_alive:
  false` → `null`, в emit ключа нет; hysteria2 с полями → `tcpKeepAlive ==
  null`, emit без них.
- URI round-trip `parseUri(spec.toUri())` сохраняет поле для 9 носителей
  (vmess — через base64-JSON).
- Xray: `sockopt.tcpKeepAliveIdle: 30, tcpKeepAliveInterval: 15` → `30s`/`15s`;
  `tcpKeepAliveIdle: -1` → `disabled: true`; `streamSettings` строкой →
  `null`, без исключения.
- `flutter analyze` чист по всему проекту; `flutter test` зелёный.
- Устройство: узел с `tcp_keep_alive: 30s` — `Outbound JSON` после Save
  показывает поля; в running config ядра (§311) поля на outbound'е.

## Docs to update

- `docs/PROTOCOLS.md` — новый раздел «TCP keep-alive (dial fields)» рядом с
  10 «JSON Outbound»: три ключа, носители, URI-имена, Xray-маппинг, guard.
- `docs/GUARDS.md` — слой 2.1 / 1.5: строка «duration не Go-формата → поле
  отброшено, silent».
- `CHANGELOG.md` → Unreleased / Added.
