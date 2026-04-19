# 018 — Detour Server Management (Multi-hop & Jump Servers)

> ℹ️ **`DetourPolicy` и место хранения переехали в спеку [`026 parser v2`](../026%20parser%20v2/spec.md)** (§1.3, §3.4, 2026-04-18).
> Флаги теперь на `ServerList`, а не на `ProxySource`. UX цепочек — остаётся здесь.

| Поле | Значение |
|------|----------|
| Статус | Частично перенесено в 026 (политика), UX остаётся здесь |

## Контекст

Chained proxy (jump server) поддерживается на уровне парсера (004): подписка может содержать ноду с `dialerProxy` / `detour`. Но пользователь не видит цепочку, не может собрать её вручную, не может изменить jump-сервер.

## 1. Multi-hop / Chained Proxy UI

### Концепция

**Chain** — упорядоченный список нод (hop'ов):
```
Client → Hop1 (entry) → Hop2 → ... → HopN (exit) → Internet
```

sing-box реализует через поле `detour`:
```
HopN.detour = Hop(N-1).tag
```

### Хранение

```json
"chains": [
  {
    "tag": "US via RU",
    "hops": ["ru-server-1", "us-server-3"]
  }
]
```

### ConfigBuilder

1. Для каждого chain создать **копии** outbound'ов хопов с уникальными тегами: `chain-tag/hop-tag`
2. Проставить `detour` по цепочке
3. Добавить последний hop (exit) в proxy-группу
4. Промежуточные хопы — outbound'ы, но не в группу

### UI — Chain Editor

```
┌─────────────────────────────┐
│ Chain name: [US via RU    ] │
│                             │
│  ① ru-server-1         [×] │
│  ② us-server-3         [×] │
│                             │
│  [+ Add hop]                │
│                             │
│  [Save]          [Delete]   │
└─────────────────────────────┘
```

- ReorderableListView (drag для порядка)
- Минимум 2 хопа, максимум 5
- Валидация: нет циклов, нет дублей

### Ноды-цепочки на главном экране

- Иконка `link`
- Subtitle: `ru-server-1 → us-server-3`

### Совместимость с jump-нодами из подписки

Ноды с `jump != null` → implicit chain. Пользователь может "Edit chain" → после ручного редактирования сохраняется в `chains[]`.

## 2. Jump Server Naming & Visibility

### Префикс вместо переименования

Jump серверам добавляется **префикс** `⚙ `, сохраняя оригинальное имя:

**Было:** `🇫🇮Финляндия-bypass_jump_server`
**Стало:** `⚙ socks-helsinki-01`

### Видимость

| Место | show_jump_servers=false | show_jump_servers=true |
|-------|----------------------|---------------------|
| Главный экран | Скрыты | Показаны с ⚙ |
| Node filter | Скрыты | Показаны |
| Detour dropdown | **Всегда показаны** | Всегда показаны |
| SubscriptionDetailScreen | **Показаны с ⚙** | Показаны с ⚙ |

### Программная фильтрация

```dart
bool isJumpServer(String tag) => tag.startsWith('⚙ ');
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/models/proxy_chain.dart` | Модель ProxyChain |
| `lib/services/settings_storage.dart` | getChains / saveChains, show_jump_servers |
| `lib/services/config_builder.dart` | Генерация outbound'ов с detour-цепочкой |
| `lib/screens/chain_editor_screen.dart` | Экран редактирования цепочки |
| `lib/widgets/node_row.dart` | Иконка и subtitle для цепочки |
| `xray_json_parser.dart` | `jumpPrefix` вместо `_jumpSuffix` |
| `node_parser.dart` | Prefix `⚙ ` для ParsedJump |
| `home_screen.dart` | Фильтрация jump серверов |
| `node_filter_screen.dart` | Фильтрация jump серверов |

## Критерии приёмки

- [ ] Можно создать цепочку из 2+ нод через UI.
- [ ] Порядок хопов меняется drag & drop.
- [ ] ConfigBuilder генерирует outbound'ы с `detour`.
- [ ] Ping цепочки работает.
- [ ] Ноды с `jump` из подписки отображаются как цепочки.
- [ ] Jump серверы сохраняют оригинальное имя с `⚙ `.
- [ ] По умолчанию jump серверы скрыты из списка нод.
- [ ] Jump серверы всегда доступны в detour dropdown.

## Per-subscription detour flags (proxy_source.dart)

Подписка хранит три независимых флага поведения detour-серверов:

| Флаг | Default | Эффект |
|------|---------|--------|
| `useDetourServers` | true | Узлы подписки соединяются через свой detour. Если off — `detour` удаляется у outbound-а, трафик идёт напрямую. |
| `registerDetourServers` | true | ⚙ серверы попадают в список нод (proxy-группы vpn-*). Если off — detour-outbound остаётся в конфиге (нужен как dialer), но в группах его нет. |
| `registerDetourInAuto` | **false** | Дополнительно контролирует попадание ⚙ в `auto-proxy-out` (urltest). Даже если `registerDetourServers=true`, ⚙ из этой подписки не попадают в auto-группу, пока этот флаг не включён явно. |

**Зачем разделение register/registerInAuto:**
⚙ сервер — это транзитный dialer, а не конечная точка. Если он включён в urltest auto-proxy-out, автовыбор может назначить его финальным egress по минимальной задержке, хотя логически трафик должен идти через ⚙ → настоящий узел. Разделение позволяет показывать ⚙ в `vpn-*` (ручной выбор) и одновременно исключать из auto (автоподбор).

**UI:**
Галки Register/Register-in-auto/Use показываются только если в подписке есть хотя бы одна нода с detour-сервером.

**Реализация (config_builder.dart):**
- `unregisteredDetourTags` — набор detour-тегов с `registerDetourServers=false`, не добавляются в `allNodeTags`.
- `detoursExcludedFromAuto` — набор detour-тегов с `registerDetourInAuto=false`, фильтруются из `nodeTags` при сборке urltest-группы.

## See also

- [006 servers ui](../006%20servers%20ui/spec.md) — per-subscription settings
- [019 wireguard endpoint](../019%20wireguard%20endpoint/spec.md) — WireGuard as detour
