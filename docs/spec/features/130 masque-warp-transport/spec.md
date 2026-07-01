# §130 — MASQUE-транспорт для WARP (CONNECT-IP over HTTP/3 + HTTP/2)

**Статус:** Dart-часть готовится заранее; ждёт живой прогон с ядром.
**Ядро:** sing-box-lx SPEC 021 (`type: masque`, ветка `lx-spec021-masque`, h3+h2 device-verified
2026-07-02). Ядро реализовано; его live-тест **ждёт наш ключевой материал** из Dart-регистрации.
**Связь:** расширяет [§025 WARP integration](../025%20warp%20integration/) — MASQUE это тот же WARP,
другой транспорт (WireGuard ↔ MASQUE). Не путать с §143 masquerade (AmneziaWG anti-DPI — созвучие,
другое).

---

## Зачем

Пользователь (Iliya) просил: WARP по MASQUE вместо WireGuard. MASQUE у Cloudflare — это **CONNECT-IP
(RFC 9484) поверх QUIC/HTTP-3** (с HTTP/2-fallback). Практическая ценность: другой пул выходных нод
(чаще иностранные IP) и лучшая маскировка от DPI — трафик выглядит как обычный HTTPS/QUIC на 443 к
Cloudflare, а не как «странный UDP» WireGuard.

**WARP = сервис Cloudflare. MASQUE и WireGuard = два транспорта к нему.** Сейчас LxBox умеет только
WG-транспорт (X25519). Добавляем второй.

---

## Разделение ответственности (контракт с ядром)

```
┌─ LxBox (Dart) ДЕЛАЕТ ──────────────────────┐   ┌─ Ядро (sing-box-lx) ДЕЛАЕТ ──────┐
│ 1. Генерит ECDSA P-256 keypair на устройстве│   │ Парсит private_key/public_key    │
│ 2. Регистрирует MASQUE-устройство в CF      │──▶│ (x509 SEC1 / PKIX DER)           │
│    (POST /reg + PATCH /reg/{id})            │   │ Поднимает CONNECT-IP туннель     │
│ 3. Сериализует ключи в DER-base64           │   │ (QUIC h3 / HTTP-2 h2)            │
│ 4. Эмитит outbound type:masque в конфиг     │   │ Раздаёт трафик через gVisor-стек │
└─────────────────────────────────────────────┘   └──────────────────────────────────┘
```

Регистрация — **вне ядра** (воспроизводима на Dart). Ядро только парсит ключи и пинит серверный
public_key. Приватник ECDSA **не покидает устройство** (как X25519 в §025).

---

## Схема конфига ядра (источник истины — `option/masque.go`)

Эмитим **`Outbound`** (НЕ `Endpoint`, в отличие от WireGuard!). Плоская структура, без `peers`/`address`/
`certificate`.

```jsonc
{
  "type": "masque",
  "tag": "🔥🎭 WARP",
  "server": "162.159.198.1",          // ServerOptions; IP пира из ответа регистрации
  "server_port": 443,
  "profile": "cloudflare",            // "cloudflare" (дефолт) | "standard"
  "network": "h3",                    // ТРАНСПОРТ: "h3" (QUIC, дефолт) | "h2" (HTTP/2). НЕ tcp/udp!
  "private_key": "<StdBase64(SEC1 DER)>",   // наш ECDSA privkey, x509.ParseECPrivateKey
  "public_key":  "<StdBase64(PKIX DER)>",   // серверный ECDSA pubkey (pinning), x509.ParsePKIXPublicKey
  "ip":   "172.16.0.2/32",            // локальный IPv4 туннеля (CIDR; голый IP → ядро добавит /32)
  "ipv6": "2606:4700:...::/128",      // локальный IPv6 (хотя бы один из ip/ipv6 обязателен)
  "sni": "",                          // дефолт по профилю: consumer-masque.cloudflareclient.com
  "mtu": 1280,                        // дефолт 1280
  "idle_timeout": "",                 // idle-suspend (как §128/§215); пусто=5m, отриц.=выкл
  "keep_alive_period": "",            // QUIC keepalive; пусто=30s
  "network_list": ["tcp","udp"]       // L4 через туннель; пусто=оба
}
```

