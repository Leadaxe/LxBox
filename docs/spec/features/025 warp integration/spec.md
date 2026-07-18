# 025 — Cloudflare WARP Integration («GET WARP» one-tap)

| Поле | Значение |
|------|----------|
| Статус | Released (v2.3.0) — 2026-06-15. Проверено на устройстве (CPH2411). NB: версия API (`v0a2158` / `CF-Client-Version`) подвижна — при поломке регистрации сверять с актуальным wgcf/warp-cli |
| Дата старта | 2026-06-14 |
| Связанные spec'ы | [`119 vpn-mode`](../119%20vpn-mode/spec.md) — WARP-нода работает в любом из режимов VPN/Proxy; [`118 subscription-fetch-identity`](../118%20subscription-fetch-identity/spec.md) — переиспользуем HTTP-identity/UA-паттерн; [`111 detour`](../111%20detour/spec.md) — «route through proxy» = outbound-цепочка proxy→WARP (см. [[project_detour_is_outbound_chain]]); WireGuard emit — `wireguard_parser.dart` + `node_spec_emit.dart` (endpoint, не outbound, sing-box 1.12+) |
| Затронутые файлы | `app/lib/services/warp/warp_client.dart` (новый), `app/lib/services/warp/warp_account.dart` (новый), `app/lib/services/settings_storage/warp.dart` (новый), `app/lib/services/settings_storage.dart`, `app/lib/controllers/subscription_controller.dart`, `app/lib/screens/subscriptions_screen.dart`, `app/pubspec.yaml`, `app/test/warp/…`, `docs/STORAGE.md`, `docs/ARCHITECTURE.md` |

## Цель

Дать кнопку **«GET WARP»** в экране Servers: один тап → приложение **само регистрирует устройство в Cloudflare** и добавляет готовый WireGuard-узел в список профилей. Без копипасты конфигов с чужих сайтов.

**Ключевое решение по безопасности.** Приватный ключ WireGuard генерируется **на устройстве** (X25519) и наружу уходит только публичная часть. Мы **не** ходим на сторонние воркеры-генераторы (`warp-generator.github.io` и аналоги) — они отдают приватник, сгенерированный на их сервере, то есть владелец воркера знает ключ туннеля каждого пользователя. Это противоречит смыслу VPN-приложения. Мы общаемся напрямую с официальным `api.cloudflareclient.com`, тем же endpoint'ом, что и `wgcf`/Amnezia/официальный клиент.

### Согласованные решения

- **Источник конфига** — собственная регистрация в Cloudflare (`POST /reg`). Не чужие воркеры, не свой хостинг.
- **Приватник** — генерируется на телефоне, не покидает устройство.
- **WARP+** — опциональное поле «License key (optional)». Пусто → free WARP. Заполнено → `PATCH /reg/{id}/account` привязывает ключ. WARP+ даёт Argo Smart Routing (чуть меньше пинг / стабильнее маршрут); приватность и шифрование идентичны free.
- **UX результата** — успешная регистрация **сразу добавляет WireGuard-узел как профиль** (`UserServer` с одним inline-узлом) в список Servers, как обычная подписка. Не показываем сырой конфиг отдельным экраном.
- **Вход в фичу** — пункт **«Get WARP»** в overflow-меню экрана Servers (рядом с «Add server…», «Get Public Test Servers») → открывает **полноэкранный визард** `WarpWizardScreen` (по образцу `add_server_wizard_screen.dart`, §074): логотип/заголовок, поле license, Advanced (endpoint, re-register), статус после регистрации, кнопка Register.
- **Endpoint по умолчанию** — `engage.cloudflareclient.com:2408`. Юзер может переопределить вручную или через встроенный сканер §284 (кнопка SCAN: собирает случайные узлы в папку «SCAN WARP», тестирует штатной probe-механикой по IP-url без DNS, оставляет живые). Раньше сканер был вынесен «вне итерации».
- **Route through proxy** — опциональный тумблер: WARP-узел получает `detour` на выбранную proxy-подписку (proxy → WARP → интернет). За рамками первой итерации, заложить место в модели.
- **Идемпотентность** — WARP-аккаунт кешируется в storage. Повторный «Get WARP» по умолчанию **переиспользует** существующий аккаунт (а не плодит регистрации); есть «Re-register» для форс-нового.

