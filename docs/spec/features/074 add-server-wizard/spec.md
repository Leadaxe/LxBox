# 074 — Add server wizard (SOCKS5 form + Paste URI + Paste JSON)

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-05 |
| Зависимости | `SubscriptionController.addFromInput` (URI/JSON paths уже работают), `SocksSpec` (models/node_spec.dart:404), `UserServer` (models/server_list.dart:163), §070 (long-press UI pattern). |
| Связанные | `SubscriptionsScreen._bottomInputRow` (existing «+» IconButton), `parseSocks`/`parseAll` (parser/uri_parsers.dart, json_parsers.dart). |
| Триггер | Юзеру нужно добавить локальный SOCKS5 (DPI bypass tooling и другой local proxy) без знания URI-формата `socks5://...`. Existing «+» = paste URI/JSON/subscription. Wizard для structured входа. |

## Цель

**Long-press на «+» IconButton** на Subscriptions screen → открывается full-screen route с **3 tabs**:

1. **SOCKS5 form** — структурированная форма (tag / host / port / user / pass / display name). Display name → `UserServer.name` (entry title в Subscriptions). Default values для locally hosted SOCKS5 (127.0.0.1:1080, tag «local-socks5-out»).
2. **Paste URI** — multiline text area для `vless://…` / `vmess://…` / `trojan://…` / `socks5://…` / `wireguard://…` / etc. + Add.
3. **Paste JSON** — multiline text area для sing-box outbound JSON ({type:vless,…}). Routing в `outbounds[]` vs `endpoints[]` уже автоматический в `parseAll` + builder.

Submit → новый `UserServer` с одной нодой → `subController.addUserServer(...)` / `addFromInput(...)` → `_regenerateAndSave`.

## Не в скопе

- Редактирование existing nodes через wizard (есть `NodeSettings` JSON editor).
- Bulk add (multiple specs at once) — каждый wizard создаёт один UserServer с одной нодой.
- WireGuard structured form — пока через Paste URI/JSON.
- Detour chain (chained) construction — wizard создаёт single-hop, chain настраивается отдельно через subscription detail.
- Импорт из файла (есть SAF picker через separate flow).

---

## Состояние до §074

```
SubscriptionsScreen._bottomInputRow:
  TextField (input)  + IconButton.filled('+')
                       └─ onPressed = _add()
                            ├─ if input empty → _pasteFromClipboard()
                            └─ else → subController.addFromInput(text)
                                       ├─ subscription URL → SubscriptionServers
                                       ├─ WG ini → UserServer + WireguardSpec
                                       ├─ Direct URI → UserServer + parsed spec
                                       └─ JSON outbound → UserServer per outbound

  '+' onLongPress = ничего
```

UI для структурированного ввода SOCKS5 отсутствует. Юзер должен помнить URI-формат.

---

## Целевое состояние

### UI — `lib/screens/add_server_wizard_screen.dart` (NEW)

Full-screen route, `Scaffold` + `AppBar(title: 'Add server')` + `DefaultTabController(length: 3)`.

**Tab 1 — «SOCKS5»**:
```
┌──────────────────────────────────────────┐
│ Tag                                       │
│ ┌──────────────────────────────────────┐ │
│ │ local-socks5-out                     │ │
│ └──────────────────────────────────────┘ │
│ Host                                      │
│ ┌──────────────────────────────────────┐ │
│ │ 127.0.0.1                            │ │
│ └──────────────────────────────────────┘ │
│ Port                                      │
│ ┌──────────────────────────────────────┐ │
│ │ 1080                                 │ │
│ └──────────────────────────────────────┘ │
│ Username (optional)                       │
│ ┌──────────────────────────────────────┐ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│ Password (optional)                       │
│ ┌──────────────────────────────────────┐ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│ Label (optional)                          │
│ ┌──────────────────────────────────────┐ │
│ │ My local proxy                       │ │
│ └──────────────────────────────────────┘ │
│ helper text: «Shown as subtitle in node  │
│  list»                                   │
│                                           │
│         [Cancel]    [Add]                 │
└──────────────────────────────────────────┘
```

