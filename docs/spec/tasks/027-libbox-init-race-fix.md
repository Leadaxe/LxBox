# 027 — Race: `Libbox.newService` до завершения `Libbox.setup` + перенос в `filesDir`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md), [`038 crash diagnostics`](../features/038%20crash%20diagnostics/spec.md) |

## Проблема

В [`BoxApplication.initialize`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt) `Libbox.setup(opts)` + `Libbox.redirectStderr(...)` запускались в фоне через `GlobalScope.launch(Dispatchers.IO)` и метод возвращался мгновенно. Параллельно [`BoxVpnService.onStartCommand`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) запускал `serviceScope.launch { startCommandServer(); startSingbox() }`. На медленных IO-scheduler'ах (старые Android) `Libbox.newService` мог запуститься до завершения `Libbox.setup` → нативный crash в JNI без записи в stderr.

Дополнительно — `workingDir = context.getExternalFilesDir(null) ?: return` молча выходил на проблемных OEM с недоступной external storage, false-positive'но complete'я deferred-флаг готовности.

## Решение

### Sync barrier

`BoxApplication.libboxReady: CompletableDeferred<Unit>` — completed когда `initializeLibbox` отработал, completed-exceptionally на ошибку:

```kotlin
val libboxReady: CompletableDeferred<Unit> = CompletableDeferred()

GlobalScope.launch(Dispatchers.IO) {
    try {
        initializeLibbox(application)
        libboxReady.complete(Unit)
    } catch (t: Throwable) {
        libboxReady.completeExceptionally(t)
    }
}
```

`BoxVpnService` `serviceScope.launch` ждёт барьер перед любым обращением к libbox-классам:

```kotlin
serviceScope.launch {
    try {
        BoxApplication.libboxReady.await()
        startCommandServer()
        startSingbox()
    } catch (t: Throwable) { stopAndAlert(...) }
}
```

На быстрых девайсах `await` завершается за один tick. Если `Libbox.setup` упадёт — exception доезжает до `await` и идёт в `stopAndAlert("Libbox init failed: ...")`.

### Перенос в internal `filesDir`

`workingDir` теперь безусловно `context.filesDir` — то же место где живут `SettingsStorage` (подписки), `ConfigManager` (`config.json`), `RuleSetDownloader` (`rule_sets/*.srs`):

```kotlin
val baseDir = context.filesDir.also { it.mkdirs() }
val workingDir = baseDir
val tempDir = context.cacheDir.also { it.mkdirs() }
```

Гарантированно доступно на любом OEM, без зависимости от Scoped Storage / external mount / Knox-SELinux. Все читатели `stderr.log` синхронизированы через `getApplicationDocumentsDirectory()`:

| Читатель | Файл |
|---|---|
| [`StderrReader`](../../../app/lib/services/stderr_reader.dart) (Debug-tab + DumpBuilder) | `getApplicationDocumentsDirectory()/stderr.log` |
| [`§031 Debug API` `_localFile`](../../../app/lib/services/debug/handlers/files.dart) | `getApplicationDocumentsDirectory()/stderr.log` |

URL `/files/external?name=...` оставлен как legacy alias на `/files/local?name=...` ради adb-скриптов.

## Verification

- На быстрых устройствах поведение не меняется (barrier завершается мгновенно).
- На медленных barrier блокирует corutine на ~50-300ms.
- Если `Libbox.setup` упадёт — `stopAndAlert` с понятным error-toast'ом.
- `stderr.log`, `cache.db` теперь в internal storage; никаких external read failure'ов.
