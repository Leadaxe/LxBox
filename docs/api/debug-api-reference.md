# Debug API reference — curl cheatsheet

| Поле | Значение |
|------|----------|
| Статус | Reference |
| Дата | 2026-04-20 |
| Версия API | совместим со [`spec 031`](../spec/features/031%20debug%20api/spec.md) |
| Парный doc | [`clash-api-reference.md`](clash-api-reference.md) — всё что под `/clash/*` |

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

Все нижеследующие endpoints требуют `$HDR`. Общие rules:
- Content-type ответа: `application/json; charset=utf-8`.
- Write'ы (PUT/POST/PATCH/DELETE) возвращают `{"ok":true, "action":"<name>", ...extras}` или 4xx/5xx с `{"error":{"code":"...","message":"..."}}`.
- Любой write опционально принимает `?rebuild=true` — после успешного write'а регенерирует sing-box конфиг через `SubscriptionController.generateConfig()` + `HomeController.saveParsedConfig()`. Ответ расширяется `rebuilt:bool + config_bytes:N` (или `rebuild_error:str`).

---

## Index

- [State & introspection](#state--introspection)
- [Config](#config)
- [Logs](#logs)
- [Actions — триггеры](#actions--триггеры)
- [Rules CRUD — `/rules/*`](#rules-crud--rules)
- [Subscriptions CRUD — `/subs/*`](#subscriptions-crud--subs)
- [Settings writes — `/settings/*`](#settings-writes--settings)
- [Files](#files)
- [Clash API proxy — `/clash/*`](#clash-api-proxy--clash)
- [Common errors](#common-errors)

---

## State & introspection

| Endpoint | Что отдаёт |
|---|---|
| `GET /ping` | `{pong,server,uptime_seconds}` — **без auth** |
| `GET /state` | full HomeState: tunnel/busy/config_length/active_in_group/selected_group/last_delay/ping_busy/traffic/… |
| `GET /state/clash` | `{available,base_uri,secret:"***",api_ok}` — `?reveal=true` снимает маску secret'а |
| `GET /state/subs` | массив подписок, `?reveal=true` показывает clear URLs |
| `GET /state/rules` | массив custom rules с `srs_cached/srs_mtime` |
| `GET /state/storage` | весь `SettingsStorage._cache` со scrubber'ом (token/URL/nodes маскируются) |
| `GET /state/vpn` | `{auto_start,keep_on_exit,is_ignoring_battery_optimizations}` |
| `GET /device` | Android version, model, ABI, app version, VPN permission, network type, uptime |

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
- **Override временный.** Любой последующий `rebuild-config` (включая `?rebuild=true` на других CRUD) перегенерит из settings и сотрёт override.

---

## Logs

| Endpoint | Метод | Query |
|---|---|---|
| `GET /logs` | GET | `limit=N` (default 200), `source=app\|core\|all` |
| `POST /logs/clear` | POST | — |

```bash
curl -s -H "$HDR" "$BASE/logs?limit=20&source=app" | jq '.[-5:]'
curl -s -H "$HDR" -X POST "$BASE/logs/clear"
```

---

## Actions — триггеры

Все POST'ы. Response `{ok,action,...}`.

| Endpoint | Query | Что делает |
|---|---|---|
| `POST /action/ping-all` | — | toggle mass-ping (запущен → cancel, не запущен → start) |
| `POST /action/ping-node` | `tag=<tag>` | одиночный ping |
| `POST /action/run-urltest` | `group=<tag>` | `/group/<tag>/delay` + reload proxies. 409 если tunnel down |
| `POST /action/switch-node` | `tag=<tag>` | selector switch на node. 409 если не выбрана группа |
| `POST /action/set-group` | `group=<tag>` | смена активной группы |
| `POST /action/start-vpn` | — | `home.start()` (с VpnService.prepare dance) |
| `POST /action/stop-vpn` | — | `BoxVpnService.stop()` |
| `POST /action/rebuild-config` | — | `SubscriptionController.generateConfig()` + save |
| `POST /action/refresh-subs` | `force=true\|false` | триггер AutoUpdater |
| `POST /action/download-srs` | `ruleId=<id>` | скачать .srs для custom rule |
| `POST /action/clear-srs` | `ruleId=<id>` | удалить cached .srs |
| `POST /action/toast` | `msg=<str>&duration=short\|long` | Toast на устройстве (до 200 chars) |
| `POST /action/check-updates` | — | force update check |
| `POST /action/preview-empty-state` | `on=true\|false` | UI-only override: HomeScreen рендерит empty-state как при чистой инсталляции, реальные данные не трогаются. Полезно для скриншотов / regression UX. |

```bash
# Типичный flow диагностики
curl -X POST -H "$HDR" "$BASE/action/refresh-subs?force=true"
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"
curl -X POST -H "$HDR" "$BASE/action/run-urltest?group=✨auto"
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

**Shape CustomRule body** (все optional кроме `name`):
```json
{
  "name": "string",                 // required, non-empty
  "enabled": true,
  "kind": "inline|srs",
  "domains": ["exact.domain"],
  "domain_suffixes": [".ru","xn--p1ai"],
  "domain_keywords": ["tracker"],
  "ip_cidrs": ["10.0.0.0/8"],
  "ports": ["443","80"],
  "port_ranges": ["8000:9000",":3000"],
  "packages": ["org.mozilla.firefox"],
  "protocols": ["tls","quic"],      // subset of sing-box known (tls/quic/http/...)
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
| `/subs/{id}` | PATCH | subset: name/enabled/tag_prefix/update_interval_hours/override_detour/register_detour_{servers,in_auto}/use_detour_servers/url |
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
- `POST /subs/{id}/refresh` на UserServer → 409 `conflict` (нечего фетчить).
- `POST /subs` с `?rebuild=true` **не ждёт fetch'а** — fetch асинхронный, rebuild'ит с текущими nodes (которых ещё нет → config без этих outbound'ов). Делай последовательно: `POST /subs` → `POST /subs/{id}/refresh` → wait → `POST /action/rebuild-config`.

---

## Settings writes — `/settings/*`

Scoped writes на `SettingsStorage`. Generic `PUT /state/storage?key=X` **намеренно нет** — blocklist и типизация кастомные per-key.

| Endpoint | Метод | Body |
|---|---|---|
| `/settings/route_final` | PUT | `{"outbound":"<tag>"}` (пустая строка = дефолт) |
| `/settings/excluded_nodes` | PUT | `{"nodes":["tag1","tag2"]}` (replace set) |
| `/settings/vars/{key}` | PUT | `{"value":"<str>"}` |
| `/settings/vars/{key}` | DELETE | — (удаляет ключ; не пишет пустую строку) |
| `/settings/dns_options/servers` | PUT | `{"servers":[{sing-box dns server object}, ...]}` |
| `/settings/dns_options/rules` | PUT | `{"rules":"<JSON string>"}` (legacy shape — stored как JSON-string) |
| `/settings/rebuild-config` | POST | — (alias для `/action/rebuild-config`) |

**Route final:**
```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"outbound":"direct-out"}' \
  "$BASE/settings/route_final?rebuild=true"
```

**Исключить ноды из URLTest:**
```bash
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"nodes":["BL: 🇲🇩 Moldova, Chisinau | [BL]","BL: 🇵🇱 Poland, Warsaw | [BL]"]}' \
  "$BASE/settings/excluded_nodes?rebuild=true"
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

| Endpoint | Что отдаёт / принимает |
|---|---|
| `GET /backup/export?include=config,vars,subs` | Pure-data snapshot. `include` опц.; default — все три |
| `POST /backup/import?merge=&rebuild=` | Восстановление. Body `{config?, vars?, server_lists?}`. Совместим с `/diag/dump` (diag-поля игнорятся). |

```bash
# Бэкап
curl -s -H "$HDR" "$BASE/backup/export" > /tmp/lxbox-backup.json

# Восстановление с автоматическим rebuild config
curl -X POST -H "$HDR" -H "Content-Type: application/json" \
  --data-binary @/tmp/lxbox-backup.json \
  "$BASE/backup/import?rebuild=true"
```

`merge=false` (default) — replace; `merge=true` — append/upsert. Кеши (cache.db, stderr.log, SRS-blob, runtime node-tags) в backup не входят — restore их пересоздаёт.

---

## Diagnostics — `/diag/*` (§038)

| Endpoint | Что отдаёт |
|---|---|
| `GET /diag/dump` | Полный JSON-pack от `DumpBuilder.build()` (то же что UI ⤴ Share) |
| `GET /diag/exit-info` | `ApplicationExitInfo` (5 последних экзитов; API 30+, иначе `[]`) |
| `GET /diag/logcat?count=N&level=L` | Logcat tail нашего процесса (N=50..5000, level=V/D/I/W/E/F) |
| `GET /diag/stderr` | Содержимое `filesDir/stderr.log` (Go panic stacktrace) |
| `GET /diag/applog?prev=true\|false\|all` | AppLog entries с фильтром по `fromPreviousSession` |

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

## Clash API proxy — `/clash/*`

Полный reference — в [`clash-api-reference.md`](clash-api-reference.md). Кратко:

```bash
# Список proxies
curl -s -H "$HDR" "$BASE/clash/proxies" | jq '.proxies | keys | length'

# Switch Selector
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d '{"name":"BL: 🇫🇷 France, Paris | [BL]"}' \
  "$BASE/clash/proxies/vpn-1"

# URLTest группы
curl -s -H "$HDR" "$BASE/clash/group/vpn-1/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=3000"

# Connections snapshot
curl -s -H "$HDR" "$BASE/clash/connections" | \
  jq '{total:(.connections|length), mem:.memory}'
```

⚠️ Streaming endpoints (`/clash/traffic`, `/clash/memory`, `/clash/logs`) через proxy **не работают** — `stream.toBytes()` buffering. Детали и workaround в clash-api-reference.md.

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
| 502 | `upstream_error` | Clash API / native plugin / saveConfig failed |
| 504 | `timeout` | handler не уложился в 30s |
| 500 | `internal` | unhandled — детали в AppLog, не в response |

Shape ошибки:
```json
{"error": {"code": "bad_request", "message": "missing query param: tag"}}
```

---

## Tips

### Batch mutation → single rebuild

Каждый write принимает `?rebuild=true`, но если меняешь несколько вещей — эффективнее написать без `rebuild`, потом один раз:

```bash
curl -X PUT  -H "$HDR" -H "Content-Type: application/json" -d '...' "$BASE/settings/route_final"
curl -X PUT  -H "$HDR" -H "Content-Type: application/json" -d '...' "$BASE/settings/excluded_nodes"
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

TAG="BL: 🇫🇷 France, Paris | [BL]"
curl -X PUT -H "$HDR" -H "Content-Type: application/json" \
  -d "{\"name\":\"$TAG\"}" \
  "$BASE/clash/proxies/vpn-1"
# /clash/proxies/vpn-1 — vpn-1 без кириллицы/эмодзи, encoder не нужен
# а вот так если нужен путь с эмодзи:
curl -H "$HDR" "$BASE/clash/proxies/$(enc "$TAG")"
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
