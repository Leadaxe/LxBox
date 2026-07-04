# Debug API reference — curl cheatsheet

| Поле | Значение |
|------|----------|
| Статус | Reference |
| Дата | 2026-07-04 |
| Версия API | совместим со [`spec 031`](../spec/features/031%20debug%20api/spec.md) |
| Парный doc | [`clash-api-reference.md`](clash-api-reference.md) — **deprecated**: `/clash/*` proxy выпилен в §122 (Clash API dropped, переход на CommandClient) |

Compact curl-ready reference для **Debug API** — HTTP-сервера L×Box на `127.0.0.1:9269`, который пробрасывается через `adb forward`. Полные объяснения полей/middleware/архитектуры — в [spec 031](../spec/features/031%20debug%20api/spec.md); здесь — «что послать чтобы получить нужное».

## Setup (one-time)

1. В App: Settings → Developer → **Debug API toggle ON** → Copy token.
2. На хосте:

```bash
adb forward tcp:9269 tcp:9269
TOK="<paste from Copy button>"
BASE="http://127.0.0.1:9269"
HDR="Authorization: Bearer $TOK"
```

Sanity check:
```bash
curl -s "$BASE/ping"
# → {"pong":true,"server":"lxbox-debug","uptime_seconds":N}
```

Актуальную поверхность API можно всегда увидеть через самодокументируемый `GET /help` (тоже без auth):
```bash
curl -s "$BASE/help"            # human-readable cheatsheet
curl -s "$BASE/help?format=json" | jq   # machine-readable для auto-tooling
```

Все нижеследующие endpoints требуют `$HDR`. Общие rules:
- Content-type ответа: `application/json; charset=utf-8`.
- Write'ы (PUT/POST/PATCH/DELETE) возвращают `{"ok":true, "action":"<name>", ...extras}` или 4xx/5xx с `{"error":{"code":"...","message":"..."}}`.
- Любой write опционально принимает `?rebuild=true` — после успешного write'а регенерирует sing-box конфиг через `SubscriptionController.generateConfig()` + `HomeController.saveParsedConfig()`. Ответ расширяется `rebuilt:bool + config_bytes:N` (или `rebuild_error:str`).

## Security model — root-доступ by design

> **Debug API — это полноценный «рутовый» доступ над приложением, намеренно.**
> Он by design даёт прямой доступ ко **всему состоянию, включая секреты в
> открытом виде**. Это осознанное проектное решение, а **не** уязвимость.

- `GET /config` отдаёт **raw sing-box JSON as-is** — с `private_key`, `password`,
  UUID нод в открытом виде.
- `GET /backup?include=storage` отдаёт весь `SettingsStorage.exportRaw()`.
- `GET /state/subs?reveal=true` отдаёт **полные URL подписок** (с секретами).
- `PUT /config` / `PUT /backup` / все CRUD-роуты полностью перезаписывают состояние.

**Единственная граница безопасности:**
1. **Bearer-токен** (`debug_token`, ротируемый через App Settings → Developer).
2. **Bind на `127.0.0.1`** (доступ только с устройства / через `adb forward`).
3. **Toggle default-OFF** — API выключен, пока юзер явно не включил.

Маскирование секретов (scrubber в `GET /state/storage`, URL-mask по умолчанию в
`GET /state/subs`) — это **UX-удобство** «не светить секрет случайно в скопированном
логе», а **не** security-граница: маску всегда можно снять (`reveal=true`, raw
`/config`). Не путать одно с другим.

**Для будущих аудитов/ревью:** прямой доступ к секретам за токеном — намеренный
дизайн; **не** помечать его как security-находку и **не** закрывать / делать
маскирование обязательным. Аудит безопасности Debug API должен проверять саму
границу (стойкость/ротацию токена, bind-адрес, default-OFF, отсутствие обхода
auth), а не факт, что за границей всё открыто.

---

## Index

