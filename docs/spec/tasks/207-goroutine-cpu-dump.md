# §207 — On-device pprof capture (goroutine dump + CPU profile)

Status: **implemented** (Dart + Kotlin обвязка; ядро не правится — Способ 1).

## Проблема

Зависший / греющийся на устройстве туннель сейчас даёт только **счётчик**
живых горутин (`StatusMessage.getGoroutines()` → `CcStatus.goroutines`,
[cc_channel.dart](../../../app/lib/vpn/cc_channel.dart)). Счётчик ловит
*утечку* (монотонный рост), но не показывает **стек-трейсы** — какая горутина
и на чём залипла, и не ловит **busy-spin** в tight-loop (100% CPU без
блокировки), который как раз и греет телефон. Нужен полный pprof-снимок с
устройства тестера.

## Решение — Способ 1: встроенный libbox `PProfServer`

libbox.aar **уже** экспортирует `Libbox.newPProfServer(long port)` →
`PProfServer{ start(); close() }` (Go `net/http/pprof`). Ядро править не
нужно. Сервер поднимается **по требованию** на loopback-порту, обслуживает
ОДИН GET и сразу гасится — в проде http-listener не висит (нулевая постоянная
поверхность атаки).

Один сервер бесплатно отдаёт весь набор `/debug/pprof/*`:

| profile | формат | для чего |
|---|---|---|
| `goroutine` (`?debug=2`) | текст | стеки всех горутин — дедлок/залипание |
| `profile` (`?seconds=N`) | `.pb` | CPU за N сек — **главный для нагрева** (busy-spin) |
| `heap` | текст | снимок памяти — утечки/OOM |
| `allocs` | текст | история аллокаций |
| `block` | текст | блокировки на синхронизации |
| `mutex` | текст | конкуренция за мьютексы |
| `threadcreate` | текст | создание ОС-потоков |

Для §207-бага (нагрев) нужны `profile` (главный) + `goroutine`
(подтверждающий). Остальное доступно тем же кодом через Debug API без правок.

**Почему фиксированный порт, а не `:0`.** `PProfServer` API даёт только
`start()`/`close()` — **нет геттера фактического порта**. Эфемерный `:0`
бесполезен (не узнаем, куда стучаться). Берём первый свободный из диапазона
`6060..6065`: `start()` на занятом порту бросает → пробуем следующий.

**Ограничение.** При рантайм-дедлоке ядра http-горутина не ответит (GET
повиснет → timeout). Но целевой кейс §207 — busy-spin / 100% CPU, где ядро
активно крутит и сервер жив. Для дедлок-кейса в будущем можно добавить в ядро
синхронный `runtime.Stack` (Способ 2) — точка интеграции (`pprofProfile`)
останется та же.

## Архитектура

```
UI (Debug screen ⋮-меню  +  App Settings → Diagnostics → Profiling)
        │ MethodChannel: pprofProfile(profile, seconds)
        ▼
VpnPlugin.kt "pprofProfile"  ──→  PProfClient (Kotlin)
        │                          newPProfServer(порт из 6060..6065).start()
        │                          GET 127.0.0.1:port/debug/pprof/<profile>
        │                          close()  (всегда, в finally)
        │ ByteArray (текст=UTF-8 / CPU=.pb)
        ▼
BoxVpnClient.pprofProfile() → Uint8List
   ├─ dumpGoroutines()    — обёртка profile=goroutine, НИКОГДА не бросает
   └─ captureCpuProfile() — обёртка profile=profile, durationMs→seconds
        ▼
ProfileDumpWriter → temp/goroutines-<ts>.txt | cpu-<ts>.pb → Share
DumpBuilder       → dump['goroutines_stack'] (только при активном туннеле)
Debug API         → GET /diag/pprof?profile=P&seconds=N
```

## Изменения по файлам

