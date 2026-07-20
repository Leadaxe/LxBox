# §293 — VpnSettings-фасад: унификация 4 входов настроек

**Тип:** structural refactor (Шаг 3b фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** дедуп enum РЕАЛИЗОВАН; фасад+экраны pending-device · **Размер:** M

> **Реализовано (безопасная часть, коммит ниже):** инлайн enum-валидация
> settings-handler'а сведена к моделям (единый источник, как §292-D):
> `BackgroundMode.isValid` (write-путь отвергает мусор — в отличие от
> `fromNative`, что молча fallback'ит в `never`) и `TunAppsConfig.isValidMode`
> (переиспользован и в `_setTunApps`, и в Debug `_putTunApps`/`_putBackgroundMode`
> вместо инлайн-списков). 5 тестов.

## Фасад `VpnSettingsFacade.applyVpnMode` (дизайн из ресёрча под probe-эталон)

**RUTHLESS scope:** фасад существует ради ОДНОГО метода с реальной политикой —
`applyVpnMode`, несущего 3 инварианта, которые сейчас продублированы в UI и
**пропущены** в Debug (реальный §291-дефект):

- (a) auth-on + пустой пароль → `generateProxyPassword()`;
- (b) non-loopback listen форсит `effectiveAuth` on (getter модели);
- (c) смена mode → зеркалить `setNativeHasTun(next.hasTun)` (гейтит
  `VpnService.prepare`, §192).

**Проверенная дивергенция:** `vpn_mode_tab._setMode/_applyListen/_toggleAuth`
делают все три; Debug `_putVpnMode` (`settings.dart:224`) — **ни одного**. `PUT
mode=proxy` через Debug оставляет native `has_tun` устаревшим → `VpnService.
prepare()` продолжает срабатывать до следующего bootstrap. Это и есть причина
фасада.

```dart
static Future<VpnModeConfig> applyVpnMode(VpnModeConfig requested,
    {bool flush = true}) async {
  var next = requested;
  if (next.hasMixed && next.effectiveAuth && next.proxyPassword.isEmpty) {
    next = next.copyWith(proxyPassword: generateProxyPassword());
  }
  final cur = await SettingsStorage.getVpnMode();
  await SettingsStorage.setVpnMode(next, flush: flush);
  if (next.hasTun != cur.hasTun) await SettingsStorage.setNativeHasTun(next.hasTun);
  return next;
}
```

### План (strangler)

- **V2 (S, CODE-PROVABLE СЕЙЧАС):** создать `VpnSettingsFacade.applyVpnMode`
  (чистая делегация в существующие `SettingsStorage`+`generateProxyPassword`,
  3 инварианта) + `loadVpnMode` passthrough. Без вызывающих. Юнит-тест на 3
  инварианта. 0 изменений поведения.
- **V3 (S, CODE-PROVABLE СЕЙЧАС — strangler-win):** Debug `_putVpnMode` через
  `applyVpnMode`. Чинит stale-`has_tun` + missing-password БЕЗ трогания UI.
  §292-валидация-BadRequest остаётся ПЕРЕД фасадом. Тест: `PUT mode=proxy`
  теперь флипает native `has_tun`. **Highest-value, lowest-risk — ship
  standalone.**
- **V4 (M, DEVICE-REQUIRED):** `vpn_mode_tab._setMode/_applyListen/_toggleAuth`
  → `applyVpnMode`, удалить дубли (~30 строк). Трогает device-verified UI.

### Scope-cuts (НЕ делать — grab-bag / тривиальные relay)

- **НЕ оборачивать `native_prefs.dart`** — уже §189 write-through фасад
  (его шапка: «Все писатели — UI, импорт, Debug API — идут через этот слой»);
  ре-обёртка дублирует эталон.
- **НЕ фасадить `tun_apps`** — `isValidMode` уже на модели, нет cross-field
  политики.
- **НЕ трогать `app_settings_screen`** — grab-bag: debug-token/port/enabled,
  auto_update/check, wifi, rotation, haptic, auto_ping, subscription UA/HWID —
  несвязанные настройки, у каждой свой владелец (DebugServer/WifiHistoryListener/
  SubscriptionIdentity).
- **НЕ фасадить** idle_suspend/passive_check/interrupt_on_switch — тонкие
  storage-relay; §277-гейт = UI disabled-state.
- **НЕ выдумывать VPN-гейт mixin** для vpn-mode — precondition'а нет.

**Открытый вопрос (flush):** `applyVpnMode` всегда write-through (как
`ProbeController.saveThresholds`), а UI роняет свой `setVpnMode`-staging?
Подтвердить, что не ломает restart-banner timing — это V4 device-verify.

---

Ниже — исходная формулировка проблемы (до дизайна):

Домен vpn-mode/tun-apps/app-settings — «эпицентр настроек»: **нет сервиса** между
экранами и `SettingsStorage`-статиками; валидация размазана по 3 слоям; ~4 входа
(UI, Debug API, backup import, build-time) **переизобретают** одни инварианты.
Нарушение §291 правил 1–2.

## Проблема

- `vpn_mode_tab`/`tun_apps_tab`/`settings_screen`/`app_settings_screen` — все
  screen==controller, зовут `SettingsStorage` напрямую.
- enum-литералы (`off/allow/deny`, `never/lazy/always`) переписаны инлайн в
  Debug-handler вместо переиспользования storage-констант.
- Инвариант (валидный порт/mode/protocol) переизобретается на каждом входе.
- **NB:** `native_prefs.dart` уже эталон (единый write-through) — его НЕ трогаем,
  фасад для него уже фактически есть.

## Решение — тонкий VpnSettingsFacade (strangler, делегирующий)

Ввести фасад, который сперва просто **делегирует** в существующие статики (0
изменений поведения), держит валидацию/enum-константы в одном месте, и на него
по одному переводятся: сперва Debug API (мал, централизован — идеальный первый
клиент), затем экраны оппортунистически. Эталон формы — `ChannelMutations` /
`SubscriptionController`.

Зависит от §292-D (валидация порта на модели) — фасад её переиспользует, не
дублирует.

## Файлы

- новый `lib/services/vpn_settings_facade.dart` (делегирующий)
- `lib/services/debug/handlers/settings.dart` (первый клиент; enum-константы из
  storage, не инлайн)
- экраны vpn_mode/tun_apps/app_settings — по одному, оппортунистически

## Приёмка

- Валидация порт/mode/protocol — один источник (модель+фасад), не переизобретена.
- Debug-handler не содержит инлайн enum-литералов.
- Каждый переведённый экран не зовёт `SettingsStorage` напрямую для vpn-mode.

## Docs to update

- `docs/ARCHITECTURE.md` — VpnSettingsFacade в карте слоёв.
- `CHANGELOG.md` — если меняется user-visible валидация.
