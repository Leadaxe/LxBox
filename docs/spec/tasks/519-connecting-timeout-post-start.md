# 519 — Таймаут `connecting` убивает живой туннель на пост-старте ядра

| Поле | Значение |
|------|----------|
| Статус | **Released в v2.25.3** (24.09.2026). Done (правка таймаута); дедуп — открытый вопрос владельцу |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Коммиты | ветка `task-519` (не в develop) |
| Связанные spec'ы | [`140`](140-force-stop-port-race-and-connecting-timeout.md) (порог введён), [`129`](129-vpnservice-force-stop-on-stuck-core.md) (force-stop на зависшем ядре), [`415`](415-stop-timeout-budget.md) (лестница бюджетов stop), [`279`](../features/279%20localization/spec.md) (`StopReason`), [`250`](250-last-start-error.md) (`lastStartError`) |
| Источник | Демо A–D на эмуляторе 24.09.2026, ДЕФЕКТ 2 |

## Проблема

Фиксированный порог `connecting` = 15с (`app/lib/controllers/home_controller.dart`,
`_defaultConnectingTimeout`) принудительно гасил **уже состоявшийся** туннель.

Ядро успевало всё: `peer(Ypnt…vKi0) - received handshake response`,
`inbound/tun[tun-in]: started at tun1`. Но
`TRACE post-start manager completed (21.48s)` > 15с → `Timeout in connecting,
forcing disconnect` → `forceStopVPN`. `Started` приходил **уже после** убийства.

Снаружи это выглядело как «молча не соединяется»: `last_error` и
`last_start_error` пустые, `core_reject` в `phase: idle`. Ни одного входа демо
(A–D) без обхода не поднялось; обход — Debug API
`POST /action/set-transient-timeout?connecting=240000`, после него туннель
встаёт за 33–90с.

Порога не хватало **даже на конфиг из одного AWG-endpoint'а и одного vless** —
то есть дело не только в медленном эмуляторе.

## Диагностика

### Что такое «post-start manager» — это ЯДРО, не мы

Термин из ядра, не из Kotlin и не из Dart. Стадии старта —
`sing-box-lx/adapter/lifecycle.go:20-46` (`StartStateInitialize` → `Start` →
`PostStart` → `Started`); `"post-start"` — строка `StartStatePostStart.String()`.
Тайминги печатает `LogElapsed` (`adapter/lifecycle.go:111-123`): он ставит
`time.AfterFunc(time.Second, …)` и по завершении пишет
`… completed (N s)`. «manager» в строке — это endpoint-manager.

### Почему пост-старт ЖДЁТ каждый endpoint по очереди

Последовательность — на двух уровнях, оба в ядре:

1. `sing-box-lx/box.go:608` — `adapter.Start(s.ctx, s.logger,
   adapter.StartStatePostStart, s.outbound, …, s.endpoint, …)`, а
   `adapter.Start` (`adapter/lifecycle.go:78-94`) идёт по сервисам **циклом**,
   каждый под своим `LogElapsed`.
2. `sing-box-lx/adapter/endpoint/manager.go:53-61` — внутри endpoint-manager'а
   снова цикл `for _, endpoint := range m.endpoints` под `m.access.Lock()`,
   и каждый endpoint получает `adapter.LegacyStart(endpoint, stage)`
   синхронно. Никакого `task.Group` здесь нет — в отличие от `Close`, где
   параллелизм уже сделан (SPEC 030, `manager.go:82-98`, `Concurrency(8)`).

Итог: стоимость пост-старта = **сумма** по endpoint'ам, а не максимум.

### На какой стадии оказывается работа AWG-узла

`sing-box-lx/transport/wireguard/endpoint.go:282-286`:

```go
func (e *Endpoint) Start(postStart bool) error {
	hasDomainPeer := common.Any(e.peers, func(peer peerConfig) bool {
		return peer.destination.IsDomain()
	})
	if postStart != hasDomainPeer { return nil }
```

Стадия выбирается **одна** из двух — по тому, доменный у peer'а адрес или IP.
В конфиге демо 8 из 11 endpoint'ов имеют доменный peer (`rrtrg.duckdns.org`,
`rrtrs.duckdns.org`) — значит вся их работа попадает **ровно в пост-старт**, и
там же суммируется. Три WARP/WG-узла с IP-peer'ами стартуют на стадии `start`.

### Ядро НЕ ждёт хендшейк и НЕ резолвит DNS на этой стадии

