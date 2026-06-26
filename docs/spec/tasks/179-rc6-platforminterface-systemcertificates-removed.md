# §179 — rc.6: `PlatformInterface.systemCertificates()` убран ядром (миграция обвязки)

**Тип:** bug-fix (breaking change в libbox-биндинге при бампе ядра rc.5→rc.6)
**Статус:** Реализовано (Kotlin собирается на rc.6)
**Связано:** §128 (сбор системных CA), §121 (адаптация на libbox 1.14),
[migration 1.14 API breaks](../../../app/android), §178 (detour — едет тем же rc.6)

## Симптом

Сборка release на ядре rc.6 падает:

```
e: PlatformInterfaceWrapper.kt:208 'systemCertificates' overrides nothing.
Execution failed for task ':app:compileReleaseKotlin'.
```

## Корень

rc.6 несёт крупный upstream-мердж sing-box (SSH-сервер, Tailscale). В нём
`PlatformInterface` **переработан**: метод `systemCertificates()` УБРАН из
интерфейса (javap AAR rc.6 подтвердил — метода нет). Наш `override fun
systemCertificates()` (§128, собирал AndroidCAStore для TLS-стека) теперь
переопределяет несуществующий метод → ошибка компиляции.

Апстрим перенёс сбор системных CA внутрь Go-рантайма — ядро читает хранилище
само через platform-bridge, отдельный Kotlin-хук больше не нужен.

## Сверка интерфейса rc.6 (javap)

Сравнение 23 abstract-методов `PlatformInterface` rc.6 ↔ наш wrapper:

- **Все 23 обязательных реализованы** (autoDetect…useProcFS) — недостающих НЕТ.
- **Единственный лишний:** `systemCertificates` (rc.6 не объявляет).
- Новых обязательных методов rc.6 НЕ добавил (SSH/shell/tailscale-методы —
  `openShellSession`/`readSystemSSHHostKey`/`tailscaleHostname`/… — уже были
  заглушены при §121-миграции на 1.14).

Вывод: миграция точечная — удалить один метод, не добавлять.

## Решение

Удалить `systemCertificates()` целиком (метод + §128-доку). Ядро его не зовёт
(нет в интерфейсе) → мёртвый код. `StringArray`-helper остаётся (используется
в `setAndroidPackageNames`/`dnsServer`/`addresses`).

Откатный план (если TLS к серверам с системными CA сломается на rc.6): вернуть
сбор CA как НЕ-`override` хук через отдельный binding. Маловероятно — ядро берёт
системные CA само.

## Проверка

- `compileReleaseKotlin` проходит на rc.6 (была ошибка — стало чисто).
- Device: TLS-соединение к узлу с сертификатом от системного CA (не встроенного
  в ядро) устанавливается — проверить любой https-узел подписки.
- Регресс: VPN стартует, конфиг применяется (PlatformInterface полностью
  реализует rc.6-контракт — иначе ClassNotFound/AbstractMethodError на старте).
