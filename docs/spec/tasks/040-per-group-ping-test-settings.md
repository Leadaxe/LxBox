# 040 — Per-group ping/test settings + persist global

| Поле | Значение |
|------|----------|
| Статус | Implementing |
| Дата | 2026-05-06 |
| Связанные spec'ы | [`014 dns settings`](../features/014%20dns%20settings/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md) |
| Затронутые файлы | `app/lib/controllers/home_controller.dart`, `app/lib/services/settings_storage.dart`, `app/lib/screens/home_screen.dart`, `app/lib/services/debug/handlers/settings.dart`, `app/lib/services/clash_api_client.dart` (timeout sync), тесты |

## Цель

Дать каждой VPN-группе **свои** test-параметры (url + timeout) для ping, mass-ping и URLTest. Сейчас один глобальный `pingUrl` / `pingTimeout` на все группы — **не подходит** когда у юзера разные группы с разной маршрутизацией:

- **VPN-1 «France bypass»** (foreign-routed) — Google / gstatic / Cloudflare доступны → тест `https://www.gstatic.com/generate_204`
- **VPN-2 «direct-out»** (РФ-маршрут) — Google может быть медленным или по DPI, Yandex живой → тест `https://ya.ru/`
- **VPN-3 «China direct»** (если когда-то) — gstatic заблокирован, тест на baidu.com / qq.com

Глобальный URL = одно из двух становится false-negative или false-positive.

**Бонус:** существующий global `pingUrl`/`pingTimeout` сейчас живёт **только в памяти** controller'а — не persist'ится в SettingsStorage. На restart сбрасывается до field-defaults и dialog показывает template-fallback. Этой задачей заодно фиксим — global тоже persist'ится.

## Текущее состояние (что менять)

**Storage** (`SettingsStorage`): нет ни global `pingUrl`, ни per-group structure.

**Controller** (`home_controller.dart:735-736`):
```dart
String pingUrl = '';        // только in-memory field-default
int pingTimeout = 10000;
```
Использует:
- `runNodeUrltest(tag)` line 718 — `clash.delay(tag, timeoutMs: pingTimeout, url: pingUrl)`
- `pingAllNodes()` mass-ping — line 802
- `runGroupUrltest(group)` — line 765

**UI** (`home_screen.dart:1095-1153`): один dialog «Ping settings» меняет controller fields → потеря на restart.

## Дизайн

### Storage schema

Одна structure `ping_options` в `_cache`, симметричная template'у. JSON-shape:

```json
{
  "ping_options": {
    "url": "https://www.gstatic.com/generate_204",
    "timeout_ms": 5000,
    "groups": {
      "vpn-1": {"url": "https://www.gstatic.com/generate_204", "timeout_ms": 5000},
      "vpn-2": {"url": "https://ya.ru/", "timeout_ms": 10000}
    }
  }
}
```

**Зачем именно так:**
- Mirror'ит template `ping_options.{url, timeout_ms, presets}` (плюс `groups` — наше расширение)
- Одно место для всех ping-related settings, не размазано по vars
- Storage scrubber / dump-builder получает одно поле, не два
- Легко добавлять новые group-scoped поля потом (`auto_ping_interval` per-group и т.п.) — просто в `groups[tag]`

### SettingsStorage API

```dart
/// Возвращает raw map ping_options из storage. Empty map если не set.
static Future<Map<String, dynamic>> getPingOptions();

/// Сохраняет всю structure целиком (atomic). Caller передаёт final shape.
static Future<void> savePingOptions(Map<String, dynamic> options);

// Sugared shortcuts (read-modify-write через get/save):
static Future<void> setGlobalPingUrl(String url);
static Future<void> setGlobalPingTimeout(int timeoutMs);
static Future<void> setGroupPing(String groupTag, {String? url, int? timeoutMs});
static Future<void> clearGroupPing(String groupTag);
```

### Resolve chain (HomeController)

