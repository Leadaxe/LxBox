# 073 — Detour: append vs replace (subscription policy)

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-05 |
| Зависимости | `DetourPolicy` (server_list.dart §1.3 spec 026), `ServerListBuild.build` (server_list_build.dart), §071 (UI bottom sheet pattern, не зависим semantically) |
| Связанные | `subscription_detail_screen.dart::_DetourMode` enum (UI radio group) |
| Триггер | До §073 единственный способ задать кастомный detour в подписке — `Override` mode, который **полностью заменяет** родную detour-цепочку из конфига одним выбранным outbound'ом. Юзер просит дополнительно режим **append**: ноды идут по своей родной цепочке, а в конец добавляется выбранный hop. Это нужно когда подписка возвращает многоhop chain (jumphost ladder) и юзер хочет дописать последний exit, не теряя intermediates. |

## Цель

Изменить семантику mode `override` → **«Add detour»** (default = **append**) + новый checkbox **«Replace existing chain»**:

- **OFF** (default): нативная цепочка из конфига сохраняется, выбранный `overrideDetour` подставляется как **новый последний хоп**. Если цепочка пуста — 1-hop (как old override).
- **ON**: текущее поведение — родная цепочка отбрасывается, `overrideDetour` становится единственным детуром.

UI: переименовать radio item `Override` → `Add detour`. Под ним появляется (1) Outbound picker (как сейчас), (2) новый `SwitchListTile` «Replace existing chain» (default OFF).

## Не в скопе

- Изменение storage schema: поле `override_detour` остаётся (semantic не меняется — это всё ещё tag для подстановки).
- Изменение `useDetourServers=false` mode (`None`) — без изменений.
- Изменение per-node `entry.overrideDetour` (NodeSettings) — это другой mechanism, не задевается.
- Backward migration: старые backup'ы без `replace_detour_chain` → default false (append). ⚠ **Это меняет поведение** существующих юзеров с `override_detour != ''`. Acceptable: пользы от append больше, риск минимален (раньше chain сбрасывался — теперь сохраняется + хвост).
- Tag allocation correctness в multi-hop chains — pre-existing issue вне scope.

---

## Текущее состояние

```
DetourPolicy {
  registerDetourServers: bool,
  registerDetourInAuto:  bool,
  useDetourServers:      bool,    // default true
  overrideDetour:        String,  // '' = no override
}

ServerListBuild.build(EmitContext):
  skipDetour = !useDetourServers || overrideDetour.isNotEmpty
  ↑ когда override активен — raw chain ВЫКИДЫВАЕТСЯ (skipDetour=true)

  for each server:
    raw = server.getEntries(ctx, skipDetour: skipDetour)
    if overrideDetour.isNotEmpty:
      main.detour = overrideDetour    // REPLACE
    elif !useDetourServers:
      remove main.detour
    elif raw.detours.isNotEmpty:
      main.detour = raw.detours.first.tag  // chain start

UI (subscription_detail_screen.dart):
  RadioGroup<_DetourMode>{ use, override, none }
    └─ Mapping:
       use      → useDetour=true,  override=''
       override → useDetour=true,  override='<tag>'  ← REPLACE only
       none     → useDetour=false, override=''
```

---

## Целевое состояние

### Model — `DetourPolicy.replaceDetourChain: bool` (default false)

```dart
class DetourPolicy {
  final bool registerDetourServers;
  final bool registerDetourInAuto;
  final bool useDetourServers;
  final String overrideDetour;
  final bool replaceDetourChain;  // §073 NEW, default false (append)
  // ...fromJson reads with default; toJson writes; copyWith adds param;
  //    ==/hashCode include the new field.
}
```

JSON key: `replace_detour_chain` в `override_detour` соседе. fromJson default = false.

### Builder — `server_list_build.dart`

```dart
void build(EmitContext ctx) {
  if (!enabled) return;
  // §073: replaceMode = override + replace toggle ON. Append mode keeps
  // raw chain (skipDetour: false), splices override at tail.
  final replaceMode = detourPolicy.overrideDetour.isNotEmpty &&
      detourPolicy.replaceDetourChain;
  final skipDetour = !detourPolicy.useDetourServers || replaceMode;

  for (final server in nodes) {
    final raw = server.getEntries(ctx, skipDetour: skipDetour);
    final main = raw.main;
    final detours = raw.detours;

    // tag allocation — unchanged
    for (final d in detours) {
      d.map['tag'] = ctx.allocateTag(_withPrefix(d.tag));
    }
    main.map['tag'] = ctx.allocateTag(_withPrefix(main.tag));

    if (replaceMode) {
      // REPLACE — chain dropped (skipDetour=true → detours is empty).
      main.map['detour'] = detourPolicy.overrideDetour;
    } else if (!detourPolicy.useDetourServers) {
      main.map.remove('detour');
    } else if (detourPolicy.overrideDetour.isNotEmpty) {
      // §073 APPEND — chain preserved, override at tail.
      if (detours.isEmpty) {
        // Empty native chain → 1-hop (functionally same as replace).
        main.map['detour'] = detourPolicy.overrideDetour;
      } else {
        // node → first(detour) → ... → last(detour) → overrideDetour
        main.map['detour'] = detours.first.tag;
        detours.last.map['detour'] = detourPolicy.overrideDetour;
      }
    } else if (detours.isNotEmpty) {
      main.map['detour'] = detours.first.tag;
    }

    // registration loops — unchanged
  }
}
```

### UI — `subscription_detail_screen.dart`

