# §192 — Proxy-режим рвёт чужой VpnService через VpnService.prepare()

**Тип:** bug (lifecycle / VPN-слот)
**Статус:** ✅ DEVICE-VERIFIED (dev, vc=2880). Proxy-режим больше НЕ убивает чужой
активный VPN. Корень (prepare, не establish) подтверждён живьём.
**Приоритет:** Medium (ломает соседний VPN при port-only режиме)
**Связано:** §119 (vpn_mode), §188 (TUN-тумблеры), §052 (keep_on_exit)

## Симптом (юзер)

«Если отключить TUN-приёмник, оставив только портовый (SOCKS), то при запуске
sing-box может прерываться активный VpnService от другого приложения.»

В режиме `proxy` (§119 — только локальный mixed/SOCKS-inbound, без TUN, без
establish) запуск нашего сервиса всё равно роняет чужой активный VPN.

## Корень (подтверждён код-инспекцией)

**`VpnService.prepare()` забирает системный VPN-слот — НЕ `establish()`.** Android
делает наше приложение «prepared VPN package» уже в момент `prepare()`-консента
(когда консент есть, `prepare()` возвращает null И немедленно отзывает —
`onRevoke` — у любого другого приложения с активным VpnService). Это происходит
независимо от того, дойдём ли мы до `establish()`.

**`prepare()` вызывается БЕЗУСЛОВНО на всех точках входа, без учёта `vpn_mode`:**
- `VpnPlugin.kt:896` — `startVpn()` (главный UI-путь)
- `VpnPlugin.kt:268` — `startVpnHeadless`
- `MainActivity.kt:226` — `startVpnWithConsent()` (QS-tile/shortcut)
- `LxBoxIntentReceiver.kt:135`, `LxBoxTileService.kt:95`,
  `automation/LocaleSettingReceiver.kt:63` — остальные входы

`establish()` встречается РОВНО ОДИН раз — `BoxVpnService.kt:341` внутри
`openTun()`, который ядро зовёт только при наличии TUN-inbound. В proxy-режиме
establish НЕ происходит — но `prepare()` уже убил чужой VPN на старте.

**Гипотеза (а) подтверждена** (с уточнением: слот забирает `prepare`, не
`establish`). Гипотеза (б) — нет: запуск/биндинг foreground VpnService-класса сам
по себе чужой VPN не роняет. `hasTun`/`VpnMode` существует только в Dart (UI-гейт
+ билдер) — НИ ОДИН native-путь запуска не сверяется с `vpn_mode` перед `prepare()`.

## Путь запуска в proxy-режиме

1. `HomeController.start()` → `_vpn.startVPN()` (`home_controller.dart:438`) —
   режим НЕ проверяется.
2. `VpnPlugin.startVpn()` → **`VpnService.prepare(act)` (`:896`)** ← чужой VPN
   получает `onRevoke` здесь (консент есть → prepare==null → мы prepared).
3. `BoxVpnService.start()` → `startForegroundService` (`:117`).
4. `BoxService.onStartCommand` → `startSingbox()`.
5. Ядро парсит port-only конфиг → `openTun()` НЕ вызывается, establish нет.

Чужой VPN убит на шаге 2, хотя tun так и не поднят.

## keep-alive в proxy-режиме

`onTaskRemoved` (`BoxService.kt:219`): `if (!isKeepOnExit) doStop()`.
- `keep_on_exit=false`: свайп → `doStop()` → закрывает локальный порт. Осмысленно.
- `keep_on_exit=true`: сервис живёт, локальный SOCKS-порт слушает после свайпа +
  приложение остаётся prepared (держит слот чужого VPN отнятым). Технически
  определено, семантически сомнительно («keep VPN» для режима без VPN).

`onRevoke` (`:226`) в proxy: `closeFileDescriptor()` = no-op (fd всегда null без
establish), безвреден. Но onRevoke в proxy-режиме — симптом той же проблемы (мы
держим слот зря).

## Направления фикса (НЕ реализовано — на согласование)

**Вариант 1 — гейтить `prepare()` за `hasTun` (минимальный).** Прокинуть
`vpn_mode`/`hasTun` в native; в proxy-режиме НЕ звать `prepare()`, стартовать
сервис напрямую.
- Плюс: малое изменение, бьёт по корню.
- Минус: native не знает `vpn_mode` — прокинуть через prefs-зеркало (паттерн
  `allow_bypass`/`keep_on_exit` уже есть; §189 native_prefs — естественное место).
  Все 6 точек входа править синхронно, иначе tile/automation останутся дырявыми.