### Поля и источники значений

| Поле | Источник | Формат |
|---|---|---|
| `private_key` | генерим на устройстве | `base64(SEC1 DER ECPrivateKey)` — **не url-safe, с `=`** |
| `public_key` | ответ регистрации (`peers[0].public_key`) | `base64(PKIX/SPKI DER)` |
| `ip` / `ipv6` | ответ регистрации (`interface.addresses.v4/v6`) | CIDR (как пришло, обычно `/32`//`128`) |
| `server` / `server_port` | ответ регистрации (`peers[0].endpoint`) или дефолт | IP + порт (снять `:0`-хвост) |
| `profile` | константа `cloudflare` | — |
| `network` | выбор юзера (h3 дефолт, h2 если режут QUIC) | `h3`\|`h2` |
| `sni` | пусто (дефолт ядра) или Advanced | домен |
| `mtu` | `1280` | int |

> ⚠️ `network: "tcp"` в MASQUE = **fail-fast ошибка**. Здесь `network` = транспорт (h3/h2),
> а L4-список — это `network_list`. Легко перепутать.

---

## Ключевой материал — КРИТИЧНО (риск №1)

Формат байт-в-байт должен совпасть с Go `x509.ParseECPrivateKey` / `ParsePKIXPublicKey`. Несовпадение
DER = ошибка парсинга при старте ядра.

| Ключ | Go-парсер ядра | ASN.1 | Base64 |
|---|---|---|---|
| `private_key` | `x509.ParseECPrivateKey` | **SEC1** `ECPrivateKey` (RFC 5915): `SEQUENCE { INTEGER(1), OCTET STRING(d 32b), [0] namedCurve OID prime256v1, [1] BIT STRING(0x04‖X‖Y) }` | `base64.StdEncoding` |
| `public_key` | `x509.ParsePKIXPublicKey` | **PKIX/SPKI**: `SEQUENCE { AlgorithmIdentifier{ ecPublicKey 1.2.840.10045.2.1, prime256v1 1.2.840.10045.3.1.7 }, BIT STRING(0x04‖X‖Y) }` | `base64.StdEncoding` |

**Кривая:** ECDSA P-256 = secp256r1 = prime256v1 = NIST P-256. OID named curve = `1.2.840.10045.3.1.7`.

**Грабля крипто-стека:** `cryptography ^2.9.0` (уже в pubspec) умеет `Ecdsa.p256().newKeyPair()` и отдаёт
сырые `d/x/y` (`EcKeyPairData.x`, `.y` — `List<int>`; `.d` — getter). НО его `toDer()` = Apple CryptoKit
формат, **НЕ** SEC1/PKIX. Поэтому: берём сырые d/x/y → собираем SEC1/PKIX DER сами через **`asn1lib`**
(новый dep, чистый Dart). Base64 = `base64.encode` (std, с `=`), НЕ `base64Url`.

**Первый шаг интеграции:** согласовать байт-в-байт **тест-вектор DER** с ядром (у них
`protocol/masque/outbound_test.go` использует `x509.MarshalECPrivateKey`/`MarshalPKIXPublicKey` — эталон).
Наш `masque_keys_test.dart` должен дать те же байты для того же ключа.

---

## Регистрация MASQUE в Cloudflare — ДВА шага (usque/mihomo, cross-verified)

WARP-MASQUE устройство регистрируется НЕ одним запросом:

```
Шаг 1: POST /v0aXXXX/reg
   body: { key: base64(32 rand)  ← ФИКТИВНЫЙ WG-ключ (mimic Android app),
           key_type: "curve25519", tunnel_type: "wireguard",
           install_id:"", fcm_token:"", tos:<CF-время>, model:"PC", locale:"en_US" }
   headers: User-Agent, CF-Client-Version, Content-Type   (без Authorization)
   ──▶ ответ: { id, token, ... }        ← token нужен для шага 2

Шаг 2: PATCH /v0aXXXX/reg/{id}          ← "enroll": подмена ключа на ECDSA
   headers: + Authorization: Bearer <token>
   body: { key: base64(PKIX DER нашего ECDSA-pub),
           key_type: "secp256r1", tunnel_type: "masque" }
   ──▶ ответ: config.interface.addresses.v4/v6  (наш ip/ipv6)
              config.peers[0].public_key         (серверный ECDSA pubkey — PEM или DER)
              config.peers[0].endpoint.{v4,v6,ports}  (data-plane IP:port, снять :0)
```

**Важно:** поле в PATCH называется `tunnel_type` (не `type`); `key` в PATCH = наш **публичный** ECDSA
(PKIX DER, base64, без PEM-обёртки). Серверный pubkey из ответа CF приходит как **PEM** — надо снять
`-----BEGIN/END-----` и перекодировать в чистый base64(DER) для нашего `public_key`.

> **Наш существующий `warp_client.dart` уже делает POST /reg** (версия `v0a2158`, headers `okhttp`) и
> парсит `token`/`id`/`config`. MASQUE-регистрация = **PATCH-шаг поверх** существующего POST + генерация
> ECDSA вместо/рядом с X25519. Не переписываем POST — версию API и headers оставляем наши рабочие.

---

## Модель данных (Dart)

### `MasqueAccount` (новый, `services/warp/masque_account.dart`)

Отдельная модель (НЕ расширяем `WarpAccount` — у него X25519-семантика, `reserved`/AWG не применимы к
MASQUE; смешивание = грязь). Паттерн копируем с `WarpAccount` (toJson/fromJson/redacted/copyWith).

```dart
class MasqueAccount {
  final String privKeyDer;    // base64(SEC1 DER) — СЕКРЕТ
  final String serverPubDer;  // base64(PKIX DER) серверного pubkey
  final String clientV4;      // "172.16.0.2/32"
  final String clientV6;      // "2606:.../128"
  final String server;        // data-plane IP (без :0)
  final int    port;          // 443
  final String deviceId;
  final String token;         // СЕКРЕТ
  final String createdAt;
  final String network;       // "h3" | "h2"
  // license/warpPlus — если понадобится WARP+ (тот же PATCH account)
}
```

- `toMasqueUri()` — собирает `masque://` URI для добавления узла через стандартный `addFromInput`
  (аналог `toWireguardUri`). Схема несёт priv/pub/ip/ipv6/server/network в query.
- `nodeTag()` — тег с эмодзи. Предлагаю `🔥🎭 WARP` (маска-эмодзи ≠ ☁️ plain WG ≠ ⛈️ AWG).
- `redacted()` — privKeyDer/token замаскированы.

### `MasqueSpec` (новый, `models/node_spec.dart`)

Копируем структуру `WireguardSpec` (строки 567–602), но поля MASQUE:

```dart
final class MasqueSpec extends NodeSpec {
  final String privateKeyDer;   // base64 SEC1
  final String publicKeyDer;    // base64 PKIX (серверный)
  final List<String> localAddresses;  // CIDR [v4, v6]
  final String profile;         // "cloudflare"
  final String network;         // "h3" | "h2"
  final String sni;             // "" = дефолт ядра
  final int? mtu;
  // server/port — в базовом NodeSpec уже есть
  @override String get protocol => 'masque';
  @override SingboxEntry emit(TemplateVars vars) => e.emitMasque(this, vars);
  @override String toUri() => e.toUriMasque(this);
}
```

### `emitMasque()` (новый, `models/node_spec_emit.dart`)

Возвращает `Outbound` (НЕ Endpoint!):

```dart
Outbound emitMasque(MasqueSpec s, TemplateVars vars) => Outbound(<String, dynamic>{
  'type': 'masque',
  'tag': s.tag,
  'server': s.server,
  'server_port': s.port,
  'profile': s.profile,
  'network': s.network,
  'private_key': s.privateKeyDer,
  'public_key': s.publicKeyDer,
  if (localAddresses has v4) 'ip': v4cidr,
  if (localAddresses has v6) 'ipv6': v6cidr,
  if (s.sni.isNotEmpty) 'sni': s.sni,
  if (s.mtu != null) 'mtu': s.mtu,
});
```

> `Outbound` → в `build_config.addEntry` попадёт в `outbounds` (не `endpoints`). Проверить: MASQUE-узел
> должен участвовать в channels/detour/routing как обычный outbound (в отличие от WG-endpoint).

---

## Точки расширения (карта файлов)

| Файл | Что делаем |
|---|---|
| `app/pubspec.yaml` | **+ `asn1lib`** (DER-сборка). `cryptography` уже есть. |
| `services/warp/masque_keys.dart` (НОВЫЙ) | `genEcdsaP256()` → keypair; `encodeSec1Der(d,x,y)`, `encodePkixDer(x,y)`; `pemToDerB64()` для серверного ключа |
| `services/warp/masque_account.dart` (НОВЫЙ) | модель `MasqueAccount` (по образцу `warp_account.dart`) |
| `services/warp/warp_client.dart` | + `registerMasque()`: POST (переиспользуем) → PATCH enroll → парс ответа → `MasqueAccount` |
| `models/node_spec.dart` | + `final class MasqueSpec` (образец WireguardSpec:567) |
| `models/node_spec_emit.dart` | + `emitMasque()` → Outbound; + `toUriMasque()` |
| `models/singbox_entry.dart` | без изменений (используем существующий `Outbound`) |
| `services/parser/uri_parsers/masque_parser.dart` (НОВЫЙ) | `parseMasqueUri('masque://...')` → MasqueSpec |
| `services/parser/uri_parsers.dart` | + `case 'masque':` в dispatch (uri_parsers.dart:57 рядом с wireguard) |
| `controllers/subscription_controller.dart` | + `addMasque()` (образец `addWarp`:217); регистрирует + добавляет узел |
| `screens/warp_wizard_screen.dart` | + `SegmentedButton` WireGuard ↔ MASQUE; ветвление `_register()` |
| `services/settings_storage/warp.dart` | + кеш `MasqueAccount` (отдельный ключ от `warp_account`) |
| `services/backup_service.dart` | + MASQUE-аккаунт в бэкап (если WARP-аккаунт бэкапится) |

### Clash YAML (отдельно, вне scope v1)

`parse_all.dart:39` сейчас `clashYaml → []`. Импорт присланного `.yaml` от Ильи (`type: masque` в
Clash-формате) — **отдельная задача**, не блокер. v1 генерит MASQUE **своей** регистрацией, как WG.

---

## UI (warp_wizard_screen)

Переключатель транспорта над Advanced-секцией:

```
┌─ WARP ────────────────────────────┐
│ Transport:  [WireGuard] [MASQUE]   │  ← SegmentedButton
│ License (optional):  [__________]  │
│ ▸ Advanced                         │
│    · WireGuard: endpoint + AWG masquerade (§143)   ← как сейчас
│    · MASQUE:    network h3/h2 + SNI                 ← новое
└────────────────────────────────────┘
```

- WireGuard выбран → текущий путь (obfuscate/quicParams/endpoint) без изменений.
- MASQUE выбран → скрываем AWG-masquerade (не применимо), показываем `network` (h3/h2) + опц. SNI;
  `_register()` вызывает `addMasque()`.
- Строки UI — **английские** (правило проекта); §-номера НЕ в видимых строках.

---

## Потоки

### Регистрация (Dart)
```
addMasque(network):
  1. genEcdsaP256() → (privDer, pubDer, rawX, rawY)   [masque_keys]
  2. warpClient.registerMasque(pubDer, network):
       POST /reg (фиктивный WG-ключ)  → id, token       [переиспользуем существующий POST]
       PATCH /reg/{id} Bearer token, {key:pubDer, key_type:secp256r1, tunnel_type:masque}
         → serverPubPem, ip/ipv6, endpoint
       pemToDerB64(serverPubPem) → serverPubDer
     → MasqueAccount
  3. account.toMasqueUri() → addFromInput() → MasqueSpec в entries
  4. storage.saveMasqueAccount(account)
```

### Эмиссия в конфиг (build)
```
MasqueSpec.emit() → emitMasque() → Outbound{type:masque,...} → build_config.outbounds[]
```

---

## Тест-план

Юнит (без сети, критично — это разблокирует ядро):
- `masque_keys_test.dart` — **тест-вектор DER**: фикс. P-256 ключ (d,x,y) → SEC1/PKIX DER → сверить
  байт-в-байт с эталоном из ядра (`outbound_test.go`). Round-trip: наш DER парсится Go-стороной.
- `masque_account_test.dart` — toJson/fromJson round-trip, redacted маскирует секреты, toMasqueUri.
- `masque_emit_test.dart` — emitMasque даёт правильный Outbound-map (поля, ip как CIDR, network h3/h2).
- `masque_parser_test.dart` — `masque://` URI → MasqueSpec.

Интеграция (live, с ядром — когда доступен стенд):
- registerMasque на реальном CF → валидный конфиг → ядро поднимает туннель (h3) → curl ifconfig.me
  показывает иностранный WARP-IP → UDP (DNS) ходит. Затем h2 там, где h3 режется.
- негатив: битый DER → ядро fail-fast при старте (ожидаемо).

---

## Открытые вопросы

1. **Версия API для MASQUE-регистрации.** Наш POST /reg на `v0a2158`. usque использует `v0a4471` для
   MASQUE-enroll. Возможно, PATCH с `tunnel_type=masque` требует более свежей версии. Проверить на живом
   CF; если наша версия не даёт MASQUE-config — бампнуть версию (вынесена в `WarpApi.version`).
2. **Формат серверного pubkey от CF** — PEM или уже DER? usque видит PEM, mihomo хранит DER. Снимаем
   PEM-обёртку если есть, иначе используем как base64(DER). Уточнить на живом ответе.
3. **WARP+ для MASQUE** — нужен ли license-path? Пока не включаем (можно добавить тем же PATCH account).
4. **idle_timeout по умолчанию** — прокидывать ли из UI или оставить дефолт ядра (5m)? Пока дефолт.

---

## Что НЕ в scope v1

- Импорт чужих Clash-YAML MASQUE-конфигов (отдельная задача — Clash-парсер).
- `standard`-профиль (чистый RFC 9484) — ядро умеет, но нам не нужно (только `cloudflare`).
- `h3-l4proxy` режим.
- MASQUE-обфускация junk (AWG-masquerade к MASQUE не применяется — это WG-фича).

---

## Референс

- Ядро: `sing-box-lx/SPECS/021-MASQUE_CONNECT_IP_OUTBOUND/SPEC.md`, `option/masque.go`,
  `protocol/masque/outbound.go` (parseECPrivateKey/parseECPublicKey — контракт байт).
- Регистрация: `Diniboy1123/usque` (api/cloudflare.go, cmd/register.go, cmd/enroll.go),
  `MetaCubeX/mihomo@Alpha` (adapter/outbound/masque.go).
- Наш WARP: [§025](../025%20warp%20integration/), `warp_client.dart`, `warp_account.dart`.
- RFC 9484 (CONNECT-IP), RFC 9297 (HTTP Datagrams).
