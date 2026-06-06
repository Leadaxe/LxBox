# 075 — Tunnel apps: regenerate config перед restart VPN

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-06 |
| Тип | fix (behavior bug) |
| Зависимости | §046 (tun_apps storage + applyTunPackages post-step), §047 (subscription controller generateConfig), §030 (HomeController saveParsedConfig). |
| Связанные | `app/lib/screens/tun_apps_tab.dart::_restartVpn`, `app/lib/services/builder/post_steps.dart::applyTunPackages`, `app/lib/controllers/subscription_controller.dart::generateConfig`. |

## Триггер (incident 2026-06-06)

Юзер выбрал `Mode = Deny-list` + добавил Internet (`com.heytap.browser`) в Tunnel apps tab. Banner «Restart needed» появился, юзер тапнул restart. Internet всё ещё ходил через VPN.

Verified via Debug API:

```
GET /settings/tun_apps  → {mode: "deny", packages: ["com.heytap.browser"]}  ✅
GET /config             → inbound[type=tun]: НЕТ exclude_package           ❌
```

Storage обновлён, applied config — нет. Restart VPN запускает **last saved config**, не пересобирает.

## Root cause

`tun_apps_tab.dart::_restartVpn` делал `stop() → start()`. `_startInternal` вызывает `_vpn.startVPN()` (native) который читает **saved config file**. Storage с новым `tun_apps` обновился, но config файл не пересобран — нет `applyTunPackages(config, tunApps)` поверх свежего storage shape.

Применение `tun.exclude_package` происходит ровно в `post_steps.dart::applyTunPackages(config, tunApps)` — этот post-step запускается **только** во время `subController.generateConfig` (pipeline §047). Native side архитектурно не читает storage напрямую — он работает с saved config файлом.

Поэтому минимально-необходимый flow для apply:

1. `subController.generateConfig()` — собирает свежий config с применением `applyTunPackages` поверх свежего `tun_apps`.
2. `homeController.saveParsedConfig(config)` — атомарно перезаписывает saved-config файл.
3. `homeController.stop()` → `homeController.start()` — native подхватывает свежий config.

В `_restartVpn` сейчас отсутствовали шаги 1-2.

## Фикс (revised)

Initial fix добавлял regenerate в `_restartVpn`, но это создавало
**второй source-of-truth** для «is restart needed». User: "локальный
banner не нужен, при любом изменении используем тот же механизм что
routing_screen".

Revised fix приводит `tun_apps_tab` к pattern'у `routing_screen._apply`:

```dart
// До §075:
Future<void> _persist() async {
  await SettingsStorage.setTunApps(_cfg);
}
// + локальный banner (_isModified vs _appliedCfg)
// + локальный _restartVpn() с stop/start без regenerate

// После §075:
Future<void> _persist() async {
  await SettingsStorage.setTunApps(_cfg);
  final config = await widget.subController.generateConfig();
  if (config != null) {
    await widget.homeController.saveParsedConfig(config);
  }
}
// banner удалён
// _restartVpn удалён
// _appliedCfg / _isModified удалены
```

Поведение теперь identical с routing_screen:
- Дебаунс 400ms собирает рапid toggle'и в один regenerate.
- `saveParsedConfig` сам set'ит `configStaleSinceStart=true` при `tunnelUp`.
- Home banner `_needsRestart` (home_screen.dart::_needsRestart getter,
  читает `state.configStaleSinceStart || _subController.configDirty`)
  показывает «Restart VPN» глобально.
- Юзер restartит из home banner — никаких локальных кнопок.

`generateConfig` может вернуть `null` если есть build errors
(subscription parsing failed, validator rejected, etc.) — в этом случае
skip save, последний валидный config остаётся в файле. Home banner всё
ещё может говорить про restart (если флаг был set'нут раньше) — это
acceptable: пользователь увидит что-то не сошлось.

## Edge cases

| Сценарий | Поведение |
|---|---|
| `generateConfig()` returns null | Skip save, restart с старым config. Banner всё ещё показывается → юзер увидит что изменения не применились. (Не хуже чем было.) |
| User меняет tun_apps быстро между restart'ами | `_persist` debounce 400ms задерживает write. Если юзер тапает restart до debounce'а — `_cfg` уже в state, но storage ещё не updated. **TODO follow-up:** flush debounce timer перед restart. Сейчас не критично т.к. debounce короткий и юзер обычно ждёт. |
| `saveParsedConfig` fails (disk full, etc.) | `home.saveParsedConfig` set'ит `lastError`. UI banner покажет error. Restart всё равно идёт — с **last successfully saved** config (тот что был перед попыткой). |
| VPN down при tap «Restart» | Banner не показывается когда `tunnelUp == false` (см. line 244). Соответственно `_restartVpn` не зовётся. Юзер start'ует VPN вручную — `_startInternal` запускает saved config. Если config был перегенерирован раньше — apply OK. Если нет — старый config. **Это другой path**, не §075. |

## Не в скопе

- Auto-regenerate config на каждом `_persist` (без restart) — может быть полезно для других путей применения, но текущий §046 design явно про restart-only. Architectural shift, не bugfix.
- Поправка для **других** screen'ов где settings меняют tun config — DNS, routing rules. Эти flow'ы уже имеют `regenerateAndSave` помощник в `subscriptions_screen.dart::_regenerateAndSave`, который вызывается после mutation. Tun_apps был выпавшим звеном.
- Native side изменения — `BoxVpnService.kt:557-560` корректно читает `options.includePackage` / `excludePackage` от libbox; bug был выше по stack'у в Dart-сборке config.

## Файлы

- `app/lib/screens/tun_apps_tab.dart` — `_restartVpn` добавляет regenerate + save перед stop/start.
- `CHANGELOG.md` — entry под `### Fixed`.
- `RELEASE_NOTES.md` — упоминание в `🐛 Fixes` секции.
- `docs/spec/tasks/075-tun-apps-restart-regen-config.md` (этот файл).

## Manual verification

После APK install:
1. Set Mode = Deny-list + add app (e.g. Internet).
2. Tap Restart.
3. Verify via Debug API: `GET /config` → inbound[type=tun].exclude_package == [pkg]. ✅
4. Open the app in question; traffic должен идти прямо через wifi/cellular (без VPN tag в connection tracking).

## Acceptance criteria

- [ ] После restart VPN из Tunnel apps tab `/config` показывает свежий `tun.exclude_package` / `include_package` matching storage.
- [ ] Banner «Restart needed» исчезает после успешного restart (existing behavior — `_appliedCfg = pending`).
- [ ] При build error (`generateConfig` returns null) restart всё равно происходит, но с старым config; banner остаётся.