Validation:
- Tag — non-empty (default «local-socks5-out» — иначе валидация бьётся).
- Host — non-empty.
- Port — integer 1..65535.
- Username, Password, Label — optional.

Submit logic для SOCKS5 tab:
```dart
final spec = SocksSpec(
  id: newUuidV4(),
  tag: _tagController.text.trim(),
  // §074 (revised): label = tag для lossless round-trip. См. блок
  // «Tag round-trip preservation» ниже.
  label: _tagController.text.trim(),
  server: _hostController.text.trim(),
  port: int.parse(_portController.text),
  rawUri: '',
  username: _usernameController.text,
  password: _passwordController.text,
);
// rawBody = sing-box outbound JSON (через spec.emit().map). ParseAll
// на reload идёт через json parser → entry['tag'] preserved exactly.
// Альтернатива (spec.toUri()) теряет tag т.к. URI fragment = label,
// а parser восстанавливает tag из fragment'а.
final outboundMap = spec.emit(TemplateVars.empty).map;
final us = UserServer(
  id: newUuidV4(),
  name: _nameController.text.trim().isNotEmpty
      ? _nameController.text.trim()  // UserServer.name persisted нативно
      : spec.tag,
  enabled: true,
  tagPrefix: '',
  detourPolicy: DetourPolicy.defaults,
  origin: UserSource.manual,
  createdAt: DateTime.now(),
  rawBody: jsonEncode(outboundMap),
  nodes: [spec],
);
await widget.subController.addUserServer(us);
```

### Tag round-trip preservation (critical)

`UserServer.fromJson` (server_list.dart:196) реконструирует `nodes` через
`parseAll(decode(rawBody))` — это сделано чтобы избежать drift между in-memory
NodeSpec и persisted JSON shape.

**Проблема URI persistence**: `socks5://user:pass@host:port#label` — URI
fragment маппится в `label`. `parseSocks` (uri_parsers.dart:633): `final
tag = tagFromLabel(label, 'socks', server, port)` — tag derive'ится из
label. После restart'а `tag = "My Local SOCKS"` (из label fragment), а юзер
вводил `tag = "my-socks-out"`. Routing rules ссылающиеся на `my-socks-out`
ломаются.

**Решение**: persist через **JSON outbound** (`{type: socks, tag: ..., ...}`).
`parseSingboxEntry` (json_parsers.dart:212): `final tag = entry['tag']` —
точный preserve. Wizard:

1. Конструирует `SocksSpec(tag: T, label: T, ...)` — `label = tag` для
   single-source consistency.
2. `rawBody = jsonEncode(spec.emit(TemplateVars.empty).map)`.
3. На reload `parseAll(decode(rawBody))` → SocksSpec с тем же tag.

**Display name** (то что юзер раньше думал положить в label) теперь
маппится в `UserServer.name` — persisted как отдельное поле в
`UserServer.toJson`, не зависит от rawBody round-trip. Отображается как
entry title в Subscriptions list. На Home node row показывается tag
(который юзер explicitly выбрал).

> **Update §243 (05.07.2026):** поле «Display name» из форм визарда
> **удалено** — `SubscriptionEntry.displayName` теперь игнорирует
> `UserServer.name`, заголовок записи = tag узла. Поле Tag стало
> опциональным (пусто → дефолтный tag `local-socks5-out`/`local-http-out`),
> `UserServer.name` визард всегда пишет пустым. Детали и принятые
> последствия — `docs/spec/tasks/243-wg-import-filename-tag.md`.

Регрессионные тесты: `app/test/services/socks_wizard_roundtrip_test.dart`
(модельный round-trip), `app/test/screens/add_server_wizard_test.dart`
(§243 — формы визарда).

