# 052 — VPN Settings: System / Core tabs + reshuffle

| Поле | Значение |
|------|----------|
| Статус | **Implemented** — Phase 1 + Phase 2 done; smoke-test pending |
| Дата | 2026-05-10 |
| Связанные spec'ы | [`046 tunnel apps split-tunneling`](../features/046%20tunnel%20apps%20split-tunneling/spec.md) — **остаётся в Routing**, не переезжает; [`049 sing-box wrapper deep audit`](./049-singbox-wrapper-deep-audit/spec.md) F15 — Allow VPN bypass toggle |
| Затронутые файлы | `app/lib/screens/settings_screen.dart`, `app/lib/screens/app_settings_screen.dart` (Background tab → cleanup), `app/lib/screens/routing_screen.dart` (без изменений), `app/lib/screens/tun_apps_tab.dart` (без изменений) |

## Решения от юзера (записаны чтобы не забывать)

Между сессиями я несколько раз забывал юзерские pre-existing решения. Фиксирую:

1. **Tunnel apps mode + packages list — ОСТАЁТСЯ в Routing → 4-я вкладка.** Не переносим в VPN Settings → System. Юзеру привычно искать «куда роутится app» в Routing; разделять на 2 места — путаница. Подтверждено явно несколько раз.
2. **Keep VPN on exit — ПЕРЕЕЗЖАЕТ из App Settings → Background → VPN Settings → System.**
3. **Tunnel sleep mode (= `background_mode` enum, foreground-service режим)** — ПЕРЕЕЗЖАЕТ из App Settings → Background → VPN Settings → System.
4. **Permissions block (Battery optimization, POST_NOTIFICATIONS, NEARBY_WIFI_DEVICES, ACCESS_BACKGROUND_LOCATION)** — ПЕРЕЕЗЖАЕТ из App Settings → Background → **App Settings → Diagnostics** (не в System!) — в том виде как было в Background, целиком копируется блок.
5. **Tab name: System / Core** (не Service — matches existing project concept `chapter: 'core'`, `corelog.txt`, `DebugSource.core`).

## Цель

Реорганизовать `VPN Settings` screen (Drawer → VPN Settings, текущий `SettingsScreen`) в **2 tab-структуру** с явным семантическим разделением:

- **System** — Android-side VPN controls, всё что идёт через `VpnService.Builder` API (`addAllowedApplication` / `addDisallowedApplication` / `allowBypass`).
- **Service** — sing-box engine settings (template-vars `chapter: core` — текущее единственное содержимое `SettingsScreen`).

## Мотивация

Сейчас:
- `Allow VPN bypass` (§049 F15) живёт в `App Settings → Diagnostics` — **семантически неверно** (это не диагностика, это runtime VPN behavior).
- `Tunnel apps mode + packages` (§046) живёт в `Routing → 4-я вкладка` — **близко по теме**, но Routing про routing decisions (sing-box rules), а Tunnel apps про OS-уровневый split-tunneling.
- `VPN Settings` screen (Drawer) содержит только template-vars (sing-box engine) — это half of the story.

Обе настройки (`Allow bypass` и `Tunnel apps`) — **`Android VpnService.Builder` API**, applied на `builder.establish()`. Они должны жить **в одном месте**. Логичный home — VPN Settings, в новом `System` tab.

## Phase 1 (этот раздел) — минимально-инвазивная реорганизация

### Что переезжает

1. **`Allow VPN bypass`** SwitchListTile из текущего места (App Settings → Diagnostics / Background — где он окажется до этой таски) → `VPN Settings → System`.

### Что **не** переезжает в Phase 1

**`Tunnel apps tab` остаётся в Routing** — с user-perspective это «роутинг по приложениям» (юзер не отличает OS-уровень от sing-box-уровня; ему важно «куда этот app пойдёт»). User uses Routing → Tunnel apps как и любые другие routing rules. Не путаем юзера переездом в backend-категорию.

**Phase 1** касается ТОЛЬКО Allow VPN bypass: добавить System tab + перенести allowBypass из текущего места. Остальные перемещения (Keep on exit, sleep mode, permissions) — Phase 2 (см. ниже).

