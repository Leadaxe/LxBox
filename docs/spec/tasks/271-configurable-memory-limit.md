# §271 — настраиваемый memory limit ядра (VPN Settings → System → Optimization)

| Поле | Значение |
|---|---|
| Статус | РЕЛИЗ v2.15.3 (2026-07-15); smoke на CPH2411 — установка + UI |
| Связанные спеки | §173 (oomMemoryLimit в SetupOptions), §189 (native_prefs), §215 (idle-suspend), §052 (System tab) |
| Ядро | v1.14.0-lx.3 (менять не требуется) |

## Проблема

Жалоба «греется процессор на последних версиях» подтверждена pprof CPU-захватом
(§207, `cpu-2026-07-13T04-25-50.pb`): 304% CPU за 10.19s, из них ~88% — Go GC
(`gcDrain` 68.9% cum, `scanobject` 51.8%), аллокационный трафик всего ~8.7% —
т.е. не alloc-шторм, а непрерывные GC-циклы по большой живой куче. Причина:
§173 захардкодил `oomMemoryLimit = 200MB` → ядро ставит
`debug.SetMemoryLimit(150MiB)` (setup.go:89, limit×3/4). У конфигов с
WG/AWG/WARP живая куча упирается в потолок (Android-пулы wireguard-go:
`MaxSegmentSize=65535` × `PreallocatedBuffersPerPool=4096`, WaitPool буферы не
освобождает) → GOMEMLIMIT death spiral. Регрессия ровно с v2.10.0 — первый тег
с коммитом 2935f9d (§173); до него лимита не было вовсе.

## Решение

Лимит становится настройкой: **VPN Settings → System → Optimization →
"Memory limit"** (dropdown, рядом с "Suspend idle tunnels").

| Wire-значение | UI label | oomMemoryLimit |
|---|---|---|
| `auto` (дефолт) | Auto (recommended) | по RAM устройства, см. лесенку |
| `off` | Off | `0` → `SetMemoryLimit(MaxInt64)` (setup.go:90-91) |
| `200` | 200 MB | 200 MiB (прежний хардкод) |
| `384` | 384 MB | 384 MiB |
| `512` | 512 MB | 512 MiB |
| `768` | 768 MB | 768 MiB |

**Auto-лесенка** (`ActivityManager.MemoryInfo.totalMem`; totalMem у «4GB»-класса
≈3.7GiB, у «8GB» ≈7.5GiB — пороги ниже маркетинговых):

| totalMem | лимит |
|---|---|
| < 3.5 GiB | 200 MB (= прежнее поведение на слабых устройствах) |
| 3.5–7 GiB | 384 MB |
| ≥ 7 GiB | 512 MB |

Дефолт `auto` сознательно меняет поведение большинства устройств (384/512
вместо 200) — это и есть фикс перегрева.

## Семантика ядра (v1.14.0-lx.3, проверено по исходникам)

- `oomKillerEnabled=true` остаётся ВСЕГДА: гейтит и `SetMemoryLimit`, и
  автоинъекцию сервиса `oom-killer` в каждый box-инстанс
  (daemon/instance.go:94-107).