Это главный отрицательный результат — ложный след закрыт:

- **Резолв peer'а ленивый.** `SetEndpointResolver`
  (`transport/wireguard/endpoint.go:378-397`) кладёт замыкание; единственное
  чтение поля — `resolveEndpoints()`
  (`submodules/wireguard-go/device/peer.go:457`), и зовёт его только
  `SendHandshakeInitiation` (`submodules/wireguard-go/device/send.go:221`).
  На горутине `Start` DNS не выполняется никогда.
- **`endpoint=`-строки у доменного peer'а нет вовсе** —
  `peerConfig.GenerateIpcLines` (`transport/wireguard/endpoint.go:625`) пишет её
  только при `c.endpoint.IsValid()`, а у доменного peer'а валиден
  `destination`, не `endpoint`. Значит синхронный `ParseEndpoint` в `IpcSet`
  (`submodules/wireguard-go/device/uapi.go:651`) недостижим.
- **`device.Up()` с горутины `Start` не зовётся.** `Endpoint.Start` лишь кладёт
  `EventUp` в буферизованный канал ёмкости 1
  (`transport/wireguard/device_stack.go:50`, `:187-195`); `Up()` выполняет
  `RoutineTUNEventReader` (`submodules/wireguard-go/device/tun.go:41-44`) —
  асинхронно.
- **gVisor-netstack строится НЕ в `Start`**, а в `NewEndpoint`
  (`transport/wireguard/endpoint.go:203` → `device_stack.go:56` →
  `submodules/sing-tun/stack_gvisor.go:221`) — эта цена приходится на разбор
  конфига.

### Куда же уходят 6.8–9.3с на endpoint

В аллокатор и GC, а не в ожидание. `Endpoint.Start` **раздаёт** работу свежим
горутинам и возвращается, а `LogElapsed` мерит стенные часы, пока те горутины
выедают CPU эмулятора:

- Android-дефолт `IdealBatchSize = 128`
  (`submodules/wireguard-go/conn/conn.go:19`, `bind_std.go:428-431`) при
  `MaxMessageSize = 65535` (`submodules/wireguard-go/device/constants.go:35`,
  `queueconstants_android.go:17`);
- `RoutineReadFromTUN` сразу набивает `batchSize` буферов по 64 КБ
  (`submodules/wireguard-go/device/send.go:418-428`) → **8 МБ**;
- `StdNetBind.Open` отдаёт **две** ReceiveFunc (v4+v6), под каждую
  `RoutineReceiveIncoming` набивает свои 128×64 КБ
  (`submodules/wireguard-go/device/receive.go:99-115`) → **16 МБ**;
- `PreallocatedBuffersPerPool = 4096`
  (`submodules/wireguard-go/device/queueconstants_android.go:18`) — это **кап**
  `WaitPool`, а не предвыделение: пулы холодные, спаны новые.

≈24 МБ крупных аллокаций на endpoint, залпом, на куче того же порядка по нашим
прежним замерам памяти ядра — отсюда
GC-циклы с mark-assist и разброс 6.8–9.3с. Разброс и есть подпись
CPU/GC-голодания: сетевое ожидание кластеризовалось бы у константы (5с
`RekeyTimeout`, 15с `C.TCPTimeout`, 127с SYN).

**Вывод по разделению «наш таймаут мал» vs «ядро медленное из-за X»:** верно
и то и другое, но виноват порог. Ядро не зависает — оно выполняет линейную по
числу endpoint'ов работу, а порог был константой. Оптимизация ядра (параллельный
пост-старт по образцу `Close`, или уменьшение batch-буферов на Android) — отдельная
задача для команды ядра, здесь **не делается**.

## Решение

Выбран **вариант (б): порог зависит от числа endpoint'ов**. Почему не остальные:

- **(а) перезапуск таймера на каждом событии прогресса** — прогресс ядра до Dart
  в нужном виде **не доходит**. Строки `TRACE post-start …` фильтруются на
  нативной стороне: `ClashLogPump` (`app/lib/services/clash_log_pump.dart:22-25`)
  документирует, что TRACE/DEBUG режутся в
  `BoxVpnService.writeDebugMessage` и до Dart не добираются. Чтобы вариант (а)
  заработал, пришлось бы снять нативный фильтр (рост трафика JNI на старте),
  протащить лог-поток из `AppLog`-синглтона в контроллер (новая связность,
  §290-грабля синглтонов в тестах) и завести парсер TRACE-строк ядра как
  контракт. Дорого и хрупко.