### Новая структура `SettingsScreen`

```dart
class SettingsScreen extends StatefulWidget {
  // accept subController + homeController как раньше
}

// Build:
DefaultTabController(
  length: 2,
  child: Scaffold(
    appBar: AppBar(
      title: const Text('VPN Settings'),
      bottom: const TabBar(tabs: [
        Tab(text: 'System'),
        Tab(text: 'Service'),
      ]),
    ),
    body: TabBarView(children: [
      _SystemTab(...),                            // новый
      _ServiceTab(template, _varValues, ...),     // existing template-vars
    ]),
  ),
)
```

### `_SystemTab` содержание

Минимально:

```
VPN Settings → System
─────────────────────────────────────────────
☐ Allow VPN bypass                          ← native-side toggle
   Apps may use ConnectivityManager to
   bypass tun. Strict tunnel by default.
```

Room для будущих Builder-API toggle'ов (`setMetered` / `setUnderlyingNetworks` / `setHttpProxy` для VPN — если когда-нибудь будем экспонировать).

### `_ServiceTab` содержание

Existing `SettingsScreen` body — `TemplateVarListView(vars: editableVars, sectionDescriptions: ..., onChanged: ...)`. Нет изменений по содержимому, только wrapped в Tab.

### `routing_screen.dart` — без изменений

Tunnel apps tab остаётся как было. С user-perspective это per-app routing — естественное место в Routing.

### `tun_apps_tab.dart` — без изменений

Остаётся 4-м tab'ом в Routing. Восстановить overflow menu (без `VPN settings` deep-link, который я добавил неудачно — раз allowBypass теперь живёт в новом home, а не куда-то в App Settings).

### Migration

- Storage не меняется — `tun_apps` ключ (§046) и `vars.allow_bypass` (если бы он там жил, но он native-side через BoxVpnClient) — без изменений.
- Существующие юзеры на v1.7.2 после upgrade видят:
  - В Routing — 3 tab'а (без Tunnel apps)
  - В VPN Settings — 2 tab'а (System/Service вместо одного template-vars view)
  - Их prev settings (mode + packages) переехали без потери — рендерятся в System tab

## Phase 2 (после Phase 1, фиксированные решения)

**Не переоткрываем — юзерские решения зафиксированы в "Решения" блоке сверху.**

### Перемещения

| Из | В | Что |
|---|---|---|
| App Settings → Background | **VPN Settings → System** | `Keep VPN on exit` SwitchListTile |
| App Settings → Background | **VPN Settings → System** | `Tunnel sleep mode` (= `background_mode` enum, foreground-service mode picker). Storage key/enum **не** меняем; label на UI можно переименовать в "Tunnel sleep mode" если понятнее |
| App Settings → Background | **App Settings → Diagnostics** | Permissions block в **полном составе как был**: Battery optimization status+grant, POST_NOTIFICATIONS check+request, NEARBY_WIFI_DEVICES check (API 33+), ACCESS_BACKGROUND_LOCATION check (API 30+). Копируется без переделки UI. |

### Что **не** переносится