**Вариант 2 — отдельный не-VPN `Service` для proxy (чистый, дорогой).** Второй
foreground-сервис без `VpnService`-наследования для port-only.
- Плюс: архитектурно честно — нет prepare/prepared, чужой VPN не трогается;
  keep-alive обретает ясную семантику.
- Минус: дублирование lifecycle/CommandServer-обвязки; `vpn_proxy` всё равно
  требует VpnService-пути → развилка «какой сервис» на 6 точках входа. Большой
  объём.

**Вариант 3 — нормализовать keep-alive под proxy (дополнение).** Решить продуктово
что `keep_on_exit` значит в port-only: игнорировать в proxy (`onTaskRemoved` всегда
`doStop` когда `!hasTun`) ИЛИ явно «держать локальный порт».

**Рекомендация:** Вариант 1 (гейт prepare за hasTun, флаг через §189-prefs-зеркало)
+ Вариант 3. Вариант 2 — если разводить VPN/proxy архитектурно (отдельная крупная
таска).

## Замечания

- Native не знает `vpn_mode` — нет prefs-ключа/аргумента. Любой фикс В1 требует
  сначала прокинуть сигнал (§189 native_prefs — готовая инфраструктура: добавить
  `vpn_mode` или `has_tun` в зеркало).
- 6 точек запуска зовут `prepare()` независимо — фикс в одном `startVpn()`
  оставит дыры в tile/automation/intent. Чинить все разом.

## ✅ Реализованный фикс (Вариант 1)

Прокинут `has_tun` (bool, производное от vpn_mode) в native через prefs +
гейт `prepare()` на ВСЕХ точках входа.

**Native:**
- `BootReceiver` — ключ `KEY_HAS_TUN` (`boxvpn_boot.has_tun`), `setHasTun`/
  `hasTun`. **Default `true`** — безопасно: нет ключа (старый юзер/до sync) →
  ведём себя как раньше (prepare вызывается, vpn-режим не ломается). proxy-фикс
  активен только при явном `has_tun=false`.
- Гейт `if (!BootReceiver.hasTun(ctx))` перед `VpnService.prepare()` в 6 точках:
  `VpnPlugin.startVpn`/`startVpnHeadless`, `MainActivity.startVpnWithConsent`,
  `LxBoxIntentReceiver.handleToggle`, `LxBoxTileService.connectOrPromptConsent`,
  `LocaleSettingReceiver.handleToggle`. В proxy → `BoxVpnService.start()` напрямую,
  prepare не зовётся → чужой VPN не отзывается.
- `VpnPlugin` handler `setHasTun` (getHasTun не нужен — native читает напрямую).

**Dart:**
- `BoxVpnClient.setHasTun` + method-name.
- `SettingsStorage.setNativeHasTun` (через native_prefs, НЕ часть backup-блока —
  has_tun вычисляемое из vpn_mode, не настройка).
- Зеркалится при смене режима (`vpn_mode_tab._setMode` → `setNativeHasTun`) +
  на старте (`bootstrapAndSyncNativePrefs` → `_syncHasTunToNative` читает
  vpn_mode → пишет has_tun). Само-синхронизируется.

**Файлы:** BootReceiver.kt, VpnPlugin.kt, MainActivity.kt, LxBoxIntentReceiver.kt,
LxBoxTileService.kt, LocaleSettingReceiver.kt (native); box_vpn_client.dart +
method_names.dart, native_prefs.dart, settings_storage.dart, vpn_mode_tab.dart (Dart).

## Device-проверка (перед коммитом релиза)

1. Включить чужой VPN (любой сторонний) → стартовать наш в **proxy-режиме** →
   чужой VPN должен ВЫЖИТЬ (не onRevoke).
2. **vpn / vpn_proxy режим** — prepare как раньше, чужой VPN отзывается штатно
   (наш TUN забирает слот — это норма).
3. Все точки входа в proxy: QS-tile, automation-intent, headless (Debug API),
   обычный старт — ни одна не должна звать prepare.
4. Старый юзер без has_tun-ключа в vpn-режиме — prepare работает (default true).