**Tab 2 — «Paste URI»**:
```
┌──────────────────────────────────────────┐
│ Paste a proxy URL                         │
│ ┌──────────────────────────────────────┐ │
│ │ vless://...                          │ │
│ │                                      │ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│ helper: «vless / vmess / trojan / ss /   │
│  hy2 / tuic / socks5 / wireguard URLs»   │
│                                           │
│         [Cancel]    [Add]                 │
└──────────────────────────────────────────┘
```

Submit:
```dart
await widget.subController.addFromInput(_uriController.text);
```

**Tab 3 — «Paste JSON»**:
```
┌──────────────────────────────────────────┐
│ Paste a sing-box outbound JSON            │
│ ┌──────────────────────────────────────┐ │
│ │ {                                    │ │
│ │   "type": "vless",                   │ │
│ │   "tag": "...",                      │ │
│ │   ...                                │ │
│ │ }                                    │ │
│ └──────────────────────────────────────┘ │
│ helper: «Single object or array of       │
│  outbounds. WireGuard routes to           │
│  endpoints automatically»                 │
│                                           │
│         [Cancel]    [Add]                 │
└──────────────────────────────────────────┘
```

Submit:
```dart
await widget.subController.addFromInput(_jsonController.text);
```

### Controller — `SubscriptionController.addUserServer(UserServer)` (NEW)

Cleanest implementation: extract from existing branches in `addFromInput`. Adds entry + persists.

```dart
Future<void> addUserServer(UserServer us) async {
  _busy = true;
  _lastError = '';
  notifyListeners();
  try {
    _entries.add(SubscriptionEntry(list: us, nodeCount: us.nodes.length));
    await _persist();
  } catch (e) {
    _lastError = humanizeError(e);
  } finally {
    _busy = false;
    notifyListeners();
  }
}
```

Используется только SOCKS5 tab. URI/JSON tabs идут через existing `addFromInput`.

### UI integration — `SubscriptionsScreen._bottomInputRow`

```dart
GestureDetector(
  onLongPress: ctrl.busy ? null : () => _openAddServerWizard(),
  child: IconButton.filled(
    tooltip: 'Add',
    onPressed: ctrl.busy ? null : () => unawaited(_add()),
    icon: const Icon(Icons.add, size: 20),
  ),
)

void _openAddServerWizard() {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => AddServerWizardScreen(
      subController: widget.subController,
      onAdded: _regenerateAndSave,  // callback для config rebuild
    )),
  );
}
```

После successful add → `_regenerateAndSave` (same flow что у `_add`).

### Visual mock for wizard tabs

```
AppBar: Add server          [Cancel]
        ─────────────────────────────
        SOCKS5  |  Paste URI  |  Paste JSON
                ─────────────────────
        (tab content per spec above)

        [Add]   ← FilledButton, bottom-center
```

Альтернатива: Cancel/Add buttons в AppBar (TextButton Cancel + FilledButton Add). **Recommend AppBar buttons** — стандарт Material для full-screen modals.

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| Tag совпадает с existing UserServer node tag | `EmitContext.allocateTag` добавит `-1` суффикс при build (происходит уже после add'а, controller'у не возвращается). Snackbar показывает tag **который юзер ввёл** — если builder суффиксовал, в node list юзер увидит финальный tag там. Trade-off: проще plumbing, юзер видит свой input как confirmation. |
| Port = 0 / 65536 / non-integer | Validation блокирует Add button. errorText под Port field. |
| Host = empty / pure whitespace | Validation блокирует Add. |
| Label с emoji / non-ASCII | OK, label свободный текст; в node list рендерится как subtitle. |
| Username с `:` в строке | OK, не пишем в URI (path = direct construct). |
| Tab switch с unsaved data | Поля сохраняются (каждый tab имеет свои controllers, не сбрасываются). |
| URI paste invalid | `addFromInput` set `lastError`. Snackbar показывает `subController.lastError`. |
| JSON paste невалидный | То же что URI — через `addFromInput` error path. |
| User добавил SOCKS5 через wizard, VPN running | Config регенерируется → `configStaleSinceStart` true → home показывает «Restart VPN to apply changes». Existing flow, ничего нового. |

