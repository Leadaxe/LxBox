# 151 — JNI-iterator throw (реальная abort-поверхность) + ALPN double-decode

| Поле | Значение |
|------|----------|
| Статус | **In progress** |
| Дата | 2026-06-21 |
| Тип | bug-fix (native / JNI boundary) + parser hardening |
| Повод | Жалоба Yuri (20.06.2026): trojan-подписка → краш «Aborted» при старте туннеля |
| Связано | §050/§128 (JNI no-throw — пересмотр механизма), §141 (audit), §026 (parser v2) |

---

## TL;DR

Расследование жалобы Yuri перевернуло понимание JNI-no-throw инварианта.
**Главный вывод: throw из Kotlin-callback роняет процесс (`Runtime::Abort`) НЕ
всегда — а только если соответствующий Go-метод возвращает `void`/value БЕЗ
`error`.** Методы с Go-сигнатурой `... error` защищены самим gomobile-биндингом
(throw ловится, конвертится в Go-error), try/catch там — косметика.

Из этого следуют две правки:
1. **Итераторы** (`StringIterator`/`NetworkInterfaceIterator`) — Go-методы
   `Next()`/`HasNext()` БЕЗ `error`. Наши `next()` бросают `NoSuchElementException`
   за концом → **реальный abort-класс**. Фикс: вернуть пустое значение, не throw.
2. **ALPN double-decode** — `alpn=http%252F1.1` в подписке → в конфиг ядра
   уходит мусор `["http%2F1.1"]`. Фикс: повторный decode + валидация в парсере.
   (Не abort — проверено на железе, но реальный баг.)

Опционально-в-этой-же-таске: **LocalResolver** — `exchange/lookup` возвращают
`error` (значит throw НЕ роняет), но `error("missing default interface")` при
`defaultNetwork==null` даёт шумный Go-error на каждый DNS-запрос под сменой сети.
Чище — вернуть ядру `ctx.errorCode` (корректный DNS-fail).

---

## Механизм (раскрыт по исходнику gomobile + ядра)

Сборка линкует ядро через форк `sagernet/gomobile`. Генератор биндинга
(`bind/genjava.go`) для каждого Go-интерфейса, реализуемого на Kotlin, эмитит
C-`cproxy_*` stub, вызывающий Java-override через JNI. Обработка исключений
**зависит от Go-сигнатуры метода**:

| Go-сигнатура | Генерируемый Java-метод | Что с throw из Kotlin |
|---|---|---|
| возвращает `error` (или `(T, error)`) | `... throws Exception` | stub зовёт `go_seq_get_exception(env)` → `ExceptionClear` → throw конвертится в **Go-error**. **Abort НЕ происходит.** |
| `void` / plain value (без `error`) | без `throws` | исключение остаётся pending в JNIEnv → следующая JNI-операция → **`Runtime::Abort`** («Aborted») |

Источник: `genjava.go:1292-1308` — `go_seq_get_exception` эмитится только при
`res.Len()==2 || isErrorType`. Подтверждено декомпиляцией биндинга: `exchange`/
`lookup` идут с `throws Exception`, `raw()`/итераторные `next()` — без.

### Классификация наших Kotlin-callbacks по этому критерию

Сигнатуры сверены в `sing-box-lx/experimental/libbox/{platform,command_server,dns,iterator}.go`.

**Safe-by-signature (Go возвращает `error` → throw ловится gomobile, abort нет):**
- `PlatformInterface`: `FindConnectionOwner (...) (*ConnectionOwner, error)`,
  `GetInterfaces() (..., error)`, `SendNotification(...) error`
- `CommandServerHandler`: `ServiceStop/ServiceReload/GetSystemProxyStatus/
  SetSystemProxyEnabled (...) error`
- `LocalDNSTransport`: `Lookup(...) error`, `Exchange(...) error`

> Следствие: обёртки §128 на `findConnectionOwner` и обёртки §141 на
> CommandServerHandler-методы были **не нужны как abort-фикс** (метод и так
> safe-by-signature). Они безвредны (чистый Go-error лучше pending-exception
> даже когда ловится) и остаются. Но «фикс краша Aborted» они не давали — что
> согласуется с тем, что tombstone уже опроверг §128 для исходной жалобы (там
> оказался Impeller, §131).

**Abort-prone (Go `void`/value без `error` → throw роняет процесс):**

| Callback | Go-сигнатура | Kotlin | Защита |
|---|---|---|---|
| `InterfaceUpdateListener.UpdateDefaultInterface` | void | `DefaultNetworkMonitor.notifySync` | ✅ §141 P1.1b |
| `CommandServerHandler.WriteDebugMessage` | void | `BoxService.writeDebugMessage` | ✅ no-throw тело |
| `PlatformInterface.ClearDNSCache` | void | `PlatformInterfaceWrapper` `{}` | ✅ пусто |
| `PlatformInterface.ReadWIFIState` | `*WIFIState` | `readWIFIState` | ✅ §050 |
| `PlatformInterface.SystemCertificates` | `StringIterator` | `systemCertificates` | ✅ §128 |
| **`StringIterator.{Len,HasNext,Next}`** | int32/bool/string — **без error** | `StringArray.next`, `singleStringIterator.next` | ❌ **бросают `NoSuchElementException`** |
| **`NetworkInterfaceIterator.{Next,HasNext}`** | `*NetworkInterface`/bool — **без error** | `emptyInterfaceIterator().next` | ❌ **`throw NoSuchElementException()`** |