```dart
Map<String, dynamic> _pingOptions = {};

Future<void> _loadPingOptions() async {
  _pingOptions = await SettingsStorage.getPingOptions();
}

String pingUrlFor(String groupTag) {
  final groups = _pingOptions['groups'] as Map<String, dynamic>?;
  final groupOverride = groups?[groupTag] as Map<String, dynamic>?;
  final groupUrl = groupOverride?['url'] as String?;
  if (groupUrl != null && groupUrl.isNotEmpty) return groupUrl;
  
  final globalUrl = _pingOptions['url'] as String?;
  if (globalUrl != null && globalUrl.isNotEmpty) return globalUrl;
  
  return _templatePingUrl;  // загруженный из template на init'е
}

int pingTimeoutFor(String groupTag) {
  final groups = _pingOptions['groups'] as Map<String, dynamic>?;
  final groupOverride = groups?[groupTag] as Map<String, dynamic>?;
  final groupTimeout = (groupOverride?['timeout_ms'] as num?)?.toInt();
  if (groupTimeout != null && groupTimeout > 0) return groupTimeout;
  
  final globalTimeout = (_pingOptions['timeout_ms'] as num?)?.toInt();
  if (globalTimeout != null && globalTimeout > 0) return globalTimeout;
  
  return _templatePingTimeoutMs;
}
```

Resolve order: **group override → global override → template default**.

`_templatePingUrl` / `_templatePingTimeoutMs` — кешируются на старте через `TemplateLoader.load()`.

Все три callsite'а (`runNodeUrltest`, `pingAllNodes`, `runGroupUrltest`) переходят на `pingUrlFor(currentGroup) / pingTimeoutFor(currentGroup)`. `currentGroup` = `_state.selectedGroup` для UI-actions, явный аргумент для programmatic.

**Backward-compat fields** на controller'е (`pingUrl` / `pingTimeout`) — оставляем как **getters** для global'а:
```dart
String get pingUrl => (_pingOptions['url'] as String?) ?? _templatePingUrl;
int get pingTimeout => (_pingOptions['timeout_ms'] as num?)?.toInt() ?? _templatePingTimeoutMs;
```
Не setter'ы — теперь меняется только через SettingsStorage save → `_loadPingOptions()`.

### UI

В существующем dialog'е «Ping settings» добавить:

1. **Header label** — показывает текущую группу: `Group: vpn-2`.
2. **Toggle / SegmentedButton** «Apply to:» c двумя option'ами: «All groups (global)» / «This group only».
   - Default — global если у текущей группы override отсутствует, иначе group.
3. **Reset-to-global** кнопка — видна только когда selected = group **и** у group'ы есть override.
4. **Save** persist'ит в SettingsStorage:
   - `Apply to: all` → `setGlobalPingUrl/setGlobalPingTimeout`
   - `Apply to: this group` → `setGroupPing(groupTag, url:, timeoutMs:)`

После save — `_loadPingOptions()` reload'ит controller cache, новые pings/urltests используют свежие значения.

### Debug API

`handlers/settings.dart` — добавить:

```
GET    /settings/ping_options                — full structure
PUT    /settings/ping_options                — body: {url?, timeout_ms?, groups?}
GET    /settings/ping_options/groups/{tag}   — override этой группы (или 404)
PUT    /settings/ping_options/groups/{tag}   — body: {url?, timeout_ms?}
DELETE /settings/ping_options/groups/{tag}   — снять override
```

После любой PUT/DELETE — controller перечитывает `_pingOptions`.

### Migration

Existing users:
- `ping_options` отсутствует в storage → resolve chain падает на template-default → identical поведение к текущему (UI ранее показывал template URL).
- На первый Save в Ping settings dialog — создаётся `ping_options` в storage.
- Никакая migration logic не нужна.

## Acceptance

