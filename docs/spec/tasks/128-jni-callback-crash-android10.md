# §128 — JNI callback crash на Android 10 (F12.3 generalization)

| Поле | Значение |
|------|----------|
| Статус | **In Progress** |
| Дата | 2026-06-15 |
| Тип | bug-fix (native / JNI boundary) |
| Связано | [§050 libbox-debug-build](050-libbox-debug-build/findings.md) (F12.3 root cause), [§049 singbox-wrapper-deep-audit](049-singbox-wrapper-deep-audit/spec.md) |

## Жалоба

> Андроид-версия не работает: открывается, но любое действие крашит приложение.
> Андроид 10, LineageOS + microG (без рута). v2raytun и clash mi работают.

v2.3.0. Логов с устройства жалобщика нет — диагноз по коду.

## Диагноз

### Что отброшено
- **GMS/microG.** В `pubspec.yaml` нет ни одной GMS/Firebase/Play-зависимости.
  Гипотеза «плагин требует Play Services» не подтверждается. То, что v2raytun
  и clash (тоже sing-box/Clash-ядра) работают на том же устройстве, доказывает:
  ядро на этом телефоне в принципе живёт → баг в **нашей** обвязке.

### Корень — generalization F12.3
§050 установил root cause крэша «refnum 42»: **unchecked Java-исключение из
Kotlin-callback пролетает через JNI-границу (gomobile cproxy stub без try/catch)
→ corrupted JNI env → `Runtime::Abort`** — убивает весь процесс мгновенно,
Flutter не успевает ничего показать. Именно так выглядит «крашит наглухо».

§050 вывел **правило проекта** ([findings.md:36](050-libbox-debug-build/findings.md)):

> defensive try/catch на JNI boundaries — **обязательно для ВСЕХ cgo callbacks
> которые могут throw**

Тогда правило применили только к `readWIFIState`. Но в том же
`PlatformInterfaceWrapper` остались **три callback'а без защиты**, которые зовут
системные API, способные бросить `SecurityException`/`RuntimeException` на
Android 10 без рута:

| Callback | Системный вызов | Когда зовётся из Go | Защита до §128 |
|---|---|---|---|
| `findConnectionOwner` | `connectivity.getConnectionOwnerUid()`, `packageManager.getPackagesForUid()` | **на каждое соединение** (`find_process: true` — глобальный дефолт, [wizard_template.json:493](../../../app/assets/wizard_template.json)) | ❌ нет |
| `getInterfaces` | `connectivity.allNetworks`, `getLinkProperties`, `getNetworkCapabilities`, `NetworkInterface.getNetworkInterfaces()` | **всегда при connect** (init маршрутизации) | ❌ только `mtu` в runCatching |
| `systemCertificates` | `KeyStore("AndroidCAStore")`, `cert.encoded` | один раз при старте TLS-стека | ❌ нет |

### Почему ударяет именно Android 10 + LineageOS, а не тест-устройство
- `getConnectionOwnerUid` различается по строгости между версиями Android и
  прошивками. На стоке Android 13 (тест-телефон) системные/чужие соединения
  отдают UID штатно; на LineageOS/Android 10 тот же вызов для недоступного
  владельца может вернуть отказ → `SecurityException`.
- [ARCHITECTURE.md](../../ARCHITECTURE.md): Android 10 (API 29) = **«Best-effort»**,
  *«не тестируется регулярно»*. Android 11+ = Primary. Весь ручной/CI тест идёт
  на «здоровом» API → путь не бросает → баг невидим разработчику.

### Почему симптом = «любое действие крашит»
В VPN-клиенте почти любое осмысленное действие ведёт к connect/трафику. Как
только пошёл трафик — `findConnectionOwner` зовётся на каждом соединении. Один
`SecurityException` оттуда = мгновенный abort процесса.

## Fix

Обернуть три callback'а в defensive try/catch с **fail-safe** деградацией —
ровно паттерн F12.3 (вернуть пустой/нейтральный результат вместо throw в Go):

- `findConnectionOwner` — при отказе вернуть `ConnectionOwner` с `userId =
  INVALID_UID` и пустыми пакетами (sing-box трактует как «owner unknown»,
  routing продолжает работать — `find_process` правило просто не матчит).
- `getInterfaces` — обернуть тело в try/catch; при отказе вернуть пустой
  итератор (sing-box деградирует к auto-detect без явного списка интерфейсов).
- `systemCertificates` — обернуть в runCatching; при отказе вернуть пустой
  список (TLS-верификация упадёт к встроенным сертификатам ядра).

Принцип: **никакой Kotlin-callback, вызываемый из Go, не должен бросать наружу.**

## Files

| File | Change |
|---|---|
| `app/android/app/src/main/kotlin/.../vpn/PlatformInterfaceWrapper.kt` | try/catch на `findConnectionOwner` / `getInterfaces` / `systemCertificates` |

## Оговорка

Без logcat с устройства жалобщика диагноз не подтверждён на 100% — это сильная
обоснованная гипотеза (нарушение собственного правила проекта + точное
совпадение симптома и best-effort-статуса API 29). Даже если краш не только
здесь — эти дыры обязаны быть закрыты по правилу §050.

## Verification

- [ ] `flutter analyze` / Kotlin compile чисто
- [ ] Сборка release+arm64 (`build-local-apk.sh`)
- [ ] (если будет доступ) воспроизведение на Android 10 без GMS — pid alive
      после connect + трафик