---

## Fix

### F1 — итераторы: `next()` за концом не бросает (реальный abort-класс)

Три call-site бросают `NoSuchElementException`, когда ядро зовёт `Next()` без
проверки `HasNext()`. Go-интерфейс без `error` → это `Runtime::Abort`. Низкая
вероятность (ядро штатно гейтит на `HasNext()`), но строго нарушает
signature-инвариант.

| Файл | Сейчас | Станет |
|---|---|---|
| `PlatformInterfaceWrapper.kt` `emptyInterfaceIterator().next()` (:146) | `throw NoSuchElementException()` | вернуть пустой `LibboxNetworkInterface()` |
| `PlatformInterfaceWrapper.kt` `StringArray.next()` (:223) | `iter.next()` (бросит за концом) | `if (!iter.hasNext()) "" else iter.next()` |
| `BoxService.kt` `singleStringIterator.next()` (:566) | возвращает value, потом сломается | guard: после `consumed` → `""` |

Принцип: **итератор-`next()` за концом возвращает пустой элемент, а не
бросает** — фактический контракт `HasNext()`-гейтинга сохраняется, но даже
нарушение его ядром не валит процесс.

### F2 — ALPN double-decode guard (parser, не abort)

`Uri.queryParameters` декодит percent ровно один раз: `alpn=http%252F1.1` →
`"http%2F1.1"` (мусор) вместо `"http/1.1"`. Уходит в `tls.alpn` ядра дословно.

`transport.dart` `_alpnFromQuery` (:176): после split — если значение всё ещё
содержит `%XX`-последовательность, попробовать повторный `Uri.decodeComponent`;
отбросить значения, не похожие на валидный ALPN-id (содержащие `%`, пробелы,
управляющие символы после де-кода). Симметрично прикрыть vmess-путь (:157).
Валидные `h2`/`http/1.1`/`h3` не трогаются.

### F3 — LocalResolver: ctx.errorCode вместо error()

`exchange/lookup` (`LocalResolver.kt`) возвращают `error` → throw ловится, НЕ
abort. Но `?: error("missing default interface")` при `defaultNetwork==null`
(реально при смене/потере сети в момент резолва) даёт шумный Go-error на каждый
DNS-запрос. Чище: вернуть ядру `ctx.errorCode(2)` (SERVFAIL) и выйти.

**Gotcha (Kotlin):** замена `?: error(...)` на null-проверку требует **явной
non-null `val defaultNetwork: Network`** — иначе компилятор не пробрасывает
smart-cast во вложенные замыкания `DnsResolver.Callback` и выдаёт каскадный
«Unresolved reference 'tryResumeWithException'» (вторичная ошибка, не сам
extension). Паттерн: `val dn = ...; if (dn == null) { ctx.errorCode; return };
val defaultNetwork: Network = dn`.

> **Артефакт диагностики:** первая верификация сборки давала флаковые
> «Unresolved reference» из-за **гонки параллельных Gradle-демонов** (другая
> сессия билдила одновременно) — частично-перекомпилированное состояние
> инкрементального компилятора. Перед верификацией §151 — `./gradlew --stop`,
> убедиться что нет чужих GradleDaemon.

---

## Files

| File | Change |
|---|---|
| `app/android/.../vpn/PlatformInterfaceWrapper.kt` | F1: `emptyInterfaceIterator`/`StringArray.next` no-throw |
| `app/android/.../vpn/BoxService.kt` | F1: `singleStringIterator.next` no-throw |
| `app/lib/services/parser/transport.dart` | F2: `_alpnFromQuery` double-decode guard + vmess |
| `app/test/parser/round_trip_test.dart` | F2: тесты double-decode ALPN |
| `app/android/.../vpn/LocalResolver.kt` | F3: `ctx.errorCode(SERVFAIL)` вместо `error()` (явный non-null тип) |

---

## Оговорка (честная граница)

**Ни F1, ни F2, ни F3 не подтверждены как причина краша Yuri.** На тест-телефоне
(Android 15, OnePlus) подписка из 82 нод НЕ роняет приложение — прогнан весь путь
(одна нода с битым ALPN, полная подписка, rebuild, stop/start туннеля, трафик):
PID неизменен, crash-буфер logcat пуст, exit-info без abort. Лога от Yuri нет.

Это **hardening реальных дыр по signature-инварианту**, а не «фикс
воспроизведённого краша». F1 — единственный подтверждённый abort-класс (но
требует, чтобы ядро нарушило `HasNext()`-контракт). Дыры закрыть надо
независимо — они нарушают инвариант. На старом Android жалобщика поверхность
может быть шире (другие code-path), но без устройства это не верифицируется.

---

## Verification

- [ ] Kotlin compile чисто (`flutter build apk --release` arm64)
- [ ] Dart: unit-тест `_alpnFromQuery` на `http%252F1.1` → `http/1.1` (или drop)
- [ ] Round-trip парсера не сломан (`flutter test test/parser/`)
- [ ] (по команде юзера) установка + connect на полной подписке — pid alive
