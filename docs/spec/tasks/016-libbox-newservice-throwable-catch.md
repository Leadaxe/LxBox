# 016 — `Libbox.newService` / `svc.start` ловят `Throwable`, не только `Exception`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-29 |
| Дата завершения | 2026-04-29 |
| Коммиты | (не закоммичено на момент написания отчёта; диф в `git status`) |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

В [`BoxVpnService.startSingbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) попытка создать sing-box service ловила только `Exception`:

```kotlin
val svc = try {
    Libbox.newService(config, this as PlatformInterfaceWrapper)
} catch (e: Exception) {
    stopAndAlert("Failed to create service: ${e.message}")
    return
}
```

`Libbox.newService` — это пересечение JNI-границы через gomobile bridge: парсит JSON-конфиг через sing-box config-loader, создаёт outbound'ы, регистрирует callback'и `PlatformInterfaceWrapper`. Может упасть несколькими способами:

| Класс | Поведение `catch (Exception)` |
|---|---|
| JVM-исключение (`NameNotFoundException` и т.п.) | ✅ ловится |
| Sing-box validation error (вернулся как Go `error` через JNI bridge) | ✅ ловится |
| Go panic с `recover()` | ✅ ловится (gomobile конвертит в Java exception) |
| **Go panic без `recover()`** (как был VLESS `packet_encoding: "none"` до [task 012](012-vless-packet-encoding-libbox-panic.md)) | ❌ **не ловится JVM** — процесс получает SIGABRT, до catch-блока не доходит |
| **`OutOfMemoryError`** (большие geosite/geoip rule-sets) | ❌ — это `Error`, а не `Exception` |
| **`NoClassDefFoundError`/`VerifyError`** при class loading из libbox AAR на старых Android | ❌ — это `Error` |

Java/Kotlin `try { } catch (Exception)` намеренно не ловит `Error`-наследников. Это разумно для прикладного кода (Error'ы обычно нерекуверабельны), но **невыгодно для bootstrap-точек native-зависимостей** — лучше показать пользователю «Failed to create service: OutOfMemoryError» и корректно завершить корутину, чем словить unhandled-Error в `serviceScope.launch` и оставить пользователя со «всё закрылось без причины».

Параллельно симметричная проблема была в `try { svc.start() } catch (e: Exception)` и в `serviceScope.launch { try { … } catch (e: Exception) { … } }`.

## Решение

Расширить catch до `Throwable` во всех трёх местах:

```kotlin
val svc = try {
    Libbox.newService(config, this as PlatformInterfaceWrapper)
} catch (t: Throwable) {
    stopAndAlert("Failed to create service: ${t.message}")
    return
}

try { svc.start() } catch (t: Throwable) {
    stopAndAlert("Failed to start service: ${t.message}")
    return
}

serviceScope.launch {
    try {
        startCommandServer()
        startSingbox()
    } catch (t: Throwable) {
        Log.e(TAG, "Start failed", t)
        stopAndAlert(t.message ?: "Unknown error")
    }
}
```

Прокомментирована **граница защиты**: `Throwable`-catch ловит JVM-уровневые `Exception` и `Error`, но **принципиально не защищает от Go panic без recover** в нативном коде — такой краш улетает SIGABRT'ом мимо JVM. Защита от него — двухсторонняя: превентивно (валидация на стороне Dart-парсера, как `normalizePacketEncoding` в [task 012](012-vless-packet-encoding-libbox-panic.md)) и постфактум (stderr-redirect → видим stacktrace при следующем старте, см. [task 017](017-stderr-rotation-on-cold-start.md), [task 018](018-stderr-viewer-debug-tab.md)).

## Verification

- Code review: все три `catch (e: Exception)` в startSingbox-цепочке заменены на `catch (t: Throwable)`. Других call-path'ов в libbox не осталось без try.
- Сборка release APK — компилируется.
- Регресс на эмуляторе: при заведомо невалидном конфиге (пустой outbounds) `stopAndAlert` показывает понятное сообщение, как и до правки. При большом конфиге (огромный geosite include) — если упрётся в heap, теперь увидим toast `Failed to create service: OutOfMemoryError` вместо тихого исчезновения процесса.
