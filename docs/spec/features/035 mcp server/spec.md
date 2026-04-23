# 035 — MCP server поверх Debug API

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-04-23 |
| Зависимости | [`031 debug api`](../031%20debug%20api/spec.md), [`docs/api/clash-api-reference.md`](../../../api/clash-api-reference.md) |
| Лэндинг | v1.5.0 (отдельный artifact, не Flutter-app) |

---

## Цель

Завернуть Debug API в **MCP server** (Model Context Protocol), чтобы любой LLM-клиент с MCP-поддержкой (Claude Desktop, IDE-плагины, кастомные агенты) дёргал L×Box напрямую — без curl-портянок, без передачи токенов в prompt'е, без ручного URL-encoding emoji-tag'ов.

**Self-documenting** — главное требование. Один запрос (`tools/list` или `lxbox.help`) возвращает **полную карту возможностей**: что можно сделать, какие параметры, примеры вызовов. Агент, впервые подключаясь, получает actionable-карту без чтения внешних доков.

### Зачем это нужно

- **Дебаг-сценарии**: "почему VPN не подключается?" — агент через MCP читает `/state`, `/logs`, `/clash/proxies`, делает вывод, не нужно копировать curl-команды в чат.
- **Автоматизация**: "после connect'а проверь что .now не пустой и rebuild config если nodes < 100" — пишется как цепочка MCP tool calls.
- **Безопасность токена**: bearer-токен лежит в env вместе с MCP-server-конфигом, не утекает в LLM-context.
- **Унификация интерфейса**: tool calls с typed params вместо `?kind=socket&target=both` query-string'ов.
- **Self-docs**: `tools/list` + `lxbox.help` дают живую справку — единственный источник правды о текущих endpoint'ах. Без рассинхрона между README и кодом.

### Не в скопе

- Запись/мутация над Flutter-app'а через каналы помимо Debug API. Всё что есть в Debug API — есть в MCP. Что нет — в МCP тоже нет (proxy, не альтернативный API).
- Production-use на чужих устройствах. Это dev-tool, как и сам Debug API.
- Стриминг логов / SSE — MVP читает `/logs?limit=N`. Live-tail — отдельная фича.
- Embed MCP server внутрь Flutter-app'а. Это отдельный standalone-binary, общается с app'ом по HTTP.

---

## Архитектура

### Transport

**stdio** (default MCP transport). MCP-server — отдельный процесс, запускается клиентом (Claude Desktop, IDE) через JSON-RPC поверх stdin/stdout. Никаких портов, никакого DNS rebinding-вектора. Конфиг в Claude Desktop:

```jsonc
// ~/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "lxbox": {
      "command": "npx",
      "args": ["-y", "@leadaxe/lxbox-mcp"],
      "env": {
        "LXBOX_DEBUG_TOKEN": "781efd346dba934e9604161af9d5629e",
        "LXBOX_DEBUG_BASE": "http://127.0.0.1:9269"
      }
    }
  }
}
```

**Не HTTP/SSE** — Claude Desktop поддерживает stdio из коробки, HTTP transport требует TLS / cert / auth и под него ещё нет stable spec в большинстве клиентов. stdio = bench-rest, ноль сетевой поверхности атаки.

### Технологии

- **TypeScript + Node.js**, MCP SDK `@modelcontextprotocol/sdk`. Самая зрелая ecosystem; node поставляется с macOS, npx — стандартный способ запуска dev-tools.
- **Bun** как альтернатива — допустимо но не дефолт (не у всех установлен).
- **Не Dart** — стандалон Dart-binary без Flutter SDK неудобен для CLI-tool'а; экосистема MCP в TS значительно шире.
- **Не Python** — лишний рантайм для пользователя; node чаще установлен на dev-машинах.

### Компоненты

```
mcp/
├── package.json          npm-package (bin = lxbox-mcp), deps: @modelcontextprotocol/sdk
├── README.md             install + Claude Desktop config snippet + usage examples
├── tsconfig.json
├── src/
│   ├── server.ts         entry point: bind transport, register handlers
│   ├── client.ts         HTTP-клиент к Debug API (fetch + auth + URL-encode emoji)
│   ├── tools/
│   │   ├── index.ts      registry: name → schema + handler
│   │   ├── state.ts      read-only state tools (mapped to /state/*)
│   │   ├── action.ts     mutating tools (mapped to /action/*)
│   │   ├── clash.ts      proxy tools (mapped to /clash/*)
│   │   ├── rules.ts      CRUD на rules (mapped to /rules/*)
│   │   └── files.ts      SRS file access (mapped to /files/*)
│   ├── resources.ts      static resource definitions
│   ├── prompts.ts        pre-canned conversational templates
│   └── help.ts           full capability text (returned by lxbox.help tool)
└── dist/                 compiled JS (output of `tsc`)
```

