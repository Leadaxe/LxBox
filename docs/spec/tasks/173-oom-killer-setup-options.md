# §173 — OOM-killer не настроен: SetupOptions без oomKillerEnabled/oomMemoryLimit

**Тип:** bug-fix (регрессия 1.14-миграции)
**Статус:** Реализовано (device-verify впереди)
**Связано:** §121 (libbox 1.14 adoption), §038 (stderr-viewer)

## Симптом

CHANGELOG (§121) и комментарий в `BoxApplication.kt:101-104` утверждают, что
OOM-killer и crash-канал сконфигурены через `SetupOptions`
(`oomKillerEnabled`/`oomMemoryLimit`/`crashReportSource`). На деле в
`SetupOptions {}`-блоке (BoxApplication.kt:88-99) выставлены ТОЛЬКО
basePath/workingPath/tempPath/fixAndroidStack/logMaxLines/debug — OOM-поля и
crashReportSource **не дописаны**. Док врёт, поля не выставлены.

Последствие: до 1.14 код звал `Libbox.setMemoryLimit(true)` (включал OOM-killer
с лимитом). В 1.14 `setMemoryLimit`/`redirectStderr` удалены из API, конфиг ушёл
в `SetupOptions` — но миграция поля **не перенесла** → Go-рантайм работает БЕЗ
memory soft-limit (`debug.SetMemoryLimit(MaxInt64)`) → на слабых устройствах
ядро может разрастись и попасть под Android lowmemorykiller. + потерян
stderr/crash-канал §038.

## Факт: поля ЕСТЬ в нашем AAR

`javap -p SetupOptions.class` (app/android/app/libs/libbox.aar) подтверждает
сеттеры: `setOomKillerEnabled(boolean)`, `setOomKillerDisabled(boolean)`,
`setOomMemoryLimit(long)`, `setCrashReportSource(String)`. Ядро трогать НЕ нужно.

## Логика ядра (sing-box-lx setup.go:80-95)

```
if oomKillerEnabled {
    if oomMemoryLimit == 0 && C.IsIos { oomMemoryLimit = <Apple default> }
    if oomMemoryLimit > 0 { debug.SetMemoryLimit(oomMemoryLimit * 3/4) }
    else                  { debug.SetMemoryLimit(MaxInt64) }   // ← Android!
} else { debug.SetMemoryLimit(MaxInt64) }
```

**КРИТИЧНО:** на Android `oomKillerEnabled=true` БЕЗ явного `oomMemoryLimit` =
НЕТ лимита (дефолт только у iOS NetEx). Поэтому лимит надо задать **явно**.

`crashReportSource` (непустой) → ядро редиректит stderr в
`workingPath/CrashReport-<source>.log` (setup.go:102).

## Фикс (BoxApplication.kt)

В `SetupOptions {}`-блок дописаны:
```kotlin
oomKillerEnabled = true
oomMemoryLimit = 200L * 1024 * 1024   // 200 MB → Go soft-limit ~150 MB
crashReportSource = "lxbox"           // stderr → CrashReport-lxbox.log
```

- **200 MB** (решение пользователя): soft-limit `200*3/4 ≈ 150 MB` → GC
  агрессивнее, меньше шансов под lowmemorykiller; мягче чем 100 MB (нет
  GC-thrashing на больших подписках), но безопаснее 256+ на устройствах 1-2GB.
- **UPD §271**: хардкод 200 MB вызывал GC-шторм и перегрев CPU на конфигах с
  большой живой кучей (WG-пулы) — лимит стал настраиваемым (VPN Settings →
  System → Optimization → Memory limit; Auto по RAM устройства / Off / пресеты
  МБ). См. `docs/spec/tasks/271-configurable-memory-limit.md`.
- **crashReportSource="lxbox"**: восстанавливает stderr-диагностику §038,
  потерянную с удалением `redirectStderr` в 1.14.

## Проверка (device, впереди)

- VPN up → ядро не падает, лог `CrashReport-lxbox.log` создаётся в workingPath
  при крэше/stderr-выводе.
- На слабом устройстве (1-2 GB) под нагрузкой (большая подписка + Live) —
  процесс не убивается lowmemorykiller так легко как без лимита.
- Косвенно: память в Stats не убегает безгранично (GC держит ~150 MB).

## Заодно (отдельный мелкий фикс, тот же коммит)

`/help` врал: документировал удалённые в §122 Clash-роуты. Вычищено:
`/state/clash` (роут удалён — нет в `state.dart`), urltest-описания «через clash
`/proxies`/`/group` delay» → «через CommandClient urlTestOutbound»,
`/clash/connections` в reset-network коммент → `/state` active_connections,
clash-reference в help-notes, stale `/state/clash → _clash` в server.dart:152 /
router.dart:15. «Clash-порт 63130» → «CommandServer-порт 63130» (порт живой, имя
устарело).
