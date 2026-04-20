# Clash API reference — sing-box 1.12.12 as seen from L×Box

| Поле | Значение |
|------|----------|
| Статус | Reference |
| Дата | 2026-04-20 |
| Версия sing-box | 1.12.12 (libbox, JitPack) |
| Источник | live-разведка через [`031 debug api`](../spec/features/031%20debug%20api/spec.md) + чтение [`sing-box/experimental/clashapi`](https://github.com/SagerNet/sing-box/tree/v1.12.12/experimental/clashapi) |

Документация сфокусирована на **реальном поведении** sing-box'овского clash-api (а не на upstream Clash.Meta — см. секцию [Differences from upstream](#differences-from-upstream-clashmeta)). Все ответы и curl-команды взяты с боевого устройства (OnePlus CPH2411, Android 15, VPN connected, 150+ nodes подписок).

## Доступ

Все примеры — через L×Box Debug API proxy на `127.0.0.1:9269`. Сам Clash API слушает на рандомном порту (`/state/clash` → `base_uri`) и требует свой секрет — знать его не нужно, proxy подмешивает.

```bash
adb forward tcp:9269 tcp:9269
TOK="<debug_token from App Settings → Developer>"
curl -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/version
```

**Важное свойство proxy:** handler в [`debug/handlers/clash.dart`](../../app/lib/services/debug/handlers/clash.dart:52) читает upstream через `streamed.stream.toBytes()` — то есть **буферит весь ответ до конца**. Для streaming-эндпоинтов (`/traffic`, `/memory`, `/logs`) это значит, что через proxy они никогда не возвращаются — упираются в 25s timeout handler'а и падают `UpstreamError`. Смотри [Streaming endpoints](#streaming-endpoints-traffic-memory-logs).

---

## Endpoint reference

### Таблица полного списка

Список полный — регистрируется в [`server.go:117–131`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/server.go#L117) + [`setupMetaAPI`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/api_meta.go#L22).

| Path (под `/clash`) | Method | Назначение | Streaming? |
|---|---|---|---|
| `/` | GET | hello + (опц.) редирект на `/ui/` | нет |
| `/version` | GET | версия sing-box | нет |
| `/logs` | GET | поток логов (JSON lines / WebSocket) | **да** |
| `/traffic` | GET | поток скоростей `{up,down}` в секунду | **да** |
| `/memory` | GET | поток RSS в секунду | **да** |
| `/configs` | GET / PUT / PATCH | schema + смена mode | нет |
| `/proxies` | GET | карта всех proxies + `GLOBAL` | нет |
| `/proxies/{tag}` | GET | single proxy | нет |
| `/proxies/{tag}` | PUT | selector switch | нет |
| `/proxies/{tag}/delay` | GET | ping одного outbound | нет |
| `/group` | GET | список группы (только OutboundGroup'ы) | нет |
| `/group/{tag}` | GET | single группа | нет |
| `/group/{tag}/delay` | GET | ping всех членов группы | нет |
| `/rules` | GET | полный список route-правил | нет |
| `/connections` | GET | snapshot или WebSocket streaming | снапшот да, WS нет |
| `/connections` | DELETE | закрыть все + `ResetNetwork()` | нет |
| `/connections/{id}` | DELETE | закрыть одно | нет |
| `/providers/proxies` | GET | `{"providers":{}}` — sing-box не поддерживает | нет |
| `/providers/proxies/{name}` | GET/PUT | 404 всегда | нет |
| `/providers/proxies/{name}/healthcheck` | GET | 404 всегда | нет |
| `/providers/rules` | GET | `{"providers":[]}` — пусто (note: **array**, не object) | нет |
| `/providers/rules/{name}` | GET/PUT | 404 всегда | нет |
| `/script` | POST / PATCH | `{"message":"not implemented"}` / 204 | нет |
| `/profile/tracing` | GET | всегда 404 (закомменчено в upstream) | нет |
| `/cache/fakeip/flush` | POST | 204 если fakeip есть, 500 `bucket not found` если нет | нет |
| `/dns/query` | GET | resolve через router DNS | нет |
| `/upgrade/ui` | POST | download external UI (404 если `external_ui` не в config'е) | нет |

Proxy **НЕ** поддерживает WebSocket upgrade — это обычный `http.Client.send`, без `ws`. Если хочешь WS — ходи напрямую на `base_uri` из `/state/clash`, но там секрет замаскирован (`***`) в API (см. [`debug_storage_view.dart`](../../app/lib/services/debug/handlers/state.dart), секрет в `/state/clash` намеренно не светится). Для reverse-engineering WS — собирай local debug-build где секрет в `debug_storage_view` не маскируется.

---

### `GET /clash/version`

Sanity-check. Отвечает всегда одинаково:

```json
{"meta":true,"premium":true,"version":"sing-box 1.12.12"}
```

`meta: true, premium: true` — захардкожено в [`server.go:428`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/server.go#L428) для совместимости с Yacd-like dashboard'ами.

```bash
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/version
```

---

### `GET /clash/`

Корень clash-api. Захардкожено в [`server.go:292`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/server.go#L292):

```json
{"hello":"clash"}
```

Если в конфиге задан `experimental.clash_api.external_ui` — редиректит на `/ui/`. В L×Box external_ui не используется → всегда JSON.

**Quirk:** `GET /clash` (без `/`) возвращает `400 {"error":{"code":"bad_request","message":"empty upstream path"}}` — это защита Debug proxy, а не upstream. Всегда ставь `/` в конце.

```bash
curl -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/
```

---

### `GET /clash/proxies`

Полный dump всех outbound'ов в форме Clash-подобной карты. В L×Box при 150 nodes весит ~45 KB.

Top-level:
```json
{"proxies": {"<tag>": {<proxy>}, ...}}
```

Каждый proxy имеет минимальный набор полей (см. [`proxies.go:61` proxyInfo](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L61)):

```json
{
  "type": "VLESS|Shadowsocks|Hysteria2|VMess|Trojan|WireGuard|Direct|Selector|URLTest|Fallback|Reject|...",
  "name": "<tag>",
  "udp": true,
  "history": [{"time":"2026-04-20T13:57:50.886498532+03:00","delay":47}]
}
```

`history` — массив из 0 или 1 элемента (только последний замер, sing-box хранит 1, не 10 как upstream).

Для групп (Selector / URLTest / GLOBAL) добавляется:
```json
{
  "now": "<current selected>",
  "all": ["<member1>","<member2>",...]
}
```

**Пример ответа** (сокращён) — найденные типы в боевом config'е:

```bash
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/proxies
```

```json
{
  "proxies": {
    "GLOBAL": {
      "type": "Fallback",
      "name": "GLOBAL",
      "udp": true,
      "history": [],
      "all": ["<все proxies кроме Direct/Block/DNS>"],
      "now": "vpn-1"
    },
    "direct-out": {
      "type": "Direct",
      "name": "direct-out",
      "udp": true,
      "history": [{"time":"2026-04-20T13:57:50.886498532+03:00","delay":47}]
    },
    "vpn-1": {
      "type": "Selector", "name": "vpn-1", "udp": true,
      "history": [...],
      "now": "BL: 🇳🇱 The Netherlands, Eindhoven | [BL]",
      "all": ["BL: 🇪🇪 Estonia, Tallinn | [BL]", ...]
    },
    "✨auto": {
      "type": "URLTest", "name": "✨auto", "udp": true,
      "history": [{"time":"2026-04-20T13:57:20.080014838+03:00","delay":228}],
      "now": "BL: 🌐 Anycast-IP | [IPv6] | [BL]-7",
      "all": [...]
    },
    "⚙ wg-parnas": {
      "type": "WireGuard", "name": "⚙ wg-parnas", "udp": true,
      "history": [{"time":"2026-04-20T13:57:50.833602916+03:00","delay":89}]
    },
    "BL: 🇪🇪 Estonia, Tallinn | [BL]": {
      "type": "VLESS", "name": "BL: 🇪🇪 Estonia, Tallinn | [BL]", "udp": true, "history": []
    },
    "BL: 🇺🇸 United States, El Segundo | 🌐 | [IPv6] | [BL]": {
      "type": "Shadowsocks", "name": "...", "udp": true, "history": []
    },
    "BL: 🇫🇷 France, Paris | [BL]-3": {
      "type": "Hysteria2", "name": "...", "udp": true, "history": []
    },
    "BL: 🇳🇱 The Netherlands, Amsterdam | [BL]-3": {
      "type": "VMess", "name": "...", "udp": true, "history": []
    },
    "BL: 🇫🇷 France, Paris | [BL]-4": {
      "type": "Trojan", "name": "...", "udp": true, "history": []
    }
  }
}
```

**Важные свойства:**
- **Ни один протокол-специфичный параметр не отдаётся**: ни адрес сервера, ни порт, ни cipher, ни UUID/password, ни ALPN, ни transport. Всё это — только в исходном конфиге через `GET /config`. Dashboard'ы, которым нужны эти детали, должны парсить конфиг отдельно.
- **Direct / Block / DNS outbound'ы в `all` списке GLOBAL отфильтрованы** ([`proxies.go:101`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L101)), но в общем Map есть.
- **`GLOBAL.all` сортируется stable так**, что `now` стоит первым — косметика для dashboard'ов.
- `GLOBAL` отсутствует в outbound'ах sing-box'а — это синтетическая запись, подмешиваемая при формировании ответа ([`proxies.go:115`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L115)). Отсюда quirk — см. ниже `/proxies/GLOBAL`.

---

### `GET /clash/proxies/{tag}`

Detail view single proxy. Шаблон:

```json
{"type":"...","name":"...","udp":true,"history":[...]}
```

Для группы — добавляются `now` + `all`.

**URL-encoding обязателен для тегов с юникодом.** Боевые теги в L×Box содержат эмодзи флагов + `✨` + `⚙`:

```bash
# ✨auto
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/%E2%9C%A8auto"

# BL: 🇪🇪 Estonia, Tallinn | [BL]
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/BL%3A%20%F0%9F%87%AA%F0%9F%87%AA%20Estonia%2C%20Tallinn%20%7C%20%5BBL%5D"
```

Pro-tip: `python3 -c "import urllib.parse; print(urllib.parse.quote('$TAG'))"`.

**Quirk — `GLOBAL` 404**: `GET /clash/proxies/GLOBAL` возвращает `404 {"message":"Resource not found"}`. Причина — GLOBAL только мёрджится в общий `/proxies` response, в реальном outbound registry его нет, а `findProxyByName` ([`proxies.go:49`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L49)) идёт через `server.outbound.Outbound(name)`. Значит `GLOBAL` **списком получить можно, детально — нельзя**.

---

### `PUT /clash/proxies/{tag}`

Переключение selector на ребёнка. Body: `{"name": "<child tag>"}`. Ответ: **204 No Content** при успехе.

```bash
# Switch vpn-1 → Paris
curl -X PUT -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"BL: 🇫🇷 France, Paris | [BL]"}' \
  "http://127.0.0.1:9269/clash/proxies/vpn-1"
# → 204

# Verify switched
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/vpn-1" | jq '.now'
# → "BL: 🇫🇷 France, Paris | [BL]"
```

**Ошибки:**
- Non-member в `.all`: `400 {"message":"Selector update error: not found"}`.
- Target не Selector (URLTest, VLESS, Direct, etc): `400 {"message":"Must be a Selector"}`.
- Bad JSON body: `400 {"message":"Bad Request"}` (`ErrBadRequest`).

**Critical:** switch на URLTest группу **запрещён**. URLTest `.now` определяется автоматически по `/delay` + scheduled `urltest_interval`.

---

### `GET /clash/proxies/{tag}/delay`

Ping одного outbound. Параметры:
- `url` — HTTPS URL для теста; **`http://` молча заменяется на пустую строку** ([`proxies.go:191`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L191)) и используется default из `urltest`-пакета (`https://www.gstatic.com/generate_204`). Если хочешь точный URL — шли HTTPS.
- `timeout` — миллисекунды, **парсится как int16** ([`proxies.go:194`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L194)) — максимум **32767 ms**, любое значение > этого → 400 Bad Request. (Для `/group/:tag/delay` лимит int32 — там он в 2 млрд, но timeout тот же context deadline, ждать больше смысла нет.)

Успех:
```json
{"delay": 152}
```

Статусы:
- `200` — `{"delay": N}`.
- `504` — `{"message":"Request Timeout"}` — ctx expired до завершения теста.
- `503` — `{"message":"An error occurred in the delay test"}` — дозвонились, но ошибка в L4/TLS/HTTP **или delay=0** (sing-box считает 0 ms невалидным замером и возвращает 503).

**Поведение по типу proxy:**

| type  | /delay | комментарий |
|---|---|---|
| Direct | работает | тестирует через host машину, игнорируя VPN |
| VLESS / SS / Trojan / Hysteria2 / VMess / WireGuard | работает но часто 503 | sing-box дозванивается до node независимо от того, выбрана ли она в активной цепочке. Для нод, которые давно down/банят / 503. |
| Selector | работает, тестирует `.now` | внутри Selector делегирует тест в `.now` ребёнка. Если `.now` сейчас тормозит — 504. |
| URLTest | работает, тестирует `.now` | аналогично Selector'у |
| `GLOBAL` | 404 | см. выше |

```bash
# HTTPS, правильно
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/direct-out/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=5000"
# → {"delay":152}

# int16 overflow — BadRequest
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/direct-out/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=40000"
# → 400 {"message":"Bad Request"}
```

**Side-effect:** успешный delay **персистит в urlTestHistory** — после вызова `GET /proxies/{tag}` покажет `history: [{time, delay}]`. Ошибка — `DeleteURLTestHistory`, т.е. history очищается. Это единственный путь заполнить `history` в `/proxies` ответе, иначе они пустые.

---

### `GET /clash/group`

Список всех **групповых** outbound'ов (Selector / URLTest / Fallback / etc) в форме как `/proxies`, но отфильтрованное:

```json
{
  "proxies": [
    {"type":"URLTest","name":"✨auto","udp":true,"history":[...],"now":"...","all":[...]},
    {"type":"Selector","name":"vpn-1","udp":true,"history":[...],"now":"...","all":[...]}
  ]
}
```

Обрати внимание: `proxies` — **массив**, не объект (в отличие от `/proxies`). Это **Clash.Meta convention**, sing-box следует ([`api_meta_group.go:33`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/api_meta_group.go#L33)).

```bash
curl -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/group
```

---

### `GET /clash/group/{tag}`

Синоним `/proxies/{tag}`, но **только для групп**. Не-группа → 404 `Resource not found`.

```bash
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/group/%E2%9C%A8auto"
```

---

### `GET /clash/group/{tag}/delay`

Ping всех членов группы параллельно. Response — Map<memberTag, delayMs>:

```json
{
  "BL: 🇩🇪 Germany, Bad Soden am Taunus (Neuenhain) | [BL]": 275,
  "BL: 🇫🇮 Finland, Helsinki | [BL]": 399,
  "BL: 🇲🇩 Moldova, Chisinau | [BL]": 2113
}
```

**Quirks** (из [`api_meta_group.go:59`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/api_meta_group.go#L59)):

1. **Только успешно протестированные ноды в результате.** Failed (error / timeout) — ИСКЛЮЧАЮТСЯ из response + `DeleteURLTestHistory` у них. Если группа в 100 нод и в результате 3 записи — 97 нод провалились (не "97 не тестились"). Это критически важно понимать, интерпретируя response: **отсутствие ноды в map ≠ "не проверялась"**, а "проверилась и упала".

2. **Для URLTest групп `url` query игнорируется.** `URLTestGroup.URLTest(ctx)` использует URL из конфига outbound'а (`experimental.clash_api.default_url` или кастомный `url` в самой URLTest секции). Передавать `url` в query бессмысленно. Для Selector / других групп — `url` используется.

3. **`http://` → пустая строка, как у `/proxies/:tag/delay`** (тот же filter).

4. **Concurrency = 10** (`batch.WithConcurrencyNum[any](10)`). При группе в 150 нод и `timeout=3000` реальное время теста — up to `ceil(150/10) * 3000 = 45000 ms`, но ctx deadline = 3000 ms обрывает всё через 3с. Ноды, которые не успели — пропущены.

5. **Дедупликация по realTag** — sing-box выкидывает duplicates через `group.RealTag(detour)`. Если в `all` одна и та же node дважды под разными aliases — тестится один раз.

6. **Возврат 504** при ошибке в `urlTestGroup.URLTest(ctx)` (только для URLTest-групп) — например если ctx deadline exceeded до того, как хоть одна нода ответила. Для Selector-групп batch.Wait() всегда возвращает — 504 не будет, просто пустой `{}`.

```bash
# Selector — честно тестит, возвращает только успешных
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/group/vpn-1/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=3000"
# → {"BL: 🇫🇷 France, Paris | [BL]":169, ...}

# URLTest — url игнорируется, использует config'овый
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/group/%E2%9C%A8auto/delay?url=https%3A%2F%2Fignored.example%2F&timeout=3000"
```

**`.now` у URLTest после `/group/:tag/delay`:** observed behavior — `.now` **не** обновляется этим вызовом. URLTest group имеет internal urltest_interval tick; `/delay` обновляет individual node histories, но group'а перевыбирает `.now` по своему расписанию. Эмпирическая проверка: `now` оставался старым после forced `/delay`, новый `.now` появился после `urltest_interval` ticka.

---

### `GET /clash/connections`

Snapshot активных TCP/UDP трекеров. WebSocket upgrade не поддерживается нашим proxy (см. [Streaming note](#streaming-endpoints-traffic-memory-logs)) — только snapshot.

**Top-level структура:**

```json
{
  "downloadTotal": 6249733,
  "uploadTotal": 450203,
  "memory": 14368768,
  "connections": [...]
}
```

| Поле | Тип | Semantic |
|---|---|---|
| `uploadTotal` | int64 | Кумулятивный upload с момента запуска sing-box (байты). Не сбрасывается reset'ом. |
| `downloadTotal` | int64 | Аналогично для download. |
| `memory` | uint64 | `runtime.MemStats.HeapInuse` в момент snapshot'а. Не `RSS процесса` — а Go heap. Может быть в разы меньше реального RSS. |
| `connections` | array | Снимок живых трекеров. Dead connections пропадают. |

**Элемент `connections[]`:**

```json
{
  "id": "d38af8ef-0ec0-4832-baf0-4e041134ac4c",
  "chains": ["BL: 🇳🇱 The Netherlands, Eindhoven | [BL]", "vpn-1"],
  "rule": "final",
  "rulePayload": "",
  "start": "2026-04-20T14:09:17.929085419+03:00",
  "upload": 3772,
  "download": 17196,
  "metadata": {
    "network": "tcp",
    "type": "tun/tun-in",
    "sourceIP": "172.16.0.1",
    "sourcePort": "40844",
    "destinationIP": "64.233.163.101",
    "destinationPort": "443",
    "host": "clients4.google.com",
    "dnsMode": "normal",
    "processPath": "com.android.chrome (10140)"
  }
}
```

Все поля — см. [Field reference: connections[]](#field-reference-connections).

---

### `DELETE /clash/connections`

Закрыть все активные connections **и** вызвать `router.ResetNetwork()`. Возвращает 204.

⚠️ `ResetNetwork()` не просто закрывает соединения — он ещё **сбрасывает DNS-кэш и состояние TUN'а**. В момент вызова есть короткая пауза в трафике. Делать без нужды — не стоит.

```bash
curl -X DELETE -H "Authorization: Bearer $TOK" \
  http://127.0.0.1:9269/clash/connections
# → 204
```

---

### `DELETE /clash/connections/{id}`

Закрыть конкретное соединение по UUID.

```bash
curl -X DELETE -H "Authorization: Bearer $TOK" \
  http://127.0.0.1:9269/clash/connections/d38af8ef-0ec0-4832-baf0-4e041134ac4c
# → 204
```

**Quirk — невалидный UUID молча 204**: id парсится через `uuid.FromStringOrNil(id)` → любая мусорная строка даёт zero-UUID → линейный поиск в snapshot'е не находит совпадения → `render.NoContent`. Соответственно, **204 не означает "закрыто"**. Если нужно удостовериться — перезапроси `/connections` и убедись что id там нет.

```bash
curl -X DELETE -H "Authorization: Bearer $TOK" \
  http://127.0.0.1:9269/clash/connections/not-a-uuid
# → 204 (no error, no action)
```

---

### `GET /clash/rules`

Полный dump routing rules.

```json
{
  "rules": [
    {"type":"default","payload":"inbound=tun-in","proxy":"resolve(prefer_ipv4)"},
    {"type":"default","payload":"inbound=tun-in","proxy":"sniff(1s)"},
    {"type":"default","payload":"protocol=dns","proxy":"hijack-dns"},
    ...
  ]
}
```

Поля: `type` (default / logical), `payload` (stringified matcher), `proxy` (action — может быть outbound tag или псевдо-action вроде `resolve(...)` / `sniff(...)` / `hijack-dns` / `reject` / `route-options(...)`).

Порядок — исходный из `route.rules[]`, plus implicit rules (resolve/sniff/hijack-dns добавляет сам sing-box в начале). Action отображается через `rule.Action().String()` — для route-action `{"outbound":"X"}` вернёт просто `"X"`.

```bash
curl -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/rules
```

---

### `GET /clash/configs`

```json
{
  "port": 0,
  "socks-port": 0,
  "redir-port": 0,
  "tproxy-port": 0,
  "mixed-port": 0,
  "allow-lan": false,
  "bind-address": "*",
  "mode": "Rule",
  "mode-list": ["Rule"],
  "log-level": "warn",
  "ipv6": false,
  "tun": null
}
```

Всё кроме `mode` / `mode-list` / `log-level` / `bind-address` — **захардкожено в нулях/дефолтах** ([`configs.go:36`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/configs.go#L36)), не отражает реальный конфиг (в sing-box нет понятия mixed-port / redir-port — это Clash-legacy). `ipv6: false` и `tun: null` — тоже заглушки; настоящее состояние TUN живёт в `/config` на Debug API (не в clash-api!).

**`mode-list`** в L×Box = `["Rule"]` (один элемент). Clash.Meta обычно имеет `["Rule","Global","Direct"]`, но sing-box `experimental.clash_api.mode_list` в конфиге пустой → default mode приклеивается один.

**`log-level`** — нормализуется: `trace` → `debug`, всё ниже `error` → `error` ([`configs.go:38`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/configs.go#L38)). В ответе увидишь только `debug|info|warn|error`, не оригинальное значение из config'а.

---

### `PATCH /clash/configs`

Поменять `mode`. Body:

```json
{"mode":"Global"}
```

Response: **204 No Content**.

Side-effects: `dnsRouter.ClearCache()` + сохранение в `cache_file` (если включён). Если `mode` не в `mode-list` — молча игнорирует (предварительно пробует case-insensitive match). `mode == current mode` — тоже молча игнорирует.

В L×Box `mode_list = ["Rule"]` → **смена mode эффективно NO-OP**, любые `{"mode":"Global"}` / `{"mode":"Direct"}` не пройдут фильтр. PATCH всегда вернёт 204, но `GET /configs` покажет прежний mode. Проверено live.

```bash
# NoOp — mode остаётся Rule
curl -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"mode":"Global"}' \
  "http://127.0.0.1:9269/clash/configs"
# → 204

curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/configs | jq .mode
# → "Rule"
```

---

### `PUT /clash/configs`

`PUT` — просто возвращает 204. Никакой логики ([`configs.go:69`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/configs.go#L69)). В upstream Clash это reload конфига из файла; в sing-box — заглушка.

---

### `GET /clash/dns/query`

Выполнить DNS запрос через sing-box DNS router (с применением `dns.rules`, strategy, etc).

Параметры:
- `name` — запрашиваемое имя (FQDN или host; sing-box добавит trailing dot).
- `type` — тип записи: `A|AAAA|MX|TXT|SOA|NS|PTR|CNAME|SRV|CAA|...`. Default `A`. Regex-less — если тип неизвестен `dns.StringToType` → 400 `{"message":"invalid query type"}`.

Response (упрощённый):

```json
{
  "Status": 0,
  "TC": false,
  "RD": true,
  "RA": true,
  "AD": false,
  "CD": false,
  "Server": "internal",
  "Question": [{"Name":"cloudflare.com.","Qtype":1,"Qclass":1}],
  "Answer": [
    {"name":"cloudflare.com.","type":1,"TTL":300,"data":"104.16.133.229"},
    {"name":"cloudflare.com.","type":1,"TTL":300,"data":"104.16.132.229"}
  ]
}
```

Дополнительные секции при наличии: `Authority[]` (SOA/NS), `Additional[]`. Формат полей внутри RR:
- `name` — строка (FQDN с точкой).
- `type` — числовой DNS type (`A=1`, `AAAA=28`, `SOA=6`, etc — decimal uint16).
- `TTL` — секунды.
- `data` — stringified RDATA без заголовка. Для `A` — dotted IP. Для `SOA` — `mname rname serial refresh retry expire minimum` через пробел. Для `MX` — `preference exchange`. И так далее (формат: `miekg/dns.RR.String()` минус `Header.String()`).

**Не путать** с `dnsMode` в connections metadata — он захардкожен `"normal"`, а запросы здесь проходят через настоящий router'ский resolver.

**Timeout** — hardcoded `C.DNSTimeout` (10s).

```bash
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/dns/query?name=cloudflare.com&type=A"

# AAAA
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/dns/query?name=example.com&type=AAAA"

# SOA root
curl -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/dns/query?name=.&type=SOA"
```

---

### `GET /clash/providers/proxies` (stub)

sing-box **не поддерживает proxy providers**. Response — пустая карта:

```json
{"providers":{}}
```

Любой `GET/PUT /clash/providers/proxies/{name}` → `404 {"message":"Resource not found"}`. В коде тело handler'ов закомменчено ([`provider.go:61`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/provider.go#L61)).

---

### `GET /clash/providers/rules` (stub)

То же что и proxy providers, но **массив вместо объекта** — upstream-inconsistency, не наша:

```json
{"providers":[]}
```

---

### `POST /clash/script` (stub)

```json
{"message":"not implemented"}
```

Status 400. Весь код starlark-инжекции закомменчен.

### `PATCH /clash/script` (stub)

204, NoOp.

### `GET /clash/script`

405 Method Not Allowed.

---

### `GET /clash/profile/tracing`

Всегда 404. Тело WS-стриминга закомменчено ([`profile.go:17`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/profile.go#L17)) — функциональность деактивирована.

---

### `POST /clash/cache/fakeip/flush`

Reset FakeIP mapping table. Успех — 204. Если fakeip не включён в DNS config'е (как в L×Box) — `500 {"message":"bucket not found"}`.

```bash
curl -X POST -H "Authorization: Bearer $TOK" \
  http://127.0.0.1:9269/clash/cache/fakeip/flush
# → 500 {"message":"bucket not found"}
```

---

### `POST /clash/upgrade/ui`

Скачать (обновить) external UI через sing-box'овский downloader. В L×Box `external_ui` не задан → `404 {"message":"external UI not enabled"}`.

---

## Streaming endpoints (`/traffic`, `/memory`, `/logs`)

Все три построены одинаково: infinite-loop с `time.NewTicker(1 sec)` + `json.Encoder.Encode(...)` + `w.(http.Flusher).Flush()`. Поддерживают WebSocket upgrade (`?token=...&level=...` для WS auth).

**Через L×Box Debug API proxy не работают.** Handler ([`clash.dart:52`](../../app/lib/services/debug/handlers/clash.dart:52)) читает upstream через `streamed.stream.toBytes()` — это **блокирующий full-body read**, возврата не будет пока upstream не закроет соединение. sing-box их никогда не закрывает → 25s timeout → `Upstream: Clash API timeout`.

Три пути, если тебе нужны эти данные:

1. **Use Debug API alternatives** (что уже есть):
   - `/state` возвращает `traffic: {up_total, down_total, active_connections}` — снапшот, обновляется при каждом запросе.
   - `/logs?limit=N` — AppLog (включает Dart-логи + некоторые core-события).
   - `/clash/connections` — top-level `memory` поле — это replacement для `/memory`.

2. **Direct access to clash-api port** — но secret'а нет в `/state/clash` (замаскирован `***`), нужен local-build. Не делать в production.

3. **Переписать proxy handler на streaming** — если понадобится, заменить `stream.toBytes()` на `pipe()` + `req.response.add(chunk); req.response.flush()`. Требует API surgery в [`BytesResponse`](../../app/lib/services/debug/transport/response.dart).

---

#### Что реально отдают (захардкожено в sing-box)

| Endpoint | Ticker | Body / entry |
|---|---|---|
| `/traffic` | 1s | `{"up":N,"down":N}` — delta за последнюю секунду (не cumulative). |
| `/memory` | 1s | `{"inuse":N,"oslimit":0}` — N = heap inuse. **Первый tick всегда `inuse:0`** (захардкожено в [`api_meta.go:67`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/api_meta.go#L67) — "make chat.js begin with zero"). |
| `/logs` | event-driven | `{"type":"info|warn|error|debug|trace","payload":"msg"}`. Query `?level=debug|info|warning|error|trace` (default `info`), ниже level'а events не отправляются. |

Формат — **NDJSON без разделителя**: `{...}{...}{...}` подряд (не `\n`-separated). Это ломает наивный `json.NewDecoder().Decode()` — на большинстве парсеров работает (readers eager), но `json.loads(full_body)` не пройдёт.

---

## Field reference: proxies[]

Единый shape выдачи `proxyInfo()` ([`proxies.go:61`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L61)):

| Поле | Тип | Пример | Semantic |
|---|---|---|---|
| `type` | string | `VLESS`, `Shadowsocks`, `Selector`, `URLTest`, `Fallback`, `Direct`, `Reject` | `ProxyDisplayName(type)`, с переименованием `Block → Reject` для Clash-compat. Регистр — CamelCase (но см. quirk про lowercase `urltest` в старых 1.8.x). |
| `name` | string | `✨auto`, `BL: 🇪🇪 Estonia, Tallinn \| [BL]` | Тег outbound'а. Может содержать любой unicode включая эмодзи. |
| `udp` | bool | `true` | UDP support. Для VLESS/SS/Trojan/Hysteria/Wireguard обычно `true`. Для TCP-only (rare) — `false`. |
| `history` | `[{time,delay}]` или `[]` | `[{"time":"2026-04-20T13:57:50.886498532+03:00","delay":47}]` | Массив из **0 или 1** элемента (последний замер). `time` — RFC3339 с нано-precision. `delay` — ms uint16. Очищается при первой ошибке в `/delay`. |
| `now` | string | `BL: 🇳🇱 The Netherlands, Eindhoven \| [BL]` | **Только для групп** (Selector / URLTest / Fallback / GLOBAL). Текущий выбранный child. Для URLTest до первого успешного test cycle — **пустая строка**. |
| `all` | string[] | `["child1","child2",...]` | **Только для групп.** Список всех members в порядке config'а. Для `GLOBAL` отсортировано так, чтобы `now` стоял первым (stable sort). |

**Чего НЕТ** (а в upstream Clash.Meta иногда есть):
- `server` / `port` / `cipher` / `password` / `uuid` / `alpn` / `sni` — никогда.
- `testUrl` / `interval` для URLTest — никогда (только в config).
- `alive` / `dead` / `lastAlive` — никогда (только через `/delay` history).
- `xudp` — никогда.

Если нужны detail'ы — парси `/config`.

---

## Field reference: connections[] + connections[].metadata

Выдаётся `MarshalJSON()` в [`trafficontrol/tracker.go:31`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/trafficontrol/tracker.go#L31). Всё ниже — **именно так, как приходит**, не upstream-конвенция.

### Top-level

| Поле | Тип | Пример | Semantic |
|---|---|---|---|
| `id` | string (uuid-v4) | `d38af8ef-0ec0-4832-baf0-4e041134ac4c` | UUID трекера, генерится при создании коннекта. Стабилен до close. |
| `chains` | string[] | `["BL: 🇳🇱 The Netherlands, Eindhoven \| [BL]", "vpn-1"]` | **Reverse**: `[terminal, ..., outermost_group]`. Первый элемент — реальный outbound через который идёт трафик, далее вложенные группы снаружи внутрь. Если цепочка ещё не раскрутилась (например URLTest без выбранного `.now`) — может оборваться на имени группы. |
| `rule` | string | `final`, `default => route(vpn-1)`, `logical(...) => route-options(...)` | `rule.String() + " => " + rule.Action().String()` либо `"final"` если правило не matched (default route). В формат входит "стрелка" — для простого route это просто `<matcher> => <outbound_tag>`. |
| `rulePayload` | string | `""` | **Всегда пустая строка.** Поле присутствует для совместимости с Clash.Meta, но sing-box его **не заполняет** ([`tracker.go:85`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/trafficontrol/tracker.go#L85)). Ранее семантика была `rule.RawPayload()`; в sing-box убрано. |
| `start` | string (RFC3339) | `2026-04-20T14:09:17.929085419+03:00` | Время создания трекера. Nano-precision, с offset'ом. |
| `upload` | int64 | `3772` | Кумулятивный upload этого коннекта в байтах. |
| `download` | int64 | `17196` | Аналогично. |
| `metadata` | object | — | См. ниже. |

### metadata{}

| Поле | Тип | Пример | Semantic |
|---|---|---|---|
| `network` | string | `tcp`, `udp` | L4 протокол. Нижний регистр. |
| `type` | string | `tun/tun-in`, `socks/mixed-in`, `http` | **Формат: `<inboundType>/<inboundTag>` если tag задан, иначе просто `<inboundType>`.** Для L×Box TUN inbound всегда `tun/tun-in` (у нас tag = `tun-in`). Upstream Clash.Meta кладёт сюда часто только inbound tag → **ломает dashboard'ы, ожидающие просто `tun` или `Mixed`**. |
| `sourceIP` | string | `172.16.0.1` | IP source. Для TUN — всегда IP из tun-subnet (`172.16.0.1` у нас). Для IPv6 — без квадратных скобок (`fe80::1`). |
| `sourcePort` | string (!) | `40844` | **STRING, не number!** Легко пропустить при парсинге. `F.ToString(uint16)`. |
| `destinationIP` | string | `64.233.163.101` | Destination IP **после sniff'а и маппинга**, но до dial'а. |
| `destinationPort` | string (!) | `443` | **STRING.** |
| `host` | string | `clients4.google.com`, `""` | FQDN after sniff (`Metadata.Domain` или `Metadata.Destination.Fqdn`). Если приложение пошло на raw IP без SNI/Host header — **пустая строка** (не `null`). В L×Box видел пустой host для: прямых VoIP конект (`com.grandstream.wave`), push mtalk, некоторые background-services типа Oplus. |
| `dnsMode` | string | `normal` | **ЗАХАРДКОЖЕНО `"normal"` всегда** ([`tracker.go:77`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/trafficontrol/tracker.go#L77)). Upstream Clash имеет `normal|fake-ip|mapped`. sing-box этого не различает в API. Если нужно — смотри `dns.rules` в `/config`. |
| `processPath` | string | `com.android.chrome (10140)`, `1000`, `""` | Process hint от Android. Формат приоритетов:<br>`<package> (<uid>)` если и package и uid известны<br>`<package> (<user>)` если user задан (редко)<br>`<package>` если только package<br>`<uid>` (просто число) если только uid<br>`""` если ничего нет (root system processes). UID `1000` = system. |

### Квирки metadata

1. **`destinationIP` != original target** — после sniff'а TCP через TUN идёт rewrite. Если `host` пустой — destinationIP это raw сокет target. Если `host` есть — destinationIP то, куда sing-box резолвнул `host`.

2. **`processPath` с суффиксом `(uid)`** — суффикс стабильно есть для app-инстанцированных процессов; отсутствует для system услуг. Dart-код `_extractPackage()` в [`clash_api_client.dart:269`](../../app/lib/services/clash_api_client.dart:269) режет по `' ('` — корректно. Если в будущем появится user-фаза (`com.x (user)`) — сломается; не критично, заменятся на `com.x`.

3. **Нет `remoteDestination` или `sniffedDomain` отдельно** — всё в `host`.

4. **Нет `inboundIP`/`inboundPort`** — inbound bind неизвестен, только tag+type.

5. **Нет `mode`/`outbound`** на уровне metadata — но есть `chains[0]` который эффективно тот же outbound tag.

---

## Quirks & gotchas

Собрано в один bullet-list для быстрой reference'и.

### Протокол и URL

- **`http://` URL в `/delay` молча пропадает** ([`proxies.go:191`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go#L191)). `if strings.HasPrefix(url, "http://") { url = "" }` — используется default `https://www.gstatic.com/generate_204`. Пиши HTTPS.
- **`timeout` для `/proxies/:tag/delay` — int16 (max 32767)**; для `/group/:tag/delay` — int32. Overflow → 400 Bad Request.
- **URL в `/group/:tag/delay` для URLTest групп игнорируется** — URLTest.URLTest(ctx) использует свой config'овый URL.

### Группы и выбор

- **URLTest `.now` после `/group/:tag/delay` не обновляется** — тесты сохраняют individual histories, но `.now` переизбирается на периодическом `urltest_interval` tick'е (default 3m, мы ставим свой).
- **`.now` URLTest пустой до первого tick'а** (если приложение только запустилось, VPN ещё не prewarm'илась).
- **chains[] в reverse** — `[terminal, intermediate, outermost]`; первый элемент — реальный outbound.
- **chains может обрываться на tag'е группы** если URLTest ещё не выбрал child.
- **PUT `/proxies/:tag` работает ТОЛЬКО на Selector** — `Must be a Selector` 400 для URLTest и всех остальных.
- **GLOBAL 404** — `GET /proxies/GLOBAL` возвращает `404 Resource not found`. Есть только в `/proxies` aggregate.

### connections & metadata

- **`rulePayload` всегда пустая строка** — sing-box не заполняет, не ждите.
- **`dnsMode` всегда `"normal"`** — hardcoded.
- **`metadata.type = <inboundType>/<inboundTag>`** — не просто inbound tag. У нас это `tun/tun-in`.
- **`processPath` с `(uid)` суффиксом** — `com.foo (10042)`. Парсить регулярным `\s*\(\d+\)$`, а не трактовать весь processPath как package.
- **`sourcePort` и `destinationPort` — строки**, не числа.
- **`destinationIP` — после sniff'а** (для host-known коннектов — это резолвнутый IP).
- **DELETE /connections/{id} с невалидным UUID молча возвращает 204** — no error.
- **DELETE /connections закрывает всё + ResetNetwork()** — не просто close, а clearDNS + TUN reset. Пауза в трафике.
- **`memory` top-level — это Go heap inuse**, не RSS процесса; обычно в разы меньше.

### Streaming

- **`/traffic`, `/memory`, `/logs` через Debug API proxy не работают** — buffering. Используй `/state` + `/logs?limit=N` + `/connections.memory`.
- **`/memory` первый tick всегда 0** даже если heap не пустой — захардкожено "для chat.js" в upstream.
- **`/traffic` отдаёт delta в секунду, не cumulative** — `up = new - prev` каждый tick.
- **NDJSON stream без разделителя** — `{...}{...}{...}` подряд. Не `json.loads(body)`.

### Конфиг и mode

- **`/configs` GET отдаёт захардкоженные нули** для port / socks-port / redir-port / tproxy-port / mixed-port / allow-lan / ipv6 / tun. Не смотри на них.
- **`PATCH /configs` mode смена** — при `mode_list=["Rule"]` (наш случай) эффективно no-op для любых других значений. Возвращает 204 но `mode` остаётся прежним.
- **`PUT /configs` — заглушка** (упрощает миграцию dashboard'ов, реально ничего не делает).
- **`log-level` в `/configs`** — нормализуется (trace→debug, <error→error). Не оригинал.

### Providers

- **`GET /providers/proxies` отдаёт `{"providers":{}}`** (object), **`GET /providers/rules` отдаёт `{"providers":[]}`** (array) — inconsistency в upstream, sing-box её дублирует.
- **Любой `/providers/{proxies,rules}/{name}` — 404**.

### Неработающие endpoints

- `/profile/tracing` — всегда 404 (закомменчен код WS-стриминга).
- `/script` POST — 400 `not implemented`.
- `/script` PATCH — 204 no-op.
- `/upgrade/ui` — 404 если `external_ui` не в config'е (всегда у нас).

### URL-encoding

- **Теги с юникодом (эмодзи, кириллица) — URL-encode обязательно**. sing-box использует `getEscapeParam` ([`common.go`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/common.go)) для parsing — не-encoded характеры с пробелами ломают path routing.

### Debug API proxy-side

- `GET /clash` (без `/`) → `400 empty upstream path` (наш handler, не sing-box). Всегда с `/`.
- `/state/clash` отдаёт `secret: "***"` — прямой доступ к `base_uri` невозможен через внешний curl. Всё через `/clash/*`.

---

## Differences from upstream Clash.Meta

Собрано по результатам разведки sing-box 1.12.12 vs [Clash.Meta docs](https://wiki.metacubex.one/).

| Область | Upstream Clash.Meta | sing-box 1.12.12 |
|---|---|---|
| `metadata.type` | Обычно строка-тип inbound'а: `Mixed`, `Tun`, `HTTP`. | `<inboundType>/<inboundTag>` склеено — `tun/tun-in`. |
| `metadata.dnsMode` | Enum: `normal|fake-ip|mapped`. | **Всегда `"normal"`** (hardcoded). |
| `rulePayload` | Строка после `=>` в правиле (actual matched payload). | **Всегда `""`**. |
| `proxies[].type` для rejected | `Reject` | `Reject` (совпадает; mapped from `Block`). |
| `proxies[]` protocol fields | Cipher, server, port, plugin-opts etc. | Ничего — только `type/name/udp/history`. |
| `proxies[].history` | Массив до 10 последних замеров. | Массив 0 или 1 элемента. |
| `GLOBAL` в `/proxies/{name}` | Работает (Clash.Meta подмешивает outbound). | **404** — GLOBAL только в `/proxies` aggregate. |
| `/proxies/:tag/delay` с `http://` | Пропускает как есть (тестит HTTP 204). | **Сбрасывает в пустую строку**; использует default HTTPS URL. |
| `/group/:tag/delay` результат | Map<tag, delay> со всеми членами (failed → 0 или -1). | **Только успешные.** Failed полностью исключены из map. |
| `/group/:tag/delay` `url` param для URLTest | Используется. | **Игнорируется** — берётся URL из URLTest config. |
| `/logs`, `/traffic`, `/memory` | Streaming через SSE или WS. | Infinite NDJSON через raw HTTP, или WS с `?token=`. |
| `/configs` PATCH | Может менять port, log-level, ipv6, allow-lan. | Только `mode`. Остальные поля в body игнорируются. |
| `/configs` PUT | Reload конфига с диска. | **No-op 204.** |
| `/providers/proxies` | Наполнен реальными providers'ами (если `proxy-providers` в config). | Всегда пусто. Proxy providers не поддерживаются. |
| `/providers/rules` | Наполнен rule-providers. | Всегда пусто. Rule providers отдельно, sing-box их не exposes через этот endpoint. |
| `/script` | Starlark filtering (старый Premium). | Stub / not implemented. |
| `/profile/tracing` | WS-стрим трассировки matched rules. | Hardcoded 404. |
| `/cache/fakeip/flush` | Сбрасывает FakeIP pool. | То же, но 500 если FakeIP не активен. |
| `/connections` DELETE | Закрывает все + ничего больше. | Закрывает все **+ `router.ResetNetwork()`** (clears DNS + TUN state). |
| `/version` | `{"version":"...","premium":true}` | То же + `meta: true` (для совместимости с Yacd). |
| `PUT /proxies/:tag` в URLTest | Allowed в некоторых fork'ах. | **400 "Must be a Selector"**. |
| Port fields в `/configs` | Реальные. | Все захардкожены в 0. |

### Авторизация и auth

- **WebSocket auth через `?token=`** — совпадает с Clash.Meta.
- **Bearer header** — совпадает.
- **CORS** — enabled, `AllowedOrigins: ["*"]` по умолчанию.
- **Host check** — нет в clash-api (только в Debug API нашем).

### Специфичное для L×Box

- **Secret клэша генерится рандомно** при каждом rebuild config'а (см. [`build_config.dart`](../../app/lib/services/builder/build_config.dart)). Прямой доступ к base_uri бесполезен — secret меняется. Всегда через Debug proxy.
- **`mode_list` всегда `["Rule"]`** — мы не конфигурим mode-switching (спеки 011 + 013 работают через другие механизмы).
- **`external_ui` не задан** → нет `/ui`, редиректов, upgrade'а.
- **TUN inbound tag = `tun-in`** → `metadata.type = "tun/tun-in"`.
- **Source IP = `172.16.0.1`** (наш tun address).

---

## Reproducible curl commands

Для копипаста: `export TOK="<debug_token>"`.

```bash
# Sanity
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/ping
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/version
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/

# Proxies
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/proxies | jq '.proxies | keys | length'
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/proxies/direct-out
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/proxies/vpn-1 | jq '{now, "members": (.all|length)}'
curl -s -H "Authorization: Bearer $TOK" "http://127.0.0.1:9269/clash/proxies/%E2%9C%A8auto" | jq .now

# Ping
curl -s -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/proxies/direct-out/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=5000"

curl -s -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/group/vpn-1/delay?url=https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=3000" | jq 'to_entries | sort_by(.value) | .[0:5]'

# Selector switch (see tag via .now first, restore after!)
BEFORE=$(curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/proxies/vpn-1 | jq -r .now)
curl -s -X PUT -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"BL: 🇫🇷 France, Paris | [BL]"}' \
  http://127.0.0.1:9269/clash/proxies/vpn-1
# ... revert ...
curl -s -X PUT -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$BEFORE\"}" http://127.0.0.1:9269/clash/proxies/vpn-1

# Groups
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/group | jq '.proxies | map({type,name,now})'
curl -s -H "Authorization: Bearer $TOK" "http://127.0.0.1:9269/clash/group/%E2%9C%A8auto" | jq .now

# Rules
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/rules | jq '.rules[:5]'

# Connections
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/connections | \
  jq '{total:(.connections|length), up:.uploadTotal, down:.downloadTotal, mem:.memory}'

curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/connections | \
  jq '.connections | map(.metadata.processPath) | unique'

# Close one (safe no-op with bogus UUID)
curl -s -X DELETE -H "Authorization: Bearer $TOK" \
  http://127.0.0.1:9269/clash/connections/00000000-0000-0000-0000-000000000000

# DNS
curl -s -H "Authorization: Bearer $TOK" \
  "http://127.0.0.1:9269/clash/dns/query?name=cloudflare.com&type=A" | jq

# Configs
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/configs

# Stubs (expect stub responses)
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/providers/proxies
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/providers/rules

# Streaming — will timeout through proxy, for reference only
curl -sN --max-time 3 -H "Authorization: Bearer $TOK" http://127.0.0.1:9269/clash/traffic
curl -sN --max-time 3 -H "Authorization: Bearer $TOK" "http://127.0.0.1:9269/clash/logs?level=debug"
```

### URL-encoding помощник

```bash
python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "BL: 🇫🇷 France, Paris | [BL]"
# → BL%3A%20%F0%9F%87%AB%F0%9F%87%B7%20France%2C%20Paris%20%7C%20%5BBL%5D
```

---

## Notes for maintainers

- Фикстуры для unit-тестов [`test/services/clash_api_client_test.dart`](../../app/test/services/clash_api_client_test.dart) должны следовать реальной shape описанной тут, особенно:
  - `connections[].metadata.type = "tun/tun-in"` (не просто `"tun"`)
  - `rulePayload: ""` всегда
  - `dnsMode: "normal"` всегда
  - `sourcePort/destinationPort` — **string**
  - `history: []` для большинства нод (не trivially populated)
  - `now: ""` для свежезапущенного URLTest
- Если sing-box обновляется — перепроверь [`tracker.go`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/trafficontrol/tracker.go), [`proxies.go`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/proxies.go), [`api_meta_group.go`](https://github.com/SagerNet/sing-box/blob/v1.12.12/experimental/clashapi/api_meta_group.go). Main breaking-change vectors — формат `type` и исчезновение/добавление полей в metadata.
- Streaming поддержка в debug proxy — задача на отдельный spec, если понадобится real-time dashboard.
