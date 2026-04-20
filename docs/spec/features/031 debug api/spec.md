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

### Auth

Все эндпоинты требуют заголовок `Authorization: Bearer <token>`. Исключение — `GET /ping` (см. ниже — health-check). Перед auth-чеком middleware валидирует `Host` — защита от DNS rebinding (см. секцию Безопасность).

Middleware:
```dart
// 1. Host header check — блокируем DNS rebinding.
// Легитимный клиент через `adb forward` шлёт Host: localhost|127.0.0.1.
// Браузер с rebinded evil.com → Host: evil.com → 403 (даже если токен утёк).
final host = (req.headers.value('host') ?? '').split(':').first;
if (host != '127.0.0.1' && host != 'localhost') {
  req.response.statusCode = HttpStatus.forbidden;
  await req.response.close();
  return;
}

// 2. Auth (кроме /ping).
if (req.uri.path != '/ping' &&
    req.headers.value('authorization') != 'Bearer $_token') {
  req.response.statusCode = HttpStatus.unauthorized;
  await req.response.close();
  return;
}
```

### Registry

Контроллеры/сервисы пробрасываются через `DebugRegistry` синглтон:

```dart
class DebugRegistry {
  static final I = DebugRegistry._();
  DebugRegistry._();

  HomeController? home;
  SubscriptionController? sub;
  AppLog? log;
  BoxVpnClient? vpn;
  ClashEndpoint? Function()? clashEndpoint;  // lazy getter (может меняться)
}
```

Биндится в `main.dart` после `runApp` init'а. Handler'ы дёргают `DebugRegistry.I.home.pingAllNodes()` etc.

### Модули

```
lib/services/debug/
  debug_server.dart        — bind + dispatch + middleware
  debug_registry.dart      — singleton с refs на контроллеры
  handlers/
    state.dart             — /state/*
    device.dart            — /device
    clash.dart             — /clash/* (proxy)
    action.dart            — /action/*
    files.dart             — /files/*
    nav.dart               — /nav/* (optional)
    logs.dart              — /logs
    config.dart            — /config
```

Каждый модуль регистрирует свои endpoints в `DebugServer.mount(...)`.

---

## Эндпоинты

Все возвращают `Content-Type: application/json`. Errors как `{"error": "<msg>"}` со status 4xx/5xx.

### Health

#### `GET /ping`
Health-check, **без auth**. Возвращает `{"pong": true, "build": "<git_desc>", "version": "<app_version>"}`.

---

### State — чтение состояния контроллеров

#### `GET /state`
Полный dump HomeState.
```json
{
  "tunnel": "connected",
  "busy": false,
  "configRaw_length": 152430,
  "activeInGroup": "auto-proxy-out",
  "selectedGroup": "vpn-1",
  "highlightedNode": "auto-proxy-out",
  "groups": ["vpn-1","vpn-2","vpn-3"],
  "nodesCount": 153,
  "lastDelay": {"auto-proxy-out": 206, "BL: Paris": 169, …},
  "pingBusy": {"auto-proxy-out": ""},
  "traffic": {"up": 0, "down": 0, "upTotal": 645000000, "downTotal": 9100000},
  "connectedSince": "2026-04-20T10:43:00Z",
  "lastError": "",
  "configStaleSinceStart": false,
  "sortMode": "latencyAsc"
}
```

