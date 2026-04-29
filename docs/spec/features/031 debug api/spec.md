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
- Web UI — только JSON endpoints
- Не-adb-доступ (LAN / remote) — bind строго на 127.0.0.1

**Scope writes:** чтение состояния, проксирование Clash API, триггеры (ping/urltest/rebuild/refresh)
плюс **CRUD на доменные ресурсы** — custom rules, subscriptions, scoped SettingsStorage writes,
прямой override сохранённого sing-box конфига. Детально — раздел
[CRUD endpoints](#crud-endpoints--доменные-мутации).

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
    logs.dart, clash.dart, action.dart, files.dart,
    rules.dart, subs.dart, settings.dart      — CRUD на доменные ресурсы

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

#### `PUT /config` (body: raw sing-box JSON)

Прямой override сохранённого конфига — минуя `buildConfig(...)`, подписки, custom rules, вообще всё. Body = любой валидный JSON объект. Вызывает `HomeController.saveParsedConfig(raw)`, что пишет на диск + reload'ит TUN если VPN запущен.

Зачем: тестить руками кастомные поля в `dns.rules`, pre-computed outbounds, изменения, которые нет в UI wizard'е. После перегенерации через `/action/rebuild-config` всё сотрётся — это **временный override**, не персистится в settings.

**Quirk:** размер бандл-конфига L×Box обычно 70-200 KB — дефолтный `maxBodyBytes=64KB` не хватит. Config-path имеет override до **1 MiB**.

Ответ: `{"ok": true, "action": "config-put", "bytes": N, "reloaded": true|false}`.

Предусловия:
- JSON-body должен парситься. Невалидный → 400.
- Если `tunnel_up == true` — пытаемся reload TUN через `home.restartWithConfig`; фейл reload → 502.

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

### CRUD endpoints — доменные мутации

Чтения через `/state/*` дают snapshot; **мутировать** тот же домен (правила, подписки, настройки) можно только через UI — это делает автотестирование изменений невозможным без AOT-ребилда. Блок ниже закрывает CRUD на:

1. **Custom rules** (`/rules/*`) — create / update / delete / reorder.
2. **Subscriptions** (`/subs/*`) — add / update meta / change URL / delete / reorder / refresh single.
3. **Settings storage** (`/settings/*`) — scoped writes на `route_final`, `excluded_nodes`, `vars/<key>`, `dns_options`.
4. **Direct sing-box config override** — уже описано выше (`PUT /config`).

Все CRUD endpoints возвращают либо `{"ok": true, "action": "<name>", ...extras}` (если результат асимметричен Create/Delete), либо полный созданный/изменённый ресурс (при GET-after-write pattern'е на Create). Ошибки — стандартные `DebugError`'ы.

**После любой мутации** config в sing-box не меняется автоматически. Чтобы применить — `POST /action/rebuild-config`. Либо вызов с query `?rebuild=true` — endpoint'ы CRUD поддерживают это как удобный shortcut (эквивалент `rebuild-config` сразу после изменения).

Write-rate limit: встроенного нет. adb-forward single-user → rate-limit не нужен; если потенциально появится remote-доступ, добавим токен-bucket в `middleware/ratelimit.dart`.

---

#### Rules — `/rules/*`

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

---

#### Subscriptions — `/subs/*`

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

- `url` переписывается **только для SubscriptionServers**; для UserServer `url` игнорируется (или 400?). Берём "silently ignored" для консистентности с UI-переименованиями.
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

---

#### Settings storage — `/settings/*`

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
Body: `{"rules": "<json-string>"}`. Save via `saveDnsRules`. Шторы: в storage лежит именно JSON-строка (legacy-shape), **не массив** — это отражение текущей реализации, не меняем.

##### `POST /settings/rebuild-config`
Alias для `/action/rebuild-config`. Исключительно для удобства — чтобы после batch'а PUT/PATCH можно было сделать один вызов "применить все" без context switch'а.

---

Любой из `/settings/*`, `/rules/*`, `/subs/*` принимает `?rebuild=true` query — endpoint после успешного write триггерит `rebuild-config` и возвращает **расширенный** response:

```json
{"ok": true, "action": "rules-update", "id": "...", "rebuilt": true, "config_bytes": 71234}
```

Если rebuild свалился — `rebuilt: false` + `rebuild_error: "<msg>"`, статус всё равно 200 (write прошёл, rebuild — отдельная ошибка).

---

### Files — read-only file access

#### `GET /files/srs?ruleId=<id>`
Returns cached .srs file as `application/octet-stream` (binary dump).

#### `GET /files/srs/list`
```json
[{"ruleId":"...","size":128000,"mtime":"2026-04-20T10:05:00Z"}, ...]
```

#### `GET /files/local?name=<name>` (alias `GET /files/external?name=<name>`)
Read from internal app-scoped storage (`/data/data/<pkg>/files/<name>`, `getApplicationDocumentsDirectory()`). Whitelisted: `cache.db`, `stderr.log`. До [task 027](../../tasks/027-libbox-init-race-fix.md) файлы лежали в external storage и хэндлер был `/files/external`; теперь internal по причине Knox/SELinux quirks на отдельных OEM (Samsung One UI 3.x на A50, EMUI на Y9). URL `/files/external` оставлен ради обратной совместимости с adb-скриптами.

---

### Diagnostics — `/diag/*` (§038)

Группа endpoints для забора crash-diagnostics-output'а через HTTP без UI. Полная семантика — в [`§038`](../038%20crash%20diagnostics/spec.md).

#### `GET /diag/dump`
Полный JSON-pack от [`DumpBuilder.build()`](../../../app/lib/services/dump_builder.dart) — то же что отдаёт UI `⤴ Share dump`: `config + vars + server_lists + debug_log + stderr_log + exit_info + logcat_tail`.

#### `GET /diag/exit-info`
Массив записей `ApplicationExitInfo` (последние 5 экзитов нашего pkg от Android-системы). На API <30 — пустой массив. Поля каждой записи: `timestamp`, `reason` (`CRASH | CRASH_NATIVE | ANR | LOW_MEMORY | SIGNALED | …`), `description`, `importance`, `pss`, `rss`, `status`, `trace` (mini-tombstone для NATIVE_CRASH или JVM stacktrace для CRASH).

#### `GET /diag/logcat?count=N&level=L`
Logcat tail нашего процесса. `count` — 50..5000 (default 1000), `level` — `V|D|I|W|E|F` (default `E`). UID-фильтрация автоматическая (logd сам отдаёт только наши события + связанные system messages). `Content-Type: text/plain`.

#### `GET /diag/stderr`
Содержимое `filesDir/stderr.log` (Go panic stacktrace из libbox; пустой если краха не было). `Content-Type: text/plain`. Эквивалент `GET /files/local?name=stderr.log`, но через `/diag/*` группу для консистентности.

#### `GET /diag/applog?prev=true|false|all`
AppLog entries с фильтром по `fromPreviousSession`. Default `all`. Каждая запись: `time`, `source`, `level`, `message`, `prev_session: true` (опционально, только если флаг выставлен).

---

### Backup — `/backup/*`

Экспорт/импорт пользовательских данных без diag-шума. См. [task 026](../../tasks/026-backup-export-import.md).

#### `GET /backup/export?include=config,vars,subs`
Pure-data snapshot для restore. `include` опц. — default все три. Возвращает JSON `{app, kind, version, config?, vars?, server_lists?}`. Кеши/диагностические поля **не включаются** (cache.db, stderr.log, SRS-blob, runtime node-tags) — restore их пересоздаст из URL подписок.

#### `POST /backup/import?merge=false&rebuild=false`
Body — JSON с любыми из `config`, `vars`, `server_lists`. Совместим с `/diag/dump` (поля `debug_log`/`stderr_log`/`exit_info`/`logcat_tail` игнорируются). `merge=false` (default) — replace; `merge=true` — append/upsert. `rebuild=true` после restore зовёт `SubscriptionController.generateConfig` и сохраняет в HomeState (эквивалент `POST /action/rebuild-config`). Returns `{"applied": {"config": bool?, "vars": N?, "server_lists": N?, "rebuilt": bool?}}`.

---

### Action: preview-empty-state

#### `POST /action/preview-empty-state?on=true|false`
UI-only override: `HomeScreen` рендерит empty-state как при чистой инсталляции (`Add a server` CTA вместо узлов и Start), реальные данные `HomeController.state` не трогаются. Полезно для скриншотов / regression-теста UX без `pm clear` и потери подписок. См. [task 025](../../tasks/025-preview-empty-state.md).

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
| `handlers/rules.dart` | `GET /rules`, `POST /rules`, `PATCH /rules/{id}`, `DELETE /rules/{id}`, `POST /rules/reorder` |
| `handlers/subs.dart` | `GET /subs`, `POST /subs`, `PATCH /subs/{id}`, `DELETE /subs/{id}`, `POST /subs/{id}/refresh`, `POST /subs/reorder` |
| `handlers/settings.dart` | `PUT /settings/{route_final,excluded_nodes}`, `PUT/DELETE /settings/vars/{key}`, `PUT /settings/dns_options/{servers,rules}`, `POST /settings/rebuild-config` |
| `handlers/files.dart` | `/files/srs`, `/files/srs/list`, `/files/local` (`/files/external` — legacy alias) |
| `handlers/diag.dart` | `/diag/dump`, `/diag/exit-info`, `/diag/logcat`, `/diag/stderr`, `/diag/applog` (см. [§038](../038%20crash%20diagnostics/spec.md)) |
| `handlers/backup.dart` | `GET /backup/export`, `POST /backup/import` |
| `handlers/config.dart` (extended) | ...`PUT /config` — direct override с bump'ом `maxBodyBytes` до 1 MiB для `/config` path'а |

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
4. **Write-доступ к storage через explicit allowlist** — `/settings/vars/{key}` запрещает запись/удаление для `debug_token`, `debug_enabled`, `debug_port` (иначе юзер сможет заблокировать самому себе доступ). Остальные vars — свободно. `/settings/{route_final,excluded_nodes,dns_options}` — scoped writes (не generic `setVar`). Files — read-only.
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
- [ ] `POST /rules` с валидным body создаёт правило, возвращает 201 + `id`. Оно появляется в `GET /state/rules`.
- [ ] `PATCH /rules/{id}` с `{"enabled": false}` меняет флаг, остальные поля сохраняются.
- [ ] `DELETE /rules/{id}` удаляет; повторный DELETE → 404.
- [ ] `POST /rules/reorder` с неполным списком ID → 400 `bad_request`; с корректным — меняет порядок.
- [ ] `POST /subs` с subscription URL — подписка создаётся, автоматически fetch'ится в фоне (проверяется в `/state/subs`).
- [ ] `PATCH /subs/{id}` с `{"enabled": false}` выключает; с `{"url": "https://new/"}` меняет URL для SubscriptionServers (UserServer игнорирует).
- [ ] `POST /subs/{id}/refresh` на SubscriptionServers — триггер refresh'а (202-like ok ответ, реально `/state/subs.last_update_status` становится `inProgress`).
- [ ] `POST /subs/{id}/refresh` на UserServer → 409 `conflict`.
- [ ] `DELETE /subs/{id}` удаляет подписку.
- [ ] `PUT /settings/vars/{key}` для произвольного `key` — сохраняет; для `debug_token`/`debug_enabled`/`debug_port` → 403 `forbidden`.
- [ ] `PUT /settings/route_final` с `{"outbound":"direct-out"}` — сохраняет; `GET /state/storage.route_final` отражает.
- [ ] `PUT /settings/excluded_nodes` — replace set, не merge.
- [ ] `PUT /config` с валидным JSON (>64KB) — принимает (не 413), `config_length` обновляется в `/state`.
- [ ] `PUT /config` с невалидным JSON → 400.
- [ ] `?rebuild=true` на любом CRUD endpoint'е после write'а триггерит rebuild-config; response включает `rebuilt: true` + `config_bytes`.

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
| CRUD write'ы через API изменяют persistent state (`custom_rules`, `server_lists`, `vars`) — баг в handler'е может corrupt'ить storage, сделав app неработоспособным | (1) Каждый write идёт через существующие controller/storage методы (не raw `_cache` мутация) — те же gate'ы что и UI. (2) Blocklist для `debug_*` ключей защищает от self-lockout. (3) После любой мутации `configDirty=true`, генерация нового sing-box config откладывается до явного `rebuild-config` — не ломаем running TUN случайно. (4) Все CRUD require Bearer auth + host check. |
| Write-флуд API'и перегружает disk I/O (`SettingsStorage._save` пишет файл целиком) | MVP — rate-limit'а нет, single-user через adb. Если появится concurrent use — добавить `middleware/ratelimit.dart` с токен-bucket. |
| `PUT /config` overrides конфиг, но после `rebuild-config` он сотрётся — юзер недоумевает | Документировано в спеке как "временный override"; handler в response явно возвращает `note: use POST /action/rebuild-config disables this override`. |
| `PATCH /subs/{id}` со сменой URL не тригерит fetch автоматически → юзер ждёт обновления, которого не будет | Документировано; отдельный `POST /subs/{id}/refresh` для явного refresh'а. Альтернатива — `?rebuild=true` ТОЛЬКО регенерит config, но не fetch'ит — это тоже в доке. |
| Ошибка в partial PATCH с невалидным типом поля (например `{"enabled":"yes"}` — строка вместо bool) молча применяется как false | Handler делает strict type-check: тип поля должен совпадать с моделью, иначе 400. |

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
