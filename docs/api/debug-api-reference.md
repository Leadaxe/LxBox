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
- `GET /backup/export?include=storage` отдаёт весь `SettingsStorage.exportRaw()`.
- `GET /state/subs?reveal=true` отдаёт **полные URL подписок** (с секретами).
- `PUT /config` / `POST /backup/import` / все CRUD-роуты полностью перезаписывают состояние.

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
  - [identity подписки (§289)](#346--identity-подписки-289)
  - [Import rules CRUD — `/subs/{id}/rules`](#346--import-rules-crud--subsidrules)
  - [`reveal` и `warnings` у одной записи (478)](#фича-478--reveal-и-warnings-у-одной-записи)
- [Nodes — `/nodes/*`](#nodes--nodes)
- [Directions CRUD — `/directions/*`](#directions-crud--directions)
- [Chains CRUD — `/chains/*`](#chains-crud--chains)
- [Folders CRUD — `/folders/*`](#folders-crud--folders)
- [Core-rejected nodes — `/core_reject/*`](#core-rejected-nodes--core_reject)
- [WARP — `/warp`](#warp--warp)
- [Pool — `/pool`](#pool--pool)
- [Settings writes — `/settings/*`](#settings-writes--settings)
- [Wi-Fi history — `/wifi_history`](#wi-fi-history--wifi_history)
- [Files](#files)
- [Support feed — `/support/*`](#support-feed--support)
- [Profiler — `/profiler/*`](#profiler--profiler)
- [Common errors](#common-errors)

---

## State & introspection

| Endpoint | Что отдаёт |
|---|---|
| `GET /ping` | `{pong,server,uptime_seconds}` — **без auth** |
| `GET /help` | `?format=text\|json` — самодокументируемая карта всей поверхности API. **Без auth** (второй no-auth endpoint). `json` — для auto-tooling, `text` (default) — human-readable cheatsheet. |
| `GET /state` | full HomeState: tunnel/busy/config_length/**running_config_length** (§311: null = снапшота ядра нет; вместе с `config_length` показывает расхождение running↔saved)/active_in_group/selected_group/last_delay/ping_busy/traffic/… **§250** — `last_start_error` + `last_start_error_at` (ISO-8601 / null): last VPN start/stop failure reason; cleared only by a successful start; in-memory (empty after process restart). В отличие от `last_error` не затирается UI-consume (`clearError`) — живёт до следующего успешного старта. |
| `GET /state/subs` | массив подписок, `?reveal=true` показывает clear URLs |
| `GET /state/rules` | массив custom rules с `srs_cached/srs_mtime` |
| `GET /state/storage` | весь `SettingsStorage._cache` в форме хранения 1.0 (§439: `storage_version`, `sources[]`, `rules[]`, `dns{}`) со scrubber'ом: `vars.debug_token` → `***`, `url` подписки — маской, `origin.raw` сервера → `origin.raw_bytes`, `nodes[]` папки → `nodes_count`. Ключей `server_lists` / `custom_rules` / `dns_options` / `chains` больше нет — [STORAGE.md](../STORAGE.md#storage-form-and-migration-439) |
| `GET /state/vpn` | `{auto_start,keep_on_exit,allow_bypass,current_session_allow_bypass,background_mode,is_ignoring_battery_optimizations}`. **§069** — `current_session_allow_bypass` это **runtime applied** значение (snapshot из последнего `VpnService.Builder.allowBypass()` в `establish()`); может отличаться от persisted `allow_bypass` если юзер поменял toggle без VPN reload. `false` пока VPN never started или после `stop`. |
| `GET /state/config_locked` | `{locked: bool}` — §037 текущее состояние auto-rebuild lock'а |
| `GET /device` | Android version, model, ABI, app version + build, core version (libbox / sing-box-lx), VPN permission, network type, uptime |

```bash
curl -s -H "$HDR" "$BASE/state" | jq '{tunnel,active_in_group,nodes_count,groups}'
curl -s -H "$HDR" "$BASE/state/subs" | jq 'map({id,title,enabled,nodes_count})'
curl -s -H "$HDR" "$BASE/state/storage?reveal=true" | jq '.vars | keys'
# Форма хранения и источники (§439/§509): цепочки в sources[] в порядке списка
curl -s -H "$HDR" "$BASE/state/storage" | \
  jq '{v: .storage_version, sources: [.sources[] | {kind, id, name, tag}], rules: (.rules | length)}'
```

---

## Config

| Endpoint | Метод | Назначение |
|---|---|---|
| `GET /config` | GET | raw JSON **сохранённого** конфига (as-is из памяти HomeController; §311 — при живом туннеле может опережать ядро) |
| `GET /config/pretty` | GET | тот же JSON с indent: 2 |
| `GET /config/path` | GET | `{app_documents_dir,note}` — путь Flutter dir, не sing-box (см. note) |
| `GET /config/running` | GET | §311 — снапшот конфига **работающего ядра** (kernel SPEC 036 `GetRunningConfig`). Re-marshal распарсенных options (post-override tun, omitempty) — diff с `/config` только семантический. `409 conflict` = туннель down / ядро < `lx.16-rc.3` / снапшот ещё не подтянут lazy-fetch'ем |
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
| `POST /action/urltest` | `tag=<node>` \| `group=<tag>` \| `all=true` \| `cancel=1` | единый URLTest-диспатч (ровно один scope): `tag` — single-node; `group` — групповой URLTest ядра (§308: force-тест ВСЕХ членов + переселект на живой узел; fire-and-forget — `ok` значит «команда принята», результат смотреть через `GET /state` → `active_in_group`; URL — из конфига группы, не из ping settings; 409 если tunnel down); `all` — mass-ping всех нод активной группы (concurrency 10); `cancel=1` — отмена in-flight mass-ping (§163, epoch-bump; уже запущенные групповые прогоны в ядре не отменяет). → `{ok,action,scope,...}` |
| `POST /action/switch-node` | `tag=<tag>` | selector switch на node. 409 если не выбрана группа |
| `POST /action/set-group` | `group=<tag>` | смена активной группы |
| `POST /action/start-vpn` | — | `runCoreRejectGuard(guard=false)` → прежний `home.start()` через Activity (может показать consent-диалог), **без** цикла страховки. Публичный Intent API (§047) этот путь не зовёт — native `LxBoxIntentReceiver` идёт в `BoxVpnService.start` напрямую |
| `POST /action/start-vpn-headless` | `guard=true` | §165 — старт VPN **без** Activity/consent, прямо через `BoxVpnService.start()`. Работает только если VPN-разрешение уже выдано (`VpnService.prepare()==null`). Для self-test/automation. → `{"ok":true,"action":"start-vpn-headless","started":<bool>,"needs_consent":<bool>}`. **Фича 478**, `guard=true` — старт **через страховку** асинхронно: тот же автомат, что на кнопке Start, но реальные старты — headless (`startVpnHeadless`, не Activity) → `{guard:true, started:true, async:true}` сразу; фазу/исход читать через `GET /core_reject` (409 если прогон уже идёт). Диалога предела на экране нет — `POST /core_reject/prompt?answer=keep` можно заранее или пока висит вопрос. Без флага — прежний путь |
| `POST /action/check-config` | `timeout_ms=<N>` | **Фича 478** — `Libbox.checkConfig`: с телом запроса проверяет **этот** JSON; без тела — **текущий собранный** конфиг на диске (не пересобранный на лету). Та же проверка, которой страховка крутит тихий цикл, но одним выстрелом и без туннеля. → `{config_ok:<bool>, error, ms, bytes}`, где `error` — **сырой** текст ядра (его и разбирает CANON §9). Сервер однопоточный, поэтому ждём с потолком: `timeout_ms` по умолчанию 10000, не больше таймаута запроса; не успели — 409 |
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
| `POST /action/quic-knobs` | `gso=on\|off` и/или `ecn=on\|off` (минимум один) | §341 — env-ручки quic-go для полевой A/B-диагностики offload-гипотез (hysteria2/tuic/masque-h3 мертвы на вендорском ядре — SPEC 044). `off` = принудительно выключить (env `QUIC_GO_DISABLE_GSO/ECN=true`), `on` = вернуть авто-детект (env снят; именно unset, не `false` — честнее в `/state`-археологии). Действует только на **НОВЫЕ** QUIC-сокеты — после переключения нужен `reload-vpn`/`reset-network`. Работает и без поднятого туннеля (static `Libbox.setQuic*Disabled`, Go-side `os.Setenv`). `native_ok:false` по ручке = AAR старее SPEC 044 (нет экспорта). → `{ok, action:"quic-knobs", gso?:{disabled,native_ok}, ecn?:{disabled,native_ok}}` |

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
| `/rules/move` | POST | `{"id":"<uuid>","after":"<uuid>"\|null}` — §370, зеркало drag'n'drop в UI |

`/rules/move` отличается от `reorder` тем, что не требует полного списка:
правило встаёт на `target.num + 1`, соседи сдвигаются только если это число
занято. `after: null` — в начало пользовательской зоны. Закреплённые правила
двигать нельзя — запрос отклоняется.

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
  "dns": {"enabled": true, "server_tag": "<tag>", "force_ipv4": false}, // inline/srs DNS-опция: dedicated server + Force IPv4 (drop AAAA); поля независимы, server_tag обязателен лишь при enabled=true
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

Подписки + inline user-servers. Shape в GET — как `/state/subs`. §435 — у
записи `kind: UserServer` есть `sections` (секции узла как хранятся, с
плейсхолдерами `@self`; `null` — нет); read-only, PATCH его не принимает.

| Endpoint | Метод | Body |
|---|---|---|
| `/subs` | GET | `?reveal=true` — clear URLs |
| `/subs` | POST | `{"input":"<url\|URI\|WG-ini\|JSON-outbound>"}` |
| `/subs/{id}` | GET | `?reveal=true`, `?warnings=true` — см. ниже |
| `/subs/{id}` | PATCH | subset: name/enabled/tag_prefix/update_interval_hours/override_detour/register_detour_{servers,in_auto}/use_detour_servers/replace_detour_chain/url + **§346**: on_update_action/import_rules_enabled/identity. **§439:** `override_detour` — ссылка на узел `{folder_id?, tag}`, `null` снимает |
| `/subs/{id}` | DELETE | — |
| `/subs/{id}/refresh` | POST | trigger fetch. 409 для UserServer |
| `/subs/reorder` | POST | `{"order":[id1,...]}` |

### Фича 478 — `reveal` и `warnings` у одной записи

**`?reveal=true`** теперь отдаёт `raw` и у одиночного `UserServer` — текст
узла, как он сохранён. Раньше сырое тело показывал только член папки, и
сличить разбор с источником у одиночной записи было нечем. Несёт
credentials, поэтому симметрично папке: только под `reveal`.

**`?warnings=true`** добавляет `origin_kind`, `source_kind` (§455/§480) и ключ
`warnings` — предупреждения разбора **по узлам**:

```jsonc
{
  "id": "…", "kind": "SubscriptionServers", …,
  "origin_kind": "uri",
  "source_kind": "uri_lines",
  "warnings": {
    "🇩🇪 Frankfurt": [
      {
        "code": "reality_fp_not_chrome",
        "severity": "warning",
        "path": "tls.utls.fingerprint",
        "value": "safari",
        "title_en": "…", "text_en": "…"
      }
    ],
    "Tokyo": []
  }
}
```

Все узлы присутствуют; у узла без предупреждений — пустой список. Тексты — **пиненный
английский**: ответ не должен зависеть от локали устройства, а проверять надо
резолв кода и подстановки, а не вёрстку. У предупреждений, чей текст пока
живёт классом приложения (не кодом реестра), `code`/`path`/`value`/`title_en`
— `null`, а `text_en` есть всегда (`NodeWarning.renderEn()`). По мере
перевода классов на `RegistryWarning` форма ответа не меняется — у кода
просто появляются `path`/`value`.

По умолчанию выключено: на 500 узлах это лишний вес.

**Добавить подписку:**
```bash
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"input":"https://provider.example/sub/abc123"}' \
  "$BASE/subs"
# → {"ok":true,"action":"subs-add","id":"<new>","kind":"SubscriptionServers"}
```

**Отказ `addFromInput` (§500)** — запись не создаётся, `400 bad_request`.
В теле, кроме `error.message` (базовая фраза без деталей), массив `dropped`
с причинами отбраковки (код реестра; `value` у секретных полей — `***`):

```json
{
  "error": {
    "code": "bad_request",
    "message": "addFromInput rejected: Could not parse direct link"
  },
  "dropped": [
    {
      "code": "type_invalid",
      "path": "address",
      "value": "1.2.3.4/64",
      "title_en": "Field address removed: wrong type"
    }
  ]
}
```

Если ввод не распознан как ссылка/JSON (нет причины разбора), `dropped`
отсутствует.

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

### §439 — `override_detour` ссылкой на узел (NodeLink)

С 2.23.3 detour источника — не финальный тег конфига, а ссылка
`{folder_id?, tag}` (D-112, `contract/docs/NODE_LINK.md`). Та же форма в ответах
`/subs` и `/state/subs` (`override_detour` и `detour_policy.override_detour`,
`null` — detour нет).

| Цель | Ссылка |
|---|---|
| член папки | `{"folder_id":"<id папки>","tag":"<сырой тег, до префикса>"}` |
| узел или группа подписки | `{"folder_id":"<id подписки>","tag":"<сырой тег>"}` |
| одиночный сервер | `{"tag":"<его финальный тег>"}` |
| Направление, `direct-out`, цепочка | `{"tag":"vpn-2"}` |

- Строка читается терпимо: как `{tag}`, а у папки — как сырой тег её члена,
  если такой член есть.
- Резолв — только на сборке. Не разрешившаяся ссылка **выпадает вместе с
  носителем** (узел не уходит напрямую), предупреждение — в сборке.
- `tag_prefix` одиночного сервера входит в его корневой адрес: смена префикса
  через этот PATCH переписывает ссылки на сервер. `DELETE /subs/{id}` гасит
  ссылки на узлы источника (detour снимается, позиция уходит из цепочек).

```bash
# detour подписки через член папки Jump (сырой тег члена, без префикса папки)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"override_detour":{"folder_id":"<folder id>","tag":"Jump"}}' \
  "$BASE/subs/<id>?rebuild=true"
# → {..., "override_detour":{"folder_id":"<folder id>","tag":"Jump"}, ...}

# Через Направление
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"override_detour":{"tag":"vpn-2"}}' "$BASE/subs/<id>"

# Снять detour
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"override_detour":null}' "$BASE/subs/<id>"
```

### §346 — identity подписки (§289)

`identity` — **тристейт**, поэтому не `null`-как-обычно:

| body | результат |
|---|---|
| ключ отсутствует | не трогаем |
| `"identity": null` | Custom → Default (глобальная идентичность §118) |
| `"identity": {...}` | Custom + наложение переданных полей **поверх слепка** |

Объект — патч, а не полная замена: при переходе в Custom слепок сначала
инициализируется копией глобальных значений, потом накладываются переданные
ключи. Поля: `user_agent`, `send_hwid`, `hwid`, `device_os`, `ver_os`,
`device_model`; неизвестный ключ → 400.

```bash
# Включить x-hwid ТОЛЬКО этой подписке (глобальные subscription_* не трогаются).
# Типовой кейс: Remnawave-панель с HWID-гейтом отдаёт заглушку
# `vless://0000…#App not supported` (§310), пока не увидит x-hwid.
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"identity":{"send_hwid":true,"hwid":"'$(uuidgen | tr A-Z a-z)'"}}' \
  "$BASE/subs/<id>"
curl -X POST -H "$HDR" "$BASE/subs/<id>/refresh" && sleep 5
curl -s -H "$HDR" "$BASE/subs/<id>" | jq '{nodes_count,identity}'

# Обратно на глобальную идентичность
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"identity":null}' "$BASE/subs/<id>"
```

`on_update_action` (§323) — `rebuild|reload|none`; в отличие от толерантного
парса storage, мусор здесь → 400 (иначе опечатка молча дала бы дефолт).

### §346 — Import rules CRUD — `/subs/{id}/rules`

Правила обработки узлов на импорте (§302/§307/§332). Упорядоченная коллекция
без id → адресация **позиционным индексом**, как у членов папки в §238: после
`DELETE`/`reorder` индексы съезжают, следующий вызов строить по снапшоту
`rules` из ответа (его возвращает каждый write). Не-подписка (UserServer /
папка) → 409.

| Endpoint | Метод | Body |
|---|---|---|
| `/subs/{id}/rules` | GET | — → `{import_rules_enabled, rules:[{index,usable,…}]}` |
| `/subs/{id}/rules` | POST | shape правила; `?index=N` — вставка в позицию (default: в конец), 201 |
| `/subs/{id}/rules/{idx}` | GET | — |
| `/subs/{id}/rules/{idx}` | PATCH | subset полей правила |
| `/subs/{id}/rules/{idx}` | DELETE | — |
| `/subs/{id}/rules/reorder` | POST | `{"order":[старые индексы]}` — полная перестановка |

Shape правила = `ImportRule.toJson()` (тот же, что в storage/backup):
`conditions[]` (`path`, `op`: `contains|equals|matches`, `pattern`, `negate`,
`case_sensitive`), `match`: `all|any`, `action`: `replace|disable|enable`,
`target_path`, `replacement`, `replace_mode`: `set|substitute`, `substitute`,
`enabled`. Enum'ы и имена полей проверяются строго → 400.

```bash
# «Все узлы с ⚡ в теге — выключить»
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"conditions":[{"path":"tag","op":"contains","pattern":"⚡"}],"action":"disable"}' \
  "$BASE/subs/<id>/rules"
# → 201 {"ok":true,"index":0,"usable":true,"rules":[…]}

# Подменить SNI у всех узлов конкретного хоста
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"conditions":[{"path":"server","op":"equals","pattern":"bad.example"}],
       "action":"replace","target_path":"tls.server_name","replacement":"good.example"}' \
  "$BASE/subs/<id>/rules"

curl -s -H "$HDR" "$BASE/subs/<id>/rules" | jq '.rules[] | {index,usable,action}'
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"order":[1,0]}' "$BASE/subs/<id>/rules/reorder"
```

**Порядок значим:** правила применяются последовательно, последнее сработавшее
`enable`/`disable` побеждает (§332) — «выключить всё» первым правилом + точечные
`enable` дальше = whitelist.

`"usable": false` — правило распарсилось, но на импорте будет пропущено
(например Replace без `target_path`). Это не ошибка: недособранное правило
легально и в UI-редакторе.

**Когда применятся:** на **следующем** refresh — существующие ноды на месте не
переразбираются (поведение §302). Поэтому `?rebuild=true` на rules-write'ах
почти бесполезен (конфиг соберётся из старых нод), хотя и принимается для
единообразия. Порядок: правки правил → `POST /subs/{id}/refresh` → wait →
`POST /action/rebuild-config`.

**Quirks:**
- `PATCH /subs/{id}` с `url` на UserServer молча игнорируется (у inline-серверов нет URL).
- `replace_detour_chain` (§073) — bool detour-флаг, ранее пропущенный в PATCH-маппинге (асимметрия с соседними `register_detour_*`); теперь маппится. Config-significant → `?rebuild=true` чтобы применить.
- `POST /subs/{id}/refresh` на UserServer → 409 `conflict` (нечего фетчить).
- `POST /subs` с `?rebuild=true` **не ждёт fetch'а** — fetch асинхронный, rebuild'ит с текущими nodes (которых ещё нет → config без этих outbound'ов). Делай последовательно: `POST /subs` → `POST /subs/{id}/refresh` → wait → `POST /action/rebuild-config`.

---

## Nodes — `/nodes/*`

Фича 478. Узел глазами **эмиттера**, а не хранения. В `/subs/{id}` узел виден
так, как лежит (`raw`, секции, поля записи); здесь — тем, что приложение
отдаст наружу. Между двумя сторонами стоит эмиттер, и расхождение заметно
только когда обе читаются рядом.

| Endpoint | Метод | Что делает |
|---|---|---|
| `/nodes/link?tag=<tag>` | GET | экспорт узла ссылкой — ровно то, что кладёт в буфер `Copy link` (`NodeSpec.toUri()`) |

```bash
curl -s -H "$HDR" "$BASE/nodes/link?tag=vpn-1-node-7&reveal=true" | jq
# → {"tag":"node-7","protocol":"vless","uri":"vless://…","private_key":false}
curl -s -H "$HDR" "$BASE/nodes/link?tag=vpn-1-node-7" | jq
# → {"tag":"node-7","protocol":"vless","private_key":false,"error":"reveal required"}
```

- `tag` принимается и «как в конфиге» (с префиксом подписки), и голым: экран
  адресует узлы первым, хранение — вторым. Звенья цепочки (§404) тоже ищутся.
- `uri` несёт credentials → только с `?reveal=true` (симметрично `/subs/{id}` и
  `raw` члена папки). Без флага → `{error:"reveal required"}`.
- `private_key: true` — ссылка несёт приватный ключ владельца. На экране это
  поднимает диалог (§466); здесь предупреждение не теряется, а становится
  данными.
- Узел найден, но ссылкой не выражается (группы §208 и прочие узлы,
  собранные приложением без текста) → `{tag, protocol, error:"node has no
  link form"}`, а **не** 404: узел есть, ответ обязан отличать «нет узла» от
  «нет ссылки».
- Узла с таким тегом нет → 404.

---

## Directions CRUD — `/directions/*`

§238 — Направления роутинга §125/§393 (`directions[]` в storage). Обёртка над
`SettingsStorage.getDirections / addDirection / updateDirection /
deleteDirection` — семантика идентична UI: `vpn-1` неудаляем и всегда enabled,
удаление/выключение Направления деградирует rules-ссылки (route_final /
custom-rule outbound) на `vpn-1` (§202, необратимо), detour-ссылки
(корневые `{tag}` на Направление в `override_detour` источника и `detour` члена
папки) снимаются (None, §248). Shape ресурса —
storage-JSON Направления (`Direction.toJson()`, snake_case), включая поле
`detour` (§248 — Направление как detour-прослойка).

> **§393 — путь переименован.** До v2.21.0 эти же ресурсы жили под
> `/channels/*` («каналы роутинга»). Путь сменился на `/directions/*` **без
> алиаса**: старый `/channels` отдаёт 404, а не редирект. Скрипты правятся
> заменой сегмента пути — тела запросов и ответов те же, только имя сущности
> в тексте другое. Данные мигрируют сами (ключ storage `channels` →
> `directions`, one-shot).

**Теги произвольные, потолка нет** (§393): `vpn-N` — обычные теги, а не
фиксированный словарь; лимит в 10 Направлений снят. POST без `tag` выдаёт
первый свободный `vpn-N`, присланный `tag` принимается как есть. Отвергнутый
тег → 409 с машинной причиной в сообщении: `empty` | `reserved`
(`direct-out`/`block`/`dns-out`/…) | `duplicate` | `auto_twin` (столкновение с
существующим двойником `<tag>-auto`).

| Endpoint | Метод | Body |
|---|---|---|
| `/directions` | GET | — |
| `/directions/{tag}` | GET | tag = тег Направления (`vpn-1` или произвольный) |
| `/directions` | POST | опц. `{"label":"...","tag":"..."}` + любые PATCH-поля; без `tag` — первый свободный `vpn-N`, 201 |
| `/directions/{tag}` | PATCH | subset: `label,enabled,include_direct,include_block,node_filter,node_filter_invert,default_filter,include,interrupt_exist_connections,auto,detour` |
| `/directions/{tag}` | DELETE | — |
| `/directions/reorder` | POST | `{"order":["vpn-1",...]}` — ровно текущие теги |

Все write'ы принимают `?rebuild=true` (порядок Направлений = порядок эмита в
конфиге, так что reorder тоже config-significant).

```bash
# Список
curl -s -H "$HDR" "$BASE/directions" | jq 'map({tag,label,enabled})'

# Создать Направление с фильтром по немецким нодам и urltest-двойником
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"label":"Germany","node_filter":"DE|Frankfurt","auto":{"interval":"3m"}}' \
  "$BASE/directions?rebuild=true"
# → 201 {"tag":"vpn-2","label":"Germany",...,"rebuilt":true,...}

# Создать Направление с произвольным тегом (§393 — потолка в 10 нет)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"tag":"ru-exit","label":"RU exit","node_filter":"RU"}' \
  "$BASE/directions?rebuild=true"

# Включить round_robin балансировщик на Направлении
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"auto":{"mode":"round_robin","balancer":{"pool":4}}}' \
  "$BASE/directions/vpn-2?rebuild=true"

# Снять галку auto (убрать urltest-двойник)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"auto":null}' "$BASE/directions/vpn-2"

# Состав: предложить внутри vpn-2 опциями другие Направления (§393)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"include":["ru-exit"],"include_direct":true}' \
  "$BASE/directions/vpn-2?rebuild=true"

# Разрешить Направление как detour-мишень (§248/§274): появляется в пикерах
# detour; целью правил остаётся, существующие ссылки правил не трогаются
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"detour":true}' "$BASE/directions/vpn-2?rebuild=true"
# → {"tag":"vpn-2",...,"detour":true,"healed":{"rules":0,"detours":0,"includes":0,"chain_positions":0,"dns_servers":0},"rebuilt":true,...}
```

**Quirks:**
- `auto` в PATCH — **merge**, не replace: `{"auto":{"url":...}}` меняет только
  `url`, остальные urltest-опции (и вложенный `balancer{}`) сохраняются.
  Полный reset — прислать все поля явно. `"auto": null` — снять галку.
- `tag` immutable (системный id) → передан в PATCH → 400. Юзер-имя — `label`.
- `include` (§393) — теги **других** Направлений, предлагаемых опциями внутри
  этого. Эмитятся только цели, объявленные **выше** по списку (порядок задаёт
  `/directions/reorder`) — порядок и исключает циклы. Ссылка вниз по списку
  молча не попадает в конфиг.
- `PATCH vpn-1 {"enabled":false}` и `DELETE /directions/vpn-1` → 409 `conflict`.
- `detour` (§248/§274): `PATCH vpn-1 {"detour":true}` → 409 `conflict`
  (vpn-1 — главное Направление и heal-резерв, продуктовое решение).
  `include_block` с `detour` совместим (§274 снял 409 и тихую нормализацию):
  оба поля принимаются и сохраняются в любой комбинации.
- **Переименование при смене `detour`** (§274): префикс `⚙ ` в `label`
  зарезервирован как маркер detour-Направления (как ⚙-метка в тегах
  detour-серверов). `detour:true` дописывает его в сохранённый `label`,
  `detour:false` срезает; присланный `label` нормализуется так же (маркер у
  не-detour Направления молча срезается). Ответ мутации несёт УЖЕ
  нормализованный `label` — он может отличаться от присланного; скрипты,
  матчащие Направления, должны ключеваться по `tag` (он для этого и immutable).
- Ответы мутаций (POST/PATCH/DELETE) содержат `"healed": {"rules": N,
  "detours": M, "includes": K, "chain_positions": C, "dns_servers": D}` —
  счётчики вылеченных ссылок (API-аналог
  UI-SnackBar'а): `rules` — route_final / custom-rule outbound (у пресета —
  переменные типа `outbound`) → `vpn-1`
  (disable, delete; §274: detour flag-set НЕ heal-триггер — Направление
  остаётся целью правил, `rules` при `{"detour":true}` всегда 0);
  `dns_servers` (§441) — DNS-серверы, которые называли Направление, →
  `vpn-1` (disable, delete): переменная типа `outbound` у template (значение,
  равное умолчанию шаблона, снимается), `body.detour` у user — в корневом
  списке и в секциях узлов; `detours` —
  корневые `{tag}` на Направление в `override_detour` / `detour` члена →
  снимаются (disable, delete, detour flag-unset); пара `{folder_id, tag}`
  адресует узел и Направлением не бывает; `includes` — вычистка тега из `include[]` остальных
  Направлений. Ссылкой «на Направление» считается его tag И tag
  urltest-двойника `<tag>-auto`.
- **Удаление** вычищает тег из `include[]` всех остальных Направлений,
  **выключение — нет**: `include` переживает disable, билдер просто
  деградирует эмитируемую группу.
- Выключение Направления (enabled:false) деградирует ссылки сразу и
  **необратимо** — повторное включение старую ссылку не воскрешает (§202,
  Решение B).
- `node_filter`/`default_filter` валидируются как regex → битый паттерн 400
  (иначе уронил бы сборку конфига).
- POST с PATCH-полями применяет их **после** создания: конфликтный body
  (например невалидный regex в `node_filter`) вернёт ошибку, но Направление
  уже создано — с `label` из body (если был) и дефолтами остальных полей;
  прочие PATCH-поля body не применены.

---

## Chains CRUD — `/chains/*`

§393 C / SPEC 110 — **цепочки хопов**, третий вид источника рядом с
подписками и серверами (§439/§509: записи `kind: chain` в `sources[]` в
storage, отдельного ключа и поля `order` нет). Цепочка — это явный маршрут
`вы → хоп 1 → хоп 2 → цель`, который эмитится одним outbound'ом
`type: "chain"`. Не путать с detour: **цепочка — это источник (маршрут)**, а
detour — свойство отдельного узла. Позиция цепочки — узел, группа или
Направление.

**Порядок списка нормативен**: цепочка может ссылаться только на цепочки,
объявленные **выше** неё, — так исключаются циклы. `hops` — позиции в
**порядке пакета**: `hops[0]` — первый хоп от клиента.

**§439 — позиция — ссылка `{folder_id?, tag}`**, как `override_detour` у `/subs`:
член папки, узел или группа подписки — `{folder_id: <id папки или подписки>,
tag: <сырой тег, до префикса>}`; одиночный сервер, Направление, `direct-out`,
другая цепочка — `{tag}`. Строка читается как `{tag}`. Сборка резолвит ссылки в
финальные теги; не разрешившаяся позиция роняет цепочку целиком.

Ответ `GET /chains`, `GET /chains/{tag}` и мутаций: `tag`, `label`, `enabled` +
канон `source_chain.schema.json` (`idle_timeout`, `strip_evasion`, `strip`,
`rewrite`, `hops` ссылками). Поля `order` нет: место цепочки — её индекс в
списке.

| Endpoint | Метод | Body |
|---|---|---|
| `/chains` | GET | — |
| `/chains/{tag}` | GET | 404, если тега нет |
| `/chains` | POST | опц. `{"tag":"...","label":"..."}` + любые PATCH-поля; без `tag` — первый свободный `chain-N`, 201 |
| `/chains/{tag}` | PATCH | subset: `label,enabled,hops,idle_timeout,strip_evasion,strip,rewrite` |
| `/chains/{tag}` | DELETE | — |
| `/chains/{tag}/probe` | GET | `?url=&timeout_ms=` — послойная проба |

Тег цепочки проверяется против **и** цепочек, **и** Направлений (два
outbound'а с одним тегом роняют конфиг): отвергнутый → 409 с той же машинной
причиной, что у Направлений (`empty` | `reserved` | `duplicate` |
`auto_twin`). Body без `hops` создаёт пустую цепочку — как и в UI.

Write'ы проходят **тот же гейт, что и форма редактора**; блокирующая находка →
400 с её кодом:

| Код | Что нарушено |
|---|---|
| `tooFewHops` | меньше двух позиций |
| `emptyHop` | пустая позиция |
| `duplicateHop` | позиция повторяется |
| `selfReference` | цепочка ссылается на себя |
| `nestedNotFirst` | вложенная цепочка не на позиции 0 |
| `forwardChainReference` | ссылка на цепочку, объявленную ниже по списку |
| `realityUtlsStripped` | `strip tls.utls` на reality-узле |
| `tagEmpty` / `tagTaken` | тег пустой / занят |

Этот класс ошибок `sing-box check` **пропускает**, а `run` роняет, — поэтому
гейт стоит на записи, а не на сборке.

```bash
# Список (порядок нормативен)
curl -s -H "$HDR" "$BASE/chains" | jq 'map({tag,label,enabled,hops})'

# Создать цепочку из двух хопов (порядок = порядок пакета):
# одиночный сервер de-frankfurt-01 и узел подписки nl-ams-02 (сырой тег)
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"label":"DE → NL","hops":[{"tag":"de-frankfurt-01"},{"folder_id":"<subscription id>","tag":"nl-ams-02"}]}' \
  "$BASE/chains?rebuild=true"
# → 201 {"tag":"chain-1",...,"hops":[{"tag":"de-frankfurt-01"},{"folder_id":"<subscription id>","tag":"nl-ams-02"}]}

# Переставить позиции / добавить третий хоп (Направление)
curl -X PATCH -H "$HDR" -H "Content-Type: application/json" \
  -d '{"hops":[{"tag":"de-frankfurt-01"},{"tag":"vpn-2"},{"folder_id":"<subscription id>","tag":"nl-ams-02"}]}' \
  "$BASE/chains/chain-1?rebuild=true"

# Послойная проба (нужен живой VPN)
curl -s -H "$HDR" "$BASE/chains/chain-1/probe" | jq '.layers'
```

**`GET /chains/{tag}/probe` — послойная диагностика.** Меряет **префиксы**
маршрута: слой `k` — путь от клиента через позицию `k`. Ядро регистрирует для
каждого слоя тег `<chain>#<k>` — это документированный контракт ядра
(`config.ChainLayerTag`), общий с десктопным лаунчером. **Цена хопа — это
разность соседних слоёв, а не собственный замер**: хоп нельзя померить в
отрыве от пути к нему.

- Требует **работающего VPN** (иначе 409): теги слоёв существуют только в
  запущенном ядре.
- Позиции берутся из **собранного** конфига; 409, если цепочки в нём нет
  (выключена, деградирована, ни разу не собиралась).
- Прогон **последовательный** — худший случай `позиции × timeout_ms`; на
  длинных цепочках снижай `timeout_ms`, чтобы уложиться в 30-секундный таймаут
  запроса. Дефолты `url`/`timeout_ms` — из глобальных `ping_options`.
- Ответ: `layers[{pos, tag, probe_tag, cumulative_ms?, delta_ms?, error?,
  not_reached?}]`. **Первый упавший слой несёт текст ошибки ядра, а всё, что
  за ним, помечается `not_reached`** — «где рвётся маршрут» видно сразу.

**Quirks:**
- `tag` immutable → передан в PATCH → 400.
- `strip_evasion` — **тристейт**: поле опущено = оставить как есть, `null` =
  дефолт ядра, bool = явное значение.
- `strip` **заменяет** карту целиком; ключи только
  `tls.fragment` | `multiplex.padding` | `xhttp.padding` | `tls.utls`.
- `rewrite` — merge-patch по RFC 7396, по одному на тип outbound'а, хранится
  дословно.
- **DELETE не чистит чужие позиции**: позиции других цепочек, указывающие на
  удалённый тег, остаются, и такая цепочка деградирует целиком
  (`chain_hop_missing`); ответ перечисляет их в `"dangling_refs"`.
- Удаление узла или источника (`DELETE /subs/{id}`, `DELETE
  /folders/{id}/members/{idx}`) снимает позиции-ссылки на его узлы из всех
  цепочек; переименование узла правкой тела и перенос переписывают их (§439).
- Требование к ядру: `type: chain` есть с **sing-box-lx v1.14.0-lx.27**
  (в v2.21.0 пин — `v1.14.0-lx.28-rc.1`). На более старом ядре цепочки не
  собираются.
- Полевые правила (проверено на живых прогонах): **MASQUE позади TCP-хопа
  требует `vhttp: auto`** (фиксированный `h3` шлёт QUIC-датаграммы через
  TCP-хоп без бюджета хендшейка → стабильный `deadline`); **WireGuard за
  TCP-хопом требует сервера с реальным UDP-проксированием** — у WG
  альтернативной ноги нет, а детектора «сервер не умеет UDP» не существует.

---

## Folders CRUD — `/folders/*`

§238 — папки серверов §234 (§439: запись `kind: folder` в `sources[]`, члены —
`nodes[]`) поверх публичных методов `SubscriptionController`. Папка — это entry
общего списка `/subs` (kind=`FolderServers`): **meta папки
(name/enabled/tag_prefix/detour_policy, общий detour — `override_detour`)
правится через `PATCH /subs/{id}`**, `/folders/*` добавляет только
папко-специфичные операции.

**§439 — `detour` члена — ссылка `{folder_id?, tag}`** (форма та же, что у
`override_detour`, см. `/subs`): сосед по папке — `{"folder_id":"<id этой
папки>","tag":"<сырой тег соседа>"}`, Направление или одиночный сервер —
`{"tag":"..."}`, `null` снимает. Строка читается как сырой тег соседа, если такой
член есть, иначе как `{tag}`. В GET `detour` — ссылка или `null`. Не разрешившийся
на сборке detour выбрасывает узел из конфига (напрямую он не уходит).

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
| `/folders/{id}/members/{idx}` | PATCH | subset `{raw,enabled,detour}` — §435: `sections` члена в GET read-only, PATCH не принимает |
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

# Личный detour члена 1 (Beta) через члена 0 (Alpha), §237 — ссылка парой (§439)
curl -X PATCH -H "$HDR" -d "{\"detour\":{\"folder_id\":\"$FID\",\"tag\":\"Alpha\"}}" "$BASE/folders/$FID/members/1"
# → {..., "folder":{..., "members":[..., {"index":1,"detour":{"folder_id":"<FID>","tag":"Alpha"},...}]}}
# Снять личный detour, выключить члена 1
curl -X PATCH -H "$HDR" -d '{"detour":null}' "$BASE/folders/$FID/members/1"
curl -X PATCH -H "$HDR" -d '{"enabled":false}' "$BASE/folders/$FID/members/1"

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

## Core-rejected nodes — `/core_reject/*`

Фича 478 — страховка «узел, который не приняло ядро, выключается сам». Ядро
отказало, назвав узел → приложение выключает этот узел, кладёт рядом причину
и тихо перепроверяет конфиг, пока он не станет чистым.

**Одно нажатие Start = ДВА реальных старта ядра** (сигнальный и финальный),
между ними — тихий цикл `checkConfig` без туннеля; каждый круг цикла выключает
ровно один узел. Поэтому `phase`, прошедшая
`signal_start → checking → final_start → done` с непустым `disabled`, —
нормальный успех, а не сбой.

| Endpoint | Метод | Что |
|---|---|---|
| `/core_reject` | GET | состояние автомата текущего (или последнего) прогона |
| `/core_reject/nodes` | GET | **все** вердикты, стоящие в хранении: `[{source, tag, reason}]` |
| `/core_reject/banner` | GET | плашка «выключено N»: `{visible, count, nodes:[{tag,reason}]}` |
| `/core_reject/banner/dismiss` | POST | закрыть плашку (идемпотентно) |
| `/core_reject/prompt` | GET | вопрос про предел кругов: `{pending, count, limit}` |
| `/core_reject/prompt?answer=stop\|keep` | POST | ответить на него за человека; `keep` можно поставить в очередь заранее |
| `/core_reject/cancel` | POST | отменить идущий прогон — то же, что нажатие кнопки в фазе цикла |
| `/core_reject/reset` | POST | сбросить состояние прогона в памяти (`phase→idle`, `round→0`); вердикты в хранилище и плашка не трогаются. 409 если прогон уже идёт |
| `/core_reject/enable?tag=<tag>` | POST | снять вердикт руками (emitted-тег ядра или сырой тег идентичности) |
| `/core_reject/notifications[?tag=<tag>]` | GET | что нарисуют строка и карточка узла: `[{code, severity, params, title_en, text_en}]` |

`GET /core_reject`:

```json
{
  "phase": "checking",
  "round": 3,
  "round_limit": 10,
  "disabled": [{"tag": "vpn-1-node-7", "reason": "unknown method: rc4-md5"}],
  "outcome": null,
  "error": ""
}
```

| Поле | Что |
|---|---|
| `phase` | `idle` \| `signal_start` \| `checking` \| `awaiting_prompt` \| `final_start` \| `done` |
| `round` | круг тихой проверки; `0` — цикл ещё не начинался |
| `round_limit` | после этого числа кругов автомат спрашивает человека |
| `disabled` | узлы, выключенные **этим прогоном**, в порядке отказов ядра |
| `outcome` | `null` до конца прогона, затем `started_clean` \| `started_with_disabled` \| `failed` \| `stopped_by_user` |
| `error` | текст ошибки прогона; пусто у успеха |

**Прогон vs хранение.** `/core_reject` живёт в памяти — после перезапуска
процесса он пуст. Стоящие вердикты лежат рядом с узлами и перезапуск
переживают: их отдаёт `/core_reject/nodes`, где `source` — отображаемое имя
записи (у одиночного сервера — label/tag узла, а не пустой `list.name`).

**Плашка** поднимается только на `outcome=started_with_disabled`: VPN поднят,
но не тем составом, который задавал человек. Уходит при × (`dismiss`), Stop/
Disconnected, следующем Start или перезапуске процесса (§498); вердикты на
узлах при этом не снимаются. После Stop `GET /core_reject/banner` отдаёт
`visible: false`. `dismiss` закрывает сообщение, а не отменяет решение.

**Вопрос про предел.** `count` — число ИЗ ТЕКСТА диалога, то есть предел
кругов, а не счётчик выключенных. `keep` снимает предел до конца этого Start,
`stop` заканчивает прогон: VPN не поднят, выключенные остаются выключенными.
Ответ принимается и query-параметром, и телом `{"answer":"..."}`.

**Отмена.** Во время тихого цикла кнопка на главном экране остаётся на своём
месте и становится отменой — иконка остановки, подпись та же
(`Checking servers… (N disabled)`). `POST /core_reject/cancel` делает ровно то
же самое снаружи: текущий круг доигрывает (прерывать ядро на середине
`checkConfig` нечем), следующий не начинается, исход — `stopped_by_user`. Если
в этот момент висел вопрос про предел, он закрывается ответом `stop`. Без
идущего прогона — 409.

**`/core_reject/notifications` — проверка рендера без экрана.** Тексты
приходят ДАННЫМИ контракта (`registry/warnings.json`), поэтому проверять надо
резолв кода, а не вёрстку: если `core_rejected` не нашёлся в реестре,
`title_en` вернётся самим кодом. Ответ пиненно английский — machine-поверхность
не должна зависеть от локали устройства. Без `tag` — карта `{tag: [...]}` по
всем узлам, у которых хранимые записи есть.

```bash
# Довести ядро до отказа и смотреть, что делает автомат
curl -X POST -H "$HDR" "$BASE/core_reject/prompt?answer=keep"   # снять предел заранее
curl -X POST -H "$HDR" "$BASE/action/start-vpn-headless?guard=true"
curl -s -H "$HDR" "$BASE/core_reject" | jq

# Если автомат уперся в предел кругов — ответить за человека
curl -s -H "$HDR" "$BASE/core_reject/prompt" | jq
curl -X POST -H "$HDR" "$BASE/core_reject/prompt?answer=keep"

# Что в итоге выключено и почему (переживает перезапуск процесса)
curl -s -H "$HDR" "$BASE/core_reject/nodes" | jq

# Что увидит человек на строке узла — код, severity и оба текста
curl -s -H "$HDR" "$BASE/core_reject/notifications?tag=vpn-1-node-7" | jq

# Вернуть узел руками
curl -X POST -H "$HDR" "$BASE/core_reject/enable?tag=vpn-1-node-7"
curl -X POST -H "$HDR" "$BASE/core_reject/banner/dismiss"
```

**Quirks:**
- `POST /core_reject/prompt?answer=keep` без висящего вопроса → `{queued:true}`
  (ответ ждёт следующего `askPrompt`). `answer=stop` без вопроса → 409.
- `POST /action/start-vpn-headless?guard=true` при уже идущем прогоне → 409.
- `answer` вне `stop|keep` → 400; `keep_checking` принимается синонимом `keep`.
- `POST /core_reject/enable` с тегом, которого нет ни у одного узла → 404.
- `GET /core_reject/notifications?tag=` с тегом без хранимых записей → 404
  (пустой список значил бы «узел есть, записей нет» — это разные факты).

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

- `tag` — auto-двойник round_robin-Направления (напр. `vpn-1-auto`).
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
| `/settings/enabled_groups` | PUT | `{"groups": ["tag",...]}`. **§125 legacy: фактически no-op** — после миграции на `directions[]` (§393; ключ storage переименован из `channels`) билдер читает `enabledGroups` только когда `directions` пуст, иначе `directions[]` перекрывает эту запись. Для управления Направлениями используйте UI (App Settings → Directions) / backup. `?rebuild=true` пересоберёт конфиг, но результат не изменится. → `{ok, action:"settings-enabled-groups", count, ...rebuild-extras}`. |
| `/settings/vpn_mode` | GET | →`{"ok":true,"vpn_mode":{...}}` — текущий `VpnModeConfig`. |
| `/settings/vpn_mode` | PUT | частичное обновление (copyWith поверх текущего): `mode`/`proxy_protocol`/`proxy_port`/`proxy_listen`/`proxy_auth`/`proxy_user`/`proxy_pass`. **Валидация (§292):** `proxy_listen` — IPv4, `proxy_port` — 1024..65535, `proxy_protocol` — `mixed`\|`http`\|`socks`; невалидное → 400. **§293:** запись идёт через `VpnSettingsFacade` (единый путь с UI) — на смену режима зеркалит native `has_tun` (гейтит `VpnService.prepare`), при auth+пустом пароле генерит его. **Config-significant** (меняет inbounds) → `?rebuild=true`. → `{ok, action:"settings-vpn-mode", vpn_mode, ...rebuild-extras}`. |
| `/settings/vars/{key}` | PUT | `{"value":"<str>"}`. Для ключей с side-effect-hook (§279: `app_language`) запись идёт через владеющий сервис, не через голый `setVar` — см. «Side-effect vars» ниже. |
| `/settings/vars/{key}` | DELETE | — (удаляет ключ; не пишет пустую строку). Для hook-ключей = сброс к дефолту через тот же сервис. |
| `/settings/dns_options/servers` | PUT | **§439:** `{"servers":[<запись dns.servers[]>]}` — только записи формы 1.0, как их отдаёт `GET /state/storage` → `dns.servers`: `{kind:"user", tag, enabled, body, description?}` (`body` — partial sing-box без `tag`), `{kind:"preset", ref:"<preset_id>:<tag>", enabled}` (`<tag>` — тег внутри пресета; вся строка — тег сервера в конфиге, например `ru-direct:dns_ru`; повтор пространства `ru-direct:ru-direct:…` ранних сборок 2.23.3 читается как одно), `{kind:"template", tag, enabled, vars?}`. Список заменяется целиком. Форма 2.23.2 (`kind: inline`, `varValues`, снимок без `kind`) → 400 с образцом записи, хранение не трогается. → `{ok, action:"settings-dns-servers", count}`. Путь URL прежний: это адрес API, не ключ файла. |
| `/settings/dns_options/rules` | PUT | **§439:** `{"rules":[<запись dns.rules[]>]}` — только записи формы 1.0: `{kind:"user", name, enabled, body}` (`body` — правило sing-box с `server`), `{kind:"preset", ref:"<preset_id>", enabled}`, `{kind:"srs", name, id, …}`, `{kind:"template", name, enabled}`. Форма 2.23.2 (`kind: inline` с `rule`, `presetId`) и строка JSON (`rules_json`) → 400 с образцом записи. → `{ok, action:"settings-dns-rules", count}`. |
| `/settings/config_locked` | PUT | `{"locked": true\|false}` — §037 toggle auto-rebuild lock. true → `generateConfig` возвращает null silently, custom config через `PUT /config` не перетирается UI. |
| `/settings/core_logs_enabled` | GET | →`{"enabled": bool}` — §043 текущее состояние forwarding'а sing-box логов в `/logs/core`. |
| `/settings/core_logs_enabled` | PUT | `{"enabled": true\|false}` — §043 включить/выключить forward. **Требует полного рестарта процесса** (`am force-stop` + relaunch, либо UI Quit & reopen) — `Libbox.setup` one-shot per process, stop/start VPN **не** перечитывает флаг. Default false. Storage в SharedPreferences (`boxvpn_boot.core_logs_enabled`), не в `lxbox_settings.json`. |
| `/settings/core_logs_verbose` | GET | →`{"enabled": bool}` — §345 состояние live-снятия TRACE/DEBUG-фильтра ядра. |
| `/settings/core_logs_verbose` | PUT | `{"enabled": true\|false}` — §345 пропускать TRACE/DEBUG-строки ядра в `/logs/core`. В отличие от `core_logs_enabled` **применяется мгновенно** (volatile в BoxService, без рестарта); бессилен при выключенном `core_logs_enabled` (ядро не форвардит вообще). Буфер core (500 строк) на живом трафике в verbose живёт секунды — включать точечно, снимать лог сразу. Default false. Storage в SharedPreferences (`boxvpn_boot.core_logs_verbose`). |
| `/settings/ping_options` | GET | →URLTest defaults `{url?, timeout_ms?, groups?}` (пустой map если не set'нуто — caller fall-through на template default). |
| `/settings/ping_options` | PUT | body `{url?, timeout_ms?, groups?}` — **overwrite целиком** (не merge). Unknown-подключи strip'аются (allowlist `url/timeout_ms/presets/groups`). `url` — string, `timeout_ms` — number, `groups` — object (иначе 400). → `{ok, action:"settings-ping-options", url, timeout_ms, groups_count}`. |
| `/settings/ping_options/groups/{tag}` | GET | override этой группы или **404** если override нет. |
| `/settings/ping_options/groups/{tag}` | PUT | body `{url?, timeout_ms?}` — минимум одно поле (read-modify-write). → `{ok, action:"settings-ping-options-group-put", group, ...}`. |
| `/settings/ping_options/groups/{tag}` | DELETE | снять override группы. → `{ok, action:"settings-ping-options-group-delete", group}`. |
| `/settings/tun_apps` | GET | →`{"mode":"off\|allow\|deny", "packages":[...]}` — §046 OS-level split-tunneling. |
| `/settings/tun_apps` | PUT | `{"mode":"off\|allow\|deny", "packages":["pkg1","pkg2",...]}` — §046. Replace целиком. Дубликаты в `packages` schлопываются (idempotent). Пустые строки skip'аются. **§293:** `mode` вне `off\|allow\|deny` → 400 (валидатор `TunAppsConfig.isValidMode`); невалидный package-name → 400. Response: `{ok, action, mode, count, rebuild_needed: true, ...rebuild-extras}`. **Требует full VPN restart** для apply (Android tun creates только на `establish()`). |
| `/settings/vpn/allow_bypass` | GET | →`{"enabled": bool}` — §052/§049 F15. |
| `/settings/vpn/allow_bypass` | PUT | `{"enabled": true\|false}` — §052/§049 F15. Native (`VpnService.Builder.allowBypass()`). Применяется при следующем `establish()` (start или reload VPN). Default false (strict tunnel). |
| `/settings/vpn/keep_on_exit` | GET | →`{"enabled": bool}` — §052. VPN остаётся активным когда app закрывается. |
| `/settings/vpn/keep_on_exit` | PUT | `{"enabled": true\|false}` — §052. Effect at app exit; live-reload не нужен. |
| `/settings/vpn/background_mode` | GET | →`{"mode": "never"\|"lazy"\|"always"}` — §052. Foreground-service режим. |
| `/settings/vpn/background_mode` | PUT | `{"mode": "never"\|"lazy"\|"always"}` — §052. `never` — туннель всегда активен (default); `lazy` — pause только в deep Doze; `always` — pause при выключении экрана. **§293:** `mode` вне набора → 400 (валидатор `BackgroundMode.isValid`; в отличие от чтения, где мусор молча fallback'ит в `never`). Применяется при следующем VPN connect. |
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

**Side-effect vars (§279):** часть ключей нельзя писать голым `setVar` —
сторадж разошёлся бы с живым состоянием до следующего полного старта. Для них
в vars-handler'е стоит per-key registry (прецедент §275 — мутации только через
владеющий сервис); generic-путь для остальных ключей не меняется.

- `app_language` (`system` | `en` | `ru`) — язык приложения (см.
  [STORAGE.md](../STORAGE.md#vars--template-vars--app-flags)). `PUT` диспатчится
  в `LocaleController.set()`: полный пайплайн смены локали — persist +
  native-зеркало (`boxvpn_boot.app_language`, notification/тайл/shortcuts
  перештамповываются при живом VPN) + `LocaleManager` на Android 13+ + rebuild
  UI. Невалидное значение → 400. `DELETE` = `set('system')` (ключ остаётся со
  значением `system`).

```bash
# Переключить приложение на русский (эффект мгновенный, без рестарта)
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"value":"ru"}' \
  "$BASE/settings/vars/app_language"

# Невалидное значение → 400
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"value":"de"}' \
  "$BASE/settings/vars/app_language"
# → 400 {"error":{"code":"bad_request","message":"app_language must be \"system\", \"en\" or \"ru\""}}

# Вернуть системный язык
curl -X DELETE -H "$HDR" "$BASE/settings/vars/app_language"
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

**DNS servers** (§439 — записи `dns.servers[]`; PUT заменяет список целиком, поэтому
удобнее взять текущий из `/state/storage` и дописать):
```bash
curl -s -H "$HDR" "$BASE/state/storage" | \
  jq '{servers: (.dns.servers + [
        {"kind":"user","tag":"dns-local","enabled":true,"body":{"type":"udp","server":"192.168.1.1"}}
      ])}' | \
  curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
    --data-binary @- "$BASE/settings/dns_options/servers?rebuild=true"
# → {"ok":true,"action":"settings-dns-servers","count":N,...}

# Форма 2.23.2 отвергается
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"servers":[{"kind":"inline","tag":"dns-local","enabled":true,"body":{"type":"udp","server":"192.168.1.1"}}]}' \
  "$BASE/settings/dns_options/servers"
# → 400 {"error":{"code":"bad_request","message":"dns server \"dns-local\": unknown kind \"inline\"; expected a record like {\"kind\":\"user\",...} (kind user|preset|template)"}}
```

**DNS rules** (§439 — записи `dns.rules[]`):
```bash
curl -s -H "$HDR" "$BASE/state/storage" | \
  jq '{rules: (.dns.rules + [
        {"kind":"user","name":"local","enabled":true,"body":{"domain_suffix":[".local"],"server":"dns-local"}}
      ])}' | \
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
| `GET /files/local` | `name=<name>` (whitelist: `cache.db`, `stderr.log`, `CrashReport-lxbox.log`, `CrashReport-lxbox.log.old`) |
| `GET /files/external` | legacy alias for `/files/local`, ради обратной совместимости |
| `GET /files/crash/list` | §316 — архив краш-репортов ядра: `[{name, size, mtime}]`, новые первыми; `[]` если крашей не было |
| `GET /files/crash` | §316 — `name=<file>` → тело архивного репорта |
| `GET /files/oom/list` | OOM-снапшоты ядра: `[{name, size, mtime, memory_usage, ...}]`, новые первыми |
| `GET /files/oom` | `name=<snapshot>` → файл снапшота; по умолчанию `metadata.json`, иначе `&file=heap.pb\|allocs.pb\|goroutine.pb\|go.log\|configuration.json` |

```bash
curl -s -H "$HDR" "$BASE/files/srs/list" | jq
curl -s -H "$HDR" "$BASE/files/srs?ruleId=abc-123" > /tmp/rule.srs

# Native stderr log (sing-box core, internal app-scoped storage)
curl -s -H "$HDR" "$BASE/files/local?name=stderr.log" | tail -30

# OOM-снапшот: сначала список, потом heap-профиль конкретного
curl -s -H "$HDR" "$BASE/files/oom/list" | jq
curl -s -H "$HDR" "$BASE/files/oom?name=<snapshot>&file=heap.pb" > /tmp/heap.pb
```

---

## Backup — `/backup/*`

Symmetric с UI `BackupScreen` (см. [§040 spec](../spec/features/040%20backup%20restore%20ui/spec.md)). Wire-format — single, без `version` поля в конверте; форму блока `storage` задаёт его `storage_version` (§439). Legacy `{vars, server_lists}` на корне конверта не поддерживается. Это внутренний бэкап LxBox, не LX Backup 1.0 для лаунчера.

| Endpoint | Что отдаёт / принимает |
|---|---|
| `GET /backup/export?include=storage,vpn_settings[&from=v0_bak]` | Snapshot. `include` опц., default — обе части. **§439** `from=v0_bak` — блок `storage` из `lxbox_settings.json.v0.bak` (форма 2.23.2 на момент миграции) вместо живого хранения; копии нет → 404; другое значение `from` → 400 |
| `POST /backup/import?merge=&rebuild=` | Восстановление. Body `{storage?, vpn_settings?}`. **§439** блок `storage` без `storage_version` (форма 2.23.2) сначала мигрирует; ссылки на узлы — тем же словарём, что при старте (тела подписок из `sub_cache`); ответ `applied.migrated` + `applied.migration` |

**Format**:
```json
{
  "app": "lxbox",
  "kind": "backup",
  "created_at": "2026-05-10T...",
  "source_app_version": "2.23.3+22303502",
  "storage": { ...lxbox_settings.json целиком: storage_version, vars, sources,
               rules, dns, tun_apps, directions, route_final, ... },
  "vpn_settings": {
    "auto_start": false,
    "keep_on_exit": false,
    "background_mode": "never",
    "core_logs_enabled": false,
    "allow_bypass": false
  }
}
```

- **`storage`** — глубокая копия `lxbox_settings.json` (все top-level keys плюс nested `vars` map), без скраббера. Включает `storage_version`, `sources`, `rules`, `dns`, `tun_apps`, `vars.wifi_history` и любые будущие top-level keys без правок API. Форма — [STORAGE.md](../STORAGE.md#storage-form-and-migration-439).
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

**§439 — форма 2.23.2 и откат.** Блок `storage` без `storage_version` (снятый на
2.23.2 и раньше) принимается и мигрирует до allowlist'а:

```bash
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  --data-binary @/tmp/lxbox-backup-2.23.2.json \
  "$BASE/backup/import?rebuild=true" | jq '.applied | {migrated, migration}'
# → {"migrated": true,
#    "migration": {"migrated": true,
#                  "info": ["sources: 3 subscriptions, …", "rules: 12 rules → 13 records", "dns: 5 servers, 4 rules", …],
#                  "warnings": [ … ]}}
# Блок формы 1.0 → "migrated": false, ключа migration нет (если нет предупреждений)
```

Копия исходника первой миграции — для стендов, где нужно вернуться на 2.23.2.
2.23.2 читает этот конверт своим `POST /backup/import`; бэкап формы 1.0 версия
2.23.2 не читает (allowlist отбросит `sources`, `rules`, `dns`,
`storage_version`).

```bash
curl -s -H "$HDR" "$BASE/backup/export?include=storage&from=v0_bak" > /tmp/lxbox-v0.json
# 404 — устройство не мигрировало с формы 2.23.2 (чистая установка 2.23.3)
```

⚠ Источники в памяти приложения (экран Servers) после `POST /backup/import` не перечитываются до холодного рестарта. Так и в 2.23.2, к §439 не относится.

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

## Support feed — `/support/*`

Лента поддержки (§356/§357): показ сообщений из `support.json` по очереди, с
гейтами по версии, времени активности и отложенному показу.

| Endpoint | Метод | Что |
|---|---|---|
| `/support/state` | GET | сырой `support_state.json` (`read`/`baseline`/`snooze`/`active`) + `app_version` + `total_active_seconds` |
| `/support/reset` | POST | стереть `read`/`baseline`/`snooze`/кэш — лента начинается заново. `?keep_active=false` обнуляет и счётчик активности |
| `/support/preview` | POST | тело = **одно** сообщение в формате ленты → немедленный полноэкранный показ, **все гейты обходятся** |

Параметры `/support/preview`:

| Параметр | По умолчанию | Что делает |
|---|---|---|
| `dry` | `true` | кнопки работают, но `markRead`/`snooze` **не** сохраняются; `?dry=false` — сохраняются |
| `snooze_hours` | `10` | `snooze_active_hours` синтетической ленты |

⚠ `/support/preview` требует живого UI-процесса — иначе `409`.

```bash
# Что лента думает о себе сейчас
curl -s -H "$HDR" "$BASE/support/state" | jq

# Показать сообщение на экране, ничего не записывая в состояние
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"id":"test-1","title":"Hi","message":"Preview"}' \
  "$BASE/support/preview"

# Прогнать ленту с нуля
curl -X POST -H "$HDR" "$BASE/support/reset"
```

---

## Profiler — `/profiler/*`

Traffic profiler — **system-wide** rolling buffer (§048, вкладка Profiler в Statistics). Источник событий (§168): parser sing-box core logs + connections-push от libbox **CommandClient** (`CcChannel.connections` через фоновый `profilerClient`, `connectProfiler()`). Clash `/connections` polling выпилен (§122 — Clash API dropped).

> **Per-app session удалена (§288).** Роуты `/profiler/{start,stop,active,
> sessions,session/<id>,stream,secondary-packages}` сняты вместе с
> session-слоем и вкладкой `Statistics → App`; запрос на любой из них вернёт
> `404`. Живые роуты профайлера — только `/profiler/live*` (ниже). Разбор
> трафика конкретного приложения делается фильтром по приложениям на вкладке
> Profiler. Историческая справка по атрибуции §168/§180 —
> [`../features/per-app-trace.md`](../features/per-app-trace.md).

**Confidence levels** в каждом event: `verified` (router-package matched target) / `secondary` (matched secondary_packages) / `inferred` (post-DNS process inference, 10s window) / `unattributed` (нет owner). UI показывает легенду; для post-mortem analysis фильтровать по `confidence`.

### System-wide (§048 Profiler tab)

Idempotent toggle для recording. **Idle profiler ничего не делает** — recording on только при явном start.

| Endpoint | Метод | Что |
|---|---|---|
| `/profiler/live/start` | POST | `startGlobalRecording` — attach AppLog listener + subscribe на CommandClient connections-push (§168) |
| `/profiler/live/stop` | POST | `stopGlobalRecording` — detach |
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
