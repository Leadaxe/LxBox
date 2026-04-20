# 031 — Debug API (Local HTTP Server for dev introspection & control)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-04-20 |
| Зависимости | [`022 app settings`](../022%20app%20settings/spec.md), [`023 debug and logging`](../023%20debug%20and%20logging/spec.md), [`026 parser v2`](../026%20parser%20v2/spec.md), [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md) |

## Цель

Встроенный HTTP-сервер в L×Box, через который **разработчик с хоста** (по `adb forward`) может:

- Читать внутреннее состояние (HomeState, subscriptions, rules, settings, logs, config)
- Проксировать запросы к Clash API без знания его рандомного secret'а
- Триггерить действия (ping, URLTest, VPN start/stop, rebuild, download SRS)
- Тестить изменения без многократных ребилдов (разобраться почему что-то не работает — минуты, а не десятки минут AOT-компиляции)

Задача закрывает проблему: сейчас любая диагностика требует `flutter build apk --release` + `adb install` + пересобрать состояние в app'е. Это дорого когда нужно проверить "а что там в store", "какой status у Clash", "почему urltest.now пустой".

**Не в скопе:**
- Production use — только dev/staging
- Write-access к storage (для MVP — read-only на файлы/settings; actions — через известные методы контроллеров)
- Web UI — только JSON endpoints
- Не-adb-доступ (LAN / remote) — bind строго на 127.0.0.1

---

## Архитектура

### Включение

**Runtime toggle в App Settings → Developer.** Не build-flag:
- Один APK serves и debug и release use cases
- Юзер может включить когда репортит баг, выключить после
- Toggle дефолт OFF — в релизе по умолчанию сервера нет
- Bind 127.0.0.1 → сеть не достанет, adb-forward обязателен

Токен генерится на **первое включение**, хранится в `SettingsStorage` (`debug_token`). На UI показывается с кнопкой Copy — это **единственный канал передачи** токена разработчику. Ни в internal-, ни в external-файлы токен не дублируется, чтобы не плодить leak-вектора (скан `/sdcard/` другими apps, попадание в backups, случайный share файла).

### Server lifecycle

```
App start:
  if SettingsStorage.debug_enabled == true:
    await DebugServer.start(
      port: 9269,
      token: SettingsStorage.debug_token,
    )

User toggles on:
  generate new token if empty
  persist to SettingsStorage
  await DebugServer.start(...)

User toggles off:
  await DebugServer.stop()

App dispose:
  await DebugServer.stop()
```

### Middleware pipeline

Композиция — outer → inner: `errorMapper → accessLog → hostCheck → auth → timeout → router.handle`. Каждый middleware — чистая функция `(req, ctx, next) → DebugResponse`; выкидывает [DebugError] для short-circuit'а (auth fail → `Unauthorized`, host-check fail → `InvalidHost`).

| Middleware | Что делает |
|------------|-----------|
| `errorMapper` | ловит все [DebugError] и unknown exceptions → [ErrorResponse] с правильным статусом. Stack traces пишутся в AppLog, но не в ответ. |
| `accessLog` | логирует каждый запрос (`[debug-api] GET /state → 200 12ms`) с redaction'ом query-параметров содержащих `token/secret/auth/key` |
| `hostCheck` | **anti-rebinding** — принимает только `Host: 127.0.0.1 \| localhost`. Срабатывает до auth: rebinded-браузер получит 403 даже с валидным токеном. |
| `auth` | `Authorization: Bearer <token>`. Исключения — через `config.unauthenticatedPaths` (по умолчанию `{'/ping'}`) |
| `timeout` | оборачивает handler в `.timeout(config.requestTimeout)` → `RequestTimeout` (504) при превышении |