## Архитектура

```
┌──────────────────────────────────────────────────────────────────┐
│ UI: SubscriptionsScreen → overflow «Get WARP»                      │
│   опц. диалог: [License key (optional)]  [Endpoint ▾]  [Register] │
└──────────────────────────────────────────────────────────────────┘
        ↓ subController.addWarp(licenseKey?, endpoint?)
┌──────────────────────────────────────────────────────────────────┐
│ WarpClient (app/lib/services/warp/warp_client.dart)               │
│   1. genKeypair()         → X25519 priv/pub (на устройстве)        │
│   2. POST /v0a2158/reg    → { peer_pub, client_v4, client_v6,     │
│                               client_id, account, token, device } │
│   3. (если license) PATCH /reg/{id}/account { license }           │
│   → WarpAccount (модель)                                          │
└──────────────────────────────────────────────────────────────────┘
        ↓ persist + emit
┌──────────────────────────────────────────────────────────────────┐
│ WarpStorage (settings_storage/warp.dart) — кеш аккаунта           │
│   privKey, peerPub, clientV4, clientV6, clientId(reserved),       │
│   accountId, deviceId, token, license?, endpoint, createdAt       │
└──────────────────────────────────────────────────────────────────┘
        ↓ toWireguardUri()
┌──────────────────────────────────────────────────────────────────┐
│ wireguard://<privKey>@<endpoint>?publickey=<peerPub>&address=...  │
│   &reserved=<clientId>&mtu=1280#WARP                              │
│   → addFromInput() → UserServer → существующий WG emit (endpoint) │
│   → нода в списке Servers, пингуется, работает в любом VPN-режиме │
└──────────────────────────────────────────────────────────────────┘
```

Никаких изменений в native/Kotlin: WARP — это обычный WireGuard-endpoint, который уже полностью поддержан билдером (emit в `config.endpoints[]`, sing-box 1.12+).

## Протокол регистрации

> Версия пути и `CF-Client-Version` — подвижные. На момент написания рабочее: путь `v0a2158`, заголовок `a-7.21-0721`. **Перед релизом свериться** с актуальным `wgcf`/`warp-cli` (см. Риски). Реализовать как константы в одном месте (`WarpApi`), чтобы менять одной правкой.

### 1. Регистрация — `POST`

```
POST https://api.cloudflareclient.com/v0a2158/reg
Headers:
  Content-Type: application/json
  User-Agent: okhttp/3.12.1
  CF-Client-Version: a-7.21-0721
Body:
  {
    "key":          "<base64 X25519 public key — наш>",
    "install_id":   "",
    "fcm_token":    "",
    "tos":          "<ISO8601 текущего времени>",
    "model":        "PC",
    "type":         "Android",
    "locale":       "en_US"
  }
```

**Ответ (200), нужные поля:**

```jsonc
{
  "id":      "<device_id>",
  "token":   "<access token — для PATCH account>",
  "account": { "id": "<account_id>", "license": "...", "warp_plus": false },
  "config": {
    "client_id": "<base64, 3 байта → reserved для sing-box>",
    "peers": [{
      "public_key": "<peer pub key>",
      "endpoint": { "v4": "162.159.x.x:2408", "v6": "[...]:2408", "host": "engage.cloudflareclient.com:2408" }
    }],
    "interface": {
      "addresses": { "v4": "172.16.0.2", "v6": "2606:4700:...:/128" }
    }
  }
}
```

Маппинг в наш `WarpAccount`: `privKey` (наш), `peerPub = config.peers[0].public_key`, `clientV4/clientV6 = config.interface.addresses`, `clientId = config.client_id` (используется как WireGuard `reserved`), `accountId`, `deviceId = id`, `token`, `endpoint` (default host).

### 2. WARP+ license — `PATCH` (только если введён ключ)

```
PATCH https://api.cloudflareclient.com/v0a2158/reg/<device_id>/account
Headers: Authorization: Bearer <token>, CF-Client-Version: a-7.21-0721
Body:   { "license": "<warp_plus_key>" }
→ account.warp_plus: true при успехе
```