### Native (Kotlin)
- **`PProfClient.kt`** (новый) — `fetch(pathAndQuery, readTimeoutMs)` поднимает
  сервер на первом свободном порту, GET, гасит в `finally`. Врапперы
  `goroutineDump()` / `cpuProfile(seconds)`. **CPU read-timeout = seconds*1000
  + headroom** (сервер держит соединение N сек — иначе SocketTimeout оборвёт
  запись).
- **`VpnPlugin.kt`** — один `"pprofProfile"` case (рядом с `getCoreVersion`):
  читает `profile` + `seconds`, на IO-потоке зовёт `PProfClient`, текст-снимки
  через `?debug=2`, CPU через `cpuProfile`. На throwable — `result.error
  PPROF_FAILED` (Dart решает смягчить/показать).

### Dart
- **`box_vpn_client/method_names.dart`** — `pprofProfile`.
- **`box_vpn_client/timeouts.dart`** — `goroutineDump` (5s) + `cpuProfile` (20s).
- **`box_vpn_client.dart`** — `pprofProfile({profile, seconds})` → `Uint8List`;
  `dumpGoroutines()` (обёртка, **никогда не бросает** — фолбэк-текст);
  `captureCpuProfile({durationMs})` (обёртка, durationMs→seconds clamp 1..60,
  пробрасывает `PlatformException`).
- **`services/profile_dump_writer.dart`** (новый) — `writeGoroutines(text)` →
  `goroutines-<ts>.txt`, `writeCpuProfile(bytes)` → `cpu-<ts>.pb` (temp + stamp
  как DumpBuilder).
- **`dump_builder.dart`** — `dump['goroutines_stack']` = текст или `null`
  (только при активном туннеле; CPU-бинарь в JSON не кладём).
- **`debug/handlers/diag.dart`** — `GET /diag/pprof?profile=P&seconds=N`,
  валидация profile, CPU→`.pb`/octet-stream, прочее→text/plain.
- **`debug/handlers/help.dart`** — регистрация эндпоинта (текст + список).

### UI (две точки — обе с уже существующим Share)
- **Debug screen** (`debug_screen.dart`) — две позиции в ⋮-меню (`PopupMenu`):
  `Capture goroutine dump` / `Capture CPU profile (10s)`. Гейт на тапе:
  `getVpnStatus().isUp`, иначе snackbar. `_capturing` дизейблит обе на время
  (чтобы не поднять два сервера на одном порту). → Share файла.
- **App Settings → Diagnostics → Profiling** — секция с двумя
  `OutlinedButton` + подпись `go tool pprof cpu-*.pb`. Те же колбэки в
  `_AppSettingsScreenState`.

## UX
- goroutine — мгновенно; snackbar `Captured N goroutines` (N = `^goroutine \d+`
  matches); Share `.txt`.
- CPU — `Profiling CPU for 10s…` → блокирует кнопку ~10s → Share `.pb`,
  подпись `analyze with: go tool pprof <name>`.
- Обе видны/доступны, но требуют активного туннеля (иначе snackbar-объяснение).

## Безопасность / приватность
- pprof http НЕ висит в проде — поднимается по тапу и гасится. Bind на
  `127.0.0.1` (loopback).
- goroutine/heap могут содержать имена outbound'ов / host'ов в аргументах
  фреймов, но не пароли — тот же уровень что у уже-шарящегося stderr (§038).

## Тесты
- `test/services/profile_dump_writer_test.dart` — round-trip txt/pb, stamp без
  двоеточий.
- `test/vpn/box_vpn_client_test.dart` (§207 group) — arg-packing `pprofProfile`,
  `dumpGoroutines` never-throws (фолбэк), `captureCpuProfile` durationMs→seconds
  clamp + проброс `PlatformException`.
- `flutter analyze` чисто; `:app:compileDebugKotlin` BUILD SUCCESSFUL (native
  резолвит `Libbox.newPProfServer`/`PProfServer` против реального libbox.aar).

## Возможное развитие
- Способ 2 (синхронный `runtime.Stack` в ядре) для дедлок-кейса — та же точка
  `pprofProfile`, добавить ветку.
- UI для heap/block/mutex (сейчас только через Debug API `/diag/pprof`).
