# 016 — `Libbox.newService` / `svc.start` ловят `Throwable`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

В [`BoxVpnService.startSingbox`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt) попытка создать sing-box service ловила только `Exception`, что пропускает `Error`-наследники (`OutOfMemoryError`, `NoClassDefFoundError`, `VerifyError`). Unhandled `Error` в `serviceScope.launch` отравляет scope и приводит к тихому исчезновению процесса вместо понятного error-toast'а.

## Решение

Расширить catch до `Throwable` во всех трёх точках:
- `Libbox.newService(config, this)`
- `svc.start()`
- общий `serviceScope.launch { startCommandServer(); startSingbox() }`

```kotlin
val svc = try {
    Libbox.newService(config, this as PlatformInterfaceWrapper)
} catch (t: Throwable) {
    stopAndAlert("Failed to create service: ${t.message}")
    return
}
```

**Не защищает** от Go panic без recover в нативе — такой краш улетает SIGABRT'ом мимо JVM. Защита от него — превентивная (валидация конфига, см. [task 012](012-vless-packet-encoding-libbox-panic.md)) и постфактум (stderr-redirect, см. [§038](../features/038%20crash%20diagnostics/spec.md)).

## Verification

- При невалидном конфиге `stopAndAlert` показывает понятное сообщение.
- При OOM (большие geosite rule-sets) — toast `Failed to create service: OutOfMemoryError` вместо тихого вылета.