- **(в) отдельный порог на пост-старт с индикацией в UI** — требует нового
  состояния фазы от native (`Starting` неделим: у Kotlin нет события «ядро
  закончило start, идёт post-start», см. `BoxService.kt:343` `setStatus(Starting)`
  → `:632` `setStatus(Started)`, между ними ничего). Это Kotlin + новое
  wire-поле + UI. Максимальный риск, минимальная выгода: пользователю всё равно
  показывают «Connecting».
- **(б)** — целиком в Dart, данные уже есть в state, работа ядра **линейна** по
  тому же самому N, что мы считаем. Минимальный риск.

### Что сделано

`app/lib/controllers/home_controller.dart`:

- `_connectingTimeoutPerEndpoint = 10с` — надбавка за endpoint (верхняя граница
  замера 6.8–9.3с с запасом на телефон под нагрузкой);
- `_connectingTimeoutCap = 4 мин` — потолок, чтобы конфиг на сотню endpoint'ов
  не превратил страховку в «никогда»; величина — тот же порядок, на котором
  демо стабильно поднималось через override (240000мс);
- `_configEndpointCount` — число узлов с `kind == 'endpoint'` в
  `_state.configModel` (`ParsedConfig`, `app/lib/models/config_node.dart:193`).
  Это ровно та секция конфига, которую перебирает endpoint-manager ядра;
  vless/hysteria2 живут в `outbounds` и пост-старт не блокируют;
- `_effectiveConnectingTimeout = база + N × надбавка`, ограничено потолком;
- **база 15с сохранена** для случая «ядро молчит» (конфиг без endpoint'ов
  получает в точности прежний порог — регресса §140 нет);
- **Debug-override §140 сохраняет приоритет и отменяет масштабирование**: если
  `_connectingTimeout != _defaultConnectingTimeout`, значение берётся дословно.
  Иначе on-device проверка force-stop'а с `connecting=500` перестала бы
  срабатывать;
- `debugEffectiveConnectingTimeout` — геттер порога и N для тестов/Debug API;
- в лог при постановке таймера пишется
  `[vpn] connecting timeout armed: Nms (endpoints=K)` — чтобы в дампе было
  видно, из чего порог выведен.

### Причина остановки — «молча» больше не бывает

До §519 таймаут писал **только** `lastError` (UI-строка, живёт до первого
`clearError`), а `stopReason`/`lastStartError` оставались пустыми — отсюда
«молча не соединяется» в отчёте демо.

- `app/lib/models/stop_reason.dart` — новый вариант `StopStartTimeout({seconds,
  endpoints})`, текст
  `Start timed out after %1$d s (post-start did not finish, %2$d endpoints)`.
  Число endpoint'ов в тексте обязательно: без него не отличить «ядро зависло»
  от «endpoint'ов больше, чем бюджета».
- `_armTransientTimeout` при `expected == connecting` заполняет `stopReason`,
  `lastStartError` (машинный English, §250), `lastStartErrorAt`, пишет причину в
  `AppLog` и отдаёт её ждущей страховке (фича 478, `_settleStartOutcome`) —
  раньше completer висел до своих 45с.
- Для `stopping` оставлен прежний `ErrKey.connectionTimedOut`: там причина
  «ядро не отдало Stopped», а не арифметика пост-старта.

`StopStartTimeout` **не** производится из `StopReason.fromEvent` — причина
синтезируется приложением, потому что native/ядро в этот момент молчат.

## Риски и edge cases

- **Зависший старт теперь ждут дольше при многих endpoint'ах.** Это осознанный
  обмен: порог — backstop, а не UX-таймер. На конфиге без endpoint'ов (типовой
  vless/hysteria2) поведение не изменилось вовсе.
- **Надбавка 10с — эмпирика с эмулятора.** Замер на телефоне обычно быстрее;
  порог может оказаться щедрее нужного. Лечится числом, не кодом.
- **Потолок 4 мин** при N ≥ 24 endpoint'ов начинает урезать линейный рост — на
  таком конфиге очень медленный старт всё ещё может быть убит. Признано: такие
  конфиги за пределами замеров.
- **Не покрыто:** оптимизация самого ядра (параллельный пост-старт endpoint'ов,
  уменьшение batch-буферов на Android) — задача команде ядра.
- Kotlin **не тронут**.

## Верификация