- [ ] **Storage:** `savePingOptions({url: 'X', timeout_ms: 1000, groups: {vpn-1: {url: 'Y'}}})` записывает; `getPingOptions()` возвращает identical map.
- [ ] **Sugared:** `setGlobalPingUrl('Z')` обновляет только `ping_options.url`. `setGroupPing('vpn-2', url: 'W')` обновляет `ping_options.groups.vpn-2.url` без затирания глобальных.
- [ ] **Resolve без overrides:** controller fresh start → `pingUrlFor('vpn-1')` = template `ping_options.url`.
- [ ] **Resolve с global override:** `setGlobalPingUrl('https://google.com')` → `pingUrlFor('vpn-1')` = `https://google.com`.
- [ ] **Resolve с group override:** `setGroupPing('vpn-1', url: 'https://ya.ru')` → `pingUrlFor('vpn-1')` = `https://ya.ru`. `pingUrlFor('vpn-2')` остаётся global.
- [ ] **clearGroupPing:** убирает override, resolve откатывается на global.
- [ ] **Persist global на restart:** Save в dialog → restart app → `pingUrl` getter возвращает saved значение.
- [ ] **Per-group ping:** UI VPN-2, override = `ya.ru`, ping ноды → `clash.delay(url: ya.ru)`. Switch на VPN-1 (без override) → `clash.delay(url: global)`.
- [ ] **Mass-ping per group:** mass-ping учитывает groupSpecific URL.
- [ ] **URLTest per group:** `runGroupUrltest('vpn-2')` дёргает `/group/vpn-2/delay?url=<override>`.
- [ ] **UI:** Apply-to toggle переключает scope. Reset-to-global убирает override.
- [ ] **Debug API:** GET/PUT/DELETE `/settings/ping_options` и `/settings/ping_options/groups/{tag}` работают; controller подхватывает изменения.
- [ ] **Migration:** Existing user без `ping_options` в storage — поведение identical к текущему (template URL fallback).

## Не в скопе (отдельные задачи)

- **Template-level per-group defaults** (`preset_groups[].test_options`) — добавить позже, после feedback что MVP работает.
- **Per-node test settings** — group-level достаточно.
- **Auto-detect best test endpoint** — heuristic «попробуй Google → fallback на Yandex». Усложнение, не сейчас.
- **UI вариант B** (group-context menu / long-press) — если current dialog с toggle'ом окажется недостаточно явным.

## Risks

| Риск | Mitigation |
|---|---|
| Юзер забыл что у group'ы есть override → видит «странные» pings | UI dialog при открытии показывает «Override active» badge для текущей группы; reset в одно нажатие. |
| Group tag меняется (юзер renaming) → override orphan | `groups: Map` keyed on tag; orphan'ы остаются. Можно добавить orphan-cleanup в `_loadPingOptions` (фильтрация по реально существующим group tags) — добавим если станет видно в эксплуатации. |
| URL невалидный / typo → все пинги фейлятся | URL.parse validation в UI dialog. Failed-ping'и уже окрашены красным в существующем UI — юзер заметит. |
| ✨auto group'а — override применяется как обычно | `runGroupUrltest('✨auto')` использует `pingUrlFor('✨auto')` → override применяется так же. Если юзер не настроил — global URL. |
| `_pingOptions` cache устаревает после Debug API write | Endpoint после save вызывает `home._loadPingOptions()`. UI dialog после save — то же самое. |

## План имплементации

1. **Storage:** `getPingOptions` / `savePingOptions` + 4 sugared метода. Тесты на serialize/deserialize и read-modify-write.
2. **HomeController:** `_pingOptions` field, `_loadPingOptions()` на init, `pingUrlFor(group)` / `pingTimeoutFor(group)`. Заменить direct usage `pingUrl`/`pingTimeout` (3 callsite). Сделать `pingUrl`/`pingTimeout` getter'ами без setter'ов.
3. **`home_screen.dart` Ping settings dialog:** SegmentedButton apply-to + reset-кнопка + save через SettingsStorage.
4. **Debug API:** scoped CRUD `/settings/ping_options*` в `handlers/settings.dart` + регистрация в router. Помощь docs в `help.dart`.
5. **Tests:** `settings_storage_test` (read-modify-write на ping_options), `home_controller_test` (resolve chain).
6. `flutter analyze` + `flutter test` + APK + smoke на устройстве (override URL для VPN-1 и VPN-2 разные, ping'и с правильным URL'ом видны в `/logs/app`).
