# §128 — Idle-suspend простаивающих WireGuard/AmneziaWG туннелей

> **СТАТУС: РЕАЛИЗОВАНО (клиентская обвязка) + DEVICE-VERIFIED.** Ядровая фича —
> sing-box-lx SPEC 020 (`route.lx_idle_suspend`), ядро rc.18. Клиент прокидывает
> порог из storage/UI в `route.lx_idle_suspend`.

## Зачем

Каждый живой WG/AWG-эндпоинт держит recv-воркеры со своими `bufsArrs`
(`make([]*[65535]byte, BatchSize)`) — на Android при `BatchSize=128` это ~8 МБ на
воркер, 2 воркера на эндпоинт. При подписке с многими WG-нодами это главный
держатель GC-нагрева и расхода RAM, даже когда трафик идёт лишь через одну ноду.

Ядро SPEC 020 умеет выборочно гасить (`device.Down()`) любой WG/AWG-эндпоинт,
который одновременно **недостижим** из активного дерева маршрутизации И
**простаивает** дольше порога. Пробуждение — лениво, на следующем дайле. Задача
клиента — дать пользователю включить фичу и задать порог.

## UX

App Settings → **General** → секция Behavior → **«Suspend idle tunnels»**.
ListTile с выбором порога (диалог, пресеты):

| Пресет | Значение `lx_idle_suspend` | Смысл |
|---|---|---|
| Off (дефолт) | `""` (поле не пишется) | Фича выключена, kill-switch |
| 30 seconds | `30s` | Тик 15 с |
| 2 minutes | `2m` | Тик 1 мин |
| 5 minutes | `5m` | Тик 2.5 мин |

Пресеты, а не сырой ввод — валидные duration-строки ядра гарантированы. Изменение
config-significant (`markConfigDirty`), применяется при следующей пересборке
конфига (reconnect). Snackbar «Applies on next connect.».

## Модель данных

| Слой | Ключ/поле | Тип | Дефолт |
|---|---|---|---|
| storage (`lxbox_settings.json`) | `route_idle_suspend` | String | `""` |
| import allowlist (§159) | `route_idle_suspend` | — | добавлен в `allowedTopLevelKeys` |
| `BuildSettings` | `idleSuspend` | String | `''` |
| выходной конфиг | `route.lx_idle_suspend` | String | опускается если пусто |

## Control flow

```
App Settings (General tab)
  → AppSettingsDialogs.pickIdleSuspend → SettingsStorage.saveIdleSuspend
      → route_idle_suspend в storage + markConfigDirty
SubscriptionController.generateConfig
  → BuildSettings(idleSuspend: getIdleSuspend())
  → buildConfig: если idleSuspend непусто → route['lx_idle_suspend'] = порог
      (omitempty: пусто = поля нет = дефолт ядра = idle-тик не запущен)
```

Валидатор билдера (`validator.dart`) не трогает неизвестные route-ключи (проверяет
только ссылки на теги/циклы), поэтому `lx_idle_suspend` проходит насквозь. Ядро
rc.18 знает поле (SPEC 020) — не роняет конфиг (в отличие от XHTTP-ловушки rc.15,
[[214-libbox-rc16-xhttp-fields]]).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| storage | `services/settings_storage/network.dart` | `_getIdleSuspend`/`_saveIdleSuspend` |
| storage | `services/settings_storage.dart` | публичные геттер/сеттер + allowlist-ключ |
| builder | `services/builder/build_config.dart` | поле `BuildSettings.idleSuspend` + инъекция в route |
| controller | `controllers/subscription_controller.dart` | `idleSuspend: getIdleSuspend()` |
| UI | `screens/app_settings_screen.dart` | state `_idleSuspend` + load + `_pickIdleSuspend` |
| UI | `screens/app_settings_screen/widgets/general_tab.dart` | ListTile + `_idleLabel` |
| UI | `screens/app_settings_screen/app_settings_dialogs.dart` | `pickIdleSuspend` (RadioGroup) |
| тесты | `test/builder/build_config_test.dart` | «30s»→route + пусто→нет поля |

## Критерии приёмки

- Builder: `idleSuspend='30s'` → `route.lx_idle_suspend == '30s'`; пусто → нет ключа. ✓
- Device (rc.18): порог попадает в конфиг, ядро грузит без падения, idle-тик усыпляет
  недостижимые WG. ✓ (см. §215 / SPEC 020 Android RESULTS)
- Off = kill-switch (0 `lx idle:` строк). ✓

## Связанные

- §215 — ядровый бамп rc.18 + device-верификация ([[215-libbox-rc18-idle-suspend]]).
- sing-box-lx SPEC 020 — ядровая реализация Down/Up + reachability.
- §124 background-mode — другой энергорычаг (глобальная пауза по экрану); idle-suspend
  ортогонален (выборочный, по достижимости).
