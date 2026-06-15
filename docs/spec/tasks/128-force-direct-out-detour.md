# 128 — «Force direct-out» в detour-настройках узла — WON'T-FIX

| Поле | Значение |
|------|----------|
| Статус | **Won't-fix — задача закрыта, фича осознанно НЕ делается (см. «Решение»)** |
| Дата старта | 2026-06-15 |
| Дата закрытия | 2026-06-15 |
| Вердикт | `"detour": "direct-out"` на конечной ноде — **запрещённая ядром конструкция**. Узел не «идёт напрямую», а полностью теряет связь: каждый dial мгновенно падает с `detour to an empty direct outbound makes no sense`. Исходный замысел задачи (форсить прямой выход через `detour: direct-out`) технически невозможен на ядре sing-box ≥ 2025-07. Ошибочная реализация откачена (`revert(detour)` `6c1d416`). Альтернативы (Вариант A/B ниже) **рассмотрены и отклонены** — фичу не делаем ни в какой форме. |
| Связанные | [§073](073-detour-append-vs-replace.md) (APPEND vs REPLACE); [§111](111-subscription-detour-without-native-chain.md) (detour-пикер подписок) |

---

## TL;DR

> **Итог одной строкой: фича «Force direct-out» НЕ реализуется — ни в исходном
> виде, ни через альтернативы. Задача закрыта как Won't-fix.** Этот документ —
> объяснение _почему_, чтобы задачу не подняли повторно. Ниже разобранные
> Вариант A/B — **отклонённые** альтернативы, а не план работ.

«Force direct-out» задумывался как пункт dropdown, который пишет в outbound узла
`"detour": "direct-out"`, чтобы **жёстко** отправить трафик напрямую, выкинув
нативную detour-цепочку. **Это не работает и работать не может.**

Ядро `sing-box-lx` (как и upstream) с июля 2025 **явно отвергает** detour на
«пустой» direct-outbound. А `direct-out` в нашем шаблоне
([wizard_template.json:490](../../../app/assets/wizard_template.json)) — это в
точности `{ "type": "direct", "tag": "direct-out" }`, то есть **голый direct без
единого dial-поля**, который по определению ядра «пустой».

Результат на устройстве: узел с `detour: direct-out` **не поднимает ни одного
соединения**. В логах:

```
ERROR endpoint/wireguard[🏠 WireGuard Warp+direct]: connect to server:
      detour to an empty direct outbound makes no sense
ERROR endpoint/wireguard[🏠 WireGuard Warp+direct]: peer(bmXO…fgyo) -
      failed to send handshake initiation: detour to an empty direct outbound makes no sense
```