- [State & introspection](#state--introspection)
- [Config](#config)
- [Logs](#logs)
- [Actions — триггеры](#actions--триггеры)
- [Rules CRUD — `/rules/*`](#rules-crud--rules)
- [Subscriptions CRUD — `/subs/*`](#subscriptions-crud--subs)
- [Channels CRUD — `/channels/*`](#channels-crud--channels)
- [Folders CRUD — `/folders/*`](#folders-crud--folders)
- [WARP — `/warp`](#warp--warp)
- [Pool — `/pool`](#pool--pool)
- [Settings writes — `/settings/*`](#settings-writes--settings)
- [Wi-Fi history — `/wifi_history`](#wi-fi-history--wifi_history)
- [Files](#files)
- [Profiler — `/profiler/*`](#profiler--profiler)
- [Common errors](#common-errors)

---

## State & introspection

| Endpoint | Что отдаёт |
|---|---|
| `GET /ping` | `{pong,server,uptime_seconds}` — **без auth** |
| `GET /help` | `?format=text\|json` — самодокументируемая карта всей поверхности API. **Без auth** (второй no-auth endpoint). `json` — для auto-tooling, `text` (default) — human-readable cheatsheet. |
| `GET /state` | full HomeState: tunnel/busy/config_length/active_in_group/selected_group/last_delay/ping_busy/traffic/… |
| `GET /state/subs` | массив подписок, `?reveal=true` показывает clear URLs |
| `GET /state/rules` | массив custom rules с `srs_cached/srs_mtime` |
| `GET /state/storage` | весь `SettingsStorage._cache` со scrubber'ом (token/URL/nodes маскируются) |
| `GET /state/vpn` | `{auto_start,keep_on_exit,allow_bypass,current_session_allow_bypass,background_mode,is_ignoring_battery_optimizations}`. **§069** — `current_session_allow_bypass` это **runtime applied** значение (snapshot из последнего `VpnService.Builder.allowBypass()` в `establish()`); может отличаться от persisted `allow_bypass` если юзер поменял toggle без VPN reload. `false` пока VPN never started или после `stop`. |
| `GET /state/config_locked` | `{locked: bool}` — §037 текущее состояние auto-rebuild lock'а |
| `GET /device` | Android version, model, ABI, app version + build, core version (libbox / sing-box-lx), VPN permission, network type, uptime |

```bash
curl -s -H "$HDR" "$BASE/state" | jq '{tunnel,active_in_group,nodes_count,groups}'
curl -s -H "$HDR" "$BASE/state/subs" | jq 'map({id,title,enabled,nodes_count})'
curl -s -H "$HDR" "$BASE/state/storage?reveal=true" | jq '.vars | keys'
```

---

## Config

| Endpoint | Метод | Назначение |
|---|---|---|
| `GET /config` | GET | raw JSON конфига (as-is из памяти HomeController) |
| `GET /config/pretty` | GET | тот же JSON с indent: 2 |
| `GET /config/path` | GET | `{app_documents_dir,note}` — путь Flutter dir, не sing-box (см. note) |
| `PUT /config` | PUT | **прямой override** — body = raw sing-box JSON объект. `HomeController.saveParsedConfig(raw)` минуя `buildConfig`. |

```bash
# Backup + restore flow
curl -s -H "$HDR" "$BASE/config" > /tmp/cfg.json

# Правим вручную (например, добавили поле в experimental)
jq '.experimental.foo = "bar"' /tmp/cfg.json > /tmp/cfg.mod.json

# Override
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  --data-binary "@/tmp/cfg.mod.json" "$BASE/config"
# → {"ok":true,"action":"config-put","bytes":74138,"tunnel_up_when_saved":true,
#    "note":"override is temporary — POST /action/rebuild-config will overwrite it ..."}
```

**Quirks:**
- Body до 1 MiB; валидация — только парсинг (`jsonDecode` must give object).
- Если `tunnel_up` — TUN перезапустится под новый config автоматически (`saveParsedConfig` делает reload).
- **Override временный по умолчанию.** Любой последующий `rebuild-config` (включая `?rebuild=true` на других CRUD) перегенерит из settings и сотрёт override.
- **Чтобы pin'нуть постоянно (§037)** — перед `PUT /config` поставить `PUT /settings/config_locked {"locked": true}`. После этого `SubscriptionController.generateConfig()` возвращает null silently на любой rebuild trigger, custom config удерживается. Снять lock через `{"locked": false}` + `POST /action/rebuild-config` чтобы вернуться к обычному flow.

### Pin custom config flow (§037)

Use-case: тест экспериментальных sing-box features (Tailscale outbound, custom DNS shapes, и т.п.) которые наш parser/builder не понимает.

```bash
# 1. Lock auto-rebuild
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"locked":true}' "$BASE/settings/config_locked"
# → {"ok":true,"action":"settings-config-locked","locked":true}

# 2. Get current config + edit
curl -s -H "$HDR" "$BASE/config" > /tmp/cfg.json
# ... добавить tailscale outbound в /tmp/cfg.json через jq/manual ...

# 3. Push back
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  --data-binary "@/tmp/cfg.json" "$BASE/config"

# 4. (Optional) Start VPN если был down
curl -X POST -H "$HDR" "$BASE/action/start-vpn"

# 5. Observe sing-box behavior через logs
curl -s -H "$HDR" "$BASE/logs?source=core&q=tailscale" | jq

# 6. Когда наигрался — unlock
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"locked":false}' "$BASE/settings/config_locked"

# 7. Любое UI-действие или rebuild restore'ит обычный config
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"

# Состояние lock'а в любой момент
curl -s -H "$HDR" "$BASE/state/config_locked"
# → {"locked":false}
```

---

## Logs

§043: per-source quotas в `AppLog` — `app=300`, `core=500` ring-buffer'ы независимы. K-way merge на read'е, direct lookup для filtered. Persistent split: `applog.txt` + `corelog.txt`, по 200 lines / 64KB на файл.

| Endpoint | Метод | Query |
|---|---|---|
| `GET /logs` | GET | `limit=N` (default 200, max 1000), `source=app\|core` (без — merged), `q=<substr>`, `level=error,warning,info,debug` (comma-separated) |
| `GET /logs/app` | GET | Alias для `/logs?source=app`. Те же query params (`level`/`q`/`limit`). |
| `GET /logs/core` | GET | Alias для `/logs?source=core`. Sing-box internal logs (router/dns/inbound/outbound/dial/...). **Требует `core_logs_enabled=true`** — иначе только наши broadcast'ы (`status=...`). |
| `POST /logs/clear` | POST | `source=app\|core` (опц., без — clear всё) |

**Sing-box logs (`source=core`)** — поток приходит через `PlatformInterface.writeDebugMessage` → EventChannel `lxbox/coreLog` → `ClashLogPump` → AppLog. Filter в Kotlin отсеивает TRACE/DEBUG (volume reduction). `parseLevel` определяет уровень regex'ом по форматам `INFO[NNNN]` (default formatter после strip ANSI) или `WARN<spaces>` (terminal mode). Включается через [`/settings/core_logs_enabled`](#settings--coresettings) — изменение применяется только после **полного рестарта процесса** (`Libbox.setup` one-shot per process; stop/start VPN не помогает — service пересоздаётся, но Application/libbox остаются).

```bash
# Только core warn/error для post-mortem диагностики
curl -s -H "$HDR" "$BASE/logs/core?level=warning,error&limit=100" | jq '.[]'

# Поиск по substring — все dial errors
curl -s -H "$HDR" "$BASE/logs/core?q=dial&level=warning,error" | jq '.[].message'

# Только app, без core-spam
curl -s -H "$HDR" "$BASE/logs/app?limit=20" | jq '.[-5:]'

# Очистить только core (app-логи остаются)
curl -X POST -H "$HDR" "$BASE/logs/clear?source=core"
```

---

## Actions — триггеры

Все POST'ы. Response `{ok,action,...}`.

| Endpoint | Query | Что делает |
|---|---|---|
| `POST /action/urltest` | `tag=<node>` \| `group=<tag>` \| `all=true` \| `cancel=1` | единый URLTest-диспатч (ровно один scope): `tag` — single-node; `group` — group-delay (409 если tunnel down); `all` — mass-ping всех нод активной группы (concurrency 10); `cancel=1` — отмена in-flight mass-ping (§163, epoch-bump). → `{ok,action,scope,...}` |
| `POST /action/switch-node` | `tag=<tag>` | selector switch на node. 409 если не выбрана группа |
| `POST /action/set-group` | `group=<tag>` | смена активной группы |
| `POST /action/start-vpn` | — | `home.start()` (через Activity, с VpnService.prepare dance — может показать consent-диалог) |
| `POST /action/start-vpn-headless` | — | §165 — старт VPN **без** Activity/consent, прямо через `BoxVpnService.start()`. Работает только если VPN-разрешение уже выдано (`VpnService.prepare()==null`). Для self-test/automation. → `{"ok":true,"action":"start-vpn-headless","started":<bool>,"needs_consent":<bool>}` |
| `POST /action/stop-vpn` | — | `BoxVpnService.stop()` (кооперативный, ждёт Stopped от ядра) |
| `POST /action/reconnect` | — | §163 — Stop→Start одной командой под общим busy-wrap. Если туннель down — делегирует в `start()`. → `{"ok":true,"action":"reconnect"}` |
| `POST /action/reload-vpn` | — | §163 — in-place reload sing-box runtime **без** убийства Android-сервиса (cooldown-gated через `canReload`; туннель дропается ~3с). `applied:false` если reload недоступен (не connected / в cooldown). → `{"ok":true,"action":"reload-vpn","applied":<bool>}` |
| `POST /action/clear-error` | — | сброс `lastError`-баннера программно (после того как automation обработала/спровоцировала ошибку). → `{"ok":true,"action":"clear-error"}` |
| `POST /action/force-stop-vpn` | — | жёсткий teardown → `stopSelf` (не кооперативный). Освобождает порт CommandServer при зависшем `stop-vpn`. → `{"ok":true,"action":"force-stop-vpn","native_ok":<bool>}` |
| `POST /action/set-transient-timeout` | `connecting=<ms>` \| `stopping=<ms>` | §140 — override порогов transient-timeout (connecting/stopping). Оба параметра опциональны, но минимум один обязателен; значения — положительные ms. → `{"ok":true,"action":"set-transient-timeout","connecting_ms":N,"stopping_ms":N}` |
| `POST /action/emulate-error` | `kind=<k>` | демо `humanizeError` в `/logs`. `kind`: `socket\|timeout\|http-401\|http-404\|http-410\|http-429\|http-503\|format\|fs\|plain\|all` |
| `POST /action/reset-network` | — | §031 light recovery: closeAllConnections + DNS cache flush + dialer rebind. БЕЗ recreate'а box/Service/TUN. Требует tunnel up (409 если down). → `{"ok":true,"action":"reset-network","native_ok":<bool>}` |
| `POST /action/rebuild-config` | — | `SubscriptionController.generateConfig()` + save |
| `POST /action/refresh-subs` | `force=true\|false` | триггер AutoUpdater |
| `POST /action/download-srs` | `ruleId=<id>` | скачать .srs для custom rule |
| `POST /action/clear-srs` | `ruleId=<id>` | удалить cached .srs |
| `POST /action/toast` | `msg=<str>&duration=short\|long` | Toast на устройстве (до 200 chars) |
| `POST /action/check-updates` | — | force update check (обход 24h cap + `auto_check_updates`). → `{ok, action, kind, tag, name, html_url, published_at, dismissed, local_version, message}` (поля tag..dismissed — только при `kind=update-available`; зеркалит UI «Check now»). Primary `api.github.com` → fallback `raw.githubusercontent.com/.../docs/latest.json`. |
| `POST /action/preview-empty-state` | `on=true\|false` | UI-only override: HomeScreen рендерит empty-state как при чистой инсталляции, реальные данные не трогаются. Полезно для скриншотов / regression UX. |

```bash
# Типичный flow диагностики
curl -X POST -H "$HDR" "$BASE/action/refresh-subs?force=true"
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"
curl -X POST -H "$HDR" "$BASE/action/urltest?group=✨auto"
curl -s -H "$HDR" "$BASE/state" | jq '{active:.active_in_group,err:.last_error}'

# Sanity что трогаешь правильный девайс
curl -X POST -H "$HDR" "$BASE/action/toast?msg=hello%20from%20debug%20API"
```

---

## Rules CRUD — `/rules/*`

Custom routing rules (§030). `id` = UUID v4, генерится сервером при create. Wire-level shape см. в `/state/rules` или ниже.

| Endpoint | Метод | Body |
|---|---|---|
| `/rules` | GET | — |
| `/rules` | POST | CustomRule без `id` |
| `/rules/{id}` | GET | — |
| `/rules/{id}` | PATCH | любой subset полей (strict type check) |
| `/rules/{id}` | DELETE | — |
| `/rules/reorder` | POST | `{"order":[id1,id2,...]}` — должен содержать все текущие ID |

**Создать:**
```bash
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{
    "name":"No telemetry",
    "enabled":true,
    "kind":"inline",
    "domain_suffixes":["app-measurement.com","firebase.io","googleanalytics.com"],
    "target":"reject"
  }' \
  "$BASE/rules?rebuild=true"
# → {"id":"abc-123","name":"No telemetry",...,"rebuilt":true,"config_bytes":72559}
```

**Частичный апдейт:**
```bash
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"enabled":false}' \
  "$BASE/rules/abc-123"

# Добавить домен к существующему правилу (replace массива, не append)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"domain_suffixes":["app-measurement.com","firebase.io","googleanalytics.com","segment.io"]}' \
  "$BASE/rules/abc-123?rebuild=true"
```

**Порядок (priority):**
```bash
ORDER_JSON=$(curl -s -H "$HDR" "$BASE/rules" | jq '{order: [.[].id] | reverse}')
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d "$ORDER_JSON" "$BASE/rules/reorder"
```

Storage order = sing-box `route.rules[]` order (за вычетом 3 system rules
`resolve` / `sniff` / `dns hijack` которые builder всегда вставляет первыми).
Rules матчатся **first-wins** сверху вниз, так что reorder напрямую влияет
на приоритет. Order соблюдается **между kind'ами** (`preset` / `inline` /
`srs`) — раньше builder делал 2 прохода и cross-kind ordering терялся, в
[§062](../spec/tasks/062-custom-rules-unified-order.md) починено.

**Shape CustomRule body** (все optional кроме `name`):
```json
{
  "name": "string",                 // required, non-empty
  "enabled": true,
  "kind": "inline|srs|preset",
  "preset_id": "<id>",              // required при kind=preset
  "vars_values": {"var":"val"},     // preset-only: overrides шаблонных vars
  "dns": {"enabled": true, "server_tag": "<tag>"}, // preset-only DNS-attach
  "domains": ["exact.domain"],
  "domain_suffixes": [".ru","xn--p1ai"],
  "domain_keywords": ["tracker"],
  "ip_cidrs": ["10.0.0.0/8"],
  "ports": ["443","80"],
  "port_ranges": ["8000:9000",":3000"],
  "packages": ["org.mozilla.firefox"],
  "protocols": ["tls","quic"],      // subset of sing-box known (tls/quic/http/...)
  "network": ["tcp","udp"],         // L4 transport, subset of tcp/udp/icmp
  "ip_is_private": false,
  "srs_url": "https://...rule-set.srs",
  "target": "vpn-1|direct-out|reject"
}
```

**Quirks:**
- PATCH с wrong type (`{"enabled":"yes"}`) → 400 `bad_request`.
- `target: "reject"` — sentinel, маппится на `{action:"reject"}` в routing rules.
- Массивы PATCH'ятся **replace**-семантикой, не append.

---

## Subscriptions CRUD — `/subs/*`

Подписки + inline user-servers. Shape в GET — как `/state/subs`.

| Endpoint | Метод | Body |
|---|---|---|
| `/subs` | GET | `?reveal=true` — clear URLs |
| `/subs` | POST | `{"input":"<url\|URI\|WG-ini\|JSON-outbound>"}` |
| `/subs/{id}` | GET | — |
| `/subs/{id}` | PATCH | subset: name/enabled/tag_prefix/update_interval_hours/override_detour/register_detour_{servers,in_auto}/use_detour_servers/replace_detour_chain/url |
| `/subs/{id}` | DELETE | — |
| `/subs/{id}/refresh` | POST | trigger fetch. 409 для UserServer |
| `/subs/reorder` | POST | `{"order":[id1,...]}` |

**Добавить подписку:**
```bash
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"input":"https://provider.example/sub/abc123"}' \
  "$BASE/subs"
# → {"ok":true,"action":"subs-add","id":"<new>","kind":"SubscriptionServers"}
```

**Inline single server (SS URI):**
```bash
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"input":"ss://YWVzLTI1Ni1nY206dGVzdA@1.2.3.4:8080#my-node"}' \
  "$BASE/subs?rebuild=true"
# → {"ok":true,"action":"subs-add","id":"...","kind":"UserServer","rebuilt":true,...}
```

**JSON outbound (sing-box шаблон):**
```bash
JSON='{"input": '$(jq -Rs . <<<'{"type":"vless","tag":"my-node","server":"1.2.3.4","server_port":443,"uuid":"..."}')'}'
curl -X POST -H "$HDR" -H "Content-Type: application/json" -d "$JSON" "$BASE/subs"
```

**WireGuard INI** (multi-line — приклеиваем через jq для корректного JSON escape):
```bash
WG_INI='[Interface]
PrivateKey = ABC=
Address = 10.0.0.2/32
[Peer]
PublicKey = XYZ=
Endpoint = wg.example.com:51820
AllowedIPs = 0.0.0.0/0'
jq -n --arg input "$WG_INI" '{input: $input}' | \
  curl -X POST -H "$HDR" -H "Content-Type: application/json" \
    --data-binary @- "$BASE/subs"
```

**Сменить URL + refresh:**
```bash
# PATCH не триггерит fetch автоматически
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"url":"https://new-provider/sub/xyz"}' \
  "$BASE/subs/<id>"
# Fetch руками
curl -X POST -H "$HDR" "$BASE/subs/<id>/refresh"
# Подождать и проверить
sleep 3
curl -s -H "$HDR" "$BASE/state/subs" | jq '.[] | select(.id=="<id>") | {title, nodes_count, last_update_status}'
```

**Reorder:** то же что у rules.

**Quirks:**
- `PATCH /subs/{id}` с `url` на UserServer молча игнорируется (у inline-серверов нет URL).
- `replace_detour_chain` (§073) — bool detour-флаг, ранее пропущенный в PATCH-маппинге (асимметрия с соседними `register_detour_*`); теперь маппится. Config-significant → `?rebuild=true` чтобы применить.
- `POST /subs/{id}/refresh` на UserServer → 409 `conflict` (нечего фетчить).
- `POST /subs` с `?rebuild=true` **не ждёт fetch'а** — fetch асинхронный, rebuild'ит с текущими nodes (которых ещё нет → config без этих outbound'ов). Делай последовательно: `POST /subs` → `POST /subs/{id}/refresh` → wait → `POST /action/rebuild-config`.

---

## Channels CRUD — `/channels/*`

§238 — каналы роутинга §125 (`channels[]` в storage). Обёртка над
`SettingsStorage.getChannels / addChannel / updateChannel / deleteChannel` —
семантика идентична UI: `vpn-1` неудаляем и всегда enabled, лимит 10 каналов,
удаление/выключение канала деградирует ссылки (route_final / custom-rule
outbound) на `vpn-1` (§202, необратимо). Shape ресурса — storage-JSON канала
(`Channel.toJson()`, snake_case).

| Endpoint | Метод | Body |
|---|---|---|
| `/channels` | GET | — |
| `/channels/{tag}` | GET | tag = `vpn-1`..`vpn-10` |
| `/channels` | POST | опц. `{"label":"..."}` + любые PATCH-поля; tag автоназначается (первый свободный `vpn-N`), 201 |
| `/channels/{tag}` | PATCH | subset: `label,enabled,include_direct,include_block,node_filter,node_filter_invert,default_filter,interrupt_exist_connections,auto` |
| `/channels/{tag}` | DELETE | — |
| `/channels/reorder` | POST | `{"order":["vpn-1",...]}` — ровно текущие теги |

Все write'ы принимают `?rebuild=true` (порядок каналов = порядок эмита в
конфиге, так что reorder тоже config-significant).

```bash
# Список
curl -s -H "$HDR" "$BASE/channels" | jq 'map({tag,label,enabled})'

# Создать канал с фильтром по немецким нодам и urltest-двойником
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"label":"Germany","node_filter":"DE|Frankfurt","auto":{"interval":"3m"}}' \
  "$BASE/channels?rebuild=true"
# → 201 {"tag":"vpn-2","label":"Germany",...,"rebuilt":true,...}

# Включить round_robin балансировщик на канале
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"auto":{"mode":"round_robin","balancer":{"pool":4}}}' \
  "$BASE/channels/vpn-2?rebuild=true"

# Снять галку auto (убрать urltest-двойник)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"auto":null}' "$BASE/channels/vpn-2"
```

**Quirks:**
- `auto` в PATCH — **merge**, не replace: `{"auto":{"url":...}}` меняет только
  `url`, остальные urltest-опции (и вложенный `balancer{}`) сохраняются.
  Полный reset — прислать все поля явно. `"auto": null` — снять галку.
- `tag` immutable (системный id) → передан в PATCH → 400. Юзер-имя — `label`.
- `PATCH vpn-1 {"enabled":false}` и `DELETE /channels/vpn-1` → 409 `conflict`.
- Выключение канала (enabled:false) деградирует ссылки на vpn-1 сразу и
  **необратимо** — повторное включение старую ссылку не воскрешает (§202).
- `node_filter`/`default_filter` валидируются как regex → битый паттерн 400
  (иначе уронил бы сборку конфига).

---

## Folders CRUD — `/folders/*`

§238 — папки серверов §234 (`FolderServers` в `server_lists`) поверх публичных
методов `SubscriptionController`. Папка — это entry общего списка `/subs`
(kind=`FolderServers`): **meta папки (name/enabled/tag_prefix/detour_policy)
правится через `PATCH /subs/{id}`**, `/folders/*` добавляет только
папко-специфичные операции.

**Члены адресуются позиционным индексом** (у `FolderMember` нет id): после
remove/ungroup/reorder индексы съезжают — каждый write-ответ возвращает свежий
снапшот папки (`folder`), по нему строить следующий вызов. `raw` члена несёт
credentials (URI/ключи) → по умолчанию скрыт, `?reveal=true` показывает
(симметрия со скраббером `/state/storage`).

| Endpoint | Метод | Body |
|---|---|---|
| `/folders` | GET | `?reveal=true` — с raw членов |
| `/folders` | POST | `{"name":"..."}` → 201 |
| `/folders/{id}` | GET | — |
| `/folders/{id}` | DELETE | `?keep_servers=true` — вынести членов одиночными серверами (default false — удалить совсем) |
| `/folders/{id}/members` | POST | ровно одно из: `{"input":"<uri\|WG-ini\|JSON>","name_fallback"?}` (paste) или `{"url":"..."}` (одноразовый снапшот: URL не хранится, авто-обновления нет) |
| `/folders/{id}/members/{idx}` | PATCH | subset `{raw,enabled,detour}` |
| `/folders/{id}/members/{idx}` | DELETE | — |
| `/folders/{id}/members/reorder` | POST | `{"order":[старые индексы в новом порядке]}` — полная перестановка |
| `/folders/{id}/members/{idx}/ungroup` | POST | член → одиночный сервер сразу после папки |
| `/folders/{id}/members/{idx}/move` | POST | `{"to":"<folder id>"}` — в другую папку |
| `/folders/{id}/move-server` | POST | `{"server_id":"<subs entry id>"}` — одиночный сервер въезжает в папку |
| `/folders/{id}/probe` | POST | опц. `{"url":"...","timeout_ms":N}` — headless «Test servers» §236 |

Все write'ы принимают `?rebuild=true`.

```bash
# Создать папку + накидать серверов paste'ом
FID=$(curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"name":"My folder"}' "$BASE/folders" | jq -r .id)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"input":"vless://uuid@h1.example:443?security=tls#Alpha\nvless://uuid@h2.example:443?security=tls#Beta"}' \
  "$BASE/folders/$FID/members?rebuild=true"
# → 201 {"ok":true,"action":"folder-members-add","added":2,"folder":{...}}

# Выключить члена 0, повесить личный detour на члена 1 (§237)
curl -X PATCH -H "$HDR" -d '{"enabled":false}' "$BASE/folders/$FID/members/0"
curl -X PATCH -H "$HDR" -d '{"detour":"jump-de"}' "$BASE/folders/$FID/members/1"

# Прогнать Test servers (§236) — результаты сразу в ответе
curl -s -X POST -H "$HDR" -d '{"timeout_ms":2000}' "$BASE/folders/$FID/probe" | \
  jq '{summary, results: [.results[] | {index,tag,status,delay_ms}]}'
# → {"summary":{"ok":1,"failed":1},"results":[{"index":0,"tag":"Alpha","status":"ok","delay_ms":184},...]}

# Распустить папку, сохранив серверы одиночными записями
curl -X DELETE -H "$HDR" "$BASE/folders/$FID?keep_servers=true&rebuild=true"
```

**Probe (§236):**
- Статусы: `ok` (+`delay_ms`), `failed` (+`message`), `broken` (raw не
  парсится), `invalid` (нода не собирается в конфиг), `not_in_config`,
  `pending` (тест не дошёл/отменён).
- При **остановленном** VPN поднимается отдельная headless probe-сессия —
  тестируются ВСЕ члены (включая выключенных). При **запущенном** VPN тест
  идёт через боевое ядро — выключенные члены не в конфиге → `not_in_config`.
- Синхронный запрос: worst-case ~`members/6 × timeout_ms`. Папка на 60+ членов
  с дефолтным timeout 3000мс может упереться в request-timeout сервера (30с) —
  снижай `timeout_ms`.

**Quirks:**
- entry существует, но не папка → 409 `conflict` (не 404) — ловит путаницу
  `/subs/{id}` vs `/folders/{id}`.
- `PATCH .../members/{idx}` с битым `raw` → 400, старый член не трогается.
- `move-server` принимает только одиночный `UserServer` (подписка в папку не
  кладётся — составом владеет источник) → иначе 409.
- `ungroup` / `delete?keep_servers=true`: личный detour члена переезжает в
  `override_detour` одиночного сервера; папочные tag_prefix/policy не
  наследуются.
- URL-снапшот с недоступным URL → 502 `upstream_error` (сетевой fetch).

---

## WARP — `/warp`

§147 — регистрация Cloudflare WARP-ноды (тот же путь, что кнопка **Get WARP** в UP). Приватный ключ X25519 генерится на устройстве, регистрация уходит в Cloudflare, готовая нода добавляется в подписки автоматически.

| Endpoint | Метод | Body |
|---|---|---|
| `/warp` | POST | все поля опциональны (см. ниже). `?rebuild=true` — регенерит config + reload ядра |

Body (все поля опциональны):
```json
{
  "licenseKey": "...",        // null/пусто → free WARP
  "endpoint": "IP:port",      // default engage.cloudflareclient.com:2408
  "obfuscate": false,         // QUIC masquerade (AmneziaWG-обфускация)
  "forceNew": false,          // игнор кэша, повторная регистрация
  "includeReserved": false,   // null → default по obfuscate
  "quicParams": {             // только при obfuscate
    "sni": "www.google.com",
    "ip": "quic",             // quic|...
    "ib": "chrome",           // chrome|firefox|curl
    "jc": 4, "jmin": 40, "jmax": 70
  }
}
```

```bash
# Free WARP одной командой + сразу в конфиг
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{}' "$BASE/warp?rebuild=true"
# → {"ok":true,"action":"warp-add","warp_plus":false,
#    "obfuscated":false,"endpoint":"...","address":"...","rebuilt":true,...}  (status 201)
```

---

## Pool — `/pool`

§208 (SPEC 019 V2) — read-only снапшот пула round_robin-балансировщика. Зеркалит UI «View pool» (`HomeController.getPool` → `CcChannel.getPool` → ядро GetPool RPC). Для отладки балансировщика без UI-попапа.

| Endpoint | Метод | Query |
|---|---|---|
| `/pool` | GET | `tag=<autoTag>` (обязателен) → `{tag, count, slots:[{slot,tag,delay,alive}]}` |

- `tag` — auto-двойник round_robin-канала (напр. `vpn-1-auto`).
- `delay==0` → нода мёртвая / не измерена.
- Не-round_robin группа / пул не готов → `slots: []` (не ошибка).
- CC-клиент недоступен (туннель down) → **409** `conflict` (§209 — раньше тихо отдавал `count:0`, что путало диагностику).

```bash
curl -s -H "$HDR" "$BASE/pool?tag=vpn-1-auto" | jq '{tag,count,slots}'
```

---

## Settings writes — `/settings/*`

Scoped writes на `SettingsStorage`. Generic `PUT /state/storage?key=X` **намеренно нет** — blocklist и типизация кастомные per-key.

| Endpoint | Метод | Body |
|---|---|---|
| `/settings/route_final` | PUT | `{"outbound":"<tag>"}` (пустая строка = дефолт) |
| `/settings/interrupt_on_switch` | GET | →`{"ok":true,"enabled":bool}` — §163 тугл «рвать активные соединения при switchNode». **НЕ** config-significant. |
| `/settings/interrupt_on_switch` | PUT | `{"enabled": true\|false}`. → `{ok, action:"settings-interrupt-on-switch", enabled}`. |
| `/settings/node_sort` | GET | →`{"ok":true,"mode":"<str>","order":["tag",...]}` — режим сортировки списка нод + ручной порядок. |
| `/settings/node_sort` | PUT | `{"mode": "<str>", "order"?: ["tag",...]}`. `mode` = `""`/`latency`/`manual`; `order` опц. (для manual). UI-only (не config-significant). → `{ok, action:"settings-node-sort", mode, order_count}`. |
| `/settings/enabled_groups` | GET | →`{"ok":true,"groups":["tag",...]}` — членство preset-групп в selector'е. **§125 legacy** — см. PUT-примечание. |
| `/settings/enabled_groups` | PUT | `{"groups": ["tag",...]}`. **§125 legacy: фактически no-op** — после миграции на `channels[]` билдер читает `enabledGroups` только когда `channels` пуст, иначе `channels[]` перекрывает эту запись. Для управления каналами используйте UI (App Settings → Channels) / backup. `?rebuild=true` пересоберёт конфиг, но результат не изменится. → `{ok, action:"settings-enabled-groups", count, ...rebuild-extras}`. |
| `/settings/vpn_mode` | GET | →`{"ok":true,"vpn_mode":{...}}` — текущий `VpnModeConfig`. |
| `/settings/vpn_mode` | PUT | частичное обновление (copyWith поверх текущего): `mode`/`proxy_protocol`/`proxy_port`/`proxy_listen`/`proxy_auth`/`proxy_user`/`proxy_pass`. `proxy_listen` валидируется как IPv4 (иначе 400). **Config-significant** (меняет inbounds) → `?rebuild=true`. → `{ok, action:"settings-vpn-mode", vpn_mode, ...rebuild-extras}`. |
| `/settings/vars/{key}` | PUT | `{"value":"<str>"}` |
| `/settings/vars/{key}` | DELETE | — (удаляет ключ; не пишет пустую строку) |
| `/settings/dns_options/servers` | PUT | §043 + §044: kind-refs `[{enabled, kind: 'inline'\|'preset'\|'template', tag, description?, body?}]`. Для `kind: inline` обязателен `body` (partial sing-box shape **без** `tag`/`description`/`enabled` — они на ref-level). Legacy full-body snapshot и §043 inline (с tag/description в body) тоже принимаются — auto-migrate на ближайший resolver. |
| `/settings/dns_options/rules` | PUT | `{"rules":"<JSON string>"}` (**legacy, §061**: пишет `dns_options.rules_json`, который билдер игнорирует → фактически no-op; используй `dns_options/servers` + custom-rules) |
| `/settings/config_locked` | PUT | `{"locked": true\|false}` — §037 toggle auto-rebuild lock. true → `generateConfig` возвращает null silently, custom config через `PUT /config` не перетирается UI. |
| `/settings/core_logs_enabled` | GET | →`{"enabled": bool}` — §043 текущее состояние forwarding'а sing-box логов в `/logs/core`. |
| `/settings/core_logs_enabled` | PUT | `{"enabled": true\|false}` — §043 включить/выключить forward. **Требует полного рестарта процесса** (`am force-stop` + relaunch, либо UI Quit & reopen) — `Libbox.setup` one-shot per process, stop/start VPN **не** перечитывает флаг. Default false. Storage в SharedPreferences (`boxvpn_boot.core_logs_enabled`), не в `lxbox_settings.json`. |
| `/settings/ping_options` | GET | →URLTest defaults `{url?, timeout_ms?, groups?}` (пустой map если не set'нуто — caller fall-through на template default). |
| `/settings/ping_options` | PUT | body `{url?, timeout_ms?, groups?}` — **overwrite целиком** (не merge). Unknown-подключи strip'аются (allowlist `url/timeout_ms/presets/groups`). `url` — string, `timeout_ms` — number, `groups` — object (иначе 400). → `{ok, action:"settings-ping-options", url, timeout_ms, groups_count}`. |
| `/settings/ping_options/groups/{tag}` | GET | override этой группы или **404** если override нет. |
| `/settings/ping_options/groups/{tag}` | PUT | body `{url?, timeout_ms?}` — минимум одно поле (read-modify-write). → `{ok, action:"settings-ping-options-group-put", group, ...}`. |
| `/settings/ping_options/groups/{tag}` | DELETE | снять override группы. → `{ok, action:"settings-ping-options-group-delete", group}`. |
| `/settings/tun_apps` | GET | →`{"mode":"off\|allow\|deny", "packages":[...]}` — §046 OS-level split-tunneling. |
| `/settings/tun_apps` | PUT | `{"mode":"off\|allow\|deny", "packages":["pkg1","pkg2",...]}` — §046. Replace целиком. Дубликаты в `packages` schлопываются (idempotent). Пустые строки skip'аются. Невалидный package-name → 400. Response: `{ok, action, mode, count, rebuild_needed: true, ...rebuild-extras}`. **Требует full VPN restart** для apply (Android tun creates только на `establish()`). |
| `/settings/vpn/allow_bypass` | GET | →`{"enabled": bool}` — §052/§049 F15. |
| `/settings/vpn/allow_bypass` | PUT | `{"enabled": true\|false}` — §052/§049 F15. Native (`VpnService.Builder.allowBypass()`). Применяется при следующем `establish()` (start или reload VPN). Default false (strict tunnel). |
| `/settings/vpn/keep_on_exit` | GET | →`{"enabled": bool}` — §052. VPN остаётся активным когда app закрывается. |
| `/settings/vpn/keep_on_exit` | PUT | `{"enabled": true\|false}` — §052. Effect at app exit; live-reload не нужен. |
| `/settings/vpn/background_mode` | GET | →`{"mode": "never"\|"lazy"\|"always"}` — §052. Foreground-service режим. |
| `/settings/vpn/background_mode` | PUT | `{"mode": "never"\|"lazy"\|"always"}` — §052. `never` — туннель всегда активен (default); `lazy` — pause только в deep Doze; `always` — pause при выключении экрана. Применяется при следующем VPN connect. |
| `/settings/rebuild-config` | POST | — (alias для `/action/rebuild-config`) |

**Route final:**
```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"outbound":"direct-out"}' \
  "$BASE/settings/route_final?rebuild=true"
```

**Custom vars** (template interpolation):
```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"value":"tls"}' \
  "$BASE/settings/vars/route-strategy"

# Посмотреть все vars
curl -s -H "$HDR" "$BASE/state/storage" | jq '.vars'

# Удалить var (getVar с default вернёт default)
curl -X DELETE -H "$HDR" "$BASE/settings/vars/route-strategy"
```

**Blocklist (409 `conflict`):** Ключи ниже нельзя менять через API — управляются UI App Settings → Developer.
- `debug_token`
- `debug_enabled`
- `debug_port`

```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" -d '{"value":"evil"}' \
  "$BASE/settings/vars/debug_token"
# → 409 {"error":{"code":"conflict","message":"var \"debug_token\" is managed via App Settings UI only"}}
```

**DNS servers:**
```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{
    "servers":[
      {"tag":"dns-google","type":"udp","server":"8.8.8.8"},
      {"tag":"dns-local","type":"udp","server":"192.168.1.1"}
    ]
  }' \
  "$BASE/settings/dns_options/servers?rebuild=true"
```

**DNS rules** (legacy — string-encoded JSON):
```bash
RULES=$(jq -c . <<'EOF'
[
  {"domain_suffix":[".local"],"server":"dns-local"},
  {"outbound":"any","server":"dns-google"}
]
EOF
)
jq -n --arg rules "$RULES" '{rules: $rules}' | \
  curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
    --data-binary @- "$BASE/settings/dns_options/rules?rebuild=true"
```

**Core logs forwarding** (§043) — диагностика sing-box internals:
```bash
# Текущее состояние
curl -s -H "$HDR" "$BASE/settings/core_logs_enabled" | jq
# {"enabled": false}

# Включить
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"enabled":true}' \
  "$BASE/settings/core_logs_enabled"
# → {"ok":true,"action":"settings-core-logs-enabled","enabled":true,
#    "note":"...force-stop & reopen the app to apply (Libbox.setup is
#     one-shot per process — stop/start VPN does NOT re-apply)"}

# Применить — полный рестарт процесса (stop/start VPN НЕ помогает:
# Libbox.setup читает флаг один раз за жизнь процесса)
adb shell am force-stop com.leadaxe.lxbox
# ... затем relaunch приложения (или UI: App Settings → Diagnostics → Quit & reopen)

# Теперь sing-box logs наполняют /logs/core
curl -s -H "$HDR" "$BASE/logs/core?level=warning,error&q=dial" | jq
```

**VPN System toggles** (§052) — то же что VPN Settings → System в UI:
```bash
# Snapshot всех VPN-system флагов одним запросом
curl -s -H "$HDR" "$BASE/state/vpn" | jq
# {"auto_start":false,"keep_on_exit":false,
#  "allow_bypass":false,"current_session_allow_bypass":false,
#  "background_mode":"never","is_ignoring_battery_optimizations":true}
#
# §069: mismatch allow_bypass != current_session_allow_bypass значит юзер
# поменял toggle, но VPN не reload'ил — runtime всё ещё со старым значением.
# Например `allow_bypass=false, current_session_allow_bypass=true` →
# `setAllowBypass(false)` записал в SharedPreferences, но `establish()` от
# прошлого start'а ещё с allowBypass()=true. Сделай stop+start чтобы apply.

# Allow VPN bypass — apps могут использовать ConnectivityManager в обход tun
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"enabled":true}' "$BASE/settings/vpn/allow_bypass"
# Эффект на следующем establish() — нужен reload VPN.

# Keep VPN on exit — туннель не падает при закрытии app
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"enabled":true}' "$BASE/settings/vpn/keep_on_exit"

# Tunnel sleep mode — never|lazy|always
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"mode":"lazy"}' "$BASE/settings/vpn/background_mode"
```

---

## Wi-Fi history — `/wifi_history`

§051 Phase 3 — список «известных» сетей `[{ssid, bssid, last_seen}]` для editor'а custom rules (`Pick saved` picker когда пишешь правило с условием `wifi_ssid` / `wifi_bssid`). Naturally заполняется через native `WifiNetworkObserver` (`NetworkCallback` listener, 5-min stickiness debounce) когда `auto_record_wifi_history` toggle ON в App Settings → Diagnostics. Через API можно injectить / удалять записи без UI flow — например для тестов или восстановления после wipe'а.

Storage: var `wifi_history` в `lxbox_settings.json` (JSON-encoded array). Cap **50 записей**, LRU evict by `last_seen`. BSSID нормализуется к lower-case при upsert. Composite key `(ssid, bssid)` — две сети с одинаковым ssid и разными bssid считаются разными.

| Endpoint | Метод | Body / response |
|---|---|---|
| `/wifi_history` | GET | →`[{ssid, bssid, last_seen}]` (newest first) |
| `/wifi_history` | POST | body `{"ssid":"...","bssid":"..."}` (`bssid` опц.). Upsert — если `(ssid, bssid)` уже есть, обновляет `last_seen`; иначе вставляет первым. → `{ok, action, ssid, bssid}`, status 201 |
| `/wifi_history` | DELETE | body `{"ssid":"...","bssid":"..."}` (`bssid` опц.). Remove конкретной записи. → `{ok, action, ssid, bssid}` |
| `/wifi_history/all` | DELETE | — clear all. → `{ok, action}` |

```bash
# Список
curl -s -H "$HDR" "$BASE/wifi_history" | jq
# [{"ssid":"HomeWiFi","bssid":"aa:bb:cc:dd:ee:ff","last_seen":"2026-05-10T12:34:56.789Z"}, ...]

# Inject запись (например для test fixture перед запуском smoke-теста)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"ssid":"OfficeWiFi","bssid":"11:22:33:44:55:66"}' \
  "$BASE/wifi_history"

# Удалить конкретную запись
curl -X DELETE -H "$HDR" -H "Content-Type: application/json" \
  -d '{"ssid":"OfficeWiFi","bssid":"11:22:33:44:55:66"}' \
  "$BASE/wifi_history"

# Wipe всё (например при сбросе настроек)
curl -X DELETE -H "$HDR" "$BASE/wifi_history/all"
```

**Quirks:**
- `POST` с пустым `ssid` → 400 BadRequest.
- `DELETE /wifi_history` с пустым `ssid` → 400 (используй `/wifi_history/all` для full wipe).
- Cap не строгий: если придёт `POST` когда уже 50 записей, новая вставляется в head, последняя выпадает. Не атомарно с UI — гонка возможна, но не критична (обе ветки сходятся к корректному состоянию).

---

## Files

Read-only file access.

| Endpoint | Query |
|---|---|
| `GET /files/srs` | `ruleId=<id>` → octet-stream .srs |
| `GET /files/srs/list` | — |
| `GET /files/local` | `name=<name>` (whitelist: `cache.db`, `stderr.log`) |
| `GET /files/external` | legacy alias for `/files/local`, ради обратной совместимости |

```bash
curl -s -H "$HDR" "$BASE/files/srs/list" | jq
curl -s -H "$HDR" "$BASE/files/srs?ruleId=abc-123" > /tmp/rule.srs

# Native stderr log (sing-box core, internal app-scoped storage)
curl -s -H "$HDR" "$BASE/files/local?name=stderr.log" | tail -30
```

---

## Backup — `/backup/*`

Symmetric с UI `BackupScreen` (см. [§040 spec](../spec/features/040%20backup%20restore%20ui/spec.md)). Wire-format — single, без `version` поля; legacy `{vars, server_lists}` на корне больше не поддерживается.

| Endpoint | Что отдаёт / принимает |
|---|---|
| `GET /backup/export?include=storage,vpn_settings` | Snapshot. `include` опц., default — обе части |
| `POST /backup/import?merge=&rebuild=` | Восстановление. Body `{storage?, vpn_settings?}` |

**Format**:
```json
{
  "app": "lxbox",
  "kind": "backup",
  "created_at": "2026-05-10T...",
  "source_app_version": "1.7.3+32",
  "storage": { ...lxbox_settings.json целиком: vars, server_lists,
               custom_rules, tun_apps, enabled_groups, route_final, ... },
  "vpn_settings": {
    "auto_start": false,
    "keep_on_exit": false,
    "background_mode": "never",
    "core_logs_enabled": false,
    "allow_bypass": false
  }
}
```

- **`storage`** — глубокая копия `lxbox_settings.json` (все top-level keys плюс nested `vars` map). Включает custom_rules, tun_apps, dns_options, wifi_history и любые будущие top-level keys без правок API.
- **`vpn_settings`** — native-side `boxvpn_boot` SharedPreferences (BootReceiver читает at boot-time из Kotlin, не вынесено в Flutter storage).

```bash
# Бэкап (всё)
curl -s -H "$HDR" "$BASE/backup/export" > /tmp/lxbox-backup.json

# Только Flutter storage без VPN system toggles
curl -s -H "$HDR" "$BASE/backup/export?include=storage" > /tmp/lxbox-storage.json

# Восстановление + rebuild config (replace)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  --data-binary @/tmp/lxbox-backup.json \
  "$BASE/backup/import?rebuild=true"

# Merge mode — top-level upsert (vars upsert, остальные ключи overwrite, отсутствующие в файле — keep)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  --data-binary @/tmp/lxbox-backup.json \
  "$BASE/backup/import?merge=true"
```

`merge=false` (default) — replace; `merge=true` — top-level upsert. Кеши (cache.db, stderr.log, SRS-blob, runtime node-tags) в backup не входят — restore их пересоздаёт.

---

## Diagnostics — `/diag/*` (§038)

| Endpoint | Что отдаёт |
|---|---|
| `GET /diag/dump` | Полный JSON-pack от `DumpBuilder.build()` (то же что UI ⤴ Share) |
| `GET /diag/exit-info` | `ApplicationExitInfo` (5 последних экзитов; API 30+, иначе `[]`) |
| `GET /diag/logcat?count=N&level=L` | Logcat tail нашего процесса (N=50..5000, level=V/D/I/W/E/F, default E) |
| `GET /diag/stderr` | Содержимое `filesDir/stderr.log` (Go panic stacktrace) |
| `GET /diag/applog?prev=true\|false\|all` | AppLog entries с фильтром по `fromPreviousSession` |
| `GET /diag/pprof?profile=P&query=Q` | §207 — pprof-снапшот через libbox PProfServer (туннель должен быть up). `P` = `goroutine\|profile\|heap\|allocs\|block\|mutex\|threadcreate` (default `goroutine`); `query` — сырой pprof-query без `?` (напр. `gc=1`/`debug=2`/`seconds=10`), дефолт зависит от профиля (`goroutine→debug=2`, `profile→seconds=10`, `heap→gc=1`). `goroutine?debug=*` отдаёт `text/plain`, остальное — `.pb` для `go tool pprof`. |

```bash
# Полный диагностический pack
curl -s -H "$HDR" "$BASE/diag/dump" -o /tmp/lxbox-dump.json

# Что система знает о последних крахах
curl -s -H "$HDR" "$BASE/diag/exit-info" | jq '.[].reason'

# Logcat нашего процесса (FATAL EXCEPTION + native backtrace)
curl -s -H "$HDR" "$BASE/diag/logcat?count=2000&level=W" | grep -E 'FATAL|DEBUG|tombstoned'

# Только pre-crash JVM-events предыдущей сессии
curl -s -H "$HDR" "$BASE/diag/applog?prev=true" | jq
```

---

## Profiler — `/profiler/*`

Traffic profiler — **per-app** session (§044, один active в любой момент) или **system-wide** rolling buffer (§048, Live tab в Statistics). Источник событий (§168): parser sing-box core logs + connections-push от libbox **CommandClient** (`CcChannel.connections` через фоновый `profilerClient`, `connectProfiler()`). Clash `/connections` polling выпилен (§122 — Clash API dropped).

### Per-app session

| Endpoint | Метод | Body |
|---|---|---|
| `/profiler/start` | POST | `{"package":"<pkg>", "verbose":false, "secondary_packages":[...]}` |
| `/profiler/stop` | POST | — |
| `/profiler/active` | GET | — — `404` если ничего не active |
| `/profiler/sessions` | GET | — — last 5 completed (FIFO ring) |
| `/profiler/sessions` | DELETE | — — wipe completed |
| `/profiler/session/{id}` | GET | — — `?include=events,domains,ips` |
| `/profiler/session/{id}` | DELETE | — |
| `/profiler/stream` | GET | — — SSE per-session (требует active) |
| `/profiler/secondary-packages` | PATCH/POST | `{"secondary_packages":[...]}` |

```bash
# Начать сессию для com.example.app, пометить webview-host'ы как secondary
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"package":"com.example.app","verbose":false,"secondary_packages":["com.google.android.webview"]}' \
  "$BASE/profiler/start"
# → {id, target_package, started_at, ...} ИЛИ 409 {error:"already_active",active_session_id}

# Текущая сессия (или 404)
curl -s -H "$HDR" "$BASE/profiler/active" | jq

# Stream live events (Ctrl-C завершает)
curl -N -H "$HDR" "$BASE/profiler/stream"

# Detail с full events
curl -s -H "$HDR" "$BASE/profiler/session/<id>?include=events,domains" | jq

# Stop
curl -X POST -H "$HDR" "$BASE/profiler/stop"
```

**Confidence levels** в каждом event: `verified` (router-package matched target) / `secondary` (matched secondary_packages) / `inferred` (post-DNS process inference, 10s window) / `unattributed` (нет owner). UI показывает легенду; для post-mortem analysis фильтровать по `confidence`.

### System-wide (§048 Live tab)

Idempotent toggle для recording, подключающего тот же connections-источник без active session. **Idle profiler ничего не делает** — recording on только при явном start.

| Endpoint | Метод | Что |
|---|---|---|
| `/profiler/live/start` | POST | `startGlobalRecording` — attach AppLog listener + subscribe на CommandClient connections-push (§168) |
| `/profiler/live/stop` | POST | `stopGlobalRecording` — detach (если нет per-app session) |
| `/profiler/live/state` | GET | `{recording, started_at, buffer_count, unattributed_count, banner_active}` |
| `/profiler/live` | GET | `{window_seconds, count, events}` — global rolling buffer snapshot, `?seconds=60` (default) |
| `/profiler/live/stream` | GET | SSE — все system-wide TrafficEvent'ы live |
| `/profiler/live/unattributed` | GET | `{count, recent_count_30s, banner_active, events}` — unattributed ring (DNS-fail без owner / TCP без process attribution) |

```bash
# Включить system-wide recording
curl -X POST -H "$HDR" "$BASE/profiler/live/start"
# → {ok, recording:true, started_at}

# Снять окно последних 30s (TCP/UDP open/close + DNS)
curl -s -H "$HDR" "$BASE/profiler/live?seconds=30" | jq '.count, .events[0]'

# Live stream (для observing в реальном времени)
curl -N -H "$HDR" "$BASE/profiler/live/stream"

# Что система не смогла attribute'нуть к app'у (banner triggers)
curl -s -H "$HDR" "$BASE/profiler/live/unattributed" | jq '.recent_count_30s, .banner_active'

# Выключить
curl -X POST -H "$HDR" "$BASE/profiler/live/stop"
```

**Когда что использовать:**
- Per-app session — root cause «почему именно app X не открывает Y»: get domain chain, IP, chain'ы, port-test history.
- System-wide live — discovery «что вообще происходит на устройстве сейчас»: DNS sniff, leakage detection (трафик мимо ожидаемых rules), unattributed events banner.

---

## Clash API proxy — `/clash/*` (removed in §122)

**Удалено.** `/clash/*` proxy и роут `GET /state/clash` выпилены в §122 (commit `2711f5b` — выпил Clash-моста). UI и весь runtime-контроль (proxies, group-delay, connections snapshot) переехали на libbox **CommandClient**:

- proxies / switch selector / group urltest → CommandClient unary-RPC + `/action/urltest` / `/action/switch-node` / `/action/set-group`.
- connections snapshot / live → CommandClient connections-push, см. [Profiler](#profiler--profiler) (`/profiler/live*`).

Старый `clash-api-reference.md` сохранён как историческая справка по поведению sing-box clash-api, но соответствующих роутов в Debug API больше **нет** — запрос на `/clash/*` или `/state/clash` вернёт `404 not_found`.

---

## Common errors

| Status | Code | Когда |
|---|---|---|
| 400 | `bad_request` | missing/wrong query, malformed JSON, wrong field type, unsupported method |
| 401 | `unauthorized` | нет/неверный Bearer token |
| 403 | `invalid_host` | Host header не `127.0.0.1`/`localhost` (rebind guard) |
| 404 | `not_found` | unknown endpoint, id не существует |
| 409 | `conflict` | pre-condition (tunnel down, controller not ready, blocked var) |
| 413 | `payload_too_large` | body > 1 MiB |
| 502 | `upstream_error` | native plugin / CommandClient / saveConfig failed |
| 504 | `timeout` | handler не уложился в 30s |
| 500 | `internal` | unhandled — детали в AppLog, не в response |

Shape ошибки:
```json
{"error": {"code": "bad_request", "message": "missing query param: tag"}}
```

### Structured tunnel alerts — `state.last_error`

Не error envelope endpoint'а, а semantic-сигнал из VPN-сервиса. После `start-vpn` если sing-box остановился из-за чего-то actionable — `state.last_error` начинается с `Stopped: alert:<type>:<details>`. Текущие типы:

| Prefix | Когда | Detail |
|---|---|---|
| `alert:permission_location:<comma-list>` | §050 — config содержит `wifi_ssid`/`wifi_bssid` правила, но не выданы required permissions | Comma-separated Android permission names. На API 30+: `ACCESS_BACKGROUND_LOCATION` (только Settings). На API 33+ в дополнение: `NEARBY_WIFI_DEVICES` (можно runtime prompt'ом). Без NEARBY на targetSdk≥33 `WifiInfo.ssid` = `"<unknown ssid>"`, rules silently не матчатся. |

```bash
curl -s -H "$HDR" "$BASE/state" | jq '.last_error'
# → "Stopped: alert:permission_location:android.permission.ACCESS_BACKGROUND_LOCATION,android.permission.NEARBY_WIFI_DEVICES"

# Quick test grant permissions через adb (вместо UI)
adb shell pm grant com.leadaxe.lxbox android.permission.NEARBY_WIFI_DEVICES
adb shell pm grant com.leadaxe.lxbox android.permission.ACCESS_BACKGROUND_LOCATION

# Re-start
curl -X POST -H "$HDR" "$BASE/action/start-vpn"
```

---

## Tips

### Batch mutation → single rebuild

Каждый write принимает `?rebuild=true`, но если меняешь несколько вещей — эффективнее написать без `rebuild`, потом один раз:

```bash
curl -X PUT  -H "$HDR" -H "Content-Type: application/json" -d '...' "$BASE/settings/route_final"
curl -X PUT  -H "$HDR" -H "Content-Type: application/json" -d '...' "$BASE/settings/dns_options/servers"
curl -X POST -H "$HDR" -H "Content-Type: application/json" -d '...' "$BASE/rules"
# Один rebuild вместо 3
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"
```

### Watch state

```bash
# Poll tunnel + traffic каждые 2s
while :; do
  curl -s -H "$HDR" "$BASE/state" | \
    jq -c '{t:.tunnel, act:.active_in_group, up:.traffic.up_total, dn:.traffic.down_total}'
  sleep 2
done
```

### URL-encode тегов с эмодзи

```bash
enc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }

# Теги нод/групп передаются query-параметром — энкодим значение
TAG="BL: 🇫🇷 France, Paris | [BL]"
curl -X POST -H "$HDR" "$BASE/action/switch-node?tag=$(enc "$TAG")"

# URLTest группы с эмодзи в имени
GROUP="✨auto"
curl -X POST -H "$HDR" "$BASE/action/urltest?group=$(enc "$GROUP")"
```

### Snapshot before dangerous write

```bash
# Backup
curl -s -H "$HDR" "$BASE/state/storage?reveal=true" > /tmp/storage.backup.json
curl -s -H "$HDR" "$BASE/state/subs?reveal=true" > /tmp/subs.backup.json
curl -s -H "$HDR" "$BASE/state/rules" > /tmp/rules.backup.json
curl -s -H "$HDR" "$BASE/config" > /tmp/config.backup.json
```

Восстановление через API не полное (restore полной storage нет), но `PUT /config` позволяет восстановить sing-box side. Для storage — через UI или ADB-бэкап shared_prefs.
