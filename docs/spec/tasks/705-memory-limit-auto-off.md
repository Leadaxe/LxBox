# 705 — Memory limit: Auto = без порога; порог считается по памяти всего процесса

| Поле | Значение |
|------|----------|
| Статус | Done (код; на устройстве не проверено) |
| Дата начала | 2026-11-01 |
| Источник | скрины пользователя Cultsonfire (Telegram, 01.11.2026): Stats → Memory 461.8 MB при Memory limit 200 MB, «такая загрузка не должно быть»; решение владельца в чате |
| Связанные | §271 (настраиваемый лимит, Auto-лесенка — снята здесь), §173 (oomMemoryLimit в SetupOptions), §242/§507 (память на Stats = RSS процесса), §122F §2.1 (однопроцессная модель), ядро: [sing-box-lx#62](https://github.com/Leadaxe/sing-box-lx/issues/62) — лимит по Go-хипу + хип в `Status` |

## Проблема

Пользователь видит «LxBox 461.8 MB» на карточке Stats при выбранном
Memory limit 200 MB и делает вывод, что лимит не работает. Подсказка
настройки говорит «Caps the VPN core's memory», а руководство — «задаёт
потолок памяти ядра». Пользователь прав: ни потолком, ни «памятью ядра»
это не является.

## Диагностика (по коду ядра `sing-box-lx`, тег lx.28)

1. Лимит уходит в ядро как `MemoryLimitOverride` (`daemon/instance.go:113`),
   `policy.go:49` выбирает `policyModeMemoryLimit`.
2. В этом режиме oom-killer сравнивает лимит с `memory.Total()`
   (`service/oomkiller/timer.go`, `readMemorySample`) — это RSS из
   `/proc/self/statm` (`sing/common/memory/memory_linux.go`; файлы `_linux`
   собираются и под `GOOS=android`). Пороги: trigger = лимит − 5 MiB,
   armed = лимит − 10 MiB (`computeLimitThresholds`, `defaultSafetyMargin`).
3. Ядро живёт в одном процессе с Flutter (`BoxVpnService` без
   `android:process`, §122F §2.1). В RSS входят Code ≈140 MB (`libbox.so`
   arm64 = 83 MB, libflutter, libapp, oat), Graphics ≈40 MB, Dalvik ≈12 MB,
   куча Dart. Процесс с открытым экраном в 200 MB не помещается пустым.
4. Что происходит при 200 MB у этого пользователя: первый опрос через 100 мс
   после старта → 461 > 195 → `ResetNetwork` + `FreeOSMemory` + OOM-отчёт.
   Соединений в этот момент нет, потерь нет. Дальше гистерезис
   (`nextPressureState`): из triggered выход только ниже 190 MB, которого не
   будет → ядро навсегда в triggered, опрос `/proc/self/statm` каждые
   100 мс (`defaultMinInterval`). Rate-trigger не добавляет сбросов:
   он работает только при `usage < limit`.
5. Мягкий потолок GC = `limit × 4/5` (`experimental/libbox/setup.go:106`),
   не ¾, как писали комментарии в `BoxApplication.kt` и спека §271. При
   200 MB это 160 MiB на Go-хип; живой хип с WG-пулами WARP-группы
   (§271, §523: порядка 100 MB одни пулы) упирается в него → GC греет
   телефон. Это и есть симптом, от которого §271 сделал настройку.
6. Число чуть выше рабочего RSS (например 600 при 461) хуже, чем 200:
   порог пробивается уже в работе, `ResetNetwork` рвёт все соединения,
   после `FreeOSMemory` RSS падает ниже armed, состояние возвращается в
   normal, и цикл повторяется. При 200 сброс один и на старте.
7. Любой лимит > 0 **выключает** слежение за свободной памятью системы:
   `readMemorySample` читает `memory.Available()` только в
   `policyModeAvailable`/`policyModeNetworkExtension`. Нас убивает LMK при
   нехватке системной памяти, а не число RSS — защита от неё есть только
   при лимите 0.
8. Правильного числа нет: RSS зависит от открытого экрана, ABI (32-битный
   `libbox.so` на 8 MB меньше), числа поднятых туннелей.
9. **Профиль пользователя** (`allocs-2026-11-01T21-27-53.pb`, снят после
   §705, тот же конфиг, VPN поднят): живой Go-хип **42 MB** при RSS 461 MB.
   WG-пулы (`PopulatePools.func3`) 16 MB живых из 108 MB выделенных за
   сессию — лишние туннели усыплены; `srs.readIPSet` 1.3 MB, буферы sing
   6.5 MB; всего выделено за сессию 616 MB — аллокационного шторма нет.
   Значит ядро занимает ~10% процесса, остальное — Flutter/Dart/Android и
   код; оценка «хип ~190 MB» из обсуждения была неверной. GC-потолок
   160 MiB у этого пользователя не достигается, и цена 200 MB здесь — один
   сброс сети на старте + опрос `statm` 10 раз/с. Вывод п. 3–7 не меняется:
   порог по RSS всё равно пробит с первой секунды.
10. **Почему Settings → OOM reports пуст** при пробитом пороге: черновик
    отчёта живёт в `oom_draft/` и при штатном `Recorder.Close()` (стоп VPN)
    **удаляется** (`recorder.go:206`); в `oom_reports/` он попадает только
    через `PromoteDraft` при следующем старте, то есть лишь если прошлая
    сессия умерла, не дойдя до `Close`. У пользователя крашей не было —
    отчётов и не будет. Единственный след порога — строка
    `memory threshold reached, usage: 4xx MB … resetting network` в логе
    ядра в первую секунду подключения.

## Решение (владелец, 01.11.2026)

- **`auto` на Android = `0`.** Ядро снимает GC-потолок
  (`SetMemoryLimit(MaxInt64)`, `setup.go:108`), oom-killer в
  Available-режиме: читает `MemAvailable` из `/proc/meminfo` и сбрасывает
  сеть, когда системе остаётся меньше `max(32 MiB, min(RSS/4, 128 MiB))`
  (`availableThresholds`). Лесенка 200/384/512 по RAM устройства снята.
- **`off` сливается с `auto`:** оба давали бы `0`, два одинаковых пункта в
  списке не нужны. Wire-значение `off` остаётся терпимым на чтении
  (бэкапы, prefs старых версий) и нормализуется в `auto`.
- Пресеты 200/384/512/768 остаются — по явному выбору, для тех, кто
  понимает, что порог считается по всему процессу.
- Подсказка настройки и руководство переписаны: порог памяти всего
  процесса приложения; выше него ядро сбрасывает соединения и освобождает
  память, вблизи него GC греет телефон; Auto порога не ставит, ядро следит
  за свободной памятью системы.
- Карточку Stats и шторку Memory не трогали: они показывают RSS процесса и
  говорят об этом в заголовке шторки; сравнения с лимитом в них нет и не
  появится, пока ядро не отдаёт Go-хип отдельно.

### Отвергнуто

- Дефолт 600 MB — п. 6, 7.
- Сравнивать с памятью ядра в приложении — ядро отдаёт в `Status` только
  `memory.Total()` = RSS; `memory.Inuse()` (Go-хип по `runtime.MemStats`)
  есть в `sing`, но не экспортирован. Это правильный путь, но с бампом
  ядра: в форке сравнивать лимит с `Inuse()` и отдать его в `Status`,
  тогда «Memory limit 200 MB» значит «ядро: GC-цель 160 MiB, сброс при
  195 MiB хипа», а в Stats появляется «Core memory: X / 200 MB». Заведено
  [sing-box-lx#62](https://github.com/Leadaxe/sing-box-lx/issues/62);
  **контракт с ядром согласован 01.11.2026** (комментарий в issue):
  `Status.MemoryRuntime` (proto 10) = `runtime/metrics` total − released,
  `Memory` остаётся RSS; флаг `SetupOptions.OomMemoryLimitHeap` (дефолт
  false, мы ставим true) + lx-поле в `OOMKillerServiceOptions`; в
  heap-режиме Available-watch остаётся; пороги −5/−10 MiB и GC 4/5 не
  меняются; latch через `ReloadSetupOptions` как сейчас; тег lx.29 только с
  этим (javap +1 геттер) — состав и срок за владельцем. **Ядро сделано:
  SPEC 148, коммит sing-box-lx `0f94afdcc` (01.11.2026), issue #62 закрыт,
  тега нет.** Сверено по коммиту: `memoryRuntime = 10` в proto,
  `StatusMessage.MemoryRuntime int64`, `SetupOptions.OomMemoryLimitHeap`,
  режим `runtime_limit` (`service/oomkiller/runtime_limit_lx.go`).
  Уточнения ядра: нулевое `memory.Available()` в heap-режиме = неизвестно
  (условие по available не применяется; на Android из `/proc/meminfo` нуля
  не бывает); ключа конфига нет, режим только через SetupOptions. Наша
  часть после тега: пин, `OomMemoryLimitHeap = true`, строка «Core
  runtime: X / limit» в шторке Memory. Поправка ядра к нашему тезису: soft limit 160 MiB у
  этого пользователя не связывающий (хип 42 MB); нагрев от GC, если есть,
  — оборот аллокаций (пулы 108/16 MB, recvMsg 43 MB), не лимит.
  Rate-trigger на Android не работает (baseline только в
  `timer_darwin.go`).
- Сервис в отдельном процессе `:bg` — RSS процесса сервиса ≈ ядро, UI
  можно выгрузить; но рвёт §122F (EventChannel-push), прямые `Libbox.*`
  из `VpnPlugin`, синхронный fd §276, Debug API в UI-процессе, prefs из
  двух процессов. Отдельная фича, не задача.

## Изменения

| Файл | Что |
|---|---|
| `app/android/.../BoxApplication.kt` | `resolveMemoryLimitBytes`: пресетное число → MiB, всё прочее → `0`; лесенка по `totalMem` удалена; комментарии про семантику ядра исправлены (4/5, RSS процесса) |
| `app/android/.../BootReceiver.kt` | комментарий к `KEY_MEMORY_LIMIT` |
| `app/lib/models/memory_limit_setting.dart` | `values` без `off`; `normalize('off')` → `auto` |
| `app/lib/screens/settings_screen.dart` | подсказка; пункт Off снят |
| `app/assets/l10n/{ru,zh}/ui.json` | новая подсказка |
| `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md` | раздел Memory limit |
| `docs/STORAGE.md` | `memory_limit`: `off` — legacy, читается как `auto` |
| `docs/spec/tasks/271-configurable-memory-limit.md` | пометка о снятии лесенки |
| `CHANGELOG.md` | Unreleased → Changed |

Wire-протокол §189 не меняется: в prefs по-прежнему `auto` | число;
`off` принимается на чтении. Debug API/бэкап совместимы.

## Часть 2 — лимит по памяти ядра (ядро v1.14.4-lx.29, SPEC 148)

Владелец 01.11.2026 (передано через сессию ядра): тег lx.29 режется только
с SPEC 148, «как выйдет ядро — можно внедрять». Контракт в коде ядра
зафиксирован (`0f94afdcc`), имена не изменятся до тега.

### Что даёт ядро

- `StatusMessage.MemoryRuntime` (int64, байты; Java `getMemoryRuntime()`):
  память Go-рантайма = `runtime/metrics` `/memory/classes/total:bytes −
  /memory/classes/heap/released:bytes` — ровно то, чем управляет
  `SetMemoryLimit`. `Memory` по-прежнему RSS процесса.
- `SetupOptions.OomMemoryLimitHeap` (bool, дефолт false): при true порог
  oom-killer сравнивается с `MemoryRuntime`, а не с RSS; слежение за
  `MemAvailable` при этом остаётся (нулевое `Available` = неизвестно).
  Пороги −5/−10 MiB и GC-потолок 4/5 без изменений.

### Изменения в приложении

| Файл | Что |
|---|---|
| `BoxApplication.kt` (onCreate, `SetupOptions`) и `VpnPlugin.kt` (`setMemoryLimit` → `reloadSetupOptions`) | `oomMemoryLimitHeap = true` рядом с `oomKillerEnabled`; комментарий: порог по памяти рантайма ядра (SPEC 148), не по RSS |
| `BoxCommandClient.kt` (`writeStatus`, snap) | `snap["memoryRuntime"] = m.getMemoryRuntime()` |
| `app/lib/vpn/cc_channel.dart` (статус, ~1020) | поле `memoryRuntime: _int(m['memoryRuntime'])` (0, если ключа нет — старое ядро) |
| `overview_tab.dart` | карточка «LxBox» остаётся RSS процесса (решение §242); в `showMemoryDetailSheet` передаётся `coreRuntime` |
| `memory_detail_sheet.dart` | в группе Process после `RSS` строка **`Core memory`** = `formatBytes(coreRuntime)` (не «Core runtime»: так уже называется группа горутин и соединений в той же шторке); при пресетном лимите (из `SettingsStorage.getNativeMemoryLimit()`, читается в `initState` рядом с `getMemoryInfo`) — `42.1 MB / 200 MB`; при `auto` — без дроби. Строка скрыта при `coreRuntime == 0`. Подпись строки ниже, стилем `bodySmall`/`onSurfaceVariant`, как подпись у Native heap: «Memory of the VPN core itself (Go runtime); the limit from VPN Settings applies to this figure. RSS is the whole app process.» |
| `settings_screen.dart` подсказка | переписать: порог по памяти самого ядра VPN (его Go-рантайма), не всего процесса; выше — сброс соединений и освобождение памяти, вблизи — GC греет телефон; Auto порога не ставит; ядро при любом значении следит и за свободной памятью системы; applies immediately. Текущую цифру смотреть в Statistics → Memory → Core memory |
| `app/assets/l10n/{ru,zh}/ui.json` | новая подсказка, «Core memory», подпись строки |
| `docs/USER_GUIDE.md`, `.ru.md` | раздел Memory limit: порог по памяти ядра с lx.29; где смотреть; Auto по-прежнему без порога |
| `docs/STORAGE.md` | комментарий `memory_limit`: threshold on the core's runtime memory (core lx.29+) |
| `docs/spec/features/012-LIVE_STATE/FUNCTIONS/traffic-statistics.md` | пункт про «Memory = весь процесс»: добавить, что Core runtime в шторке — память ядра |
| `CHANGELOG.md` Unreleased | дополнить запись 705: with core lx.29 the limit is compared with the core's own memory; Statistics → Memory shows Core runtime next to process RSS |
| тесты | разбор статуса (`memoryRuntime`, отсутствие ключа → 0) в тесте cc_channel/box_vpn_client, где уже проверяется `memory`; widget-тест шторки: строка `Core runtime` с `/ 200 MB` при пресете и без дроби при `auto`, скрыта при 0 |

Пин ядра (`app/android/libbox.version`, `.libbox.version`,
`kCoreBuildTagsPin` в `core_chain_capability.dart`, `docs/KERNEL.md` с javap
и sha256) — отдельным шагом по регламенту после публикации AAR lx.29;
до этого код против `getMemoryRuntime()` не собирается, поэтому ветка
исполнителя вливается в develop вместе с пином.

### Проверка части 2

- Эмулятор, лимит 200: лог ядра без `memory threshold reached` на старте;
  Statistics → Memory → `Core memory ~40 MB / 200 MB`, RSS прежний.
- Лимит Auto: строка без дроби.
- У пользователя с WARP-группой — то же на его устройстве (после релиза).

## Проверка

- `app/test/services/native_prefs_memory_limit_test.dart` — дефолт `auto`,
  нормализация (`off` → `auto`).
- На устройстве (не делалось): Auto → лог ядра на старте без
  `memory threshold reached`; Settings → Debug → OOM reports не растут с
  каждым подключением; Stats → Memory показывает прежний RSS (это норма).
- У пользователя с 200 MB и RSS 461 MB после обновления ничего не меняется,
  пока он не переключит значение на Auto — выбранное явно число уважаем.