### `reserved` / client_id — ТРЕБУЕТ правки WireGuard-модели

`config.client_id` — base64 из 3 байт. В sing-box 1.12+ WireGuard endpoint поле живёт **внутри каждого peer**: `peers[].reserved: [b0, b1, b2]`. Без корректного `reserved` WARP-хендшейк проходит, но трафик НЕ идёт.

**Проверено по коду (2026-06-14): поддержки `reserved` в проекте сейчас НЕТ.** `WireguardPeer` ([node_spec.dart:526](../../../app/lib/models/node_spec.dart)) не имеет поля reserved; `parseWireguardUri` ([wireguard_parser.dart:13-64](../../../app/lib/services/parser/uri_parsers/wireguard_parser.dart)) не читает `reserved=`/`client_id`; `emitWireguard` ([node_spec_emit.dart:473-497](../../../app/lib/models/node_spec_emit.dart)) не эмитит его. Значит маршрут «собрать `wireguard://` URI → `addFromInput`» потеряет client_id.

**Минимальная правка (по паттерну существующих `preSharedKey`/`keepalive`):**
1. `WireguardPeer` — добавить `final List<int>? reserved` (3 байта).
2. `emitWireguard` — внутри peer-map: `if (p.reserved != null && p.reserved!.isNotEmpty) 'reserved': p.reserved`.
3. `parseWireguardUri` — читать `q['reserved']`: формат `b0,b1,b2` (десятичные) ИЛИ base64 client_id → 3 байта; класть в peer.
4. `toUriWireguard` — писать `reserved=b0,b1,b2` обратно (round-trip).

Это нужно как для WARP, так и для любого другого источника WARP-конфигов (стандартный параметр). Покрыть тестом round-trip.

## Storage

Новый фасад `settings_storage/warp.dart` по образцу `settings_storage/vpn_mode.dart` (§119). Ключ `"warp_account"`.

```dart
class WarpAccount {
  final String privKey;      // base64, генерится на устройстве — НЕ логировать
  final String peerPub;
  final String clientV4;     // 172.16.0.2
  final String clientV6;
  final String clientId;     // base64, → reserved
  final String accountId;
  final String deviceId;
  final String token;        // bearer — НЕ логировать
  final String? license;     // WARP+ ключ, если введён
  final bool warpPlus;
  final String endpoint;     // engage.cloudflareclient.com:2408 или кастом
  final String createdAt;    // ISO8601
}
```

- Секреты (`privKey`, `token`) — маскировать в любом логировании/diag-снапшоте (`./scripts/lxbox-diag.sh`, [[feedback_no_destructive_diagnostics]]).
- Документировать в `docs/STORAGE.md`.

## Subscription integration

`SubscriptionController.addWarp({String? licenseKey, String? endpoint, bool reuse = true})`:

1. `reuse && есть кешированный WarpAccount` → переиспользовать, иначе `WarpClient.register()`.
2. Опц. `PATCH account` если `licenseKey`.
3. `persist` аккаунт в storage.
4. `addFromInput(account.toWireguardUri())` — переиспользует существующий путь добавления `UserServer` (никакого нового emit-кода).
5. `_regenerateAndSave()`.

Тег узла — `WARP` (или `WARP+` если `warpPlus`). Повторный вызов с `reuse=true` не создаёт дубль-узел — обновляет существующий по тегу.

## UI

- **Overflow-меню `SubscriptionsScreen`** (`PopupMenuButton`, рядом со строкой ~241): пункт **«Get WARP»** → `_getWarp()`.
- `_getWarp()` показывает лёгкий диалог:
  - `[License key (optional)]` — TextField, пусто = free.
  - `[Endpoint]` — предзаполнен `engage.cloudflareclient.com:2408`, сворачиваемый «Advanced».
  - `[ ] Re-register` (force new) — скрыто за Advanced, по умолчанию off.
  - Кнопка **Register** → `busy`-индикатор (переиспользуем `progressMessage`) → snackbar успех/ошибка.
- Узел появляется в общем списке как обычная подписка — отдельного WARP-экрана не делаем.

## Зависимости