#### `GET /state/clash`
Endpoint + secret (raw, для ручного curl'а минуя прокси).
```json
{
  "baseUri": "http://127.0.0.1:7842",
  "secret": "a1b2c3d4...",
  "available": true,
  "apiOk": true
}
```
`apiOk` — результат последнего `/version` ping'а.

#### `GET /state/subs`
Все подписки.
```json
[
  {
    "id": "...",
    "kind": "SubscriptionServers" | "UserServer",
    "url": "https://...",
    "title": "My provider",
    "enabled": true,
    "tagPrefix": "BL",
    "nodesCount": 120,
    "lastUpdateAt": "2026-04-20T10:05:00Z",
    "lastUpdateStatus": "ok" | "failed" | "inProgress",
    "consecutiveFails": 0,
    "updateIntervalHours": 24,
    "overrideDetour": "",
    "rawBodyBytes": 45200
  },
  ...
]
```

#### `GET /state/rules`
Все custom rules.
```json
[
  {
    "id": "...", "name": "Firefox RU", "enabled": true,
    "kind": "inline",
    "domainSuffixes": ["ru","xn--p1ai"],
    "packages": ["org.mozilla.firefox"],
    "ports": [], "portRanges": [],
    "packages": [], "protocols": [],
    "ipIsPrivate": false,
    "srsUrl": "",
    "target": "direct-out",
    "srsCached": false,
    "srsPath": null
  },
  ...
]
```
`srsCached`/`srsPath` заполняются для `kind=srs`.

#### `GET /state/storage`
Полный dump `SettingsStorage._cache` (raw JSON). Включает **все настройки** — vars, enabledRules (legacy), rule_outbounds (legacy), route_final, dns_options, excluded_nodes, custom_rules, presets_migrated, debug_enabled, debug_token, auto_ping_on_start, haptic_enabled, auto_rebuild и т.д.

#### `GET /state/vpn`
Native VPN flags:
```json
{
  "autoStart": false,
  "keepOnExit": false,
  "isIgnoringBatteryOptimizations": true
}
```

---

### Device — окружение и permissions

#### `GET /device`
Метаданные устройства и приложения — то, без чего половина баг-репортов теряет контекст (версия ОС, модель, ABI, разрешения).

```json
{
  "androidVersion": "14",
  "sdkInt": 34,
  "manufacturer": "Google",
  "model": "Pixel 7 Pro",
  "device": "cheetah",
  "abi": "arm64-v8a",
  "appVersion": "1.4.0",
  "appBuild": 140,
  "packageName": "com.leadaxe.lxbox",
  "locale": "ru_RU",
  "timezone": "Europe/Moscow",
  "vpnPermissionGranted": true,
  "isIgnoringBatteryOptimizations": true,
  "networkType": "wifi",
  "uptimeSeconds": 3600
}
```

Поля:
- `androidVersion` / `sdkInt` — через `device_info_plus` (`AndroidDeviceInfo.version.release` / `version.sdkInt`).
- `manufacturer` / `model` / `device` / `abi` — оттуда же (`supportedAbis.first`).
- `appVersion` / `appBuild` / `packageName` — через `package_info_plus`.
- `locale` / `timezone` — `Platform.localeName`, `DateTime.now().timeZoneName`.
- `vpnPermissionGranted` — native plugin (`VpnPlugin.isPrepared()`).
- `isIgnoringBatteryOptimizations` — уже есть в `/state/vpn`, дублируем для удобства.
- `networkType` — `connectivity_plus`: `wifi | cellular | ethernet | vpn | none`.
- `uptimeSeconds` — `DateTime.now().difference(appStartedAt).inSeconds`, где `appStartedAt` биндится в `main.dart`.

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
    "message": "proxies[auto-proxy-out]: type=URLTest now= all=151"
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

**Note on /group/:tag/delay** — как раз то что нужно для диагностики URLTest'а. Пример: `curl localhost:9269/clash/group/auto-proxy-out/delay?url=https://cp.cloudflare.com/generate_204&timeout=5000 -H "Authorization: Bearer $TOKEN"`.

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

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `lib/services/debug/debug_server.dart` | `HttpServer.bind` + dispatch + middleware + mount API |
| `lib/services/debug/debug_registry.dart` | Singleton с refs на контроллеры/services |
| `lib/services/debug/handlers/state.dart` | `GET /state/*` |
| `lib/services/debug/handlers/device.dart` | `GET /device` |
| `lib/services/debug/handlers/config.dart` | `GET /config*` |
| `lib/services/debug/handlers/logs.dart` | `GET /logs`, `POST /logs/clear` |
| `lib/services/debug/handlers/clash.dart` | `/clash/*` proxy |
| `lib/services/debug/handlers/action.dart` | `POST /action/*` |
| `lib/services/debug/handlers/files.dart` | `/files/*` read-only |
| `lib/services/debug/handlers/nav.dart` | `/nav/*` (optional) |
| `lib/screens/app_settings_screen.dart` | Developer section — toggle + token + regenerate |
| `lib/main.dart` | Bind `DebugRegistry`, start server if enabled |
| `test/services/debug_server_test.dart` | Auth middleware, routing, error codes |

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
- [ ] `GET /clash/group/auto-proxy-out/delay?url=&timeout=` форсит URLTest и возвращает Map<child, delay>.
- [ ] `POST /action/run-urltest?group=auto-proxy-out` — same как меню-пункт.
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
