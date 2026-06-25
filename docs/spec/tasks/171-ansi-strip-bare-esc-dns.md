# §171 — Live не показывает DNS: ANSI-strip не срезал голые ESC-байты

**Тип:** bug-fix
**Статус:** Реализовано (device-verified)
**Связано:** §048 (Live/профайлер), §043 (core-log pump), permanent rule «ANSI strip»

## Симптом

В Live-вкладке нет DNS-событий (`dnsResolve`/`dnsFail`), хотя TCP/UDP open/close
видны. На устройстве `/logs?source=core` показывает 48+ строк `dns: exchanged`
— то есть DNS в ядре ЕСТЬ, но в Live не доходит.

## Корень

DNS-события профайлер берёт ТОЛЬКО из core-логов (`_processLogLine` →
`_dnsRe`), не из connections-стрима (потому TCP/UDP не задеты — они из стрима).

Sing-box оборачивает уровень и conn_id в **ГОЛЫЕ ESC-байты** (``), не в
классические CSI-цвета. Реальная строка:
```
<ESC>INFO<ESC>[0617] [<ESC>759645927<ESC> 20ms] dns: exchanged A foo. 300 IN A 1.2.3.4
```

ANSI-strip в `BoxService.writeDebugMessage` (`BoxService.kt:686`) был:
```kotlin
Regex("\\[[0-9;]*[A-Za-z]")   // ищет "[…<letter>" — БЕЗ ESC в паттерне
```
Этот паттерн НЕ содержит `` → голые ESC-байты **оставались** в строке →
доезжали до Dart. DNS-regex профайлера `\[(\d+)\s+\S+\]\s+dns:` ждёт цифру
сразу после `[`, а в реале там `[` + `` → **матч проваливался** → DNS не
парсился → Live без DNS.

## Решение

`BoxService.kt` ansi-strip regex:
```kotlin
Regex("\\u001B\\[[0-9;]*[A-Za-z]|\\u001B")
```
Срезает И полные CSI-последовательности (`ESC[…<letter>`), И любые одиночные
ESC-байты. Скобки `[0617]` / `[connId ms]` (НЕ ANSI, нужны парсеру conn_id)
сохраняются — внутри них уходит только ESC, цифры остаются.

## Проверка (доказано юнит-эмуляцией)

Реальная строка с устройства → новый strip даёт
`INFO[0617] [759645927 20ms] dns: exchanged A foo. 300 IN A 1.2.3.4`
→ `_dnsRe` MATCH: connId=759645927, type=A, name=foo, answer=1.2.3.4.
Старый strip оставлял ESC → DNS-match ✗.

## Результат (device CPH2411 wifi-adb, 2026-06-26, vc 2819)

✅ ПОДТВЕРЖДЁН. VPN up → Live recording → DNS-трафик (ping example.com/
cloudflare.com/wikipedia.org/github.com) → `/profiler/live` буфер:
```
по типам: {'udpOpen': 4, 'tcpOpen': 4, 'dnsResolve': 10}
example.com -> 8.47.69.6 ; cloudflare.com -> 104.16.132.229
```
**10 dnsResolve** (было 0). DNS-regex теперь матчит — ESC-байты срезаны.

## Заметка про Live vs Conns (для контекста)

- **Conns** — срез АКТИВНЫХ соединений сейчас (из connections-стрима).
- **Live** — ЖУРНАЛ событий за ~60с: dnsResolve/dnsFail (из core-логов) +
  tcpOpen/tcpClose/udpOpen (из стрима) + confidence/атрибуция. Окно
  `_globalRollingWindow=60s`, cap `_globalRollingHardCap=3000`, GC каждые 5с.
  Событие живёт 60с даже если коннект ещё жив (это журнал, не список живых).
