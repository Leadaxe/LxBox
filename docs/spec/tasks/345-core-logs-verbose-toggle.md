# §345 — Verbose core logs: live-тумблер, снимающий TRACE/DEBUG-фильтр

| | |
|---|---|
| Статус | В работе |
| Дата | 2026-08-02 |
| Связанные | [`043 applog per-source quotas`](../features/043%20applog%20per-source%20quotas/spec.md) (фильтр и volume-модель), §189 (native_prefs JSON-зеркало), §221 (backup-симметрия), [`031 debug api`](../features/031%20debug%20api/spec.md), [`340`](340-user-present-rebind-stale-endpoints.md) (первый заказчик: device-верификация нуджа) |

## Проблема

Ядро работает на `log.level=trace` и шлёт всё, но `BoxService.writeDebugMessage`
безусловно выбрасывает строки `TRACE|DEBUG` (`traceDebugRe`, §043 volume
reduction) — до очереди, до EventChannel, до `AppLog`. Фильтр правильный
(trace-поток на живом трафике — строка на пакет), но невыключаемый: любая
device-верификация по debug-строкам ядра невозможна в принципе. На §340 это
стоило нескольких слепых итераций — rebind-строки с триггером `nudge` пишутся
на debug-уровне и не доезжают ни до Debug-экрана, ни до `/logs/core`.

## Решение

Дефолт не меняется. Новый **суб-тумблер** «verbose» у существующей плитки
Forward sing-box logs: при включённом основном тумблере снимает
TRACE/DEBUG-фильтр **на лету**, без перезапуска VPN.

Два разных гейта — две разных цены:

| граница | механизм | применение |
|---|---|---|
| off ↔ on (существующая) | `SetupOptions.debug` в `Libbox.setup` | force-stop процесса (как сейчас, не меняем) |
| normal ↔ verbose (новая) | `@Volatile`-флаг в Kotlin, проверка на каждой строке | мгновенно |

### Хранение (§189 write-through)

Ключ `core_logs_verbose` (bool, default `false`) в секции `native_prefs`:
`NativePrefsKeys` (`bools`/`all`/defaults) + case в `_mirrorBoolToNative`,
`_nativeGetBool`, `_bootstrapFromNative`. Бэкап получает ключ автоматически
(§221: `_exportToBackupMap`/`_applyFromBackupMap` итерируют `all`;
forward-compat — старые бэкапы без ключа пропускаются штатно).

### Kotlin

- `BootReceiver`: `KEY_CORE_LOGS_VERBOSE` + `set/isCoreLogsVerbose` (persist,
  по образцу CoreLogs).
- `BoxService`: `companion @Volatile var coreLogsVerbose`; инициализация из
  prefs в `onStartCommand`; фильтр становится
  `if (!coreLogsVerbose && traceDebugRe.containsMatchIn(plain)) return`.
- `VpnPlugin`: `setCoreLogsVerbose` (persist **и** live-обновление volatile),
  `getCoreLogsVerbose`.

Back-pressure не трогаем: `LOG_QUEUE_MAX=4096` + drop-newest со счётчиком уже
защищают от потопа.

### UI

`diagnostics_tab.dart`, сразу под плиткой Forward sing-box logs —
самодостаточный StatefulWidget (сам читает/пишет `SettingsStorage`,
без пропсов родителя): `SwitchListTile` «Verbose (TRACE/DEBUG)», активен
только при включённом основном тумблере, subtitle предупреждает про объём.

### Debug API

`GET/PUT /settings/core-logs-verbose` — зеркало существующего
`core-logs-enabled`, но note в ответе честный: «applies immediately».

## Поведение и ограничения

- verbose при выключенном основном тумблере бессилен (ядро не форвардит
  вообще) — UI это отражает disabled-состоянием суб-тумблера.
- В verbose буфер core (500 строк) на живом трафике живёт секунды — режим
  «включил → воспроизвёл → снял лог → выключил», в спеке и subtitle так и
  позиционируется. Квоты не расширяем.

## Файлы

- `app/lib/services/settings_storage/native_prefs.dart` — ключ + 3 case
- `app/lib/vpn/box_vpn_client.dart`, `.../method_names.dart` — set/get
- `app/lib/screens/app_settings_screen/widgets/diagnostics_tab.dart` — суб-тумблер
- `app/lib/services/debug/handlers/settings.dart` — GET/PUT маршрут
- `app/android/.../BootReceiver.kt` — persist
- `app/android/.../BoxService.kt` — volatile + фильтр
- `app/android/.../VpnPlugin.kt` — методы канала
- `app/assets/l10n/ru/ui.json` — переводы новых строк

## Верификация

1. Юнит: storage round-trip ключа + дефолт false; backup export/apply содержит
   ключ.
2. Device: при работающем VPN включить verbose → `/logs/core` начинает отдавать
   `DEBUG`-строки БЕЗ перезапуска; выключить → поток снова только info+.
3. Целевой сценарий §340: verbose on → сон ≥3 мин без трафика → разблокировка →
   в `/logs/core` строка rebind с триггером `nudge` (закрывает device-остаток
   §340 и SPEC 041 v2).
