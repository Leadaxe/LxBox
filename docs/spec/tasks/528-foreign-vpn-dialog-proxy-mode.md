# 528 — диалог «Another VPN is active» не показывается в proxy-режиме

| Поле | Значение |
|------|----------|
| Статус | **Done** (фикс + тест), ожидает релиза |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Issue | #126 «Asks to turn off other vpn when it starts in proxy only mode» |
| Коммиты | см. ветку `task-528` |
| Связанные spec'ы | §211 (сам диалог), §192 (гейт `prepare()` по `hasTun`), §119 (vpn_mode), §189 (native_prefs — зеркало `has_tun`), §241 (кнопка «VPN settings» в диалоге), §328 (прецедент: предикат UI вынесен и покрыт unit-тестом) |

---

## Проблема

Пользователь в issue #126: в режиме **proxy** (port-only, без TUN) при нажатии
Start приложение спрашивает «Another VPN is active. Switch to L×Box?», хотя
чужой туннель наш старт не трогает.

Вопрос там бессмысленный и хуже того — вводит в заблуждение: человек читает
«переключиться?» и понимает это как «чужой VPN будет отозван», то есть либо
отменяет старт зря, либо выключает соседний VPN руками, хотя в proxy-режиме тот
продолжил бы работать.

## Причина

Системный VPN-слот забирает `VpnService.prepare()`, а не `establish()` — это
корень §192. Поэтому §192 навесил гейт по `hasTun` на **все 6 точек** вызова
`prepare()`; в proxy-режиме prepare не вызывается вовсе:

```kotlin
// app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt:1386-1394
if (!BootReceiver.hasTun(context)) {
    BoxVpnService.start(context)
    result.success(true)
    return
}
val intent = VpnService.prepare(act)
```

Признак берётся из `VpnModeConfig.hasTun`
(`app/lib/services/settings_storage/vpn_mode.dart:144`, `mode != 'proxy'`),
который зеркалится в native через `setNativeHasTun`
(`app/lib/services/vpn_settings/vpn_settings_facade.dart:37-38`).

**Диалог §211 такого гейта не получил.** `_startWithAutoRefresh` спрашивал
native безусловно:

```dart
// app/lib/screens/home_screen.dart:941-948 (до фикса)
if (await _vpn.isForeignVpnActive()) {
  if (!mounted) return;
  final ok = await showForeignVpnDialog(context);
  if (ok != true) return;
}
```

Native-детект (`VpnPlugin.kt:1360-1378`, `isForeignVpnActive`) режим тоже не
смотрит — он отвечает ровно на «есть ли сейчас чужая VPN-сеть», и это
правильно: его задача — факт, а не решение.

Это не регресс, а известный, сознательно отложенный долг. §211 в разделе «НЕ
трогаем» записал прямо:

> «§192 proxy-режим (без TUN) — там вообще не зовём prepare, чужой VPN не рвём;
> detect бессмыслен, но и не вреден… Гейт можно навесить только под `hasTun`
> если потребуется; в первой версии диалог покажем всегда».

Issue #126 — тот самый случай «если потребуется»: бессмысленный вопрос оказался
всё-таки вреден, потому что человек принимает его за предупреждение.

## Решение

Гейт по режиму — в одном месте, **тем же признаком `hasTun`**, что и гейт
`prepare()`. Оба гейта теперь судят по одному полю `VpnModeConfig.hasTun`:
Dart-сторона решает, спрашивать ли, native — звать ли prepare, и разойтись они
могут только вместе со сменой режима. Новых флагов режима не введено.

Сам гейт вынесен из `home_screen.dart` в `home/home_dialogs.dart` двумя
сущностями:

1. **Предикат** — `askBeforeOverridingForeignVpn({required bool hasTun})`.
   Чистая функция, принимает `hasTun` параметром именно затем, чтобы её можно
   было прогнать unit-тестом (прецедент — §328 `showAddServerGuide`).
2. **Гейт** — `confirmForeignVpnOverride({context, loadVpnMode,
   isForeignVpnActive, showDialogFn})`. Возвращает `true`, когда старт можно
   продолжать.

Порядок обращений в гейте существенный и он же — предмет задачи:

```
режим (локальное чтение JSON)  →  если !hasTun: true, выход
                               →  если hasTun: native isForeignVpnActive()
                               →  если чужой есть: диалог
```

В proxy-режиме MethodChannel **не дёргается вовсе** — не «дёргается, а ответ
игнорируется». Это сильнее, чем нужно для issue, но дешевле: лишний round-trip
в native на каждый Start без всякой пользы.

`home_screen.dart` после фикса зовёт один гейт и получает bool.

### Почему native не тронут