Это не баг ядра — это **намеренное** поведение upstream. Исходная реализация
задачи была откачена (`6c1d416`). Обходные пути теоретически существуют (см.
[«Рассмотренные альтернативы»](#рассмотренные-альтернативы--и-почему-их-тоже-не-делаем)),
но **отклонены** — фичу не делаем.

---

## Почему detour на direct — запрещённая конструкция у конечных нод

### 1. Запрет находится в ядре диалера, не в UI и не в валидаторе конфига

Запрет ввёл upstream-коммит (мейнтейнер sing-box, `世界 <i@sekai.icu>`):

```
fb622ccbdf44b13b3009f8223c58698091b0bcaf
"Explicitly reject detour to empty direct outbounds"
author date: 2025-03-20 · в ветку sing-box-lx попал 2025-07-08
```

Он встроен в `DetourDialer.init()` ядра (`common/dialer/detour.go`). Любой
outbound/endpoint, в конфиге которого есть `"detour": "<tag>"`, при попытке
установить соединение резолвит цель через этот код:

```go
func (d *DetourDialer) init() {
    dialer, loaded := d.outboundManager.Outbound(d.detour)
    if !loaded {
        d.initErr = E.New("outbound detour not found: ", d.detour)
        return
    }
    if !d.legacyDNSDialer {                               // см. п.3 — почему это «все, кроме legacy-DNS»
        if directDialer, isDirect := dialer.(DirectDialer); isDirect {
            if directDialer.IsEmpty() {
                d.initErr = E.New("detour to an empty direct outbound makes no sense")
                return
            }
        }
    }
    d.dialer = dialer
}
```

Это **общий** механизм диалера, а не что-то специфичное для VLESS/WireGuard. Под
него попадают все протоколы конечных нод.

### 2. Что ядро считает «пустым» direct — и почему `direct-out` именно такой

`protocol/direct/outbound.go`:

```go
options.UDPFragmentDefault = true                    // ставится ВСЕГДА каждому direct-outbound
...
isEmpty: reflect.DeepEqual(options.DialerOptions,
         option.DialerOptions{UDPFragmentDefault: true})   // «пусто» = нет НИЧЕГО, кроме авто-флага
```

`isEmpty == true` ⟺ у direct-outbound в конфиге **нет ни одного dial-поля**
(`bind_interface`, `inet4_bind_address`, `routing_mark`, `detour` и т.п.) —
только автоматически выставленный `UDPFragmentDefault`.

Наш `direct-out` ([wizard_template.json:490](../../../app/assets/wizard_template.json)):

```json
{ "type": "direct", "tag": "direct-out" }
```

Ноль dial-полей → **`isEmpty() == true`** → detour на него отвергается. Канонический
голый direct (классика, годами работавшая) теперь по определению «пустой».

### 3. Запрет действует на конечные ноды, а НЕ на DNS (распространённое заблуждение)

Условие в коде — `if !d.legacyDNSDialer`. Логика **обратная** интуиции:

| Кто делает detour на пустой direct | `legacyDNSDialer` | `!flag` | Запрет? |
|---|---|---|---|
| **VLESS / VMess / Trojan / SS / Hysteria2 / TUIC / WireGuard-endpoint …** | `false` | `true` | **🚫 ДА, запрещено** |
| Современный DNS-сервер (`legacy` не задан) | `false` | `true` | 🚫 ДА, запрещено |
| Legacy-DNS-сервер с `"legacy": true` | `true` | `false` | ✅ единственное исключение |

`legacyDNSDialer = true` выставляется **только** в `dns/transport_dialer.go` для
legacy-DNS-серверов. Все конечные ноды зовут `dialer.New(...)` / `NewWithOptions`
без этого флага → `false` → запрет действует. **DNS — единственная амнистированная
категория, конечные ноды — основная мишень запрета.**

### 4. Как именно «разваливается» соединение

Конфиг с `detour: direct-out` **парсится и стартует без ошибок** — поля легальны.
Ошибка не на старте, а в момент первого dial:

1. Диалер ноды — это `DetourDialer`. Первый `DialContext` → лениво (`sync.Once`)
   вызывает `init()`.
2. `init()` видит пустой direct → кэширует `initErr = "detour to an empty direct
   outbound makes no sense"`.
3. `DialContext` возвращает эту ошибку **вместо** соединения:
   ```go
   dialer, err := d.Dialer()
   if err != nil { return nil, err }   // ← каждый dial падает здесь
   ```
4. `sync.Once` ⇒ ошибка закэширована навсегда. **Каждая** последующая попытка
   мгновенно фейлится без обращения к сети.

Итог для пользователя: узел не «отваливается посреди сессии» — он **вообще не
поднимает ни одного коннекта** с самого старта. Для WireGuard-endpoint это
выглядит как `connect to server` → `failed to send handshake initiation`: сокет к
серверу не создан, handshake не уходит, туннель не встаёт (ровно лог из триггера).

### 5. Почему запрет логичен (а не каприз upstream)

Detour означает «установи это соединение **через** указанный outbound». Но пустой
direct — это и есть «прямой выход из текущего сетевого стека». «Соединиться
напрямую через прямой выход» — тавтология: detour не добавляет ни bind, ни mark,
ни цепочки, ничего. Конструкция всегда либо no-op, либо ошибка конфигурации —
upstream выбрал делать её явной ошибкой, чтобы ловить опечатки в цепочках detour.

---

## Рассмотренные альтернативы — и почему их тоже НЕ делаем

Когда стало ясно, что `detour: direct-out` невозможен, рассматривались два обхода.
**Оба отклонены.** Раздел оставлен, чтобы не пришлось проходить тот же путь заново.

### Вариант A (отклонён) — REPLACE на пустой `detour`, без `direct-out`

Технически рабочий обход: пункт «Force direct» = `overrideDetour: ''` +
`replaceDetourChain: true`, а builder в этом случае **удаляет** ключ `detour` из
outbound узла (`main.map.remove('detour')`) вместо проставления `'direct-out'`.
Outbound без `detour` выходит напрямую из своего стека — формально это и есть
«жёсткий прямой выход».

**Почему не делаем:**

- Требует правку builder'а (REPLACE+empty → remove key), новый пункт dropdown,
  новые тесты и regression-guard «никогда не писать `detour: direct-out`». Объём
  работы несоразмерен ценности.
- Семантика «REPLACE + пустая цель» почти неотличима от «None» для пользователя,
  но ведёт себя иначе (выкидывает нативную цепочку) — источник будущей путаницы.
- Реальной потребности, которую закрывал бы этот пункт, не подтверждено. Исходный
  триггер строился на неверном предположении, что `direct-out` форсит прямой
  выход; предположение оказалось ложным, и задача вместе с ним.

### Вариант B (отклонён) — сделать `direct-out` непустым в шаблоне

Дать `direct-out` хотя бы одно dial-поле в
[wizard_template.json](../../../app/assets/wizard_template.json), чтобы
`isEmpty() == false` и detour на него перестал отвергаться.

**Почему не делаем:** меняет смысл базового `direct-out`, который по всему проекту
используется как «чистый прямой выход» (routing/DNS-экраны), и тащит побочные
эффекты на не связанные с задачей подсистемы. Неприемлемо ради одного пункта
dropdown.

---

## Решение по задаче

1. **Исходная реализация (`overrideDetour: 'direct-out'`, `replaceDetourChain: true`)
   — откачена** коммитом `revert(detour)` `6c1d416` (consts/`kDirectOutTag`,
   `setDetourOverride`, пункт dropdown «Force direct-out», тесты §128 удалены).
   Она гарантированно ломала узел.
2. **Фича закрыта как Won't-fix.** Ни исходный `detour: direct-out`, ни Вариант A
   (REPLACE+empty), ни Вариант B (непустой `direct-out`) **не реализуются**.
3. Если в будущем появится подтверждённая потребность в «жёстком прямом выходе» —
   заводить **новую** задачу с нуля, начав с реального юзкейса, а не реанимировать
   §128: его формулировка изначально опиралась на ложное предположение о ядре.

## Acceptance

Нет — фича не делается. Код состояния «без §128» зафиксирован коммитом `6c1d416`
(dropdown узла: только `None (direct)` + список узлов, как до §128).

## NB / источники

- Запрет в ядре: коммит `fb622ccb` "Explicitly reject detour to empty direct
  outbounds" (sing-box-lx, в ветке с 2025-07-08), `common/dialer/detour.go`,
  `protocol/direct/outbound.go`.
- Заблуждение «это запрет только на DNS» — **неверно**: `!legacyDNSDialer` делает
  запрет универсальным для конечных нод; амнистирован только legacy-DNS.
- `direct-out` в нашем шаблоне — голый `{ "type": "direct", "tag": "direct-out" }`
  ([wizard_template.json:490](../../../app/assets/wizard_template.json)),
  `isEmpty() == true`.