- `flutter analyze` — `No issues found!`
- Все четыре l10n-чекера с `--strict` — 0 failures, 0 warnings (новая строка
  добавлена в `ru`/`zh` по-английски).
- Новый тест `app/test/controllers/connecting_timeout_endpoints_test.dart` (5
  кейсов): база 15с без endpoint'ов; линейный рост с N и перекрытие замеренных
  21.48с; потолок; приоритет Debug-override; таймаут оставляет `stopReason` +
  `lastStartError`.
- `app/test/models/stop_reason_test.dart` — 3 новых кейса на `StopStartTimeout`.
- Затронутые существующие: `stop_timeout_budget_test.dart`,
  `home_last_start_error_test.dart`, `ui_msg_test.dart` — зелёные.
- **On-device не проверено:** эмулятор на момент задачи занят/в ANR. Ожидаемый
  критерий приёмки владельцем: конфиг демо D поднимается **без**
  `set-transient-timeout`, а в логе видно
  `[vpn] connecting timeout armed: 95000ms (endpoints=8)`.

---

## Открытый вопрос владельцу — дедуп `vpn://` ↔ `amneziawg://` (ДЕФЕКТ 1 демо)

**Правка не делалась**, только разведка: решение сдвигает identity живых узлов,
а критерий владельца запрещает делать это молча.

### Что происходит

Подписка D содержит одни и те же 4 AWG-peer'а дважды — как `vpn://` и как
`amneziawg://`, с **разными именами**. Тело идентично: endpoint, ключи, все
AWG-параметры. Получилось 8 AWG-узлов вместо 4 (плюс 4 vless = 12 вместо 8).

### По чему дедупит LxBox

Ключ дедупа — **тело**, и он корректен:
`app/lib/services/node_hash.dart:189` `nodeDedupSignature(NodeSpec)` —
рекурсивно по цепочке `.chained`, поверх
`legacyNodeIdentityHash` (`node_hash.dart:161`): sha256 от полной канонической
эмиссии узла в sing-box с удалёнными ровно двумя ключами — `tag` и `detour`,
ключи рекурсивно отсортированы. Два узла, различающиеся только именем, дают
одинаковую подпись.

**Но зовут его только два из четырёх парсеров:**

| Ветка | Файл | Дедуп |
|---|---|---|
| Xray JSON | `app/lib/services/parser/json_parsers.dart:291` | **есть** |
| sing-box JSON | `app/lib/services/parser/singbox_config.dart:293` | **есть** |
| URI-строки (`amneziawg://`) | `app/lib/services/parser/parse_all.dart:147` `_parseUriLines` | **нет** |
| INI/Amnezia (`vpn://`) | `app/lib/services/parser/parse_all.dart:173` `_parseIniConfigs` | **нет** |

Обе непокрытые ветки добавляют узел безусловно, guard только на `null`:

```dart
final n = parseUri(l, dropped: verdict);
if (n != null) {
  nodes.add(n);
```

Аккумулятор `seen` создаётся в `parse_all.dart:264` и прокидывается **только** в
JSON-ветки. Структурная причина: дедуп живёт **внутри** двух пер-форматных
парсеров, поэтому третий формат молча выпадает.

Суффикс `-1` — **не** дедуп и **не** identity: это аллокатор тегов сборщика,
`app/lib/services/builder/build_config.dart:941` `allocateTag`, цикл с `i = 1`.
Он лишь разводит коллизию тегов на эмите, ниже по потоку от пропущенного
дедупа. Уникализатор identity — другой, он начинает с `2`
(`node_hash.dart:113`). Наличие `-1` в конфиге доказывает, что коллизию
разрулили на эмите.

### По чему дедупит лаунчер

По телу, **формато-независимо, в едином воронке**:
`singbox-launcher/core/config/subscription/server_conn_key.go:33`
`dedupSignature(*configtypes.ParsedNode)` — тот же контентный хеш
(`LegacyNodeIdentityHashFunc`, `core/config/node_hash.go:48`) плюс путь набора
(`"|via:"` + хеш каждого хопа `node.Chain`, SPEC 120). Применяется в
`bodyParseState.accept` (`core/config/subscription/parse_body.go:512`),
первая запись выигрывает.

Ограничение порядка стадий записано там же дословно
(`parse_body.go:500-503`):

> дедуп ДО тегов, иначе дубль получил бы уникализованный тег и собственную
> идентичность

Это ровно наш режим отказа.

### Почему нельзя просто включить дедуп