Гейта на Dart-стороне достаточно, и native менять не нужно по трём причинам:

1. **Диалог существует только на Dart-стороне** — native ничего не показывает.
   Его `isForeignVpnActive()` — чистый детект факта, у него нет «решения», из
   которого можно было бы убрать proxy-случай. Вернуть оттуда `false` в
   proxy-режиме означало бы соврать в имени метода.
2. **Диалог показывается ровно с одной точки входа** (`_startWithAutoRefresh`,
   ручной Start из UI) — в отличие от `prepare()`, у которого 6 входов и потому
   §192 гейтил именно native. Здесь дыр «в tile/automation» физически нет:
   фоновые точки диалога не показывают и `isForeignVpnActive` не зовут (это
   зафиксировано ещё §211).
3. **Единственный признак остаётся один.** Продублировав гейт в native, мы
   получили бы третье место, где написано «в proxy иначе», — ровно та развилка,
   из-за которой §192 и §211 разошлись.

### Рассмотрено и отклонено

- **Гейтить внутри `showForeignVpnDialog`** — диалог остался бы «умным» (лез бы
  в storage за режимом), а лишний native-опрос всё равно бы происходил.
- **Гейтить в `BoxVpnClient.isForeignVpnActive`** — сломало бы честность
  обёртки: Debug API и любой будущий вызывающий получали бы `false` там, где
  чужой VPN реально есть.

## Что изменено

| Файл | Изменение |
|---|---|
| `app/lib/screens/home/home_dialogs.dart` | `askBeforeOverridingForeignVpn` + `confirmForeignVpnOverride` |
| `app/lib/screens/home_screen.dart` | `_startWithAutoRefresh` зовёт гейт вместо прямого `isForeignVpnActive` + `showForeignVpnDialog` |
| `app/test/screens/home/foreign_vpn_proxy_mode_gate_test.dart` | новый, 7 проверок |

## Тесты

`app/test/screens/home/foreign_vpn_proxy_mode_gate_test.dart` — 7 проверок,
все зелёные:

- предикат: `proxy` → `false`; `vpn` и `vpn_proxy` → `true`;
- **главный кейс** `proxy` + активен чужой VPN: `foreignChecks == 0`,
  `dialogs == 0`, старт разрешён (фиксирует именно «native не опрашивается», а
  не только «диалога нет»);
- `vpn` + чужой активен → диалог показан, Switch пускает старт;
- `vpn` + чужой активен → Cancel отменяет старт;
- `vpn_proxy` + чужой активен → диалог показан (TUN есть — поведение как было);
- `vpn` + чужого нет → опрос был, диалога нет.

Контрольный прогон (тест не вакуумный): предикат временно заменён на
`=> true` — падают ровно две проверки, обе proxy-шные, остальные пять зелёные.

`flutter analyze` по трём затронутым файлам — `No issues found!`
Полный `flutter test` локально не гоняли (остальное проверяет CI).

## Что НЕ меняется

- **Native** — ни `VpnPlugin.kt`, ни гейты §192, ни `isForeignVpnActive()`
  (обоснование выше).
- **Поведение в `vpn` и `vpn_proxy`** — диалог, его текст, три кнопки (§211,
  §241) и отмена старта по Cancel в точности как были.
- **Сам детект чужого VPN** — `BoxVpnClient.isForeignVpnActive` и его
  Dart-тесты (`app/test/vpn/box_vpn_client_test.dart:159-178`) не тронуты.
- **Фоновые точки старта** — tile / shortcut / automation-intent / Debug API /
  boot: диалога не показывали и не показывают.
- **UI-строки** — ни одной новой, l10n-корпус не затронут.
- **Форма хранилища и модель `VpnModeConfig`** — новых флагов нет, `hasTun`
  переиспользован как есть.

## Риски и edge cases

- **`vpn_proxy`** попадает в «спрашиваем»: TUN там есть, `prepare()` зовётся,
  чужой VPN реально будет отозван — вопрос по-прежнему честный.
- **Смена режима между Start'ами** — гейт читает режим на каждый Start
  (`SettingsStorage.getVpnMode`, кэш storage), а не разово при инициализации
  экрана, так что переключение proxy↔vpn в настройках действует сразу.
- **Старый юзер без ключа `vpn_mode`** — `_getVpnMode` отдаёт
  `VpnModeConfig.defaults()` (`mode = vpn`, `hasTun = true`) → диалог как
  раньше. Совпадает с native-дефолтом `KEY_HAS_TUN = true` (§192).
- **Гонка `mounted`** — проверка `context.mounted` осталась ровно там же, между
  await'ом детекта и показом диалога; в `home_screen.dart` после гейта добавлен
  свой `if (!mounted) return`.