- **X25519 keygen** — `package:cryptography` (чистый Dart, без нативщины) или `package:x25519`. Выбрать по весу/совместимости; добавить в `pubspec.yaml`. Проверить, нет ли уже подходящего в дереве зависимостей.
- HTTP — существующий `package:http` (как в `services/subscription/sources.dart`).

## Edge cases

| Случай | Поведение |
|---|---|
| Нет сети / таймаут | snackbar «WARP registration failed: <reason>», аккаунт не пишется, узел не добавляется |
| `api.cloudflareclient.com` заблокирован/недоступен | то же; подсказка в тексте ошибки, что можно зарегистрировать через включённый proxy/detour (будущее) |
| Cloudflare сменил версию API (4xx на /reg) | внятная ошибка; версия вынесена в константу для быстрой правки |
| Невалидный WARP+ ключ (PATCH 4xx) | регистрация free уже прошла — узел добавляем, но показываем «license not applied» |
| Повторный «Get WARP» | `reuse=true` → тот же узел обновляется, не дубль |
| `reserved`/client_id пустой или кривой | хендшейк есть, трафика нет — валидировать длину 3 байта до emit |
| Кастомный endpoint невалиден (не host:port) | ошибка валидации в диалоге до запроса |

## Порядок имплементации

1. `WarpAccount` модель + `WarpStorage` фасад + ключ в `settings_storage.dart`.
2. `WarpClient`: keygen (X25519), `register()`, `applyLicense()`; константы версии в `WarpApi`.
3. `WarpAccount.toWireguardUri()` + проверка `reserved=` в `wireguard_parser.dart`.
4. `SubscriptionController.addWarp()`.
5. UI: пункт меню + диалог в `subscriptions_screen.dart`.
6. Маскировка секретов в diag/логах.
7. Тесты (ниже).
8. Docs: `STORAGE.md`, `ARCHITECTURE.md`, индекс фич.

## Tests

**Unit** (`app/test/warp/`):
- `warp_client_test.dart` — мок HTTP: успешный /reg → корректный `WarpAccount`; PATCH license; 4xx → исключение с понятным сообщением.
- `warp_uri_test.dart` — `toWireguardUri()` даёт валидный `wireguard://` с `reserved`, парсится `wireguard_parser.dart` обратно в `WireguardSpec`.
- `warp_reserved_test.dart` — client_id base64 → 3-байтовый `reserved`.

**Device-smoke** (по [[feedback_apk_build_install_flow]]):
- «Get WARP» на тест-телефоне (USB `CE8XX48PCI79U4XG`) → узел появляется → пинг → коннект в VPN-режиме §119.
- Перед любой диагностикой при баге — `./scripts/lxbox-diag.sh` ([[feedback_no_destructive_diagnostics]]).

## Acceptance criteria

- [ ] «Get WARP» в overflow-меню Servers регистрирует устройство через `api.cloudflareclient.com`.
- [ ] Приватный ключ генерируется на устройстве; в Cloudflare уходит только публичный (проверяется в тесте — тело /reg содержит `key`, не приватник).
- [ ] Готовый WireGuard-узел `WARP` появляется в списке и пингуется.
- [ ] Узел подключается и гонит трафик в VPN-режиме (корректный `reserved`).
- [ ] Пустой license → free WARP; валидный ключ → `warp_plus: true`, тег `WARP+`.
- [ ] Невалидный license не ломает добавление free-узла.
- [ ] Повторный «Get WARP» переиспользует аккаунт, не плодит дубли; «Re-register» создаёт новый.
- [ ] Секреты замаскированы в diag-снапшоте и логах.

## Future extensions (вне этой итерации)

- ~~Встроенный сканер рабочих endpoint'ов~~ — **доставлен §284** (кнопка SCAN: рандом-посев узлов → папка «SCAN WARP» → штатный `FolderProbeRunner` по IP-url без DNS → автоочистка мёртвых). Research-фундамент — [§132](../../tasks/132-warp-endpoint-scanner-research.md).
- «Route through proxy» — `detour` WARP-узла на выбранную proxy-подписку (§111).
- Авто-ротация endpoint при падении хендшейка.
- WARP как полноценная подписка с авто-апдейтом (перерегистрация по расписанию).
