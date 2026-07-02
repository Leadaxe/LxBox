# §222 — протокол HTTP(S)-прокси (sing-box `type: http`)

> **СТАТУС: РЕАЛИЗАЦИЯ.** Чисто клиентская обвязка — ядро не трогаем
> (`http` outbound — стандартный sing-box, есть в 1.14 из коробки).

## Проблема

L×Box поддерживает 11 протоколов (vless/vmess/trojan/ss/hy2/naive/tuic/ssh/
socks/wg/masque), но не умеет HTTP CONNECT-прокси — самый базовый тип
(корпоративные прокси, локальные обвязки вроде squid/mitmproxy, chaining).
В `protoLabel` метка `'http' => 'HTTP'` уже заложена — остальной цепочки нет.

## Решение

Новый `HttpSpec` по полной схеме sing-box `http` outbound:
`server`/`server_port`/`username`/`password`/`path`/`headers`/`tls`.
TLS через существующий `TlsSpec` → покрыт и HTTPS-прокси (CONNECT over TLS).

### URI-схема: `proxy-http://` / `proxy-https://`

Стандартной share-схемы для HTTP-прокси в экосистеме нет, а голые
`http://`/`https://` брать нельзя:

- `isSubscriptionUrl` перехватывает `http(s)://` **раньше** `isDirectLink`
  в `addFromInput` — вставленная ссылка всегда стала бы «подпиской»;
- в телах подписок промо-строки вида `https://t.me/...` превращались бы
  в мусорные «ноды».

Кастомная схема снимает обе проблемы целиком (решение согласовано):

```
proxy-http://[user[:pass]@]host:port[?path=..&headers=..][#label]
proxy-https://[user[:pass]@]host:port[?path=..&headers=..&sni=..&fp=..&alpn=..&allowInsecure=1][#label]
```

- Схема — дискриминатор TLS: `proxy-https` → `tls.enabled=true`.
- Порт по умолчанию: 80 (`proxy-http`) / 443 (`proxy-https`).
- userinfo как у socks: `user`, `user:pass`, `:pass` (только пароль).
- `path` — sing-box `path` (query-параметр, не URI-path — проще round-trip).
- `headers` — сериализация как naive `extra-headers`
  (`Header1: V1\r\nHeader2: V2`, URL-encoded; reuse
  `parseNaiveExtraHeaders`/`serializeNaiveExtraHeaders`).
- TLS-параметры — конвенции trojan (`parseTrojanTls`): `sni`/`peer`/`host`,
  `fp`, `alpn` (comma), `insecure`-алиасы (`isTlsInsecure`).
  `tls.insecure` → `InsecureTlsWarning` (как trojan).
- REALITY в URI не переносится (как у trojan) — JSON-путь сохраняет.

### Слои

| Слой | Файл | Изменение |
|---|---|---|
| Модель | `app/lib/models/node_spec.dart` | `final class HttpSpec extends NodeSpec` (username, password, path, headers, tls); `protocol => 'http'` |
| Emit | `app/lib/models/node_spec_emit.dart` | `emitHttp` (`_baseOutbound('http')` + optional-поля + `tls.toSingbox()` + `_addDetour`), `toUriHttp` |
| URI-парсер | `app/lib/services/parser/uri_parsers/http_parser.dart` (новый) | `parseHttpProxy` — обе схемы |
| Диспетчер | `app/lib/services/parser/uri_parsers.dart` | `case 'proxy-http': case 'proxy-https':` |
| JSON-парсер | `app/lib/services/parser/json_parsers.dart` | `case 'http':` в `parseSingboxEntry` (headers: значения string или list-first, как naive `extra_headers`; tls через `_tlsFromSingbox`) — покрывает paste JSON и **edit ноды** (редактор работает через JSON) |
| Ввод | `app/lib/services/subscription/input_helpers.dart` | `isDirectLink` += `proxy-http://`, `proxy-https://` |
| Визард | `app/lib/screens/add_server_wizard_screen.dart` | 4-й таб `HTTP` зеркально SOCKS5: Tag (`local-http-out`), Host, Port (hint 8080), Username/Password (opt), switch **HTTPS (TLS)**, Display name. Persist как у SOCKS: rawBody = JSON outbound (tag lossless) |
| UI-метки | `node_list_presenter.dart` | нет изменений — `'http' => 'HTTP'` уже есть |

Тела подписок: `body_decoder` пропускает все не-комментные строки в
`parseUri` — строки `proxy-http://` доходят без правок. Exhaustive-switch'ей
по sealed `NodeSpec` в коде нет (полиморфные `emit`/`toUri`) — новый подтип
ничего не ломает.

Xray-flavor (`parseXrayOutbound`) HTTP-outbound **не** добавляем — вне
объёма (в jump-цепочках xray socks/vless, http не встречался).

### Wizard-форма (детали)

- Дефолты: tag `local-http-out`, host `127.0.0.1`, port hint `8080`.
- Switch «HTTPS (TLS)» OFF по умолчанию; ON → `TlsSpec(enabled: true,
  serverName: host)` (как naive). Тонкая настройка TLS (sni/insecure/alpn) —
  через JSON-редактор ноды.
- Submit-путь = копия `_submitSocks` (форма-ключ, defensive port-parse,
  label = tag — lossless round-trip через JSON rawBody).

## Тесты

- `test/parser/http_proxy_test.dart` — parse обеих схем (auth-варианты,
  дефолтные порты, path/headers, TLS-параметры, insecure-warning),
  round-trip `parseUri(toUri()) ≈ spec`, emit-JSON (полный набор полей),
  `parseSingboxEntry` round-trip (включая headers-list и tls).
- `test/services/http_wizard_roundtrip_test.dart` — по образцу
  `socks_wizard_roundtrip_test.dart`: спека → emit JSON → `parseSingboxEntry`
  → поля сохранены (оба TLS-состояния).

## Доки

- `docs/PROTOCOLS.md` — новый раздел «HTTP(S)» после SOCKS + TOC + счётчик
  протоколов 11 → 12.
- `CHANGELOG.md` → `[Unreleased]` / Added.
