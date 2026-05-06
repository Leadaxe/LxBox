# 043 — Diagnostics platform (Debug API + AppLog + Crash diagnostics)

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-20 → 2026-05-06 (consolidation) |
| Замещает | [`§031 debug api`](../031%20debug%20api/spec.md), [`§038 crash diagnostics`](../038%20crash%20diagnostics/spec.md) |
| Зависимости | [`022 app settings`](../022%20app%20settings/spec.md), [`023 debug and logging`](../023%20debug%20and%20logging/spec.md), [`026 parser v2`](../026%20parser%20v2/spec.md), [`030 custom routing rules`](../030%20custom%20routing%20rules/spec.md), [`012 native vpn service`](../012%20native%20vpn%20service/spec.md) |

## Цель

Единый umbrella-spec для diagnostics-инфраструктуры L×Box. Содержит три исторически отдельных, но тесно связанных раздела:

- **[Раздел A — Debug API](#раздел-a--debug-api-was-031)** — встроенный HTTP-сервер на localhost:9269 (Bearer-auth) для introspection / CRUD / proxy к Clash API. Заменил §031.
- **[Раздел B — Crash diagnostics](#раздел-b--crash-diagnostics-was-038)** — четыре канала post-mortem (stderr-redirect, ApplicationExitInfo, persistent AppLog, logcat tail) для отладки крашей без `adb`. Заменил §038.
- **[Раздел C — AppLog per-source quotas + core logs pump](#раздел-c--applog-per-source-quotas--core-logs-pump-original-043)** — refactor `AppLog` на per-source map с раздельными quota'ми + EventChannel `lxbox/coreLog` для forwarding'а sing-box логов в наш AppLog. Original §043.

Объединены потому что:
1. Код частично живёт в одних файлах (`AppLog`, `debug_server`, `dump_builder`, `BoxVpnService`).
2. Cross-deps: §031 endpoints `/logs/*` и `/diag/*` опираются на §038 (persistent AppLog) и §043 (per-source quotas). §043 без §031 виден только через UI.
3. Single source of truth для будущих агентов / разработчиков — не нужно прыгать между тремя файлами.

---

# Раздел A — Debug API (was §031)

> **Статус:** done. Был отдельный spec [§031](../031%20debug%20api/spec.md), теперь живёт здесь.

## A.1 Цель

Встроенный HTTP-сервер в L×Box, через который **разработчик с хоста** (по `adb forward`) может:

- Читать внутреннее состояние (HomeState, subscriptions, rules, settings, logs, config)
- Проксировать запросы к Clash API без знания его рандомного secret'а
- Триггерить действия (ping, URLTest, VPN start/stop, rebuild, download SRS)
- Тестить изменения без многократных ребилдов (разобраться почему что-то не работает — минуты, а не десятки минут AOT-компиляции)

Задача закрывает проблему: сейчас любая диагностика требует `flutter build apk --release` + `adb install` + пересобрать состояние в app'е. Это дорого когда нужно проверить "а что там в store", "какой status у Clash", "почему urltest.now пустой".

**Не в скопе:**
- Production use — только dev/staging
- Web UI — только JSON endpoints
- Не-adb-доступ (LAN / remote) — bind строго на 127.0.0.1

**Scope writes:** чтение состояния, проксирование Clash API, триггеры (ping/urltest/rebuild/refresh)
плюс **CRUD на доменные ресурсы** — custom rules, subscriptions, scoped SettingsStorage writes,
прямой override сохранённого sing-box конфига. Детально — раздел
[A.10 CRUD endpoints](#a10-crud-endpoints--доменные-мутации).

## A.2 Архитектура

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
    logs.dart, clash.dart, action.dart, files.dart,
    rules.dart, subs.dart, settings.dart      — CRUD на доменные ресурсы

  serializers/                 — pure Map<String, Object?>-продюсеры для JSON
    home_state.dart            — HomeState → Map
    subs.dart                  — SubscriptionEntry → Map + maskSubscriptionUrl
    rules.dart                 — CustomRule → Map + srs_cached/srs_mtime
    storage.dart               — _cache → Map (denylist + scrubber — см. ниже)
```

Pipeline-ордер (outer→inner): `errorMapper → accessLog → hostCheck → auth → timeout → router.handle`.

## A.3 Контракт ответа

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

## A.4 Эндпоинты — Health

#### `GET /ping`
Health-check, **без auth** (но Host-check всё равно работает). Минимальный ответ — жив ли сервер, сколько секунд аптайм. Build/version берутся через `GET /device` (требует auth).

```json
{ "pong": true, "server": "lxbox-debug", "uptime_seconds": 775 }
```

#### `GET /help[?format=text|json]`
**Self-documenting capability map.** Без auth (то же исключение что `/ping`), Host-check работает. LLM-агент / wrapper / новый разработчик может **discover'нуть** всю поверхность Debug API одним запросом, не нужен токен на этом шаге.

Два формата:
- `?format=text` (default) — markdown-текст со списком endpoint'ов, параметров и quick-examples curl'а. Удобно вставлять в LLM-context напрямую.
- `?format=json` — структурированный JSON: `{server, docs, auth, transport, endpoints[], errors, notes}`. Каждый endpoint описан как `{method, path, params?, body?, description, auth?}`. Для auto-tooling (генерация MCP-обёртки, OpenAPI-spec, сверка с реальным router'ом).

Содержимое — **hand-maintained** в `lib/services/debug/handlers/help.dart`. При добавлении / переименовании / удалении endpoint'а обязательно обновить **обе** константы (`_capabilityText`, `_capabilityJson`). Single-source-of-truth для агентов и wrapper'ов; рассинхрон с реальным router'ом — баг.

```bash
curl http://127.0.0.1:9269/help               # markdown text
curl http://127.0.0.1:9269/help?format=json   # structured
```

## A.5 Эндпоинты — State (чтение состояния контроллеров)

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

## A.6 Эндпоинты — Device

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

## A.7 Эндпоинты — Config

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

#### `PUT /config` (body: raw sing-box JSON)

Прямой override сохранённого конфига — минуя `buildConfig(...)`, подписки, custom rules, вообще всё. Body = любой валидный JSON объект. Вызывает `HomeController.saveParsedConfig(raw)`, что пишет на диск + reload'ит TUN если VPN запущен.

Зачем: тестить руками кастомные поля в `dns.rules`, pre-computed outbounds, изменения, которые нет в UI wizard'е. После перегенерации через `/action/rebuild-config` всё сотрётся — это **временный override**, не персистится в settings.

**Quirk:** размер бандл-конфига L×Box обычно 70-200 KB — дефолтный `maxBodyBytes=64KB` не хватит. Config-path имеет override до **1 MiB**.

Ответ: `{"ok": true, "action": "config-put", "bytes": N, "reloaded": true|false}`.

Предусловия:
- JSON-body должен парситься. Невалидный → 400.
- Если `tunnel_up == true` — пытаемся reload TUN через `home.restartWithConfig`; фейл reload → 502.

## A.8 Эндпоинты — Logs

> **Cross-ref:** Per-source quotas + sing-box logs forwarding — см. [Раздел C](#раздел-c--applog-per-source-quotas--core-logs-pump-original-043).

#### `GET /logs?limit=N&source=app|core`
AppLog entries. По умолчанию limit=200, source=all. Max limit=1000.
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

#### `GET /logs/app`
Alias для `/logs?source=app`. Те же query params (`level`, `q`, `limit`).

#### `GET /logs/core`
Alias для `/logs?source=core`. Те же query params. Sing-box логи (router/inbound/outbound события, dial errors, DNS failures).

#### `POST /logs/clear[?source=app|core]`
Очистить AppLog. Без `source` — оба source clear'аются. С `?source=` — только указанный.

## A.9 Эндпоинты — Clash API proxy (auth injected)

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

## A.10 Эндпоинты — Actions (триггеры контроллеров)

Все `POST`. Возвращают `{"ok": true}` или `{"error":...}` c 4xx/5xx.

#### `POST /action/run-mass-urltest`
→ `HomeController.runMassUrltest()`. Параллельный URLTest на всех нодах активной группы (concurrency cap 10). Запускает если не running; если running — cancel'ит.

#### `POST /action/run-node-urltest?tag=<tag>`
→ `HomeController.runNodeUrltest(tag)` — single-node URLTest через clash `/proxies/<tag>/delay`.

#### `POST /action/run-urltest?group=<tag>`
→ `HomeController.runGroupUrltest(tag)` — дёргает Clash `/group/<tag>/delay` с per-group resolved url/timeout (§040) + reloadProxies.

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

#### `POST /action/reset-network`
→ `commandServer.resetNetwork()` через native bridge. Закрывает ВСЕ active connections + flush DNS cache + DoH/DoT transports `Reset()` + interface refresh у inbound/outbound/endpoints. **БЕЗ recreate** runtime. См. [§031 task](../../tasks/031-reset-network-api.md).

## A.11 CRUD endpoints — доменные мутации

Чтения через `/state/*` дают snapshot; **мутировать** тот же домен (правила, подписки, настройки) можно только через UI — это делает автотестирование изменений невозможным без AOT-ребилда. Блок ниже закрывает CRUD на:

1. **Custom rules** (`/rules/*`) — create / update / delete / reorder.
2. **Subscriptions** (`/subs/*`) — add / update meta / change URL / delete / reorder / refresh single.
3. **Settings storage** (`/settings/*`) — scoped writes на `route_final`, `excluded_nodes`, `vars/<key>`, `dns_options`, `core_logs_enabled`.
4. **Direct sing-box config override** — уже описано выше (`PUT /config`).

Все CRUD endpoints возвращают либо `{"ok": true, "action": "<name>", ...extras}` (если результат асимметричен Create/Delete), либо полный созданный/изменённый ресурс (при GET-after-write pattern'е на Create). Ошибки — стандартные `DebugError`'ы.

**После любой мутации** config в sing-box не меняется автоматически. Чтобы применить — `POST /action/rebuild-config`. Либо вызов с query `?rebuild=true` — endpoint'ы CRUD поддерживают это как удобный shortcut (эквивалент `rebuild-config` сразу после изменения).

Write-rate limit: встроенного нет. adb-forward single-user → rate-limit не нужен; если потенциально появится remote-доступ, добавим токен-bucket в `middleware/ratelimit.dart`.

### Rules — `/rules/*`

Тонкая обёртка над `SettingsStorage.getCustomRules` / `saveCustomRules`. Модель ресурса — `CustomRule` ([`custom_rule.dart`](../../../../app/lib/models/custom_rule.dart)), JSON-shape как в `/state/rules` GET'е.

##### `GET /rules`
Alias для `/state/rules` (с `srs_cached`/`srs_mtime`).

##### `POST /rules`
Создать новое правило. Body — `CustomRule` без `id`:
```json
{
  "name": "YouTube via Trojan",
  "enabled": true,
  "kind": "inline",
  "domain_suffixes": ["googlevideo.com","youtube.com"],
  "target": "vpn-1"
}
```
Server генерит `id` (UUID v4). Response: полный созданный ресурс (с `id`), status 201.

Опции: `?rebuild=true` — после create триггерит `rebuild-config`.

##### `PATCH /rules/{id}`
Частичное обновление. Body — любой subset полей `CustomRule` (кроме `id`). Поля переданные = overwrite, непереданные = as-is. Response: 200 + обновлённый ресурс.

Примеры:
```bash
# Выключить
curl -X PATCH ... -d '{"enabled": false}' /rules/<id>

# Добавить суффикс
curl -X PATCH ... -d '{"domain_suffixes": ["tube.com","googlevideo.com","youtube.com"]}' /rules/<id>

# Сменить target
curl -X PATCH ... -d '{"target": "reject"}' /rules/<id>
```

**Quirk:** обновить массив — только целиком (replace). Нет `add_item`/`remove_item` — это избыточно для debug-tool'а, и вероятность race условий выше.

`{id}` не существует → 404.

##### `DELETE /rules/{id}`
Удалить. Response: `{"ok": true, "action": "rules-delete", "id": "..."}`, status 200. Неизвестный id → 404.

##### `POST /rules/reorder`
Сменить порядок (приоритет matcher'а). Body — полный список ID в новом порядке:
```json
{ "order": ["id1", "id2", "id3", ...] }
```
Проверки:
- Длина `order` === текущему числу правил — иначе 400 `bad_request`.
- Множество ID совпадает — иначе 400.

Response: `{"ok": true, "action": "rules-reorder", "count": N}`.

### Subscriptions — `/subs/*`

Обёртка над `SubscriptionController` public методами. Shape ресурса — как в `/state/subs`, плюс `id` (уже есть).

##### `GET /subs`
Alias для `/state/subs`. Query `?reveal=true` — не маскирует URL.

##### `POST /subs`
Добавить подписку или inline user server. Body:
```json
{ "input": "<url | URI | wireguard-ini | json-outbound>" }
```
Делегирует в `SubscriptionController.addFromInput(input)`. Поддерживаемые форматы (§027/028): subscription URL, direct VLESS/Trojan/SS/Hysteria/WG URI, paste'нутый WireGuard INI, JSON outbound (`{ "type": "vless", ... }`).

Response: `{"ok": true, "action": "subs-add", "id": "<new-id>", "kind": "SubscriptionServers|UserServer"}`.

Fail cases:
- Input нераспознан → 400 + `lastError` в `message`.
- Fetch подписки свалился (URL unreachable) → 502 (но запись всё равно создастся — status=failed).

Опции: `?rebuild=true` — после add + fetch перегенерирует config.

##### `PATCH /subs/{id}`
Update meta. Body — subset следующих полей:
```json
{
  "name": "My provider",
  "enabled": true,
  "tag_prefix": "BL",
  "update_interval_hours": 6,
  "override_detour": "",
  "register_detour_servers": true,
  "register_detour_in_auto": false,
  "use_detour_servers": true,
  "url": "https://new-url/sub"
}
```

- `url` переписывается **только для SubscriptionServers**; для UserServer `url` игнорируется.
- Остальные поля — через `SubscriptionEntry` setters + `controller.persistSources()`.
- После PATCH **fetch не триггерится** автоматически — это manual action. Если нужно — `POST /subs/{id}/refresh`.

Response: 200 + обновлённый ресурс.

##### `DELETE /subs/{id}`
`SubscriptionController.removeAt(index_of_id)`. Response: `{"ok": true, "action": "subs-delete", "id": "..."}`.

##### `POST /subs/{id}/refresh`
Триггер одиночного refresh'а — `controller.refreshEntry(entry, trigger: UpdateTrigger.manual)`. Async — endpoint возвращает сразу после kick-off (`unawaited`). Смотри состояние через `/state/subs`.

Response: `{"ok": true, "action": "subs-refresh", "id": "..."}`.

Предусловия: для UserServer это no-op (нет URL'а) → 409 `Conflict`.

##### `POST /subs/reorder`
Body `{"order":["id1","id2",...]}`. Аналогично `/rules/reorder`.

### Settings storage — `/settings/*`

**Scoped writes на отдельные поля `SettingsStorage`** — не generic `POST /state/storage?key=X&value=Y`, потому что некоторые ключи критичны (`debug_token`, `debug_enabled`, `debug_port` — сменить через API = заблокировать самому себе доступ). Ниже — явный allow-list.

##### `PUT /settings/route_final`
Body: `{"outbound": "<tag>"}`. Save via `saveRouteFinal`. Response: `{"ok": true, "action": "settings-route-final", "outbound": "..."}`.

Пустая строка — легальное значение (тогда sing-box использует дефолт `direct-out`).

##### `PUT /settings/excluded_nodes`
Body: `{"nodes": ["tag1","tag2",...]}`. Replace set. Response: `{"ok": true, "action": "settings-excluded-nodes", "count": N}`.

##### `PUT /settings/vars/{key}`
Body: `{"value": "..."}`. `SettingsStorage.setVar(key, value)`.

**Blocklist (409 Conflict, message: "var X is managed via App Settings UI only"):**
- `debug_token`
- `debug_enabled`
- `debug_port`

Этот blocklist хранится в хендлере `handlers/settings.dart` константой `_varBlocklist`; любой другой var — свободно write/delete. 409 вместо 403, потому что причина отказа — **pre-condition mismatch** (этим ключом владеет UI), а не auth/permission failure.

##### `DELETE /settings/vars/{key}`
Удалить var (через `_cache['vars'].remove(key)` + save). Те же forbidden keys.

##### `PUT /settings/dns_options/servers`
Body: `{"servers": [ {dns-server-object}, ... ]}`. Save via `saveDnsServers`.

Shape `dns-server-object` — sing-box native schema: `{"tag":"dns-google","type":"udp","server":"8.8.8.8"}` etc. **Не валидируем здесь** — sing-box сам скажет при reload'е; endpoint сугубо proxy.

##### `PUT /settings/dns_options/rules`
Body: `{"rules": "<json-string>"}`. Save via `saveDnsRules`.

##### `GET /settings/core_logs_enabled` / `PUT /settings/core_logs_enabled`
Toggle для sing-box log forwarding (раздел C). Body: `{"enabled": true|false}`. Storage — SharedPreferences `boxvpn_boot.core_logs_enabled`.

##### `POST /settings/rebuild-config`
Alias для `/action/rebuild-config`. Исключительно для удобства — чтобы после batch'а PUT/PATCH можно было сделать один вызов "применить все" без context switch'а.

Любой из `/settings/*`, `/rules/*`, `/subs/*` принимает `?rebuild=true` query — endpoint после успешного write триггерит `rebuild-config` и возвращает **расширенный** response:

```json
{"ok": true, "action": "rules-update", "id": "...", "rebuilt": true, "config_bytes": 71234}
```

Если rebuild свалился — `rebuilt: false` + `rebuild_error: "<msg>"`, статус всё равно 200 (write прошёл, rebuild — отдельная ошибка).

## A.12 Files — read-only file access

#### `GET /files/srs?ruleId=<id>`
Returns cached .srs file as `application/octet-stream` (binary dump).

#### `GET /files/srs/list`
```json
[{"ruleId":"...","size":128000,"mtime":"2026-04-20T10:05:00Z"}, ...]
```

#### `GET /files/local?name=<name>` (alias `GET /files/external?name=<name>`)
Read from internal app-scoped storage (`/data/data/<pkg>/files/<name>`, `getApplicationDocumentsDirectory()`). Whitelisted: `cache.db`, `stderr.log`, `applog.txt`, `corelog.txt`. До [task 027](../../tasks/027-libbox-init-race-fix.md) файлы лежали в external storage и хэндлер был `/files/external`; теперь internal по причине Knox/SELinux quirks на отдельных OEM. URL `/files/external` оставлен ради обратной совместимости с adb-скриптами.

## A.13 Diagnostics — `/diag/*`

> **Cross-ref:** Полная семантика — [Раздел B](#раздел-b--crash-diagnostics-was-038).

#### `GET /diag/dump`
Полный JSON-pack от [`DumpBuilder.build()`](../../../app/lib/services/dump_builder.dart) — то же что отдаёт UI `⤴ Share dump`: `config + vars + server_lists + debug_log + stderr_log + exit_info + logcat_tail`.

#### `GET /diag/exit-info`
Массив записей `ApplicationExitInfo` (последние 5 экзитов нашего pkg от Android-системы). На API <30 — пустой массив. Поля каждой записи: `timestamp`, `reason` (`CRASH | CRASH_NATIVE | ANR | LOW_MEMORY | SIGNALED | …`), `description`, `importance`, `pss`, `rss`, `status`, `trace` (mini-tombstone для NATIVE_CRASH или JVM stacktrace для CRASH).

#### `GET /diag/logcat?count=N&level=L`
Logcat tail нашего процесса. `count` — 50..5000 (default 1000), `level` — `V|D|I|W|E|F` (default `E`). UID-фильтрация автоматическая. `Content-Type: text/plain`.

#### `GET /diag/stderr`
Содержимое `filesDir/stderr.log` (Go panic stacktrace из libbox; пустой если краха не было). `Content-Type: text/plain`.

#### `GET /diag/applog?prev=true|false|all`
AppLog entries с фильтром по `fromPreviousSession`. Default `all`. Каждая запись: `time`, `source`, `level`, `message`, `prev_session: true` (опционально, только если флаг выставлен).

## A.14 Backup — `/backup/*`

Экспорт/импорт пользовательских данных без diag-шума.

#### `GET /backup/export?include=config,vars,subs`
Pure-data snapshot для restore. `include` опц. — default все три. Возвращает JSON `{app, kind, version, config?, vars?, server_lists?}`.

#### `POST /backup/import?merge=false&rebuild=false`
Body — JSON с любыми из `config`, `vars`, `server_lists`. `merge=false` (default) — replace; `merge=true` — append/upsert. `rebuild=true` после restore зовёт `rebuild-config`.

## A.15 Action: preview-empty-state

#### `POST /action/preview-empty-state?on=true|false`
UI-only override: `HomeScreen` рендерит empty-state как при чистой инсталляции. См. [task 025](../../tasks/025-preview-empty-state.md).

## A.16 Navigation (optional MVP+1)

#### `POST /nav/home|routing|subs|settings|stats|debug|speed_test`
Pushes/replaces to the named screen.

#### `GET /nav/route`
Returns current route name.

## A.17 UI — App Settings → Developer

Toggle в `app_settings_screen.dart` Developer section: enable Debug API, port input, token field с Copy и Regenerate, endpoint preview.

Toggle on → генерируется токен (32-hex через `Random.secure()`), сохраняется в `SettingsStorage`, `DebugServer.start()`. Токен никуда, кроме storage, не пишется.
Toggle off → `stop()`. Токен остаётся в storage.
Regenerate → новый токен, все сохранённые curl-команды идут в 401.
Port change → валидируется (1024–65535), сохраняется в `debug_port`; если сервер сейчас запущен → restart на новом порту.

## A.18 Storage keys

| Key | Тип | Default | Назначение |
|-----|-----|---------|-----------|
| `debug_enabled` | String | `"false"` | Toggle state |
| `debug_token` | String | `""` | Persisted token (32 hex) |
| `debug_port` | String | `"9269"` | Port (tweakable в UI) |

## A.19 Безопасность

1. **Bind 127.0.0.1** — не LAN, не 0.0.0.0. **Важное уточнение:** Android **не изолирует loopback между приложениями** — любой процесс на устройстве может открыть TCP на `127.0.0.1:9269`. Защита — только auth token.
2. **Toggle default OFF** — ничего не слушает пока юзер явно не включит.
3. **Auth token обязателен** — 32-hex random.
4. **Write-доступ через explicit allowlist** — `/settings/vars/{key}` запрещает `debug_*` (self-lockout).
5. **Clash secret не светится по умолчанию** — только через `/state/clash?reveal=true`.
6. **Host header check** — middleware рефьюзит запросы с `Host != 127.0.0.1|localhost` (403). Защита от DNS rebinding.
7. **Токен только в UI** — не пишется ни в internal-файлы, ни в `/sdcard/`.
8. **Log masking** — токен никогда не светится в `/logs`.

## A.20 Acceptance (Раздел A)

См. оригинальный [§031 spec.md](../031%20debug%20api/spec.md) — checkpoints 1-30 (App Settings toggle, ping без auth, Host check, auth required, /state, /state/clash, /device, /action/toast, port change restart, /clash/proxies, /clash/group/delay, /action/run-urltest, /action/rebuild-config, /logs, /config, toggle off connection-refused, regenerate, CI release behavior, /rules CRUD, /subs CRUD, /settings/* PUT с blocklist, /config PUT >64KB, ?rebuild=true).

---

# Раздел B — Crash diagnostics (was §038)

> **Статус:** done (MVP1 + MVP2). Был отдельный spec [§038](../038%20crash%20diagnostics/spec.md), теперь живёт здесь.

## B.1 Цель

Дать пользователю однокнопочный путь отдать stacktrace последней сессии VPN core разработчику, без `adb`. Главный кейс — нативный краш sing-box / libbox при старте VPN, когда процесс умирает SIGABRT'ом и in-memory `AppLog` теряется.

**Не в скопе:**
- Tombstone parsing / pretty-print — текстом разбирается на стороне разработчика.
- Внешние сервисы (Crashlytics / Sentry / breakpad) — никогда; локально, off-line.
- Retention / UI-список крашей / автоматический snackbar «Previous session crashed».

## B.2 Архитектура — четыре канала

| Канал | Что ловит | Где переживает смерть процесса |
|---|---|---|
| **A. stderr-redirect** | Go panic stacktrace из libbox/sing-box — всё что Go runtime пишет в stderr перед SIGABRT'ом | `filesDir/stderr.log` |
| **B. ApplicationExitInfo** (API 30+) | native SIGABRT/SIGSEGV, JVM Throwable, ANR, LMK; tombstone в `traceInputStream` для NATIVE_CRASH; Java stacktrace для CRASH (на некоторых OEM пуст) | в Android-системе, читается ленивым запросом из `DumpBuilder` |
| **C. Persistent AppLog** | warning + error JVM-events до краха (что приложение делало в моменте) | `filesDir/applog.txt` + `corelog.txt` (per-source, см. Раздел C), ring-buffer ~200 строк каждый |
| **D. Logcat tail** | system-level логи нашего процесса: `AndroidRuntime FATAL EXCEPTION` (Java throwable), `libc`/`DEBUG`/`tombstoned` (native signal+backtrace), `art`/`linker` (class-load failures) | kernel circular buffer, читается через `Runtime.exec("logcat -d")` |

`A` ловит Go panic, но только если процесс дожил до `Libbox.redirectStderr`. `B` ловит то что убило процесс уровнем системы. `C` ловит JVM-сторону — что мы делали. `D` — независимый источник от B (logd — kernel-buffer, AEI — ActivityManager); полезен на API <30 где B недоступен. Вместе закрывают post-mortem без `adb`.

## B.3 Канал A — stderr viewer

### Контракт `Libbox.redirectStderr`

Подключён в [`BoxApplication.initializeLibbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt):

- При вызове `Libbox.redirectStderr(path)` Go runtime через `dup2(file_fd, STDERR_FILENO)` перенаправляет свой stderr в указанный файл.
- При panic'е без `recover()` Go runtime пишет полный multi-goroutine stacktrace в stderr **до** SIGABRT'а.
- Файл — `Context.filesDir / stderr.log` (= `/data/data/<pkg>/files/stderr.log`), internal app-scoped storage.

### История крашей не накапливается

Намеренно: показываем только последнюю сессию. Никаких `.old`-копий, ротации, retention. Цель — закрыть текущий инцидент.

### Чтение из Dart

`lib/services/stderr_reader.dart`:

```dart
class StderrReader {
  static Future<String?> read();   // null если файл отсутствует/пуст
  static Future<String?> path();   // путь или null
}
```

### UI

[`Debug-экран`](../../../app/lib/screens/debug_screen.dart) — на `initState` async читает stderr; если непустой → `DefaultTabController(length: 2)` с `TabBar`:

- **Log** — events с фильтрами/search/share-dump.
- **stderr** — `SelectableText` (monospace) + Refresh + Share.

Если файл пустой — без TabBar.

### Share

Два пути:

1. **Кнопка Share на вкладке stderr** — отдаёт `stderr.log` через `share_plus`.
2. **Кнопка Share dump (⤴ AppBar)** — `DumpBuilder.build()` включает поле `stderr_log` в JSON-pack.

## B.4 Канал B — ApplicationExitInfo

Native MethodChannel-метод `getApplicationExitInfo` в [`VpnPlugin`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt):

- На API <30 — возвращает пустой массив.
- На API 30+ — `ActivityManager.getHistoricalProcessExitReasons(packageName, 0, 5)` → массив структур: `timestamp`, `reason` (mapped в `CRASH | CRASH_NATIVE | ANR | LOW_MEMORY | …`), `description`, `importance`, `pss`, `rss`, `status`, `trace` (`traceInputStream` целиком в string).

Зовётся **только из `DumpBuilder.build()`**. Ленивое: пользователь жмёт ⤴ Share dump → дамп включает поле `exit_info: [...]`.

## B.5 Канал C — Persistent AppLog (file-backed ring-buffer)

> **Cross-ref:** После рефактора в [Раздел C](#раздел-c--applog-per-source-quotas--core-logs-pump-original-043) persist split на два файла per source.

В [`AppLog`](../../../app/lib/services/app_log.dart) добавляется persistence для **только warning + error** уровней. `debug`/`info` остаются in-memory.

- **Файлы**: `filesDir/applog.txt` (для app source) + `filesDir/corelog.txt` (для core source), JSON-lines.
- **Cap**: 200 entries или ~64KB на файл — что меньше.
- **Write**: async через `Future.microtask` с debounce-флагом; при каждом новом warning/error планируется rewrite файла.
- **Read**: на старте `main()` зовётся `AppLog.I.initPersistent()` → entries из обоих файлов кладутся в `_entriesBySource` с маркером `fromPreviousSession=true`.

UI `debug_screen.dart` — entries с `fromPreviousSession=true` визуально отделены (subtitle-тег «← prev session», италик).

`DumpBuilder.debug_log` автоматически содержит и persistent, и live entries.

## B.6 Канал D — Logcat tail

Native MethodChannel `getLogcatTail` в `VpnPlugin` — `Runtime.exec("logcat", "-d", "-t", count, "*:level")` через `ProcessBuilder` с timeout 2s.

`logd` UID-фильтрует автоматически — без `READ_LOGS` permission читатель получает только события собственного UID. Permission не запрашивается.

[`LogcatReader.tail()`](../../../app/lib/services/logcat_reader.dart) Dart-сервис, зовётся из `DumpBuilder.build()` → поле `logcat_tail: String?`. Default — последние 1000 строк уровня Error+Fatal.

## B.7 Безопасность (Раздел B)

- AEI tombstone — безопасно (memory addresses, регистры, имена SO; user-data нет).
- `applog.txt` / `corelog.txt` — warning/error что юзер и так видит в Debug-экране. Маскирование URL-секретов уже работает.
- Logcat — UID-фильтрован logd'ом, только наш процесс.
- Stderr содержит имена outbound'ов и иногда host'ы; **пароли — нет** (Go panic пишет stack-frames, не входной JSON).

## B.8 Сводка реализации

| Канал | Status | Tasks |
|---|---|---|
| A (stderr viewer) | done | [018](../../tasks/018-stderr-viewer-debug-tab.md) |
| B (ApplicationExitInfo) | done | [029](../../tasks/029-application-exit-info.md) |
| C (Persistent AppLog) | done | [028](../../tasks/028-persistent-applog.md), расширен в [Раздел C](#раздел-c--applog-per-source-quotas--core-logs-pump-original-043) |
| D (Logcat tail) | done | [022](../../tasks/022-logcat-tail-in-dump.md) |
| HTTP API `/diag/*` | done | см. [Раздел A.13](#a13-diagnostics--diag) |

---

# Раздел C — AppLog per-source quotas + core logs pump (original §043)

> **Статус:** done. Триггер: при диагностике bug-репортов sing-box-side детали недоступны — `writeDebugMessage` forward в мёртвый Clash channel, в наш `AppLog` ничего не попадало.

## C.1 Цель

Видеть подробные sing-box-логи через **наш** Debug API endpoint `/logs?source=core` (или новый shortcut `/logs/core`), для диагностики реальных проблем транспорта. При этом не дать verbose'ному sing-box'у вытеснить наши собственные app-сообщения из ring buffer'а — раздельные quotas на каждый source.

## C.2 Архитектурные решения

### Проблема `commandServer.writeMessage(0, message)` сейчас

Текущий `writeDebugMessage` override:
```kotlin
override fun writeDebugMessage(message: String) {
    commandServer?.writeMessage(0, message)
}
```

Это **forward в никуда**: `commandServer.writeMessage` доставляет сообщение subscriber'ам Clash API через Unix-socket. У нас этих subscriber'ов нет — мы единственный клиент Clash API (используем для `fetchTraffic`, `fetchProxies`, `selectInGroup`, и т.п. — все simple HTTP requests, не /logs WebSocket). Это был copy-paste из примера sing-box-android.

**Удаляем строку.**

### Куда писать вместо

В наш `AppLog` через EventChannel `lxbox/coreLog`:
```
sing-box log line
   ↓
PlatformInterface.writeDebugMessage(message)        ← Kotlin override
   ↓
EventChannel("lxbox/coreLog").send(message)         ← bridge to Flutter
   ↓
ClashLogPump.start() в Dart                         ← подписан на event channel
   ↓
AppLog.I.log(level: parsed, source: core, message)
   ↓
доступно через GET /logs?source=core / GET /logs/core
```

Sing-box формат:
```
+0300 2026-05-06 12:34:56 INFO  router: rule[0]: ...
+0300 2026-05-06 12:34:56 WARN  outbound/vless[vpn-1]: dial failed: i/o timeout
```

Level извлекается substring search'ем (5 уровней — `TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`FATAL`/`PANIC`, сводим к нашим 4 — `debug`/`info`/`warning`/`error`).

### `AppLog` refactor: per-source map

Текущий `AppLog._entries: List<DebugEntry>` единый для всех источников. Один cap `_maxEntries = 500`. Если sing-box (verbose, сотни строк/мин на busy traffic) пушит в общий buffer — наши собственные app-сообщения вытесняются за минуты.

Переходим на **per-source map**:

```dart
class AppLog {
  static const Map<DebugSource, int> _maxEntriesPerSource = {
    DebugSource.app:  300,
    DebugSource.core: 500,
  };

  final Map<DebugSource, List<DebugEntry>> _entriesBySource = {
    for (final s in DebugSource.values) s: <DebugEntry>[],
  };

  void log(DebugLevel level, String message, {DebugSource source = DebugSource.app}) {
    final list = _entriesBySource[source]!;
    list.insert(0, DebugEntry(...));
    final cap = _maxEntriesPerSource[source]!;
    if (list.length > cap) {
      list.removeRange(cap, list.length);
    }
    notifyListeners();
  }
}
```

**Insert — O(1) amortized**.
**Source A не вытесняет source B** — независимые ring buffer'ы.
**Расширение на k источников** — добавление одной entry в map.

### Read pattern: merge на чтение, не на write

```dart
/// Все entries отсортированные по времени (newest first).
List<DebugEntry> get entries => _mergeByTime(_entriesBySource.values);

/// Source-filtered — без merge'а, direct lookup.
List<DebugEntry> entriesForSource(DebugSource source) {
  return List.unmodifiable(_entriesBySource[source]!);
}
```

Каждый source-list уже sorted desc (insert(0)). Merge — k-way merge sort. Для k=2 sources × 800 entries = ~2000 операций. Микросекунды.

**Filter by source через `entriesForSource(s)` — O(1)**, без merge'а.

### Persistent: два файла, две quota

| Source | File | Cap lines | Cap bytes |
|---|---|---|---|
| `app`  | `applog.txt`  | 200 | 64 KB |
| `core` | `corelog.txt` | 200 | 64 KB |

Каждый файл — независимый ring buffer. Total worst case ~128 KB на диске.

`initPersistent()` грузит **оба** файла на старте, помечает entries `fromPreviousSession: true`. Используется в [Раздел B](#раздел-b--crash-diagnostics-was-038) для post-mortem диагностики.

При log warn/error → пишет в `_persistFileNames[source]`. Только warn/error persist'ятся.

### Migration существующих `applog.txt`

Существующий `applog.txt` на устройствах юзеров содержит фактически только app warn/error (мы core ещё не пушили). На первом запуске после апгрейда:
1. `initPersistent()` читает `applog.txt` → грузит как `DebugSource.app` (правильно).
2. `corelog.txt` ещё не существует → skip без error.
3. Дальше core warn/error пишутся в `corelog.txt` (создаётся на первом core warn/error).

Никакой data loss, никакой migration logic не нужна.

## C.3 Реализация

### Kotlin side

**`BoxVpnService.kt`:**

```kotlin
override fun writeDebugMessage(message: String) {
    // §043: removed commandServer.writeMessage(0, message) — мёртвый forward.
    // Strip ANSI + filter TRACE/DEBUG + post on main looper.
    val stripped = message.replace(ansiRegex, "")
    if (traceDebugRegex.containsMatchIn(stripped)) return
    coreLogMainHandler.post {
        coreLogSink?.success(stripped)
    }
}

@Volatile companion object {
    var coreLogSink: EventChannel.EventSink? = null
}
```

**`VpnPlugin.kt` — register EventChannel:**

```kotlin
private var coreLogChannel: EventChannel? = null

override fun onAttachedToEngine(binding: FlutterPluginBinding) {
    coreLogChannel = EventChannel(binding.binaryMessenger, "lxbox/coreLog")
    coreLogChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            BoxVpnService.coreLogSink = sink
        }
        override fun onCancel(args: Any?) {
            BoxVpnService.coreLogSink = null
        }
    })
}
```

`coreLogSink` — `@Volatile` field в companion object `BoxVpnService`. `EventSink.success()` требует main thread (`@UiThread` annotation), поэтому `Handler(Looper.getMainLooper()).post { ... }` обязателен — sing-box зовёт `writeDebugMessage` из своих Go goroutine'ов на background.

### Dart side

**`lib/services/clash_log_pump.dart`** (new file):

```dart
class ClashLogPump {
  ClashLogPump._();
  static final ClashLogPump I = ClashLogPump._();

  static const _channel = EventChannel('lxbox/coreLog');
  StreamSubscription? _sub;

  void attach() {
    _sub = _channel.receiveBroadcastStream().listen((event) {
      if (event is! String) return;
      final level = _parseLevel(event);
      AppLog.I.log(level, event, source: DebugSource.core);
    });
  }

  void dispose() => _sub?.cancel();

  /// Парсит sing-box формат: `+0300 2026-05-06 12:34:56 INFO  ...`
  /// Использует word-boundary regex (формат после ANSI strip может быть `INFO[0006]` без пробела).
  static DebugLevel _parseLevel(String line) {
    if (RegExp(r'\b(ERROR|FATAL|PANIC)\b').hasMatch(line)) return DebugLevel.error;
    if (RegExp(r'\bWARN\b').hasMatch(line))  return DebugLevel.warning;
    if (RegExp(r'\bINFO\b').hasMatch(line))  return DebugLevel.info;
    if (RegExp(r'\b(DEBUG|TRACE)\b').hasMatch(line)) return DebugLevel.debug;
    return DebugLevel.info;
  }
}
```

### Debug API endpoints

См. [Раздел A.8](#a8-эндпоинты--logs) — `/logs/app`, `/logs/core`, `/logs/clear?source=`.

### `main.dart` wire'инг

```dart
// после AppLog.I.initPersistent():
ClashLogPump.I.attach();
```

## C.4 Tests

### `test/services/app_log_test.dart`

1. **log записывает в правильный source bucket**
2. **per-source quota** — push 350 app entries → trim до 300, core touched=0
3. **per-source quota independence** — push 500 app + 600 core → app=300, core=500
4. **`entries` merged by time** — newest first глобально
5. **`entriesForSource(s)`** — direct lookup
6. **clear()** — все source-buckets

### `test/services/clash_log_pump_test.dart`

1. **_parseLevel WARN** → DebugLevel.warning
2. **_parseLevel ERROR/FATAL/PANIC** → DebugLevel.error
3. **_parseLevel INFO** → DebugLevel.info
4. **_parseLevel DEBUG/TRACE** → DebugLevel.debug
5. **fallback** → DebugLevel.info

### `test/services/app_log_persist_test.dart`

1. **persist split: app warn/error → applog.txt, core warn/error → corelog.txt**
2. **persist не пишет debug/info**
3. **initPersistent грузит оба файла**
4. **persist cap per file**
5. **persist миграция** — старый applog.txt с mixed entries → грузим как app

## C.5 Implementation gotchas (Раздел C)

При имплементации §043 встретилась цепочка из **четырёх** последовательных root cause'ов — каждый блокировал следующий.

1. **`SetupOptions.debug` default false → `writeDebugMessage` callback не зовётся.** В sing-box `daemon/started_service.go:1048` есть gate `if s.debug { s.handler.WriteDebugMessage(message) }`. Без `debug = true` в `Libbox.setup(opts)` платформенный callback **не получает ни одной строки**.

2. **`EventChannel.EventSink.success()` требует main thread.** Sing-box зовёт `writeDebugMessage` из своих Go goroutine'ов на background. Прямой вызов `coreLogSink.success(message)` бросает `@UiThread` exception → sing-box ловит через JNI → интерпретирует как failure при `openTun` → tunnel падает на старте. Fix: `coreLogMainHandler.post { sink.success(...) }`.

3. **ANSI escape codes ломают level parsing.** Sing-box default formatter вставляет terminal-цвета: `\x1b[36mINFO\x1b[0m`. Без strip'а regex `\bINFO\b` не матчит. Fix: regex strip `Regex("\\x1b\\[[0-9;]*[A-Za-z]")` перед всеми проверками.

4. **Filter `" TRACE "` (с пробелами) не сработал.** После strip'а ANSI получается `TRACE[0017]` — без пробела перед `[`. Fix: word-boundary regex `Regex("\\b(TRACE|DEBUG)\\b")`. То же для `parseLevel` в Dart — расширил с `' INFO '` substring до regex `\bINFO\b`.

## C.6 Toggle для core logs forwarding

`debug = true` всегда — нерационально (volume на busy traffic + лишние JNI roundtrip'ы для юзеров которые core логи не смотрят). Runtime-toggle:

- **Единственная точка переключения:** App Settings → Diagnostics tab → Switch "Forward sing-box logs". Default false.
- **Shortcut в DebugScreen:** в 3-точечном popup-меню AppBar'а пункт "Diagnostics settings" (`Icons.tune`) — открывает `AppSettingsScreen(initialTab: 2)`. **На самом DebugScreen toggle'а нет** — чтобы не дублировать состояние.
- **Через Debug API:** `GET/PUT /settings/core_logs_enabled` — для adb-сценариев.

Storage в `SharedPreferences("boxvpn_boot")` как `core_logs_enabled` ключ — потому что `BoxApplication.initialize` читает значение **до** Flutter engine'а готовности (нельзя ходить в `lxbox_settings.json` через path_provider в этот момент). Изменение применяется после restart Service'а (`Libbox.setup` зовётся один раз на process'е).

### Restart-required UX hint

Toggle не «магический» — `SetupOptions.debug` читается на старте процесса и не меняется на лету. Без явного сигнала юзер мог переключить switch и потом долго недоумевать «почему core пустой». Чтобы убрать эту fragility:

- **При смене toggle** в App Settings → Diagnostics показывается hint / snackbar `"Restart app to apply"` (или эквивалент). Обязательная UX-часть — без неё switch выглядит broken.
- **Применение** — пользователь делает full app restart (kill + relaunch) либо Force Stop через системные настройки. `BoxApplication.initialize` при следующем старте process'а перечитывает SharedPreferences и applies `debug` flag в `Libbox.setup(opts)`.
- **VPN reconnect недостаточно** — Flutter `BoxApplication.initialize` зовётся один раз на process; перезапуск Service'а в рамках того же process'а не пере-инициализирует libbox.

## C.7 Что не в скопе

- WebSocket streaming `/logs` endpoint — sse/ws stream'инг для live-tail.
- Структурированные core логи — sing-box формат остаётся plain string.
- Per-source UI tabs в DebugScreen — пока merged view.
- Configurable quotas через App Settings — пока compile-time константы.
- Throttling sing-box flood — митигация через filter уровня в Kotlin (debug/trace не пушим вообще).

---

## Файлы (actual layout)

### Раздел A — Debug API

```
lib/services/debug/
  debug_server.dart, debug_registry.dart, context.dart, bootstrap.dart
  contract/errors.dart
  transport/{server,config,request,response,router,pipeline}.dart
  transport/middleware/{host_check,auth,access_log,error_mapper,timeout}.dart
  handlers/{ping,state,device,config,logs,clash,action,files,rules,subs,settings,diag,backup,nav}.dart
  serializers/{home_state,subs,rules,storage}.dart
```

### Раздел B — Crash diagnostics

```
lib/services/{stderr_reader,logcat_reader,dump_builder}.dart
android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/{BoxApplication,VpnPlugin}.kt
  ↑ getApplicationExitInfo, getLogcatTail, redirectStderr
```

### Раздел C — AppLog per-source + core forwarding

```
lib/services/app_log.dart                  — refactored на per-source map + dual persist
lib/services/clash_log_pump.dart           — EventChannel "lxbox/coreLog" subscriber
android/.../BoxVpnService.kt               — coreLogSink @Volatile + ANSI strip + main-thread post
android/.../VpnPlugin.kt                   — EventChannel "lxbox/coreLog" registration
android/.../BoxApplication.kt              — SetupOptions.debug = BootReceiver.isCoreLogsEnabled()
android/.../BootReceiver.kt                — KEY_CORE_LOGS = "core_logs_enabled"
lib/screens/app_settings_screen.dart       — Diagnostics tab (initialTab=2)
lib/screens/debug_screen.dart              — ⋮ menu shortcut "Diagnostics settings"
```

## Docs to update

См. постоянную карту в [`docs/spec/README.md → Карта обновления документации`](../../README.md#карта-обновления-документации).

| Файл | Что добавить | Статус |
|---|---|---|
| [`docs/api/debug-api-reference.md`](../../../api/debug-api-reference.md) | Все endpoints из Раздела A + `/logs/app`, `/logs/core` per-source aliases (Раздел C). `GET/PUT /settings/core_logs_enabled`. `/action/reset-network`. | ✅ Done |
| [`CHANGELOG.md`](../../../../CHANGELOG.md) | Entry в `Unreleased`: per-source quotas + sing-box logs forwarding + новые endpoints + toggle. | ✅ Done |
| [`docs/ARCHITECTURE.md`](../../../ARCHITECTURE.md) | Section про AppLog: per-source map structure + k-way merge + dual persist files + ClashLogPump data flow. | ✅ Done |
| [`RELEASE_NOTES.md`](../../../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../../../releases/) | На bump'е версии. | ⏳ Deferred till release |
| [`pubspec.yaml`](../../../../app/pubspec.yaml) | Patch bump (1.6.0 → 1.6.1) в release-batch'е. | ⏳ Deferred till release |
| [`docs/DEVELOPMENT_REPORT.md`](../../../DEVELOPMENT_REPORT.md) | Опционально — нарратив. | ⏳ Optional |

## Acceptance (полный)

См. оригинальные spec'и:
- [§031 Acceptance](../031%20debug%20api/spec.md) — раздел A (HTTP API endpoints)
- [§038 Sумma реализации](../038%20crash%20diagnostics/spec.md) — раздел B (4 канала)
- Раздел C tests выше (C.4)

Дополнительно для consolidation:
- [x] §031 spec.md содержит stub со ссылкой на §043
- [x] §038 spec.md содержит stub со ссылкой на §043
- [x] memory/project_features_status.md отражает консолидацию
- [x] CHANGELOG / ARCHITECTURE — без изменений (уже ссылаются на §043 в актуальных entry'ях)