Identity узла в LxBox — **уникализованный сырой тег**, то есть ИМЯ
(`node_hash.dart:8-30`, вычисление `sourceNodeIdentities` на `:66`). Тело,
адрес, порт, ключи в identity намеренно **не входят**: провайдер может сменить
адрес под тем же именем — это тот же узел, и отметка «выключен» должна за ним
следовать. Контентный хеш был identity до контракта 0.10.0 и отменён §283.
Identity — ключи `disabledHashes` (`subscription_controller.dart:395`,
`:1852-1864`, codec — `app/lib/models/codec/source_record.dart:70`).

Ловушка: identity — функция **всего выжившего списка** (уникализация X / X-2 /
X-3), поэтому выброс узла может сдвинуть identity его тёзок: узел, бывший `X-2`,
станет `X`, его ключ `disabledHashes` перестанет резолвиться, и отметка
пользователя плюс пер-узловые настройки молча отвяжутся и истекут по TTL.
Миграции identity→identity нет (`migrateLegacyDisabledKeys`,
`node_hash.dart:97`, умеет только 64-hex legacy-ключи).

В **этом** дефекте дубли носят РАЗНЫЕ имена, поэтому identity четырёх
выживших не сдвинется, а ключи потеряют только четыре выброшенных имени —
сравнительно безопасно. Но общего случая это не закрывает.

### Варианты владельцу

1. **Предупреждение без слияния** (предлагается по умолчанию, как
   соответствующее критерию «молча — нельзя»). Дедуп не включаем; при совпадении
   подписи показываем `дубликат узла X` на обоих узлах. Список не меняется,
   identity не двигается, пользователь решает сам. Цена: 8 узлов остаются в
   конфиге, пост-старт по-прежнему вдвое дольше (что после правки таймаута
   больше не ломает соединение).
2. **Включить дедуп по телу в обе URI/INI-ветки** — поднять `seen` в `parseAll`
   (один аккумулятор на тело: `vpn://` и `amneziawg://` приезжают в ОДНОЙ
   подписке, пер-ветковый набор этот случай не закрыл бы). Даёт паритет с
   лаунчером и порядок стадий «дедуп до тегов». Цена: сдвиг identity тёзок в
   общем случае, без пути миграции. Лаунчер решает аналогичную задачу для
   членства в группах через `collapsedInto` (`server_conn_key.go:78`) — LxBox
   потребовался бы эквивалент, чтобы перевязывать, а не выбрасывать.
3. Ничего не делать (зафиксировать как known issue).

### Расхождение счётчика `warnings` vs список — отдельный баг сериализатора

`nodes_count` = 12 **верен**: `app/lib/services/debug/serializers/subs.dart:30`
отдаёт `e.nodeCount`, то есть `nodes.length`.

Баг в `warnings`:
`app/lib/services/debug/serializers/subs.dart:153`

```dart
byTag[n.tag] = [for (final w in n.warnings) serializeNodeWarning(w)];
```

Карта (`subs.dart:152`) ключуется **сырым тегом провайдера** `n.tag`, не
identity и не хешем тела. Поэтому:

- расхождение — это «на уникальный СЫРОЙ ТЕГ» против «на ссылку», **а не** «на
  уникальное тело против на ссылку». В этом демо оба числа совпали случайно
  (дубли тел оказались и единственными дублями тегов) — совпадение не нужно
  закреплять как правило;
- второй дефект той же строки: last-write-wins, предупреждения **раннего**
  дубля молча теряются, а не сливаются;
- doc-комментарий на `subs.dart:150` обещает «Все узлы присутствуют» — нарушено
  при любой коллизии тегов;
- баг **не зависит** от дедупа и переживёт его: останется на легитимных дублях
  тегов (документированный §310-случай, когда провайдер зовёт каждый узел
  `proxy` — `app/lib/services/parser/json_parsers.dart:206`). Починка дедупа
  сделает это чтение 8/8 и **замаскирует** баг.

Правильный ключ — identity (`sourceNodeIdentities`; прецедент —
`app/lib/controllers/subscription_controller/core_reject_ops.dart:82`, `:194`,
`:291`), с оговоркой: identity намеренно нет у group-узлов и узлов с пустым
тегом (`node_hash.dart:57-64`) — им нужен определённый ключ, иначе контракт «все
узлы присутствуют» снова ломается. Текст справки тоже обещает ключ `tag`
(`app/lib/services/debug/handlers/help.dart:733`) — править вместе.