### Auth

- Token берётся из `process.env.LXBOX_DEBUG_TOKEN`. Если не задан — server запускается, но любой tool call возвращает error: "LXBOX_DEBUG_TOKEN not set, cannot reach Debug API".
- Base URL — `process.env.LXBOX_DEBUG_BASE`, default `http://127.0.0.1:9269`.
- Token **не** появляется в tool descriptions / responses / errors — только в `Authorization` header'е, замаскирован в любом outgoing log'е.

### Encoding

- emoji в tag (`✨auto`, country flags) — MCP server делает `encodeURIComponent` автоматом. Юзер пишет `tag: "✨auto"` в JSON-параметрах tool call'а, server конвертит в `%E2%9C%A8auto` для URL.

---

## Tools

| Имя | Метод | Endpoint | Назначение |
|-----|-------|----------|-----------|
| **`lxbox.help`** | — | (local) | Возвращает полную capability text — главный self-doc tool |
| **State (read-only)** |
| `state.home` | GET | `/state` | HomeState dump |
| `state.clash` | GET | `/state/clash` | Clash endpoint info (secret masked) |
| `state.subscriptions` | GET | `/state/subs?reveal=` | Подписки (URL masked, reveal-flag для full) |
| `state.rules` | GET | `/state/rules` | CustomRule[] (sealed: inline/srs/preset) |
| `state.storage` | GET | `/state/storage` | Raw SettingsStorage (для дебага) |
| `state.vpn` | GET | `/state/vpn` | VPN runtime flags |
| `state.device` | GET | `/device` | Android meta + uptime |
| `state.config` | GET | `/config?pretty=` | Saved sing-box JSON (raw или indent) |
| `state.logs` | GET | `/logs?limit=&source=&q=&level=` | AppLog entries с фильтрами |
| **Clash API proxy** |
| `clash.version` | GET | `/clash/version` | sing-box version + meta flags |
| `clash.proxies` | GET | `/clash/proxies` | Все proxies + groups |
| `clash.proxy` | GET | `/clash/proxies/{tag}` | Один proxy/group (auto URL-encode emoji) |
| `clash.switch_proxy` | PUT | `/clash/proxies/{tag}` | Selector switch ({"name": child}) |
| `clash.delay_proxy` | GET | `/clash/proxies/{tag}/delay?url=&timeout=` | Single delay test |
| `clash.delay_group` | GET | `/clash/group/{tag}/delay?url=&timeout=` | Force urltest на группе |
| `clash.connections` | GET | `/clash/connections` | Активные соединения + totals + memory |
| `clash.close_all_connections` | DELETE | `/clash/connections` | Закрыть все |
| `clash.close_connection` | DELETE | `/clash/connections/{id}` | Закрыть одно |
| **Actions (mutating)** |
| `action.start_vpn` | POST | `/action/start-vpn` | Запустить туннель |
| `action.stop_vpn` | POST | `/action/stop-vpn` | Остановить |
| `action.ping_all` | POST | `/action/ping-all` | Mass-ping |
| `action.ping_node` | POST | `/action/ping-node?tag=` | Ping одной ноды |
| `action.run_urltest` | POST | `/action/run-urltest?group=` | Force urltest |
| `action.switch_node` | POST | `/action/switch-node?tag=` | HomeController switchNode |
| `action.set_group` | POST | `/action/set-group?group=` | Smjena группы |
| `action.rebuild_config` | POST | `/action/rebuild-config` | Регенерация конфига |
| `action.refresh_subs` | POST | `/action/refresh-subs?force=` | Manual sub-refresh |
| `action.download_srs` | POST | `/action/download-srs?ruleId=` | Download SRS файла |
| `action.clear_srs` | POST | `/action/clear-srs?ruleId=` | Удалить cached SRS |
| `action.toast` | POST | `/action/toast?msg=&duration=` | Android toast (debug-confirm) |
| `action.emulate_error` | POST | `/action/emulate-error?kind=` | Демо humanize в logs |
| **Rules CRUD** |
| `rules.list` | GET | `/rules` | Все CustomRule |
| `rules.get` | GET | `/rules/{id}` | Одно правило |
| `rules.create` | POST | `/rules?rebuild=` | Новое правило (kind: inline\|srs\|preset) |
| `rules.update` | PATCH | `/rules/{id}?rebuild=` | Partial update |
| `rules.delete` | DELETE | `/rules/{id}?rebuild=` | Удалить |
| `rules.reorder` | POST | `/rules/reorder` | `{order:[id,...]}` |
| **Files (read-only)** |
| `files.srs_list` | GET | `/files/srs/list` | Cached SRS files + size + mtime |
| `files.srs_get` | GET | `/files/srs?ruleId=` | Binary SRS dump (как base64) |
| **Logs** |
| `logs.clear` | POST | `/logs/clear` | Очистить AppLog |

