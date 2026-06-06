# 069 — Current session allowBypass tracking + Stats warning

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-05 |
| Зависимости | §049 F15 (existing allow_bypass toggle), §052 (VPN Settings System tab), §063 (Debug API /state/vpn) |
| Связанные | `BoxVpnService.kt:160-162` (existing `if (BootReceiver.isAllowBypass(this)) builder.allowBypass()`), `VpnPlugin.kt:197-205` (existing getAllowBypass/setAllowBypass handlers), `state.dart::_vpn` (Debug API /state/vpn handler), `stats_screen.dart` |
| Триггер | Persisted setting (`SharedPreferences.allow_bypass`) и **runtime applied** state (`VpnService.Builder.allowBypass()` вызванный при `establish()`) могут расходиться: юзер меняет toggle → persisted updated → но runtime остаётся со старым значением до stop+start VPN. В incident 2026-06-05 юзер уверял что toggle off, но runtime был on — backup restore set'нул persisted=true, юзер не заметил т.к. не открыл Settings tab. Нужен visual indicator если bypass **сейчас applied** в active VPN session. |

## Цель

Tracking **runtime applied** значения `allowBypass()` (что реально передано в `VpnService.Builder` при последнем `establish()`), отдельно от persisted setting. Expose через Debug API + показывать warning icon в Stats screen AppBar.

## Не в скопе

- Изменение поведения `allow_bypass` toggle (как было, как есть)
- Warning на других screens (Home, Settings — там уже есть info-tooltip на toggle)
- Auto-restart VPN при изменении toggle (это намеренно opt-in через explicit stop+start)
- Backup format — `allow_bypass` всё ещё persisted snapshot (см. §063)

---

## Текущее состояние

```
persisted state:                  runtime state:
SharedPreferences                 VpnService.Builder
  boxvpn_boot.xml                   (set ONLY at establish())
  KEY_ALLOW_BYPASS: Bool          
       │                                    │
       │ читается в establish() →          │
       │                            ┌──────▼──────┐
       └───── setAllowBypass() ←────│  Mismatch   │
              UI/API/Backup         │  possible!  │
                                    └─────────────┘
```

UI и `/state/vpn` сейчас отдают **persisted** значение. Runtime — invisible (известно только Android Framework, не recoverable из app code).

## Новая модель

```
persisted:                        runtime applied:
SharedPreferences                 BoxVpnService.companion
  KEY_ALLOW_BYPASS                  var currentSessionAllowBypass: Boolean
       │                                  │
       │ читается ────►            ◄──── снимок при establish()
       │                                  │
       │                                  ▼
       │                          сброс в false при service onDestroy
       ▼                                  │
   /state/vpn.allow_bypass         /state/vpn.current_session_allow_bypass
```

**Точное отражение** что сейчас applied в Android: `currentSessionAllowBypass` — companion var в `BoxVpnService` (process-lifetime). Set ровно один раз per `establish()`. Reset to `false` в `onDestroy()` (когда VpnService умирает → applied значение больше не действует).

### Native (Kotlin) изменения

`BoxVpnService.kt`:
```kotlin
companion object {
    /// §069: snapshot of allow_bypass value at last establish() call.
    /// Represents what's actually applied in VpnService.Builder.allowBypass().
    /// Persisted setting (BootReceiver.isAllowBypass) is separate.
    @Volatile var currentSessionAllowBypass: Boolean = false
}

// in establish():
val abs = BootReceiver.isAllowBypass(this)
currentSessionAllowBypass = abs
if (abs) builder.allowBypass()

// in onDestroy():
currentSessionAllowBypass = false
super.onDestroy()
```

`VpnPlugin.kt` — новый handler:
```kotlin
"getCurrentSessionAllowBypass" -> {
    result.success(BoxVpnService.currentSessionAllowBypass)
}
```

### Dart layer

`BoxVpnClient.dart` — новый method:
```dart
Future<bool> getCurrentSessionAllowBypass() async {
  final v = await _invoke<bool>(
    _Methods.getCurrentSessionAllowBypass,
    timeout: _Timeouts.settings,
    onTimeoutValue: false,
  );
  return v ?? false;
}
```