- `Auto-start on boot` — остаётся в App Settings → General (autostart app'а, не Builder API).
- Tunnel apps mode + packages — остаётся в Routing → 4-я вкладка (см. решение #1 в "Решения" блоке).

### Состояние после Phase 2

```
App Settings:
  General      — auto-start on boot, updates, ping defaults, haptic
  Background   — пустой → УДАЛИТЬ (если ничего не остаётся)
  Diagnostics  — debug API + core logs + permissions block (battery / notifications / wifi / location)

VPN Settings:
  System       — Allow VPN bypass + Keep VPN on exit + Tunnel sleep mode
  Core         — sing-box engine vars (template chapter='core')

Routing:
  Channels / Presets / Rules / Tunnel apps   — без изменений
```

Pros: семантика — System (VPN runtime) / Core (sing-box vars) / Diagnostics (permissions + debug).
Cons: muscle memory у current users; нужны UX-cues при первом open после upgrade.

## Acceptance criteria — Phase 1

- [x] `SettingsScreen` использует `DefaultTabController(length: 2)`, AppBar содержит TabBar c System/**Core**.
- [x] System tab: Allow VPN bypass SwitchListTile + native-side `BoxVpnClient.{get,set}AllowBypass` wired up.
- [x] Core tab: existing template-vars view, без изменений по содержимому.
- [x] `routing_screen.dart`: без изменений (4 tab'а, Tunnel apps остаётся).
- [x] `tun_apps_tab.dart`: остался без изменений в Routing.
- [x] `app_settings_screen.dart`: убран `_allowBypass` field и `_toggleAllowBypass` method.
- [x] BoxVpnClient.{get,set}AllowBypass работает в System tab.
- [x] `flutter analyze` clean.
- [ ] Smoke на телефоне: open VPN Settings → System tab — toggle Allow bypass работает, сохраняется.

## Acceptance criteria — Phase 2

- [x] `Keep VPN on exit` SwitchListTile перенесён из App Settings → Background в VPN Settings → System.
- [x] `Tunnel sleep mode` (background_mode picker, RadioGroup<BackgroundMode> never/lazy/always) перенесён туда же.
- [x] Permissions block (battery / notifications / wifi / location / app info) скопирован **в том виде как был** в App Settings → Diagnostics — interactive ListTile с onTap → grant-flow handlers, не read-only.
- [x] App Settings: Background tab удалён (TabBar 3→2: General + Diagnostics). `_buildBackgroundTab` убран, `_keepOnExit`/`_backgroundMode` fields + `_applyBackgroundMode` handler удалены. Read-only `_permissionRow` удалён (interactive block заменил его).
- [x] Storage keys / enum значения не меняются (`auto_start`, `keep_on_exit`, `background_mode` storage shapes preserved — backward-compat).
- [x] `flutter analyze` clean (8 info-level deprecation warnings про RadioListTile.groupValue/onChanged — Flutter 3.32+ deprecated, существующий API ещё работает).
- [x] `flutter test` green (548 passed).
- [ ] Smoke на телефоне: все перемещённые controls работают на новом месте, prev-state preserved.

## Imp log

Что фактически переехало:

| Из | В | Что |
|---|---|---|
| App Settings → Background tab → top SwitchListTile | VPN Settings → System tab | `Keep VPN on exit` (state, handler, UI) |
| App Settings → Background tab → bottom RadioGroup | VPN Settings → System tab | `Tunnel sleep mode` (state, handler, UI — `BackgroundMode` enum import) |
| App Settings → Background tab → "System setup" section | App Settings → Diagnostics tab | 5 ListTile (Battery / Notifications / Location / Nearby Wi-Fi / App info) — interactive c onTap, без переделки |

> **UPD**: позже в System tab добавлены «Suspend idle tunnels» (§215) и
> «Memory limit» (§271) — состав секции Optimization см.
> `docs/spec/features/128 idle-suspend/spec.md` (раздел UX).

Что **не** переехало:
- `Auto-start on boot` — остался в App Settings → General (autostart app, не Builder API).
- Tunnel apps — остался в Routing → 4-я вкладка (per-app routing с user-perspective).

Touched files:
- `app/lib/screens/settings_screen.dart` (+ ~80 LOC: Keep on exit + Tunnel sleep mode block, BackgroundMode import, _toggleKeepOnExit/_applyBackgroundMode handlers, _vpnLoaded gate)
- `app/lib/screens/app_settings_screen.dart` (− ~150 LOC: `_buildBackgroundTab` целиком, `_keepOnExit`/`_backgroundMode` fields, `_applyBackgroundMode`, `_permissionRow` helper; + ~80 LOC: permissions ListTile в Diagnostics tab)

Storage / native: без изменений. Storage `auto_start_vpn`, `keep_on_exit`, `background_mode` ключи не тронуты, native слой `BoxVpnClient.{get,set}{KeepOnExit,BackgroundMode,AllowBypass}` использован как есть.