### Tool description style

Каждый tool description — обязательно:
- Одна строка goal
- Список параметров с типами (если есть)
- 1-2 inline-example вызова

Пример (для `clash.delay_group`):

```jsonc
{
  "name": "clash.delay_group",
  "description": "Force URLTest on a group, return per-child latency map. Group tag may include emoji (auto URL-encoded). Example: {\"tag\":\"✨auto\",\"url\":\"https://cp.cloudflare.com/generate_204\",\"timeout\":5000} → {\"BL: NL\":206,\"BL: DE\":311,...}",
  "inputSchema": {
    "type": "object",
    "properties": {
      "tag":     {"type": "string", "description": "Group tag (e.g. ✨auto)"},
      "url":     {"type": "string", "default": "https://cp.cloudflare.com/generate_204"},
      "timeout": {"type": "number", "default": 5000, "description": "ms"}
    },
    "required": ["tag"]
  }
}
```

---

## Resources

| URI | Тип | Содержимое |
|-----|-----|------------|
| `lxbox://capabilities` | text/markdown | Полная карта tool'ов + примеров (то же что `lxbox.help` tool, но как resource) |
| `lxbox://state/home` | application/json | Cached HomeState (тот же что `state.home` tool) |
| `lxbox://state/clash` | application/json | Clash endpoint info |
| `lxbox://state/subs` | application/json | Subscriptions (URL masked) |
| `lxbox://state/rules` | application/json | CustomRule[] |
| `lxbox://state/device` | application/json | Device meta |
| `lxbox://config` | application/json | Saved sing-box JSON |
| `lxbox://logs/recent` | text/plain | Last 100 AppLog entries (formatted) |

Resources read-only, кэшируются клиентом (Claude Desktop) — для **картирования** state'а перед действиями.

---

## Prompts

Pre-canned conversational templates — клиент видит их как готовые "слоты" с подставляемыми параметрами:

| Имя | Описание | Заполняет |
|-----|----------|-----------|
| `diagnose-vpn-cant-connect` | Чек-лист "почему VPN не connect'ится" — собирает /state, /logs?level=error, /clash/proxies (если up), отдаёт LLM для diagnosis | — |
| `top-traffic-apps` | "Кто хогает трафик?" — fetches /clash/connections, агрегирует по processPath | — |
| `subscription-health` | Состояние всех подписок: lastUpdate, nodeCount, fail-counts | — |
| `add-domain-rule` | Шаблон: "добавь правило на домены X через outbound Y" → POST /rules с pre-filled JSON | `{domains, outbound}` |
| `force-urltest-and-report` | run-urltest на ✨auto → ждёт 2 сек → /clash/proxies/✨auto → выводит latency-map | `{group?}` |

Promp'ты не обязательны для агента — это **convenience-shortcuts** для типовых сценариев.

---

## `lxbox.help` — главный self-doc

Особый tool без параметров. Возвращает один большой text-блок:

```
=== L×Box MCP Server ===
Version: 0.1.0
Connects to Debug API at: http://127.0.0.1:9269
Auth: configured via LXBOX_DEBUG_TOKEN env var

=== Tools (44) ===

[State, read-only]
state.home              — HomeState (tunnel, groups, nodes_count, last_delay)
state.clash             — Clash endpoint info (secret masked)
...

[Actions, mutating]
action.start_vpn        — Start tunnel; returns {ok,action}
action.run_urltest      — Force URLTest on group {group: tag}
                          NOTE: .now field doesn't update from this — sing-box
                          quirk (only first urltest_interval tick).
...

=== Resources ===
lxbox://capabilities    — this text (cacheable)
lxbox://state/home      — same as state.home tool
...

=== Prompts ===
diagnose-vpn-cant-connect  — chained state+logs+proxies for cold diagnosis
...

=== Quick Examples ===

Connect & ping:
  action.start_vpn → state.home (tunnel=connected) → action.ping_all

Diagnose stuck node:
  state.logs(q="error", level="error,warn", limit=20)
  → state.clash → clash.delay_group(tag="✨auto")

Add domain block:
  rules.create(kind="inline", domains=["ads.example.com"], outbound="reject", rebuild=true)

=== Notes ===
- Emoji in tags auto URL-encoded.
- All mutating tools support ?rebuild= flag where Debug API does.
- Subscription URLs masked by default; pass reveal=true to state.subscriptions for full.
- See docs/api/clash-api-reference.md for nuances of /clash/* responses.
```

Идея — **один tool call** возвращает full living map. LLM-агент дёргает `lxbox.help` в начале сессии, получает контекст, дальше вызывает конкретные tools со знанием схемы.

---