- `limit=0` на Android = `SetMemoryLimit(MaxInt64)` (setup.go:90-91), а
  oom-killer уходит в режим `policyModeAvailable` (policy.go:42-44) — следит за
  **системной** свободной памятью (cgroup//proc/meminfo, маржа 32–128 MiB).
  Т.е. «Off» снимает GC-потолок, но анти-LMK-страховка (ResetNetwork +
  FreeOSMemory при давлении) сохраняется.
- `Libbox.reloadSetupOptions(SetupOptions)` присутствует в AAR (javap
  подтверждён), читает ТОЛЬКО три OOM-поля (setup.go:80-96) и сразу применяет
  `debug.SetMemoryLimit` → настройка действует **мгновенно**, без
  переподключения VPN.
- **Известное ограничение**: порог RSS-мониторинга oom-killer-сервиса
  защёлкивается в `daemon.StartedService` при создании CommandServer
  (command_server.go:69-71); `ReloadSetupOptions` защёлку НЕ обновляет, а
  `SetOOMKillerOptions` (started_service.go:113) не экспортирован в
  libbox-биндинг. Мгновенно меняется главный рычаг (Go soft-limit → GC);
  порог RSS-мониторинга подтянется при **следующем подключении VPN** —
  BoxService создаёт новый CommandServer на каждый старт сервиса
  (BoxService.kt `startCommandServer`), и `NewCommandServer` перечитывает
  обновлённые `sOOM*`-глобалы. Рестарт процесса НЕ требуется.

## Модель данных

Седьмой ключ §189 `native_prefs` (write-through: JSON `lxbox_settings.json`
секция `native_prefs` = истина → зеркало в Android SharedPreferences
`boxvpn_boot`):

- Dart: `NativePrefsKeys.memoryLimit = 'memory_limit'` (String, НЕ в `bools`),
  дефолт `'auto'`; нормализация неизвестных значений → `'auto'` через
  `MemoryLimitSetting.normalize` (models/memory_limit_setting.dart, по образцу
  `BackgroundMode.fromNative`).
- Kotlin: prefs-ключ `memory_limit` в `boxvpn_boot` (BootReceiver companion,
  default `"auto"`).
- Бэкап: автоматически в блоке `vpn_settings` (§189: `_exportToBackupMap` /
  `_applyFromBackupMap` итерируют `NativePrefsKeys.all`) — §221-симметрия
  бесплатно. Секция `native_prefs` не входит в `allowedTopLevelKeys` — так и
  должно быть (restore идёт через write-through, bootstrap пересеет).

## Поток применения

1. UI dropdown → `SettingsStorage.setNativeMemoryLimit(v)` → JSON + method
   channel `setMemoryLimit`.
2. Kotlin `setMemoryLimit`: `BootReceiver.setMemoryLimit(prefs)` + асинхронно
   (`libboxReady.await()`) `Libbox.reloadSetupOptions(SetupOptions{
   oomKillerEnabled=true, oomMemoryLimit=resolveMemoryLimitBytes(...)})` —
   лимит применён к работающему ядру немедленно.
3. Старт процесса: `BoxApplication.initializeLibbox` читает prefs через
   `resolveMemoryLimitBytes(context)` вместо хардкода 200MB.
4. Снэкбар в UI: «Applied.» (без «next connect» — применение мгновенное).

`markConfigDirty` НЕ поднимается — значение не входит в sing-box JSON-конфиг.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/models/memory_limit_setting.dart` | НОВЫЙ: wire-значения, normalize |
| `app/test/models/memory_limit_setting_test.dart` | НОВЫЙ: normalize-юниты |
| `app/test/services/native_prefs_memory_limit_test.dart` | НОВЫЙ: write-through/backup |
| `app/test/vpn/box_vpn_client_test.dart` | contract-тесты get/setMemoryLimit |
| `app/lib/vpn/box_vpn_client/method_names.dart` | +`getMemoryLimit`/`setMemoryLimit` |
| `app/lib/vpn/box_vpn_client.dart` | обёртки двух методов |
| `app/lib/services/settings_storage/native_prefs.dart` | ключ `memory_limit`: default, getter/setter, ветки bootstrap/sync/backup-apply |
| `app/lib/services/settings_storage.dart` | фасад `getNativeMemoryLimit`/`setNativeMemoryLimit` |
| `app/lib/screens/settings_screen.dart` | dropdown в System tab между idle-suspend и Tunnel sleep mode |
| `android .../vpn/BootReceiver.kt` | `KEY_MEMORY_LIMIT` + set/get |
| `android .../vpn/BoxApplication.kt` | `resolveMemoryLimitBytes` (companion) + использование в `initializeLibbox` |
| `android .../vpn/VpnPlugin.kt` | методы `getMemoryLimit`/`setMemoryLimit` + live-apply через `reloadSetupOptions` |
| `docs/spec/features/128 idle-suspend/spec.md` | UX-раздел: секция Optimization — три рычага |
| `docs/spec/tasks/052-vpn-settings-system-service-tabs.md` | состав System tab |
| `docs/spec/tasks/173-oom-killer-setup-options.md` | пометка: лимит стал настраиваемым |
| `docs/STORAGE.md` | секция native_prefs: +memory_limit |

## Тесты

- `test/models/memory_limit_setting_test.dart` — normalize: валидные значения
  проходят, мусор/null → `auto`; состав wire-значений стабилен.
- `test/vpn/box_vpn_client_test.dart` — contract-тесты канала: set передаёт
  wire, get нормализует ответ native.
- `test/services/native_prefs_memory_limit_test.dart` — default `auto`,
  write-through (JSON-истина + зеркало в native), нормализация мусора с диска,
  export backup-блока содержит `memory_limit`, apply применяет/нормализует,
  старый бэкап без ключа не затирает значение. Существующий §221-инвариант
  (`backup_service_test.dart`) не трогается — native_prefs не top-level ключ.
- Kotlin-логика (`resolveMemoryLimitBytes`) юнитами не покрывается — в проекте
  нет JVM-тестов; лесенка и строгий парсер (только пресетные числа, прочее =
  `auto` — зеркало `MemoryLimitSetting.normalize`) зафиксированы здесь.

## Риски

- Auto на устройствах 3.5–7 GiB поднимает потолок RSS до 384MB — выше шанс
  встречи с LMK на замусоренных устройствах; страховка остаётся (oom-killer
  Available-watch у Off, MemoryLimit-watch у явных значений).
- Юзер, восстановивший бэкап с `512` на слабом устройстве, получит завышенный
  лимит — осознанно принято: настройка видима и легко возвращается в Auto.