Для pre-pipeline ошибок (PayloadTooLarge при чтении body ещё до middleware'ов) логирование идёт напрямую из `server._onRequest` — формат и статус матчат `accessLog`.

### Registry + Context

Контроллеры пробрасываются через singleton [DebugRegistry]:

```dart
class DebugRegistry {
  static final I = DebugRegistry._();
  HomeController? home;
  SubscriptionController? sub;
  AutoUpdater? autoUpdater;
}
```

Handlers получают refs через [DebugContext] (инжектится в каждый вызов), а не дёргают singleton напрямую — это делает их тестируемыми без Flutter runtime.

```dart
class DebugContext {
  final DebugRegistry registry;
  final DateTime appStartedAt;
  final DebugServerConfig config;     // port/token/timeouts — для handlers
  final AppLog log;
  final DateTime Function() _clock;   // injectable для тестов

  DateTime now() => _clock();
  HomeController requireHome();       // throw Conflict если не готов
  SubscriptionController requireSub();
  DebugContext withConfig(DebugServerConfig);  // copy для сервера при старте
}
```

Registry биндится в `HomeScreen.initState` после создания контроллеров. `appStartedAt` фиксится в `bootstrap.dart` (импортируется из `main.dart`). Config подмешивается сервером при `start()` через `context.withConfig(config)`.

### Модули (actual layout)

Четырёхслойная архитектура — contract / transport / handlers / serializers.
Каждый слой имеет чёткую ответственность и один уровень зависимостей:

```
lib/services/debug/
  debug_server.dart            — public barrel (exports DebugServer, DebugContext,
                                  DebugRegistry, DebugServerConfig, DebugError)
  debug_registry.dart          — singleton с refs на long-lived controllers
  context.dart                 — DebugContext (DI в handlers: registry + config +
                                  clock + log)
  bootstrap.dart               — appStartedAt + applyDebugApiSettings() хелпер

  contract/
    errors.dart                — sealed DebugError hierarchy (9 типов: BadRequest,
                                  Unauthorized, InvalidHost, NotFound, Conflict,
                                  PayloadTooLarge, UpstreamError, RequestTimeout,
                                  InternalError)

  transport/                   — HTTP-specific plumbing, reusable под другой контракт
    server.dart                — DebugServer singleton (bind, listen, stop)
    config.dart                — DebugServerConfig (port, token, timeouts, limits)
    request.dart               — DebugRequest (query/body/headers — typed API)
    response.dart              — sealed DebugResponse: Json/RawJson/Bytes/Error
    router.dart                — prefix→Handler, longest-match
    pipeline.dart              — Middleware chain runner
    middleware/
      host_check.dart          — anti DNS-rebind (Host header)
      auth.dart                — Bearer token (с unauth-paths для /ping)
      access_log.dart          — per-request log line с latency + redaction
      error_mapper.dart        — DebugError → ErrorResponse + unknown → 500
      timeout.dart              — per-request .timeout(config.requestTimeout)

  handlers/                    — бизнес-логика endpoints, bridge contract→domain
    ping.dart, state.dart, device.dart, config.dart,
    logs.dart, clash.dart, action.dart, files.dart

  serializers/                 — pure Map<String, Object?>-продюсеры для JSON
    home_state.dart            — HomeState → Map
    subs.dart                  — SubscriptionEntry → Map + maskSubscriptionUrl
    rules.dart                 — CustomRule → Map + srs_cached/srs_mtime
    storage.dart               — _cache → Map (denylist + scrubber — см. ниже)
```

Pipeline-ордер (outer→inner): `errorMapper → accessLog → hostCheck → auth → timeout → router.handle`.

---

## Контракт ответа

Все ответы имеют `Content-Type: application/json; charset=utf-8`. Ключи в JSON — **snake_case** (`tunnel_up`, `config_length`, `connected_since`), timestamps — **ISO-8601 UTC**.

### Успех

```json
{ "pong": true, "server": "lxbox-debug", "uptime_seconds": 123 }
```

Action-endpoints имеют унифицированный shape:
```json
{ "ok": true, "action": "<name>", ...extras }
```

### Ошибки

Все ошибки через sealed [DebugError]:

```json
{ "error": { "code": "not_found", "message": "rule: abc123" } }
```

Коды и статусы (см. `contract/errors.dart`):

| status | code               | когда                                              |
|--------|--------------------|-----------------------------------------------------|
| 400    | `bad_request`      | missing query param, invalid format                 |
| 401    | `unauthorized`     | нет/неверный Bearer token                           |
| 403    | `invalid_host`     | Host header не `127.0.0.1`/`localhost`              |
| 404    | `not_found`        | unknown endpoint или resource                       |
| 409    | `conflict`         | pre-condition не выполнен (VPN down, controller не готов) |
| 413    | `payload_too_large`| body больше `config.maxBodyBytes`                   |
| 502    | `upstream_error`   | Clash API / native plugin вернул ошибку             |
| 504    | `timeout`          | handler не уложился в `config.requestTimeout`       |
| 500    | `internal`         | необработанное исключение (stack в AppLog, не в ответе) |

**Никогда не возвращаем `{"ok": false, ...}` c 200** — либо 200 + `ok:true`, либо 4xx/5xx + error body.

---

## Эндпоинты

Response-контракт выше; ниже — конкретные endpoints.

### Health

#### `GET /ping`
Health-check, **без auth** (но Host-check всё равно работает). Минимальный ответ — жив ли сервер, сколько секунд аптайм. Build/version берутся через `GET /device` (требует auth).

```json
{ "pong": true, "server": "lxbox-debug", "uptime_seconds": 775 }
```

---

### State — чтение состояния контроллеров

#### `GET /state`
Полный dump HomeState. Сериализатор — `serializers/home_state.dart`.

```json
{
  "tunnel": "connected",
  "tunnel_up": true,
  "busy": false,
  "config_length": 152430,
  "active_in_group": "✨auto",
  "selected_group": "vpn-1",
  "highlighted_node": "✨auto",
  "groups": ["vpn-1", "vpn-2", "vpn-3"],
  "nodes_count": 153,
  "last_delay": {"✨auto": 206, "BL: Paris": 169, …},
  "ping_busy": {"✨auto": ""},
  "traffic": {
    "up_total": 645000000,
    "down_total": 9100000,
    "active_connections": 3
  },
  "connected_since": "2026-04-20T10:43:00Z",
  "last_error": "",
  "config_stale_since_start": false,
  "sort_mode": "latencyAsc"
}
```

#### `GET /state/clash`
Endpoint + secret (для ручного curl'а минуя прокси). Секрет по умолчанию маскируется как `***`; раскрывается явно через `?reveal=true`.

```json
{
  "available": true,
  "base_uri": "http://127.0.0.1:7842",
  "secret": "***",
  "api_ok": true
}
```
`api_ok` — результат последнего `/version` ping'а (ретраится при каждом запросе).

#### `GET /state/subs`
Все подписки. URL маскируется по умолчанию (провайдер-токен живёт в path); раскрыть целиком — `?reveal=true`.

```json
[
  {
    "id": "...",
    "kind": "SubscriptionServers",
    "url": "https://provider.com/***",
    "title": "My provider",
    "enabled": true,
    "tag_prefix": "BL",
    "nodes_count": 120,
    "last_update_at": "2026-04-20T10:05:00Z",
    "last_update_status": "ok",
    "consecutive_fails": 0,
    "update_interval_hours": 24,
    "override_detour": ""
  },
  ...
]
```

#### `GET /state/rules`
Все custom rules (§030). Сериализатор — `serializers/rules.dart`; поля `srs_cached`/`srs_path`/`srs_mtime` заполняются для `kind=srs`.

```json
[
  {
    "id": "...",
    "name": "Firefox RU",
    "enabled": true,
    "kind": "inline",
    "domains": [],
    "domain_suffixes": ["ru", "xn--p1ai"],
    "domain_keywords": [],
    "ip_cidrs": [],
    "ports": [],
    "port_ranges": [],
    "packages": ["org.mozilla.firefox"],
    "protocols": [],
    "ip_is_private": false,
    "srs_url": "",
    "target": "direct-out",
    "srs_cached": false,
    "srs_path": null,
    "srs_mtime": null
  },
  ...
]
```

#### `GET /state/storage`
Dump `SettingsStorage._cache` с применением **denylist + scrubber** (сериализатор — `serializers/storage.dart`).

Философия: debug-tool → по умолчанию всё видно разработчику; новые настройки автоматически попадают в ответ без правки кода. Известные чувствительные поля всегда маскируются:

| Ключ | Обработка |
|------|-----------|
| `vars.debug_token` | `"***"` |
| `server_lists[].url` | `scheme://host/***` (см. `maskSubscriptionUrl`) |
| `server_lists[].nodes` | заменяется на `nodes_count: N` (UUID/password в узлах) |
| `server_lists[].rawBody` | заменяется на `raw_body_bytes: N` (inline URI могут содержать токены) |
| всё остальное | pass-through |

Добавить новое чувствительное поле → правка `serializers/storage.dart` + тест.

#### `GET /state/vpn`
Native VPN flags:
```json
{
  "auto_start": false,
  "keep_on_exit": false,
  "is_ignoring_battery_optimizations": true
}
```

---

### Device — окружение и permissions

#### `GET /device`
Метаданные устройства и приложения — то, без чего половина баг-репортов теряет контекст (версия ОС, модель, ABI, разрешения).

```json
{
  "android_version": "15",
  "sdk_int": 35,
  "manufacturer": "OnePlus",
  "model": "CPH2411",
  "device": "OP5566L1",
  "abi": "arm64-v8a",
  "app_version": "1.3.1",
  "app_build": 6,
  "package_name": "com.leadaxe.lxbox",
  "locale": "ru_IL",
  "timezone": "MSK",
  "is_ignoring_battery_optimizations": true,
  "network_type": "wifi",
  "uptime_seconds": 3600
}
```

Поля:
- `android_version` / `sdk_int` — через `device_info_plus` (`AndroidDeviceInfo.version.release` / `version.sdkInt`).
- `manufacturer` / `model` / `device` / `abi` — оттуда же (`supportedAbis.first`).
- `app_version` / `app_build` / `package_name` — через `package_info_plus`.
- `locale` — `Platform.localeName`.
- `timezone` — `ctx.now().timeZoneName` (через injectable clock на context'е — детерминировано тестируется).
- `is_ignoring_battery_optimizations` — через `BoxVpnClient` (native plugin).
- `network_type` — `connectivity_plus`: `wifi | cellular | ethernet | vpn | none`.
- `uptime_seconds` — `ctx.now().difference(ctx.appStartedAt).inSeconds`, где `appStartedAt` биндится в `bootstrap.dart`.

---

### Config

#### `GET /config`
Текущий saved sing-box JSON (тот что лежит в `/data/data/<pkg>/files/singbox_config.json`). Возвращает raw JSON — без auth middleware к нему аттачится `Content-Type: application/json` и body.
```json
{
  "log": {...},
  "dns": {...},
  "route": {"rule_set": [...], "rules": [...], "final": "vpn-1", ...},
  "outbounds": [...],
  "inbounds": [...],
  "experimental": {"clash_api": {...}}
}
```

#### `GET /config/pretty`
То же но indent: 2.

#### `GET /config/path`
Путь на диске (внутренний, для справки):
```json
{"path": "/data/user/0/com.leadaxe.lxbox/files/singbox_config.json"}
```

---

### Logs

#### `GET /logs?limit=N&source=app|core`
AppLog entries. По умолчанию limit=200, source=all.
```json
[
  {
    "ts": "2026-04-20T10:43:00.380Z",
    "level": "debug",
    "source": "app",
    "message": "proxies[✨auto]: type=URLTest now= all=151"
  },
  ...
]
```

#### `POST /logs/clear`
Очистить AppLog.

---

### Clash API proxy (auth injected)

Каждый эндпоинт форвардит запрос на реальный Clash API (`ClashEndpoint.fromConfigJson(_state.configRaw)`), подмешивая `Authorization: Bearer <secret>`. Ответ — raw как вернул sing-box.

#### `GET /clash/proxies`
→ forward `GET <base>/proxies`

#### `GET /clash/proxies/<tag>`
→ `GET <base>/proxies/<tag>`

#### `PUT /clash/proxies/<tag>` (body: `{"name": "<child>"}`)
→ `PUT <base>/proxies/<tag>` — переключить selector.

#### `GET /clash/proxies/<tag>/delay?url=&timeout=`
→ `/proxies/<tag>/delay`

#### `GET /clash/group/<tag>/delay?url=&timeout=`
→ `/group/<tag>/delay` (форсит URLTest на группе; ожидается Map<child, delay_ms>).

#### `GET /clash/traffic`
→ `/traffic`

#### `GET /clash/connections`
→ `/connections`

#### `DELETE /clash/connections`
→ close all.

#### `DELETE /clash/connections/<id>`
→ close single.

#### `GET /clash/version`
→ sanity-check.

**Note on /group/:tag/delay** — как раз то что нужно для диагностики URLTest'а. Пример: `curl localhost:9269/clash/group/✨auto/delay?url=https://cp.cloudflare.com/generate_204&timeout=5000 -H "Authorization: Bearer $TOKEN"`.

---

### Actions — триггеры контроллеров

Все `POST`. Возвращают `{"ok": true}` или `{"error":...}` c 4xx/5xx.

#### `POST /action/ping-all`
→ `HomeController.pingAllNodes()`. Запускает mass-ping если не запущен; если запущен — cancel'ит.

#### `POST /action/ping-node?tag=<tag>`
→ `HomeController.pingNode(tag)`.

#### `POST /action/run-urltest?group=<tag>`
→ `HomeController.runGroupUrltest(tag)` — дёргает Clash `/group/<tag>/delay` с текущими pingUrl/pingTimeout + reloadProxies.

#### `POST /action/switch-node?tag=<tag>`
→ `HomeController.switchNode(tag)` — переключает selector на node.

#### `POST /action/set-group?group=<tag>`
→ `HomeController.applyGroup(tag)` — смена активной группы.

#### `POST /action/start-vpn`
→ `HomeController.startVpn()` (wrapper который обрабатывает VpnService.prepare dance).

#### `POST /action/stop-vpn`
→ `BoxVpnService.stop(context)`.

#### `POST /action/rebuild-config`
→ `SubscriptionController.generateConfig()` + `HomeController.saveParsedConfig(...)`.

#### `POST /action/refresh-subs?force=true|false`
→ `AutoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: ...)`.

#### `POST /action/download-srs?ruleId=<id>`
→ `RuleSetDownloader.download(id, url)` (для URL берём из CustomRule в storage).

#### `POST /action/clear-srs?ruleId=<id>`
→ `RuleSetDownloader.delete(id)`.

#### `POST /action/toast?msg=<text>&duration=short|long`
Показать Android Toast через native plugin (`Toast.makeText(...).show()`). `duration` default `short`. Возвращает `{"ok": true}`.

Зачем: sanity-check "моё ли это устройство сейчас подключено к adb", подтверждение что команда дошла, лайфхак для remote-handoff ("попроси юзера подтвердить что видит toast"). Message — URL-encoded string, обрезается до 200 символов (toast всё равно больше не покажет).

Реализация: расширить `VpnPlugin` (или завести отдельный `DebugPlugin`) method `showToast(msg, duration)`. Dart-сторона просто вызывает platform channel.

---

### Files — read-only file access

#### `GET /files/srs?ruleId=<id>`
Returns cached .srs file as `application/octet-stream` (binary dump).

#### `GET /files/srs/list`
```json
[{"ruleId":"...","size":128000,"mtime":"2026-04-20T10:05:00Z"}, ...]
```

#### `GET /files/external?name=<name>`
Read from `/sdcard/Android/data/<pkg>/files/<name>`. Whitelisted: `cache.db` (head только), `stderr.log`, `stderr.log.old`.

---

### Navigation (optional MVP+1)

Требует global `NavigatorKey` в `MaterialApp`.

#### `POST /nav/home|routing|subs|settings|stats|debug|speed_test`
Pushes/replaces to the named screen.

#### `GET /nav/route`
Returns current route name.

---

## UI — App Settings → Developer

Новая секция в `app_settings_screen.dart`:

```
┌──────────────────────────────────────────┐
│  Developer                               │
│                                          │
│  🐛 Debug API              [⬤── ]       │
│  Expose HTTP server on localhost          │
│  for adb-forwarded debugging.            │
│                                          │
│  Port                                    │
│  ┌────────────────────────────────────┐  │
│  │ 9269                               │  │
│  └────────────────────────────────────┘  │
│                                          │
│  Token                                   │
│  ┌────────────────────────────────────┐  │
│  │ a1b2c3d4e5f6... (32 hex)     [📋]  │  │
│  └────────────────────────────────────┘  │
│  Endpoint: http://127.0.0.1:9269         │
│  (Copy — единственный способ получить    │
│   токен. В файлы не пишется.)            │
│                                          │
│  [🔄 Regenerate token]                    │
│                                          │
│  ⚠ Only for development. Do not enable   │
│     on production devices.               │
└──────────────────────────────────────────┘
```

Toggle on → генерируется токен (32-hex через `Random.secure()`), сохраняется в `SettingsStorage`, `DebugServer.start()`. Токен никуда, кроме storage, не пишется — разработчик получает его через Copy в UI.
Toggle off → `stop()`. Токен остаётся в storage (при следующем on — тот же токен), чтобы сохранённые curl-сессии продолжали работать.
Regenerate → новый токен, все сохранённые curl-команды идут в 401.
Port change (input) → валидируется (1024–65535), сохраняется в `debug_port`; если сервер сейчас запущен — `stop()` + `start()` на новом порту. Endpoint-строка в UI обновляется реактивно.

---

## Storage keys

| Key | Тип | Default | Назначение |
|-----|-----|---------|-----------|
| `debug_enabled` | String | `"false"` | Toggle state |
| `debug_token` | String | `""` | Persisted token (32 hex) |
| `debug_port` | String | `"9269"` | Port (tweakable в UI) |

---

## Файлы (actual)

### Core

| Файл | Что |
|------|-----|
| `lib/services/debug/debug_server.dart` | Public barrel (exports) |
| `lib/services/debug/debug_registry.dart` | Singleton с refs на контроллеры |
| `lib/services/debug/context.dart` | DebugContext (DI handlers) + `withConfig` |
| `lib/services/debug/bootstrap.dart` | `appStartedAt` + `applyDebugApiSettings()` |
| `lib/services/debug/contract/errors.dart` | sealed DebugError (9 типов) |

### Transport

| Файл | Что |
|------|-----|
| `transport/server.dart` | DebugServer singleton (bind/listen/stop) |
| `transport/config.dart` | DebugServerConfig |
| `transport/request.dart` | DebugRequest (typed query/body/headers) |
| `transport/response.dart` | sealed DebugResponse + JsonResponse / RawJsonResponse / BytesResponse / ErrorResponse |
| `transport/router.dart` | Prefix-based Router (longest-match) |
| `transport/pipeline.dart` | Middleware chain runner |
| `transport/middleware/{host_check,auth,access_log,error_mapper,timeout}.dart` | 5 middleware-функций |

### Handlers

| Файл | Endpoints |
|------|-----------|
| `handlers/ping.dart` | `/ping` |
| `handlers/state.dart` | `/state`, `/state/{clash,subs,rules,storage,vpn}` |
| `handlers/device.dart` | `/device` |
| `handlers/config.dart` | `/config`, `/config/pretty`, `/config/path` |
| `handlers/logs.dart` | `GET /logs`, `POST /logs/clear` |
| `handlers/clash.dart` | `/clash/*` proxy (всё что угодно под префиксом) |
| `handlers/action.dart` | `POST /action/{ping-all, ping-node, run-urltest, switch-node, set-group, start-vpn, stop-vpn, rebuild-config, refresh-subs, download-srs, clear-srs, toast}` |
| `handlers/files.dart` | `/files/srs`, `/files/srs/list`, `/files/external` |

### Serializers

| Файл | Что |
|------|-----|
| `serializers/home_state.dart` | HomeState → Map |
| `serializers/subs.dart` | SubscriptionEntry → Map + `maskSubscriptionUrl` |
| `serializers/rules.dart` | CustomRule → Map (с `srs_cached`/`srs_path`/`srs_mtime`) |
| `serializers/storage.dart` | `_cache` → Map (denylist + scrubber) |

### Интеграция

| Файл | Что |
|------|-----|
| `lib/screens/app_settings_screen.dart` | Developer section — toggle + token + port + regenerate |
| `lib/screens/home_screen.dart` | `DebugRegistry.I.home = _controller` + `applyDebugApiSettings()` после init |
| `lib/main.dart` | `import bootstrap.dart` → фиксит `appStartedAt` |
| `android/.../VpnPlugin.kt` | `showToast` native method для `/action/toast` |
| `lib/services/settings_storage.dart` | `debug_enabled/token/port` + `dumpCache()` |

### Тесты

| Файл | Покрытие |
|------|----------|
| `test/services/debug/errors_test.dart` | DebugError.toJson + status codes |
| `test/services/debug/request_test.dart` | query/body parsing, size limit |
| `test/services/debug/router_test.dart` | prefix matching, longest-match, NotFound |
| `test/services/debug/pipeline_test.dart` | все 5 middleware + chain composition |
| `test/services/debug/serializers_test.dart` | URL masking + storage denylist/scrubber |
| `test/services/debug/handler_test.dart` | ping, logs (pure handlers без platform deps) |
| `test/services/debug/server_integration_test.dart` | реальный HttpServer.bind — auth/host/404 end-to-end |

---

## Безопасность

1. **Bind 127.0.0.1** — не LAN, не 0.0.0.0. Другие устройства сети не видят. **Важное уточнение:** Android **не изолирует loopback между приложениями** — любой процесс на устройстве (в т.ч. вредоносный app без специальных permissions) может открыть TCP-коннект на `127.0.0.1:9269` нашего процесса. Защита — только auth token; bind-адрес отсекает LAN/remote, но не co-located apps.
2. **Toggle default OFF** — ничего не слушает пока юзер явно не включит.
3. **Auth token обязателен** — 32-hex random, персистится в SettingsStorage.
4. **Нет write-доступа к storage** — read-only на files; actions — только через известные методы controllers (не `setVar` напрямую).
5. **Clash secret не светится по умолчанию** — только через `/state/clash` (опционально, явный get).
6. **Host header check** — middleware рефьюзит запросы с `Host != 127.0.0.1|localhost` (403). Защита от DNS rebinding: если токен всё-таки утёк (скриншот Settings, баг-репорт, clipboard), злоумышленник через браузер на устройстве не эксплуатирует — SOP даёт ему "доступ" к `http://evil.com:9269/...`, но DNS-rebind подменяет IP на `127.0.0.1`, а наш сервер отвечает только на свои имена. `curl` через `adb forward` шлёт `Host: localhost` — проходит.
7. **Токен только в UI** — не пишется ни в internal-файлы, ни в `/sdcard/`. Единственный канал передачи — Copy button в App Settings → Developer. Убирает векторы: другое приложение читает external storage, токен попадает в device backup, случайный share файла с `/sdcard/`.
8. **Log masking** — в общих `/logs` response токен никогда не светится (AppLog при генерации логирует только hint "Debug token issued" без значения).

---

## Acceptance

- [ ] App Settings → Developer → Debug API toggle работает, токен генерится на первое включение, отображается в UI, Copy кладёт в буфер.
- [ ] Токен нигде в файловой системе не появляется — ни в `/sdcard/Android/data/<pkg>/files/`, ни где-либо ещё кроме internal `shared_prefs`.
- [ ] `curl localhost:9269/ping` отдаёт `{"pong": true}` без auth.
- [ ] `curl -H "Host: evil.com" localhost:9269/ping` → 403 (Host check срабатывает до `/ping`-исключения).
- [ ] Любой другой endpoint без `Authorization: Bearer` → 401.
- [ ] `GET /state` возвращает HomeState в человекочитаемом JSON.
- [ ] `GET /state/clash` отдаёт secret + base URI.
- [ ] `GET /device` возвращает Android version, model, ABI, app version, VPN permission, network type, uptime.
- [ ] `POST /action/toast?msg=hello` показывает Toast "hello" на устройстве.
- [ ] Изменение порта в UI → сервер перезапускается на новом порту; старый порт connection-refused, новый — 200.
- [ ] `GET /clash/proxies` = `curl с secret'ом напрямую` (по содержимому).
- [ ] `GET /clash/group/✨auto/delay?url=&timeout=` форсит URLTest и возвращает Map<child, delay>.
- [ ] `POST /action/run-urltest?group=✨auto` — same как меню-пункт.
- [ ] `POST /action/rebuild-config` перегенерирует и сохраняет конфиг.
- [ ] `GET /logs?limit=50` возвращает последние 50 AppLog entries.
- [ ] `GET /config` отдаёт весь saved sing-box JSON.
- [ ] Toggle off → `curl` падает с connection-refused.
- [ ] Regenerate token → старый токен 401, новый 200.
- [ ] В CI-release APK (BUILD_LOCAL не передан) — секция Developer видна, но при toggle off ничего не слушает, при toggle on запускается нормально (server самодостаточный).

---

## Риски

| Риск | Mitigation |
|------|-----------|
| Другое приложение на устройстве открывает TCP на `127.0.0.1:9269` (Android loopback не изолирован между apps — любой процесс может достучаться до нашего порта без network permissions) | Единственная защита — auth token. Токен лежит в internal `shared_prefs` нашего app'а (sandbox), другие apps его не прочитают. Без токена — 401/403 на любой endpoint кроме `/ping`. Risk materializes только при компрометации storage нашего app'а (root, exploit) или leak'е через UI/скриншот. |
| Токен утёк через скриншот/баг-репорт → злоумышленник эксплуатирует через браузер устройства | Host header check — запросы с `Host: evil.com` режутся 403 до auth. DNS rebinding перестаёт работать. |
| Secret утечка через `/state/clash` | Это явный endpoint, не дефолтный. Требует auth. Dev-use only. |
| Сервер падает на некорректном запросе → краш app'а | `try/catch` в dispatch, логирование 500 в AppLog. Unit-тесты на malformed запросы. |
| Port conflict | При `HttpServer.bind` exception — лог warning + скип. UI показывает "Port in use, try different" (или берёт из `debug_port`). |
| Actions с side-effects запускаются в неправильный момент (VPN offline, config пустой) | Каждый action проверяет пред-условия; возвращает 409 Conflict если state не подходит. |
| Debug server ship'ится в CI release — увеличение APK size + площадь атаки | Размер не большой (~15 KB). Атаку закрывает toggle off + auth. Если параноично — gate через `kBuildLocal` но юзер сказал без этого. |

---

## Out of scope / future

- **WebUI** (static HTML страницы для introspection) — для MVP не нужно, curl достаточно.
- **Storage write** (`POST /state/storage?key=...&value=...`) — сейчас read-only; если понадобится — отдельный spec с явным opt-in'ом.
- **Performance profiling endpoints** (/profile/flutter, /profile/build_time) — отдельная тема.
- **Remote collaboration** (SSH-tunnel к мне, чтобы я дебажил девайс юзера удалённо) — категорически не делаем, bind 127.0.0.1 на века.

---

## Notes

- Все response'ы ограничены размером. `/config` может быть ~100-500 KB — OK. `/files/srs/<id>` — до нескольких MB. Используем streaming write (`req.response.add(bytes)`), не `jsonEncode` для бинарных.
- Logs endpoint должен пагинироваться — limit + offset / cursor.
- Timezone: все timestamp'ы в ISO-8601 UTC.