## Configuration

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) или `%AppData%\Claude\claude_desktop_config.json` (Windows):

```jsonc
{
  "mcpServers": {
    "lxbox": {
      "command": "npx",
      "args": ["-y", "@leadaxe/lxbox-mcp"],
      "env": {
        "LXBOX_DEBUG_TOKEN": "<your token from App Settings → Developer>",
        "LXBOX_DEBUG_BASE": "http://127.0.0.1:9269"
      }
    }
  }
}
```

После рестарта Claude Desktop — в чате доступны tools под namespace `lxbox.*`.

### Other clients

Любой MCP-aware клиент (Continue.dev, Cursor, кастомный) — стандартный stdio launch с теми же env. Конфиг-формат у каждого свой; см. их доку.

### Required prerequisites

- Node.js ≥ 20 (для встроенного fetch + ES modules)
- L×Box запущен на устройстве, Debug API toggle включён, `adb forward tcp:9269 tcp:9269` активен (или хост достижим иначе)

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `mcp/package.json` | npm package; `"bin": {"lxbox-mcp": "./dist/server.js"}` |
| `mcp/tsconfig.json` | strict TS, ESM, target ES2022 |
| `mcp/src/server.ts` | Entry: stdio transport bind, registers tools/resources/prompts |
| `mcp/src/client.ts` | `LxboxClient`: fetch wrapper с auth + URL encoding |
| `mcp/src/tools/index.ts` | Tool registry (массив + dispatcher) |
| `mcp/src/tools/state.ts` | Read-only state tools |
| `mcp/src/tools/action.ts` | Mutating action tools |
| `mcp/src/tools/clash.ts` | Clash API proxy tools |
| `mcp/src/tools/rules.ts` | Rules CRUD tools |
| `mcp/src/tools/files.ts` | Files read tools |
| `mcp/src/resources.ts` | Static + dynamic resources |
| `mcp/src/prompts.ts` | Conversational prompts |
| `mcp/src/help.ts` | Capability text generator (используется и `lxbox.help`, и `lxbox://capabilities`) |
| `mcp/README.md` | Install / config / usage |
| `docs/spec/features/035 mcp server/spec.md` | этот документ |

Total estimate: ~600 строк TS + 200 строк README/configs.

---

## Acceptance

- [ ] `npx @leadaxe/lxbox-mcp` запускается без error'ов с валидным `LXBOX_DEBUG_TOKEN`.
- [ ] Без `LXBOX_DEBUG_TOKEN` — server стартует, но любой tool call возвращает понятный error.
- [ ] Claude Desktop конфиг (см. выше) поднимает MCP server, в чате доступны `lxbox.*` tools.
- [ ] `lxbox.help` возвращает полную capability text с примерами.
- [ ] `tools/list` возвращает все 44 tools с описаниями + JSON schema.
- [ ] `resources/list` возвращает 8 resources.
- [ ] `prompts/list` возвращает 5+ prompts.
- [ ] `clash.delay_group` с emoji-tag (`tag: "✨auto"`) корректно URL-encode'ит и возвращает map.
- [ ] `rules.create` создаёт inline-правило, возвращает id; `rules.delete` его удаляет.
- [ ] Token **не** появляется в outgoing log'ах / error responses.
- [ ] README документирует Claude Desktop config + минимум 3 example session'а.

---

## Риски

| Риск | Mitigation |
|------|-----------|
| Token leak через MCP error response | Token mask в всех error path'ах; unit-тесты на error formatting. |
| Изменения Debug API ломают MCP-mapping | tools/resources/prompts генерируются из одной registry; добавление endpoint'а в Debug API → одна правка в registry-файле, новый tool сам появится в `lxbox.help`. |
| Юзер забудет про `adb forward` | Tools возвращают specific error "Cannot reach 127.0.0.1:9269 — did you `adb forward tcp:9269 tcp:9269`?" |
| stdio buffering на больших responses (`/config` ~150KB, `/clash/connections` ~25KB) | MCP SDK chunks автоматически; тестировать на `/config` + `/state/storage`. |
| Версия MCP SDK ломает API | pin major-version в `package.json`; CI smoke-test через `npx`. |

---

## Out of scope

- **Live log streaming** (SSE-style). MVP — `state.logs?limit=N`. Tail — следующая итерация.
- **Multi-device support** — один MCP server один device. Если хочется два — два MCP-server'а с разными namespaces (`lxbox-pixel`, `lxbox-oneplus`).
- **Embed в Flutter app** — MCP server остаётся standalone Node-binary, общается через HTTP.
- **Auth refresh** — token статичный, как в Debug API. Rotation — manual rebuild config.
- **Read-only mode** — не разделяем "наблюдатель" / "executor". Если нужно — отдельный env флаг `LXBOX_MCP_READONLY=1` (отложено).
