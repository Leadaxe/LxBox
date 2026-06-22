# 157 — Automation: убрать нерабочую галку «Require permission»

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-06-22) — галка/логика удалены (Dart+native+manifest+docs); `flutter analyze` чисто, Kotlin compile подтверждён release-сборкой arm64, grep 0 остаточных ссылок в коде. On-device toggle не проверялся (телефон не подключён). |
| Дата | 2026-06-22 |
| Тип | cleanup (удаление нерабочего механизма защиты) |
| Повод | Галка «Require permission» в Settings → Automation по факту не защищает |
| Связано | §047 (Public Intent API — обе части), §154/§156 (i18n automation_tab — параллельная сессия) |

---

## TL;DR

Галка **«Require permission»** (`automation_require_permission`) обещает
ограничить приём automation-broadcast'ов приложениями, держащими
`com.leadaxe.lxbox.permission.AUTOMATION`. Реализована через
`context.checkCallingPermission(PERMISSION_AUTOMATION)` внутри `onReceive`
broadcast-receiver'а — **и это не работает детерминированно**.

Удаляем механизм целиком: галку из UI, всю Dart-логику (storage-ключ, method
channel, client-метод), native-логику (native-кеш, permission-чек в incoming,
permission-фильтр в outgoing), объявление custom-permission из манифеста.

Защита приёма остаётся прежней — **сам мастер-toggle** «Accept automation
commands»: пока он OFF, receiver'ы `enabled=false` и не существуют для системы.
Это и есть единственный реальный барьер.

---

## Почему галка не работает

`checkCallingPermission()` отдаёт грант отправителя **только если есть живая
binder-транзакция** от него (как при `bindService`/`startActivity`). У обычного
(не-ordered) broadcast'а в момент доставки **caller-identity уже потеряна** —
отправитель ушёл. Поэтому чек:

```kotlin
context.checkCallingPermission(PERMISSION_AUTOMATION) == PERMISSION_GRANTED
```

в `onReceive` для broadcast'а недетерминирован: на большинстве путей вернёт
`PERMISSION_DENIED` независимо от того, держит ли отправитель permission. То
есть при включённой галке отбиваются и легитимные команды от Tasker —
механизм не «защищает строже», он просто ломает приём.

Честные кросс-версионные механизмы (для справки, НЕ реализуются здесь):
- **shared-secret токен** в extra — работает на всех Android, с любым
  отправителем; не подделывается без знания секрета;
- **UID-allowlist** через `getSentFromUid()` — только Android 14+ И только для
  ordered broadcast; не покрывает старые устройства (целевые для L×Box);
- **custom-permission `signature`** — надёжно, но блокирует и Tasker (он не
  подписан нашим ключом) → несовместимо с самой целью automation.

Решение: не подменять нерабочий барьер на полу-рабочий, а **убрать** его.
Мастер-toggle (receiver `enabled=false` по умолчанию) — достаточный и честный
gate. Если в будущем понадобится реальная защита — отдельная таска с
токеном/allowlist.

---

## Что меняется в outgoing-эмиттере

`VpnPlugin.sendAutomationBroadcast` сейчас в «строгом режиме» шлёт
`sendBroadcast(intent, PERMISSION_AUTOMATION)` — события получают только
держатели permission. После удаления — безусловный `sendBroadcast(intent)`.

Последствие: outgoing-события (если юзер включил emit-категории, default OFF)
видны любому подписчику. Приемлемо: события **не содержат секретов** — только
лейблы (теги нод, имена групп, статус), это явно сказано в emit-explainer'е.
Permission-фильтр и так действовал только при ON-галке, которую мы признали
нерабочей.

---

## Files

| File | Change |
|---|---|
| `app/lib/screens/app_settings_screen/widgets/automation_tab.dart` | удалить SwitchListTile «Require permission» + условный permission-блок; поле `_requirePermission`; загрузку/`_onRequireChanged`; константу `_permission`; упоминание в emit-explainer'е |
| `app/lib/services/settings_storage.dart` | удалить `get/setAutomationRequirePermission` + ключ; поправить doc-комментарий блока |
| `app/lib/vpn/box_vpn_client.dart` | удалить `setAutomationRequirePermission` |
| `app/lib/vpn/box_vpn_client/method_names.dart` | удалить const `setAutomationRequirePermission` |
| `app/lib/services/automation/event_emitter.dart` | поправить doc-комментарий (убрать «granted permission») |
| `app/android/.../vpn/LxBoxIntentReceiver.kt` | удалить `PERMISSION_AUTOMATION`, `requirePermission`/`setRequirePermission`, PREFS-кеш `require_permission`, permission-чек в `dispatch`; поправить class-doc |
| `app/android/.../vpn/VpnPlugin.kt` | удалить method-channel `setAutomationRequirePermission`; в `sendAutomationBroadcast` — безусловный `sendBroadcast(intent)` |
| `app/android/.../AndroidManifest.xml` | удалить `<permission>` + `<uses-permission>` AUTOMATION; поправить comment у receiver'а |
| `docs/AUTOMATION.md` | убрать упоминания «Require permission» / custom-permission |

**Migration:** не нужна — приложение не релизилось, юзеров кроме разработчика
нет (подтверждено). Мёртвый ключ `automation_require_permission` просто
перестаёт писаться; у разработчика будет осиротевший ключ в локальном
`lxbox_settings.json` (storage tolerant к лишним ключам) — безвреден.

---

## Verification

- [x] `flutter analyze` чисто (нет ссылок на удалённые символы) — No issues found
- [x] Kotlin compile чисто (`flutter build apk --release` arm64) — `✓ Built app-release.apk`
- [x] grep подтверждает 0 упоминаний `requirePermission` / `RequirePermission` /
      `PERMISSION_AUTOMATION` / `permission.AUTOMATION` / `require_permission` в
      коде `app/` (остались только спека §157 и §047 — с пометкой об изменении)
- [ ] вкладка Automation открывается, мастер-toggle включает/выключает приём
      (on-device — телефон не подключён, не проверялось)
