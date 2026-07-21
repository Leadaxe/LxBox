# 037 — Debug API: write `config.json` + toggle auto-rebuild

| Поле | Значение |
|------|----------|
| Статус | ✅ Реализовано (позже) — `PUT /config` (saveParsedConfig), `GET/PUT /state|settings/config_locked`. Шапка «Draft» устарела. |
| Дата | 2026-05-06 |
| Связанные | [`031 debug api`](../features/031%20debug%20api/spec.md), [`036 sendNotification`](036-send-notification-clickable-url.md) |

## Цель

Дать через Debug API возможность **переписать `config.json` напрямую сырой JSON-строкой** и заставить sing-box работать с ним. Плюс — toggle auto-rebuild (флаг "config_locked"), чтобы pinned-конфиг не перезаписывался при следующем UI-действии.

Use-case: тест экспериментальных sing-box features (Tailscale outbound в spec §036, custom DNS settings, прочие фичи которые наша parser/builder pipeline не понимает) **без полноценной поддержки в `NodeSpec` / parser / builder**. Юзер pinned-ит свой config через Debug API, тестирует, потом снимает lock — продолжает обычное использование.

## Текущий flow (без этой таски)

```
[UI action: save server list / toggle preset / DNS rule]
   ↓
SubscriptionController.generateConfig()          ← regenerates from storage
   ↓ (canonical JSON или null)
HomeController.saveParsedConfig(json)            ← writes file + applies (reload sing-box)
```

24+ callsite'ов в коде дёргают `generateConfig()` — почти каждое UI-действие. Любая ручная правка `config.json` через `adb push` / Debug API будет перетёрта на следующем `generateConfig()`.

## Целевой flow

### Когда lock включён

```
[UI action]
   ↓
SubscriptionController.generateConfig()
   ├─ checks `config_locked_for_debug` var
   └─ returns null (silently skipping) если lock=true
   ↓
HomeController.saveParsedConfig() — вызывается только если generateConfig != null,
                                     поэтому пропускается natural flow'ом
```

Storage по-прежнему обновляется (юзер может крутить свои настройки), но `config.json` остаётся pinned'ом до выключения lock.

### Когда lock выключен

Поведение как сейчас. Никаких изменений.

### Через Debug API

```
PUT /config (body: raw JSON)
   ↓
HomeController.saveParsedConfig(rawJson)        ← bypass'ит lock — apply path,
                                                   не generation
   ↓
sing-box reload с новым config'ом
```

`saveParsedConfig` это **apply pipeline**, lock на генерацию её не блокирует.

## Изменения в коде

### 1. `SettingsStorage` — новая var

```dart
/// §037: Когда `true`, `SubscriptionController.generateConfig()` возвращает
/// `null` без regeneration. Используется чтобы pin'ить `config.json`
/// записанный через Debug API `PUT /config`. Default `false` — обычный flow.
static Future<bool> getConfigLockedForDebug() async =>
    (await getVar('config_locked_for_debug', 'false')) == 'true';

static Future<void> setConfigLockedForDebug(bool locked) =>
    setVar('config_locked_for_debug', locked.toString());
```

### 2. `SubscriptionController.generateConfig()` — gate

В начале метода:

```dart
Future<String?> generateConfig() async {
  if (await SettingsStorage.getConfigLockedForDebug()) {
    _log('generateConfig skipped (config_locked_for_debug=true)');
    return null;
  }
  // ... existing logic ...
}
```

Возврат `null` уже handled callers (24 места) — все они проверяют `if (json != null)` или равноценно. Никаких UI breakage.

### 3. `_handlerLogs.dart` (или подходящий handler) — endpoint `GET /state/config_locked`

В `state.dart` добавить путь:

```dart
'/state/config_locked' => _configLocked(req, ctx),

Future<DebugResponse> _configLocked(DebugRequest req, DebugContext ctx) async {
  final locked = await SettingsStorage.getConfigLockedForDebug();
  return JsonResponse({'locked': locked});
}
```

### 4. `config.dart` handler — endpoint `PUT /config`

В `lib/services/debug/handlers/config.dart` (handler уже есть для GET) добавить:

```dart
Future<DebugResponse> configHandler(DebugRequest req, DebugContext ctx) async {
  return switch ('${req.method} ${req.path}') {
    'GET /config'        => _readConfig(req, ctx),
    'GET /config/pretty' => _readConfigPretty(req, ctx),
    'GET /config/path'   => _configPath(req, ctx),
    'PUT /config'        => _writeConfig(req, ctx),
    _ => throw NotFound('config path: ${req.method} ${req.path}'),
  };
}

Future<DebugResponse> _writeConfig(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final raw = req.body;                        // raw bytes
  if (raw.isEmpty) {
    throw const BadRequest('empty body — provide raw sing-box JSON');
  }
  final text = utf8.decode(raw);
  // Валидация: парсим JSON чтобы убедиться что это вообще JSON-объект.
  // Sing-box-side валидация дальше — если конфиг невалидный, sing-box
  // отвергнет на reload и вернёт error через next status events.
  try {
    final obj = jsonDecode(text);
    if (obj is! Map<String, dynamic>) {
      throw const BadRequest('config must be a JSON object');
    }
  } catch (e) {
    throw BadRequest('invalid JSON: $e');
  }
  final ok = await home.saveParsedConfig(text);
  if (!ok) {
    throw const UpstreamError('saveParsedConfig returned false');
  }
  return JsonResponse({
    'ok': true,
    'action': 'write-config',
    'bytes': raw.length,
  });
}
```

`saveParsedConfig` сам триггерит sing-box reload — больше ничего не нужно.

### 5. `settings.dart` handler — endpoint `PUT /settings/config_locked`

В `lib/services/debug/handlers/settings.dart` добавить case в switch:

```dart
case '/settings/config_locked':
  if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
  final body = req.jsonBodyAsMap();
  final locked = body['locked'];
  if (locked is! bool) {
    throw const BadRequest('body must be {"locked": true|false}');
  }
  await SettingsStorage.setConfigLockedForDebug(locked);
  return JsonResponse({'ok': true, 'config_locked': locked});
```

### 6. `help.dart` — задокументировать

Добавить в text capability map (раздел `=== Config ===` и `=== State ===`):

```
GET /config                         Saved sing-box JSON (raw bytes, no re-encode)
PUT /config                         Перезаписать config.json + reload sing-box.
                                      Body: raw sing-box JSON (Map). На reload sing-box
                                      сам валидирует — если invalid, ошибка прилетит
                                      через next status events. ВАЖНО: pin (lock) перед
                                      этим, иначе UI-rebuild перетрёт. См. §037.
GET /config/pretty                  То же с indent
GET /config/path                    Абсолютный путь к файлу на устройстве

GET /state/config_locked            { "locked": bool } — текущее состояние §037 lock'а
PUT /settings/config_locked         Включить/выключить auto-rebuild lock. Body:
                                      {"locked": true|false}. true → generateConfig
                                      возвращает null silently, custom config pin'нут.
                                      Default false (обычный flow). См. §037.
```

И в JSON capability map (`_capabilityJson`) — те же endpoint'ы добавить.

## Use-case (что юзер делает через API)

```bash
TOKEN=357f5aacdf154419d2787ec61e3ad9f2
HOST=http://127.0.0.1:9270

# 1. Залочить — теперь UI не будет regenerate'ить config
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"locked": true}' \
     "$HOST/settings/config_locked"

# 2. Получить current config, edit'нуть локально
curl -s -H "Authorization: Bearer $TOKEN" "$HOST/config" > /tmp/cfg.json
# ... добавить tailscale outbound в /tmp/cfg.json ...

# 3. Загнать обратно
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     --data-binary @/tmp/cfg.json \
     "$HOST/config"

# 4. (Опционально) Connect VPN если не was up
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$HOST/action/start-vpn"

# 5. Наблюдать через /logs?source=core что sing-box делает с tailscale outbound
curl -s -H "Authorization: Bearer $TOKEN" "$HOST/logs?source=core&q=tailscale" | jq

# 6. Когда наигрался — расxlock'ить
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"locked": false}' \
     "$HOST/settings/config_locked"

# 7. Любое UI-действие (или /action/rebuild-config) восстановит нормальный config
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$HOST/action/rebuild-config"
```

## Что НЕ в скопе

- **UI banner "config locked via debug API"** — юзер сам помнит что локнул. Если забыл — `/state/config_locked` показывает true. Когда юзер начнёт менять что-то в UI и не увидит эффекта — сам поймёт. Можно добавить banner в follow-up.
- **Validation pipeline для injected config** — мы делаем только базовый JSON.parse check'. Sing-box-side validation на reload — её ошибки прилетают через status events / `/logs?source=core`. Дублировать наш Builder'овский валидатор не нужно (юзер специально хочет конфиг которого Builder не понимает).
- **Backup integration** — backup/restore flow через `/backup/export` отдельно. Если юзер хочет вернуться к pre-pin состоянию — есть `/backup/import`, в самом крайнем случае `/action/rebuild-config` восстановит из storage.
- **Auto-unlock после X секунд** — юзер сам управляет, никаких таймеров. Lock остаётся до явного снятия (или удаления storage / `/backup/import` который перетирает vars).
- **Multiple pinned configs** — один config за раз. Хочешь сменить — `PUT /config` ещё раз.
- **Per-callsite override** (например, lock не блокирует rebuild от нашего own AutoUpdater) — нет. Lock универсальный, блокирует все `generateConfig()` вызовы.

## Risks

