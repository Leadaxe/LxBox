# §269 — AnyTLS protocol support

## Что

Полная поддержка протокола **AnyTLS** (sing-box `type: "anytls"`, ядро с 1.12.0;
в нашем `v1.14.0-lx.3` присутствует). AnyTLS — анти-DPI мультиплекс с гибким
паддингом поверх обычного TLS. По структуре ближе всего к Trojan: `password` +
TLS + TCP, без transport-обёртки.

Раньше AnyTLS не парсился нигде — ни URI, ни sing-box JSON. Ссылка/конфиг с
AnyTLS игнорировались.

## Схема данных (из ядра, `option/anytls.go`)

`AnyTLSOutboundOptions`:

| Поле | Тип | Обяз. |
|------|-----|-------|
| `server` / `server_port` | string / int | да |
| `password` | string | да |
| `tls` | TLS-блок | да (AnyTLS всегда поверх TLS) |
| `idle_session_check_interval` | Duration (`"30s"`) | нет (default 30s) |
| `idle_session_timeout` | Duration (`"30s"`) | нет (default 30s) |
| `min_idle_session` | int | нет (default 0) |

## URI-схема

Канонической стандартизированной `anytls://` схемы у AnyTLS **нет** (sing-box
документирует только JSON). Де-facto в экосистеме (Karing, v2rayN-моды)
используется trojan-подобная форма — её и принимаем:

```
anytls://<password>@<host>:<port>?sni=..&insecure=..&alpn=..&fp=..#<label>
```

- userinfo = `password` (как trojan)
- TLS всегда включён (AnyTLS без TLS не бывает) — `security=none` игнорируем, но
  **не теряя** параметров (снимаем `security` из query перед парсингом, иначе
  `security=none` обнулил бы весь TLS-блок)
- TLS-параметры по **vless-конвенции** (`parseVlessTls`): sni/peer, fp, alpn,
  insecure-алиасы + **REALITY** (`pbk`/`sid`). vless, а не trojan — чтобы
  REALITY-блок из sing-box JSON round-trip'ился через URI (ядро anytls REALITY
  принимает)
- idle-поля (`idle_session_check_interval`/`idle_session_timeout`/
  `min_idle_session`) **кодируем в URI как query** — round-trip их сохраняет

## Затрагиваемые файлы

| Файл | Изменение |
|------|-----------|
| `models/node_spec.dart` | `final class AnyTlsSpec extends NodeSpec` (password, tls, idle-поля) |
| `models/node_spec_emit.dart` | `emitAnyTls` (outbound type:anytls), `toUriAnyTls` |
| `services/parser/uri_parsers/anytls_parser.dart` | новый `parseAnyTls` (эталон trojan_parser) |
| `services/parser/uri_parsers.dart` | import/export + `case 'anytls'` в parseUri |
| `services/parser/json_parsers.dart` | `case 'anytls'` в parseSingboxEntry |
| `services/subscription/input_helpers.dart` | `isDirectLink` += `anytls://` |
| `screens/home/node_list_presenter.dart` | `protoLabel` += `'anytls' => 'AnyTLS'` |
| `docs/PROTOCOLS.md` | §5.x AnyTLS |

`clipboard_analysis.dart` — правки не требует (поверх `isDirectLink`).
Sealed-switch по подтипам NodeSpec в проекте нет (полиморфизм через методы) —
добавление подтипа ничего не ломает.

## Инвариант

`parseUri(spec.toUri()) ≈ spec` — round-trip замыкается полностью, включая
idle-поля (несутся в URI как query).

## Тесты

- `test/parser/anytls_test.dart` (новый) — parseUri, round-trip, emit→singbox,
  parseSingboxEntry(type:anytls), password-only/anon/insecure/sni/alpn/idle-поля.
- `test/subscription/input_helpers_test.dart` — `anytls://` → isDirectLink true.