## Файлы

- `app/lib/screens/add_server_wizard_screen.dart` — NEW, full-screen TabBar wizard.
- `app/lib/controllers/subscription_controller.dart` — добавить `addUserServer(UserServer)` method.
- `app/lib/screens/subscriptions_screen.dart` — wrap «+» IconButton в GestureDetector с long-press; new `_openAddServerWizard` helper.
- `app/test/services/subscription_controller_test.dart` (если есть) или новый — unit test для `addUserServer`.
- `docs/spec/features/074 add-server-wizard/spec.md` (этот файл).
- `CHANGELOG.md` — entry под `### Added`.
- `RELEASE_NOTES.md` — highlight в v1.9.0.

## Locked decisions

1. **Long-press на «+» triggers wizard** + **«Add server…» в overflow menu (три точки в AppBar)** — duplicate access для discoverability. Long-press = accidental discovery; overflow menu = explicit affordance для тех кто его ищет. Tap на «+» = existing add (clipboard / text input).
2. **3 tabs** (SOCKS5 / URI / JSON). Single full-screen route с `DefaultTabController`.
3. **SOCKS5 form** — поля tag / host / port / user / pass / display name. Display name → `UserServer.name` (persisted нативно). Изначально планировали отдельное `SocksSpec.label` для subtitle на Home node row, но это ломает tag round-trip (см. блок «Tag round-trip preservation»). Revised: `SocksSpec.label = SocksSpec.tag` всегда; ввод note живёт в `UserServer.name`, виден в Subscriptions list.
4. **URI / JSON tabs** — re-use `addFromInput` (parser flow тот же что у paste-text).
5. **`UserSource.manual`** (q2 reuse). Не плодим enum.
6. **Tag uniqueness** — leave to builder (`allocateTag` суффиксует). UI не валидирует (q5 b).
7. **Один JSON wizard** (q ambiguous — изначально 2 separately, потом юзер confirm'нул один). Auto-routing в outbound vs endpoint через NodeSpec.emit / build pipeline.
8. **Cancel + Add buttons в AppBar**. FilledButton Add справа в actions.
9. **Default SOCKS5 values**: tag = «local-socks5-out», host = `127.0.0.1`, port = `1080`. Готовый template для locally hosted SOCKS5 / DPI bypass tooling.
10. **Snackbar показывает tag который юзер ввёл** (не финальный после allocateTag). Builder'овская суффиксация при collision происходит после add'а, controller'у не возвращается; финальный tag юзер видит в node list. Это сознательный trade-off — proper plumbing требует возврата tag-map'а из builder через addUserServer, не оправдано для одного edge-case'а.

## Acceptance criteria

- [ ] Long-press на «+» открывает full-screen wizard с 3 tabs.
- [ ] SOCKS5 tab: defaults заполнены, form validates host non-empty + port 1..65535.
- [ ] SOCKS5 add → UserServer создан с одним SocksSpec, persistance OK, config регенерирован.
- [ ] Paste URI tab: вставляет любой URI (vless/vmess/trojan/etc.), routes через `addFromInput`.
- [ ] Paste JSON tab: вставляет outbound JSON (single или array), routes через `addFromInput`. WireGuard → endpoints[].
- [ ] Cancel или back gesture закрывает wizard без add.
- [ ] Snackbar после add показывает финальный tag (если allocateTag suffix'нул — видно).
- [ ] Tag conflict resolution — allocateTag добавляет `-1`/`-2`, нет ошибок.
- [ ] Tab switch не сбрасывает поля на ненавигированных tabs.

## Open Qs (для решения после первого APK)

- Long-press helper tooltip? «Long-press for wizard» — добавим если discoverability слабая.
- Saved-snackbar duration: 2s standard или дольше когда tag re-allocated?