### Debug API `/state/vpn`

Add new field, **non-breaking** (existing consumers unaffected):

```json
{
  "auto_start": false,
  "keep_on_exit": false,
  "allow_bypass": false,
  "current_session_allow_bypass": true,  ← NEW (runtime)
  "background_mode": "never",
  "is_ignoring_battery_optimizations": true
}
```

Mismatch `allow_bypass=false` && `current_session_allow_bypass=true` = «toggle меняли, не reload'нули VPN; runtime всё ещё bypass-enabled».

### UI — Stats screen

В `_StatsScreenState`:
```dart
bool _currentSessionAllowBypass = false;

@override
void initState() {
  ...
  unawaited(_loadCurrentSessionBypass());
}

Future<void> _loadCurrentSessionBypass() async {
  final v = await BoxVpnClient().getCurrentSessionAllowBypass();
  if (mounted) setState(() => _currentSessionAllowBypass = v);
}

// в _refresh() (3-sec polling — переиспользуем):
unawaited(_loadCurrentSessionBypass());
```

В AppBar:
```dart
AppBar(
  title: const Text('Statistics'),
  actions: [
    if (_currentSessionAllowBypass)
      Tooltip(
        message: 'VPN bypass is active in this session.\n\n'
            'Apps can use bindProcessToNetwork() to skip the tunnel '
            '(banking apps, WhatsApp, system services). '
            'Some traffic may not go through VPN.\n\n'
            'Disable in VPN Settings → System → Allow VPN bypass '
            'and reload VPN to enforce strict tunnel.',
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 12),
        waitDuration: const Duration(milliseconds: 100),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(Icons.warning_amber, size: 22),
        ),
      ),
  ],
  bottom: TabBar(...)
)
```

Icon в AppBar → видна **на всех 4 tabs** (Stats / Conns / App / Live).

---

## Файлы

| Файл | Изменение |
|---|---|
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt` | + companion var + snapshot в `establish()` + reset в `onDestroy()` |
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` | + handler `getCurrentSessionAllowBypass` |
| `app/lib/vpn/box_vpn_client.dart` | + method `getCurrentSessionAllowBypass()` + _Methods constant |
| `app/lib/services/debug/handlers/state.dart` | + поле `current_session_allow_bypass` в `/state/vpn` JSON |
| `app/lib/screens/stats_screen.dart` | + `_currentSessionAllowBypass` field + load + AppBar warning IconButton + Tooltip |
| `docs/api/debug-api-reference.md` | doc для нового поля в `/state/vpn` |
| `CHANGELOG.md` Unreleased | Added entry |

Объём ~70 строк production, без новых тестов (companion var simple snapshot, не требует unit-test).

## Risks

| Риск | Митигация |
|---|---|
| Race condition: read companion var во время establish() | `@Volatile` modifier. Atomic read/write on JVM. |
| Companion var stale после service death + new establish() | Reset в `onDestroy()` гарантирует clean slate. Если service возрождается → новый establish() → новый snapshot. |
| Mismatch перед `_refresh()` first invocation | Initial `_currentSessionAllowBypass = false` — pessimistic default, no warning until confirmed. |
| Warning остаётся показанным после toggle off + VPN reload | На reload `onDestroy()` → companion=false → next establish() → new value. Stats screen `_refresh()` каждые 3 sec увидит. |

## Test plan

Manual (no unit tests):
1. Build APK с фичей
2. Включить allow_bypass → start VPN → open Stats → warning icon visible (на всех 4 tabs)
3. Tap icon → tooltip с английским объяснением
4. Stop VPN → warning исчезает в течение 3 sec (next refresh)
5. Set allow_bypass=false без reload → warning **остаётся** (runtime still true)
6. Reload VPN (stop+start) → warning исчезает
7. Debug API `/state/vpn` — оба поля видны (`allow_bypass`, `current_session_allow_bypass`), потенциально разные

`flutter analyze` clean.