| Риск | Митигация |
|---|---|
| Юзер залочил, забыл, удивляется почему UI ничего не меняет | `/state/config_locked` показывает true. Можно добавить banner в UI если станет частой проблемой. |
| Невалидный config через `PUT /config` → sing-box не стартует | Sing-box-side validation на reload, ошибки в `/logs?source=core`. Юзер откатывается через `PUT /config` с предыдущим (или `/backup/import`). |
| Lock остаётся через app restart | Это **намеренно** — `var` персистентная. Юзер сам решает когда снимать. |
| AutoUpdater (spec 027) триггерит rebuild когда lock on | Auto-update пайплайн упирается в `generateConfig() == null` → null-check на callsite skipping. Подписка обновляется в storage, конфиг не перегенерируется. Когда unlock — следующий rebuild подхватит свежие данные. |
| Backup/restore с lock-флагом | `var` попадёт в backup/export. На import у другого юзера — он унаследует lock. Не критично, но может удивить. Рекомендация в спеке: документировать в backup notes. (Не делаем в этой таске.) |

## План имплементации

### Код

1. `SettingsStorage`: `getConfigLockedForDebug` / `setConfigLockedForDebug` методы.
2. `SubscriptionController.generateConfig`: гард в начале → `return null` если locked.
3. `state.dart` handler: новый `/state/config_locked` endpoint.
4. `config.dart` handler: добавить `PUT /config` case.
5. `settings.dart` handler: добавить `/settings/config_locked` case.
6. `help.dart`: задокументировать в обоих форматах (text + JSON).

### Документация (обязательно вместе с кодом)

7. `docs/api/debug-api-reference.md` — добавить разделы:
   - `PUT /config` (request body, response, validation behavior, example curl)
   - `GET /state/config_locked` (response shape)
   - `PUT /settings/config_locked` (request body)
   - Use-case рецепт (bash flow: lock → get → edit → put → unlock)
8. `CHANGELOG.md` — entry в `## [Unreleased]` (или текущей версии-в-работе):
   - "Debug API: support direct config.json write + lockable auto-rebuild (§037)"
9. `docs/ARCHITECTURE.md` — если есть section про Debug API / config pipeline, добавить упоминание lockable generateConfig. Если нет — пропускаем, не выдумываем разделы.

### Verification + Release

10. `flutter analyze`.
11. Build APK + install.
12. Smoke test:
    - Lock → modify config (добавить tailscale outbound) → upload → start VPN → проверить что sendNotification (§036) триггерится.
    - Unlock → rebuild-config → проверить что обычный config вернулся.
13. На момент catch-all релиза (когда наберётся пачка тасок) — bump `pubspec.yaml` version + entry в `RELEASE_NOTES.md` + `docs/releases/vX.Y.Z.md`. Не в этой таске — release flow отдельно.

## Verification

1. **Lock blocks UI rebuild:** lock → менять server list (e.g., toggle preset) → `/config` остаётся pinned (тот что был до lock'а или последний `PUT /config`).
2. **Write+reload:** `PUT /config` с tailscale outbound → sing-box логирует "tailscale outbound: waiting for authentication" → `sendNotification` показывает notification → юзер видит на устройстве.
3. **Unlock returns to normal:** unlock → `/action/rebuild-config` → `/config` снова из generateConfig (без tailscale outbound).
4. **Bad JSON rejected:** `PUT /config` с garbage → 400 Bad Request, sing-box не reload'ится.
5. **State endpoint:** `/state/config_locked` корректно отражает текущий lock state.

## Docs to update

См. постоянную карту в [`docs/spec/README.md → Карта обновления документации`](../README.md#карта-обновления-документации).

| Файл | Что добавить |
|---|---|
| [`docs/api/debug-api-reference.md`](../../api/debug-api-reference.md) | `PUT /config` (body — sing-box JSON, side effect — reload), `GET /state/config_locked`, `PUT /settings/config_locked` + bash use-case примеры (lock → PUT config → start → unlock → rebuild). |
| [`CHANGELOG.md`](../../../CHANGELOG.md) | Entry в `Unreleased` секцию: «Debug API: write-config + lock-rebuild для experimental sing-box features (tailscale outbound)». |
| [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) | Опционально — короткая заметка в Debug API section про "lockable generateConfig" если такая section появится. Структурно это small surface, можно и без. |
| [`RELEASE_NOTES.md`](../../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../../releases/) | На bump'е версии (catch-all release) — entry про новые endpoints. |
| [`pubspec.yaml`](../../../app/pubspec.yaml) | Patch bump (1.6.0 → 1.6.1) если катим релиз с этой кучей тасок (§035-§037). |
| [`docs/DEVELOPMENT_REPORT.md`](../../DEVELOPMENT_REPORT.md) | Опционально — нарратив в текущий рабочий цикл. |