```dart
// Rename Radio item label:
RadioListTile<_DetourMode>(
  value: _DetourMode.override,
  title: const Text('Add detour'),   // was 'Override'
  subtitle: Text(entry.overrideDetour.isEmpty
      ? 'Append an outbound to the end of the chain'
      : entry.replaceDetourChain
          ? 'Replace chain → ${entry.overrideDetour}'
          : 'Append → ${entry.overrideDetour}'),
),

// Sub-tile in override mode — existing Outbound picker stays.
// NEW: add SwitchListTile under the picker:
if (_detourMode == _DetourMode.override) ...[
  // Outbound picker (existing)
  ListTile(...),
  // §073 NEW
  SwitchListTile(
    title: const Text('Replace existing chain'),
    subtitle: const Text(
      'Drop the native detour chain and use only this outbound'),
    value: entry.replaceDetourChain,
    onChanged: (v) {
      setState(() => entry.replaceDetourChain = v);
      unawaited(controller.persistSources());
    },
  ),
],
```

`SubscriptionEntry` getter/setter (controllers/subscription_controller.dart) добавляет:

```dart
bool get replaceDetourChain => detourPolicy.replaceDetourChain;
set replaceDetourChain(bool v) => _replaceList(
    _copy(detourPolicy: detourPolicy.copyWith(replaceDetourChain: v)));
```

### Migration — `proxy_source_migration.dart`

Read with default false:

```dart
overrideDetour: (s['override_detour'] as String?) ?? '',
replaceDetourChain: (s['replace_detour_chain'] as bool?) ?? false,
```

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| `overrideDetour = ''`, `replaceDetourChain = true` | `replaceDetourChain` игнорируется (нет toggle effect без overrideDetour). UI checkbox видим только когда юзер выбрал outbound — но даже если состояние persisted с replaceDetourChain=true и пустым override, builder seamless. |
| `overrideDetour = 'x'`, native chain пустая, `replaceDetourChain = false` | 1-hop: `node → x → internet`. Functionally same как replace=true. |
| `overrideDetour = 'x'`, native chain N hops, replace=false | `node → native[0] → ... → native[N-1] → x → internet`. |
| `overrideDetour = 'x'`, native chain N hops, replace=true | `node → x → internet`. |
| `useDetourServers = false` + `overrideDetour = 'x'` | use=false выигрывает: `node` direct, без detour. (Не меняется.) |
| Switch с override (replace=true) → on append (toggle replace OFF) | Native chain re-emerge'ит из raw config — потому что `skipDetour` пересчитывается на build. Persisted на disk сразу через `persistSources`. |
| Backup restore старого формата (без `replace_detour_chain` ключа) | Default false = append. ⚠ **Поведение existing юзеров с override меняется** — была replace, стала append. Подсветим в release notes. |

## Файлы

- `app/lib/models/server_list.dart` — `DetourPolicy` +1 поле + fromJson/toJson/copyWith/==/hashCode.
- `app/lib/services/builder/server_list_build.dart` — append branch.
- `app/lib/services/migration/proxy_source_migration.dart` — read with default.
- `app/lib/controllers/subscription_controller.dart` — `replaceDetourChain` getter/setter.
- `app/lib/screens/subscription_detail_screen.dart` — rename Radio item label + add SwitchListTile + update subtitle copy.
- `app/test/builder/build_config_test.dart` (или новый `detour_append_test.dart`) — тесты:
  - append: `node → native_chain → override` (multi-hop)
  - append, native chain пустая: `node → override` (1-hop)
  - replace=true: `node → override` (chain дропнут)
- `app/test/models/server_list_json_test.dart` — round-trip с `replaceDetourChain`.
- `docs/spec/tasks/073-detour-append-vs-replace.md` (этот файл).
- `CHANGELOG.md` — entry под `### Changed` (behaviour shift) + `### Added` (UI option).
- `RELEASE_NOTES.md` — highlight в v1.9.0 (юзеры с override увидят разницу).

## Locked decisions

1. **Append default** — soft-er semantic, native chain сохраняется.
2. **Field rename: НЕ переименовываем `overrideDetour` в код/storage** — backward compat, JSON keys (storage + backup) intact. Меняется только UI label («Add detour» вместо «Override») + новый toggle.
3. **`replaceDetourChain` per-entry**, в `DetourPolicy` рядом с `overrideDetour`.
4. **Migration: default = append** (потенциально меняет behaviour). Альтернатива (default replace = preserve old behaviour) → отвергнута: новые юзеры запомнят что «add detour = append», старые редко используют override — explainable break.
5. **UI: SwitchListTile** под outbound picker (Material standard для on/off под секцией), не Checkbox в Row.
6. **Empty native chain → 1-hop** в append mode (равнозначно replace для этого случая).

## Acceptance criteria

- [ ] DetourPolicy persist/load round-trip с replaceDetourChain.
- [ ] Migration с старого backup (без `replace_detour_chain` key) → default false.
- [ ] Builder append: node со chain N+1 hops, тег `overrideDetour` присутствует только как detour для последнего native hop.
- [ ] Builder append + пустая chain: главный node.detour = overrideDetour (1-hop).
- [ ] Builder replace=true: chain не строится (skipDetour=true), main.detour = overrideDetour.
- [ ] UI: Radio item label «Add detour». В Override mode под Outbound picker есть SwitchListTile «Replace existing chain».
- [ ] Subtitle Radio item корректно отображает Add/Append/Replace состояние.
- [ ] Switch toggle persists через `persistSources()`.
- [ ] Существующие тесты builder/server_list_json/migration не сломаны (default replaceDetourChain=false).
