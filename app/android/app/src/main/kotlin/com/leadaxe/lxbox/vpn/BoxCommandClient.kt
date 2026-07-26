package com.leadaxe.lxbox.vpn

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Connections
import io.nekohasekai.libbox.DnsQuery
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.PoolSlotIterator
import io.nekohasekai.libbox.RuleIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.URLTestOutboundResult
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/// §122 Фаза 0 — нативный канал управления UI↔ядро через libbox `CommandClient`
/// (gRPC поверх `command.sock`), замена Clash API HTTP-петли.
///
/// **Три клиента (§2.8)** — разный lifecycle под реальные нужды (разведано: что
/// работает в фоне vs гасится с экраном):
///  - `statusClient`   — `CommandStatus` + `setStatusInterval`. Foreground пока
///    туннель up; §164 спит в фоне (pauseStatus). NORMAL 0.5с (главный) / FAST
///    0.1с (Stats). Питает скорость в шапке + Stats-счётчики.
///  - `screenClient`   — `CommandOutbounds`+`CommandGroup`+`CommandConnections`.
///    refcount по открытию экрана узлов/stats/conn; §164 спит в фоне (pauseScreen).
///  - `profilerClient` — `CommandConnections` + `CommandDNS` (§261, SPEC 018 v2:
///    DNS-стрим в мультиплексе). connect/disconnect по recording (§048). Живёт в
///    фоне ПОКА идёт запись; DNS авто-реконнектится с клиентом. См. feature 123.
///  - `pingClient`     — голый `PingHandler`, БЕЗ подписок (§175). §209: носитель
///    ВСЕХ unary RPC (urlTestOutbound + getPool/getGroups/getRules + select/
///    close*). lifecycle-НЕзависим — pause не трогает → unary работают в фоне.
///    Поднимается лениво, дисконнект лишь в cancelPing/resync/shutdown.
///
/// **Подписка в gomobile-фасаде** = `CommandClientOptions.addCommand(int)` + колбэки
/// `CommandClientHandler.write*` (НЕ прямые `subscribe*`-методы — их в AAR нет).
///
/// **JNI-no-throw** ([[project_jni_callbacks_must_not_throw]]): КАЖДЫЙ колбэк handler'а
/// обёрнут в try/catch — unchecked exception через JNI = `Runtime::Abort` всего процесса.
///
/// **Эмиттеры** — по образцу `BoxService` core-log drainer: `LinkedBlockingQueue` + cap +
/// drop-newest (не блокируем producer-thread ядра) + single Runnable + main-Handler + batch.
///
/// Sink'и читаются из `BoxVpnService`-companion (`cc*Sink`, @Volatile) — инвариант §2.1:
/// эмиттер живёт во Flutter-процессе.
class BoxCommandClient {

    companion object {
        private const val TAG = "BoxCommandClient"

        /// §163 — интервал status-стрима (наносекунды: `time.Duration(Interval)`
        /// на сервере). ДВЕ частоты + пауза (энергосбережение):
        ///  - FAST (0.1с) — когда открыт Stats-экран (плавная статистика).
        ///  - NORMAL (0.5с) — главный экран (цифра скорости в шапке; 0.5с глазу
        ///    достаточно, в 5× меньше gRPC+IPC+EventChannel-marshal тиков).
        ///  - пауза — в фоне (onAppPaused): statusClient гасится, 0 тиков, 0 drain.
        /// Корень groups:[] был НЕ в интервале (закрыт dedup+stale-guard+getGroups-pull).
        private const val STATUS_INTERVAL_FAST = 100_000_000L   // 1e8 нс = 0.1с
        private const val STATUS_INTERVAL_NORMAL = 500_000_000L  // 5e8 нс = 0.5с

        /// Cap очереди эмиттера — drop-newest при переполнении (producer не блокируется).
        /// Эмиттер coalesce'ит до последнего снапшота, так что cap — страховка.
        private const val QUEUE_MAX = 4096

        private const val RECONNECT_BACKOFF_START_MS = 500L
        private const val RECONNECT_BACKOFF_MAX_MS = 8_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // ───────────────────────── клиенты ─────────────────────────
    private val statusClient = AtomicReference<CommandClient?>(null)
    private val screenClient = AtomicReference<CommandClient?>(null)
    private val profilerClient = AtomicReference<CommandClient?>(null)
    // §175 — ОТДЕЛЬНЫЙ клиент под масс-пинг: свой ctx/conn, чтобы его
    // disconnect() (отмена) рвал per-call ctx тестов (ядро SPEC 015 §3.6,
    // rc.5: disconnect отменяет уже-ушедшие в dial тесты), НЕ задевая
    // status/screen/profiler-стримы. Поднимается лениво под прогон.
    private val pingClient = AtomicReference<CommandClient?>(null)
    // §261 — DNS больше НЕ отдельная подписка: это команда мультиплекса
    // (addCommand(CommandDNS)), приходит через ProfilerHandler.writeDNSQuery,
    // живёт/умирает/реконнектится вместе с profilerClient. Поля dnsSubscription
    // нет — закрывать нечего.

    /// §2.8 reset-синхронизация: каждый connect инкрементит поколение; снапшоты/события
    /// из устаревшего поколения игнорируются (защита от гонки connect/disconnect, §141 P1.2).
    private val statusGen = AtomicInteger(0)
    private val screenGen = AtomicInteger(0)
    private val profilerGen = AtomicInteger(0)

    /// Туннель считается живым — гейтит реконнект statusClient (не дёргать после stop).
    @Volatile
    private var tunnelAlive = false

    // ═══════════════════════ Public lifecycle API ═══════════════════════

    /// §163 — текущий интервал status-стрима (для reconnect-backoff восстановить
    /// ту же частоту). По умолчанию NORMAL (0.5с) — главный экран. @Volatile:
    /// читается/пишется из разных потоков (lifecycle / reconnect).
    @Volatile private var statusIntervalNs = STATUS_INTERVAL_NORMAL

    /// §163 — флаг паузы: в фоне statusClient гашен, реконнект-петля не поднимает.
    @Volatile private var statusPaused = false

    /// Поднять `statusClient`. Вызывать ПОСЛЕ `BoxService.startCommandServer()`
    /// и когда сервис в статусе `Started` (сокет существует только после старта сервера).
    fun startStatus() {
        tunnelAlive = true
        statusPaused = false
        connectStatus()
    }

    fun stopStatus() {
        tunnelAlive = false
        disconnectClient(statusClient, "stopStatus")
    }

    /// §163 — переключить частоту status-стрима (пересоздаёт statusClient с новым
    /// интервалом; gRPC-reconnect дешёвый). FAST=0.1с (Stats открыт), NORMAL=0.5с.
    /// No-op если интервал не изменился или туннель не жив.
    fun setStatusFast(fast: Boolean) {
        val want = if (fast) STATUS_INTERVAL_FAST else STATUS_INTERVAL_NORMAL
        if (statusIntervalNs == want) return
        statusIntervalNs = want
        if (tunnelAlive && !statusPaused) connectStatus()
    }

    /// §163 — пауза в фоне (onAppPaused): гасим statusClient, 0 тиков/0 drain.
    /// Реконнект-петля не поднимает (гейт statusPaused). Идемпотентно.
    fun pauseStatus() {
        if (statusPaused) return
        statusPaused = true
        disconnectClient(statusClient, "pauseStatus")
    }

    /// §163 — возобновить из фона (onAppResumed): поднять statusClient с текущим
    /// интервалом. Идемпотентно. tunnelAlive-гейт: не поднимаем после stop.
    fun resumeStatus() {
        if (!statusPaused) return
        statusPaused = false
        if (tunnelAlive) connectStatus()
    }

    /// §2.8 — `screenClient` поднимается при открытии экрана узлов/stats/connections.
    /// §122 — REF-COUNTED: и главный экран (groups-стрим), и StatsScreen/Connections
    /// — независимые потребители. connectScreen поднимает клиент при ПЕРВОМ
    /// потребителе; disconnectScreen гасит при ПОСЛЕДНЕМ. Без refcount закрытие
    /// StatsScreen гасило бы screenClient, нужный главному экрану.
    private val screenRefs = AtomicInteger(0)

    fun connectScreen() {
        // §164 — в фоне (screenPaused) только считаем потребителя; клиент поднимет
        // resumeScreen на onAppResumed. Иначе подняли бы клиент в фоне зря.
        val wasZero = screenRefs.getAndIncrement() == 0
        if (wasZero && !screenPaused) connectScreenClient()
    }

    fun disconnectScreen() {
        // decrementAndGet с полом 0 (defensive против лишних disconnect).
        val n = screenRefs.updateAndGet { if (it > 0) it - 1 else 0 }
        if (n == 0) disconnectClient(screenClient, "disconnectScreen")
    }

    /// §164 — флаг lifecycle-паузы screenClient (фон). Отличается от refcount=0:
    /// refcount=0 = «потребителей нет» (экран закрыт), pause = «потребитель есть,
    /// но UI в фоне». connectScreen в паузе НЕ поднимает клиент (только refcount++).
    @Volatile private var screenPaused = false

    /// §164 — усыпить screenClient в фоне (onAppPaused). Гасит клиента, НО НЕ
    /// трогает `screenRefs` — экран-потребитель формально жив (открыт, не виден),
    /// при resume восстановим. Идемпотентно.
    fun pauseScreen() {
        if (screenPaused) return
        screenPaused = true
        disconnectClient(screenClient, "pauseScreen")
    }

    /// §164 — возобновить из фона (onAppResumed): поднять screenClient ТОЛЬКО если
    /// есть живые потребители (`screenRefs>0`). Если все экраны закрылись пока были
    /// в фоне — не поднимаем. Идемпотентно.
    fun resumeScreen() {
        if (!screenPaused) return
        screenPaused = false
        if (tunnelAlive && screenRefs.get() > 0) connectScreenClient()
    }

    /// §185 — cold-start Flutter после swipe-keep (туннель жив, движок умер).
    /// Все CC-клиенты PERSISTENT (поля CC на companion → пережили swipe), но
    /// привязаны к МЁРТВЫМ sink'ам прошлого движка; Dart-потребители EPHEMERAL
    /// (умерли с движком). При swipe disconnect/pause НЕ вызвались (Dart мёртв) →
    /// клиенты осиротели, refcount/паузы застряли. Reopen без resync → стримы
    /// привязаны к мёртвому движку → пустой UI (хотя статус-broadcast горит).
    ///
    /// Переподнять ОБА стрим-клиента на свежий движок:
    ///
    /// 1. **screenClient** (groups/connections — главный экран + Stats/Conns):
    ///    `screenRefs` застрял на 1 → новый `connectScreen` дал бы 1→2 →
    ///    `wasZero=false` → клиент НЕ переподнят. Сброс refs=0 + снять паузу +
    ///    закрыть осиротевший → следующий `connectScreen` увидит `refs=0` →
    ///    `wasZero=true` → переподнимет на свежие sink'и → ядро даст стартовый push.
    ///
    /// 2. **statusClient** (трафик/память — И шапка главного, И Stats): НЕ
    ///    refcounted. На cold-start остаётся привязан к мёртвому движку (swipe не
    ///    вызвал pause/disconnect) → ни шапка, ни Stats не получают тики
    ///    (device-факт: скорость ↑↓ в шапке тоже висит, не только память Stats).
    ///    Без resync лечилось лишь сворачиванием→разворачиванием (resumeStatus →
    ///    connectStatus). Форсим `connectStatus()` (минуя ранний return
    ///    setStatusFast) — сам закроет осиротевший, поднимет новый. Сняв паузу.
    ///
    /// ИДЕМПОТЕНТНО и безопасно при ЛЮБОМ старте: первый запуск (refs=0,
    /// клиенты null) — connectStatus поднимет statusClient штатно, screen — no-op
    /// до первого connectScreen, ping — no-op (null). profilerClient чистит
    /// отдельно через handler (VpnPlugin → disconnectProfiler, публичный API).
    ///
    /// Итог cold-start по 4 клиентам:
    ///  - statusClient   — пере-поднят (NORMAL),
    ///  - screenClient   — почищен + пере-поднимется на следующем connectScreen,
    ///  - profilerClient — остановлен+почищен (handler),
    ///  - pingClient     — остановлен+почищен (тут).
    fun resyncForReopen() {
        // screenClient — сброс протухшего refcount + закрыть осиротевший.
        screenRefs.set(0)
        screenPaused = false
        disconnectClient(screenClient, "resyncForReopen")
        // pingClient — мог остаться живым с прошлой сессии (масс-пинг шёл в момент
        // swipe, cancelPing не вызвался). Не подписочный (unary, без sink) — UI не
        // ломает, но висящий gRPC-клиент держит ресурс ядра зря. Чистим.
        disconnectClient(pingClient, "resyncForReopen")
        // statusClient — форс-переподнятие на свежий движок (минуя ранний return
        // setStatusFast). Сбрасываем интервал на NORMAL — дефолт главного экрана.
        // На cold-start ВСЕГДА виден HomeScreen (main.dart: home=HomeScreen, нет
        // restorationScopeId → навигация не восстанавливается) → Stats НЕ
        // смонтирован в момент resync. `statusIntervalNs` мог залипнуть на FAST с
        // прошлой Stats-сессии (поле пережило swipe) → без сброса главный зря
        // тикал бы 0.1с (дренаж). NORMAL корректен. Когда юзер ПОЗЖЕ навигирует
        // на Stats — его initState.setStatusFast(true) увидит NORMAL≠FAST → НЕ
        // выйдет рано → переподнимет на FAST штатно (resync давно отработал, гонки
        // нет). connectStatus сам disconnect'нет старый + connect новый.
        statusPaused = false
        statusIntervalNs = STATUS_INTERVAL_NORMAL
        if (tunnelAlive) connectStatus()
    }

    /// §2.8 — `profilerClient` поднимается при `startGlobalRecording` (§048).
    fun connectProfiler() = connectProfilerClient()
    fun disconnectProfiler() {
        // §261 — DNS в мультиплексе, гаснет с клиентом. Отдельной подписки нет.
        disconnectClient(profilerClient, "disconnectProfiler")
    }

    /// Полный teardown — из `BoxService.doStop`/`closeCommandServerAtomic`.
    fun shutdownAll() {
        tunnelAlive = false
        screenRefs.set(0) // §122 — туннель умер, все экраны логически отвалились
        screenPaused = false // §164 — сброс lifecycle-флагов на teardown
        statusPaused = false
        disconnectClient(statusClient, "shutdownAll")
        disconnectClient(screenClient, "shutdownAll")
        disconnectClient(profilerClient, "shutdownAll")
        disconnectClient(pingClient, "shutdownAll") // §175
        screenAccumulator.set(null)
        profilerAccumulator.set(null)
    }

    // ═══════════════════════ connect helpers ═══════════════════════

    private fun connectStatus() {
        if (statusPaused) return // §163 — в фоне не поднимаем
        val gen = statusGen.incrementAndGet()
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandStatus)
                setStatusInterval(statusIntervalNs) // §163 — NORMAL 0.5с / FAST 0.1с
            }
            val client = CommandClient(StatusHandler(gen), options)
            client.connect()
            statusClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure {
            Log.w(TAG, "connectStatus failed (gen=$gen): ${it.message}")
            scheduleReconnect(RECONNECT_BACKOFF_START_MS) { if (tunnelAlive && !statusPaused) connectStatus() }
        }
    }

    private fun connectScreenClient() {
        val gen = screenGen.incrementAndGet()
        ensureAccumulator(screenAccumulator)
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandOutbounds)
                addCommand(Libbox.CommandGroup)
                addCommand(Libbox.CommandConnections)
            }
            val client = CommandClient(ScreenHandler(gen), options)
            client.connect()
            screenClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure { Log.w(TAG, "connectScreen failed (gen=$gen): ${it.message}") }
    }

    private fun connectProfilerClient() {
        val gen = profilerGen.incrementAndGet()
        ensureAccumulator(profilerAccumulator)
        runCatching {
            // §261 — DNS теперь ЧЛЕН мультиплекса (SPEC 018 v2), рядом с
            // CommandConnections: живёт на общем c.ctx, поднимается/умирает с
            // profilerClient, авто-восстанавливается через Connect() при обрыве
            // (фон/Doze). Отдельной подписки/reconnect-хука больше нет.
            // setDNSIncludeAnswers(true) — CNAME-цепочка (Q3, как includeAnswers).
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandConnections)
                addCommand(Libbox.CommandDNS)
                setDNSIncludeAnswers(true)
            }
            val client = CommandClient(ProfilerHandler(gen), options)
            client.connect()
            profilerClient.getAndSet(client)?.runCatching { disconnect() }
        }.onFailure { Log.w(TAG, "connectProfiler failed (gen=$gen): ${it.message}") }
    }

    private fun disconnectClient(ref: AtomicReference<CommandClient?>, reason: String) {
        ref.getAndSet(null)?.runCatching { disconnect() }
            ?.onFailure { Log.w(TAG, "disconnect($reason) failed: ${it.message}") }
    }

    private fun scheduleReconnect(delayMs: Long, action: () -> Unit) {
        val capped = delayMs.coerceAtMost(RECONNECT_BACKOFF_MAX_MS)
        mainHandler.postDelayed({ runCatching { action() } }, capped)
    }

    // ═══════════════════════ Imperative (unary) ═══════════════════════
    // Прямые методы CommandClient. Дёргаются из VpnPlugin через MethodChannel.
    // Используем любой живой клиент (унарные RPC не зависят от подписок).

    private fun anyClient(): CommandClient? =
        statusClient.get() ?: screenClient.get() ?: profilerClient.get()

    /// §4.6 — per-node delay. ИНВАРИАНТ: `error` — единственный признак провала,
    /// `delay==0 && error==""` = успех 0мс. `timeout` — МИЛЛИСЕКУНДЫ.
    ///
    /// §175 — идёт через ОТДЕЛЬНЫЙ pingClient (лениво поднимается), чтобы
    /// `cancelPing()` мог оборвать in-flight тесты, не задев другие стримы.
    fun urlTestOutbound(tag: String, link: String, timeoutMs: Int): Map<String, Any> {
        val client = ensurePingClient()
            ?: return mapOf("delay" to 0, "error" to "command client not connected")
        return runCatching {
            val r: URLTestOutboundResult = client.urlTestOutbound(tag, link, timeoutMs)
            mapOf("delay" to r.getDelay(), "error" to r.getError())
        }.getOrElse { mapOf("delay" to 0, "error" to (it.message ?: "urlTestOutbound failed")) }
    }

    /// §308 — групповой URLTest: ядро force-тестит ВСЕХ членов группы её
    /// конфиг-URL'ом и делает переселект на живой узел (+interrupt).
    /// Fire-and-forget в ядре (`go CheckOutbounds`): RPC возвращается сразу,
    /// без результатов — новый selected приедет groups-стримом, делеи членов
    /// лягут в history. true = команда принята ядром.
    fun urlTestGroup(tag: String): Boolean {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "urlTestGroup: no command client (paused/down)")
            return false
        }
        return runCatching { client.urlTest(tag); true }
            .getOrElse { Log.w(TAG, "urlTestGroup failed: ${it.message}"); false }
    }

    /// §175/§209 — поднять pingClient лениво. Голый `PingHandler`: подписок нет,
    /// только unary RPC. Свой ctx/conn — disconnect рвёт лишь его вызовы.
    /// Идемпотентно (CAS): возвращает живой если есть.
    ///
    /// §209 — это ЕДИНСТВЕННЫЙ lifecycle-независимый клиент: `pauseStatus`/
    /// `pauseScreen` (фон, §164) его НЕ трогают. Поэтому ВСЕ unary RPC
    /// (urlTestOutbound + getPool/getGroups/getRules + select/close*) идут через
    /// него — работают и когда приложение в фоне. Дисконнект только в `cancelPing`
    /// / `resyncForReopen` / `shutdownAll` (явные события, не lifecycle-парковка).
    private fun ensurePingClient(): CommandClient? {
        pingClient.get()?.let { return it }
        return runCatching {
            val options = CommandClientOptions() // подписок нет — unary RPC
            val client = CommandClient(PingHandler(), options)
            client.connect()
            if (pingClient.compareAndSet(null, client)) client
            else { client.runCatching { disconnect() }; pingClient.get() }
        }.getOrElse { Log.w(TAG, "ensurePingClient failed: ${it.message}"); null }
    }

    /// §175 — отмена масс-пинга: disconnect pingClient → ядро отменяет per-call
    /// ctx уже-ушедших в dial тестов (SPEC 015 §3.6, rc.5), in-flight рвутся, не
    /// дожидаясь TCPTimeout. status/screen/profiler-стримы целы (другие клиенты).
    /// Следующий urlTestOutbound поднимет свежий pingClient (ensurePingClient).
    fun cancelPing() {
        disconnectClient(pingClient, "cancelPing")
    }

    /// §4.7 — снапшот route+DNS правил (только для диагностики).
    /// §209 — через ensurePingClient (lifecycle-независим). `null` = клиент
    /// недоступен, `[]` = правил нет.
    fun getRules(): List<Map<String, Any>>? {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "getRules: no command client (paused/down)")
            return null
        }
        return runCatching {
            val out = ArrayList<Map<String, Any>>()
            val it: RuleIterator = client.getRules()
            while (it.hasNext()) {
                val r = it.next()
                out.add(mapOf(
                    "type" to r.getType(),
                    "payload" to r.getPayload(),
                    "action" to r.getAction(),
                    "isDNS" to r.getIsDNS(),
                ))
            }
            out
        }.getOrElse {
            Log.w(TAG, "getRules RPC failed: ${it.message}")
            null
        }
    }

    /// §122/SPEC015 — unary pull-снапшот групп. Закрывает дыру pull-vs-push:
    /// если стартовый `SubscribeGroups`-push не доехал (гонка waitForStarted —
    /// сервис не STARTED в момент подписки) или порвался, перечитать дерево групп
    /// больше нечем (push-only). Формат Map ИДЕНТИЧЕН writeGroups (общий
    /// `serializeGroup`) → Dart-парсер один. null ≠ пустой список: null = «не
    /// смогли прочитать», []=«групп нет» (не трогаем state).
    ///
    /// §209 — через `ensurePingClient()` (НЕ anyClient): pingClient
    /// lifecycle-независим (не паркуется в фоне §164) → pull работает и в фоне.
    fun getGroups(): List<Map<String, Any>>? {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "getGroups: no command client (paused/down)")
            return null
        }
        return runCatching {
            val out = ArrayList<Map<String, Any>>()
            val it: OutboundGroupIterator = client.getGroups()
            while (it.hasNext()) out.add(serializeGroup(it.next()))
            out
        }.getOrElse {
            // не-STARTED / транспорт — НЕ ошибка приложения, просто пока нет данных.
            Log.d(TAG, "getGroups unavailable: ${it.message}")
            null
        }
    }

    /// §208 (SPEC 019 V2) — unary snapshot пула round_robin-группы. Возвращает
    /// слоты `[{slot, tag, delay}]`. Не-round_robin группа (selector/least_test/
    /// urltest без balancer) → ПУСТОЙ список (не ошибка). `delay` мс, `0`=мёртвая
    /// /не измерена (живая всегда ≥1, ядро клампит).
    ///
    /// §209 — идёт через `ensurePingClient()` (НЕ anyClient): pingClient
    /// lifecycle-независим (не паркуется в фоне §164), значит /pool и UI-попап
    /// работают и когда приложение в фоне. КОНТРАКТ: `null` = клиент недоступен
    /// (туннель down / RPC-фейл), `[]` = пул пуст (группа не round_robin / нет
    /// данных). Caller различает «недоступно» от «пусто».
    /// §312 (kernel SPEC 035) — unary снапшот состояния DNS-групп (тип
    /// сервера `group`, SPEC 033): по группе mode/current + члены с
    /// clean/liveErrors/возрастом ошибки/liveWins/current/lastRtt.
    /// null = недоступен (down/paused/не-STARTED/ядро без метода);
    /// [] = групп в конфиге нет. Через незасыпающий pingClient (§209).
    fun getDnsGroups(): List<Map<String, Any>>? {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "getDnsGroups: no command client (paused/down)")
            return null
        }
        return runCatching {
            val out = ArrayList<Map<String, Any>>()
            val it = client.getDNSGroups()
            while (it.hasNext()) {
                val g = it.next()
                val members = ArrayList<Map<String, Any>>()
                val mi = g.members()
                while (mi.hasNext()) {
                    val m = mi.next()
                    members.add(mapOf(
                        "tag" to m.tag,
                        "serverType" to m.serverType,
                        "clean" to m.clean,
                        "liveErrors" to m.liveErrors,
                        "lastErrorAgeMs" to m.lastErrorAgeMs,
                        "liveWins" to m.liveWins,
                        "current" to m.current,
                        // gomobile: RTT капитализирован (getLastRTTMs)
                        "lastRttMs" to m.lastRTTMs,
                    ))
                }
                out.add(mapOf(
                    "tag" to g.tag,
                    "mode" to g.mode,
                    "current" to g.current,
                    "members" to members,
                ))
            }
            out
        }.getOrElse {
            // не-STARTED / Unimplemented — НЕ ошибка приложения.
            Log.d(TAG, "getDnsGroups unavailable: ${it.message}")
            null
        }
    }

    /// §311 (kernel SPEC 036) — unary снапшот конфига РАБОТАЮЩЕГО ядра:
    /// канонический re-marshal запущенных options, захвачен ядром один раз на
    /// старте, отдача — копия строки. null = недоступен: клиент down/paused,
    /// ядро не-STARTED (FailedPrecondition), attached-путь (Unavailable),
    /// сборка без with_lx_command (Unimplemented), ядро < lx.16-rc.3
    /// (нет метода). Через незасыпающий pingClient (§209) — отдаёт и в фоне.
    fun getRunningConfig(): String? {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "getRunningConfig: no command client (paused/down)")
            return null
        }
        return runCatching {
            client.getRunningConfig().takeIf { it.isNotEmpty() }
        }.getOrElse {
            // не-STARTED / старое ядро — НЕ ошибка приложения.
            Log.d(TAG, "getRunningConfig unavailable: ${it.message}")
            null
        }
    }

    fun getPool(tag: String): List<Map<String, Any>>? {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "getPool: no command client (paused/down)")
            return null
        }
        return runCatching {
            val out = ArrayList<Map<String, Any>>()
            val it: PoolSlotIterator = client.getPool(tag)
            while (it.hasNext()) {
                val s = it.next()
                out.add(mapOf(
                    "slot" to s.slot,
                    "tag" to s.tag,
                    "delay" to s.delay,
                ))
            }
            out
        }.getOrElse {
            Log.w(TAG, "getPool RPC failed: ${it.message}")
            null
        }
    }

    /// §223 Часть B (#23) — native-fallback подтекста уведомления, когда UI не
    /// открывался (старт с QS-плитки → нет Flutter-движка → Dart лейбл не
    /// прислал). Один unary-pull `getGroups()` (через ensurePingClient —
    /// lifecycle-независим, БЕЗ подписки): читаем «главную» группу и её
    /// выбранную ноду, возвращаем готовую строку «<группа>: <нода>».
    ///
    /// Повторяет логику выбора selectedGroup из home_controller.dart:807
    /// (Dart-источник): исключить GLOBAL → взять route.final если он валидный
    /// selector, иначе первую группу. `null` = групп нет / RPC не удался
    /// (caller оставит статусный fallback "Connected"). Ловит ТОЛЬКО начальную
    /// ноду — последующее URLTest-переключение без UI вне скоупа (нет фонового
    /// подписчика по энергомодели).
    fun selectedNodeLabel(configRaw: String): String? {
        val groups = getGroups() ?: return null
        val selectors = groups.filter { (it["tag"] as? String) != "GLOBAL" }
        if (selectors.isEmpty()) return null

        val finalTag = routeFinalTag(configRaw)
        val group = selectors.firstOrNull { (it["tag"] as? String) == finalTag }
            ?: selectors.first()

        val groupTag = group["tag"] as? String ?: return null
        val node = (group["selected"] as? String).orEmpty()
        return if (node.isNotEmpty()) "$groupTag: $node" else groupTag
    }

    /// Разбор route.final из сырого конфига — эквивалент Dart
    /// RouteConfig.finalTag (config/route_config.dart). org.json надёжнее regex.
    private fun routeFinalTag(configRaw: String): String? = runCatching {
        org.json.JSONObject(configRaw)
            .optJSONObject("route")
            ?.optString("final")
            ?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    /// Сериализация одной группы в Map — единый формат для push (writeGroups) и
    /// pull (getGroups). Менять формат — только здесь.
    private fun serializeGroup(g: OutboundGroup): Map<String, Any> {
        val items = ArrayList<Map<String, Any>>()
        val gi = g.getItems()
        while (gi.hasNext()) {
            val item = gi.next()
            items.add(mapOf(
                "tag" to item.tag,
                "type" to item.type,
                "urlTestDelay" to item.urlTestDelay,
                "urlTestTime" to item.urlTestTime,
            ))
        }
        return mapOf(
            "tag" to g.getTag(),
            "type" to g.getType(),
            "selectable" to g.getSelectable(),
            "selected" to g.getSelected(),
            "isExpand" to g.getIsExpand(),
            "items" to items,
        )
    }

    // §209 — действия через ensurePingClient (lifecycle-независим). Команда
    // применяется в ЯДРЕ (оно одно) → подписки screen/profiler-клиентов увидят
    // результат через свои стримы. anyClient давал тихий `true` при null-клиенте
    // (`?.` пропускал вызов, но `; true` срабатывал) — теперь честный false + лог.
    fun selectOutbound(group: String, tag: String): Boolean {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "selectOutbound: no command client (paused/down)")
            return false
        }
        return runCatching { client.selectOutbound(group, tag); true }
            .getOrElse { Log.w(TAG, "selectOutbound failed: ${it.message}"); false }
    }

    fun closeConnection(id: String): Boolean {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "closeConnection: no command client (paused/down)")
            return false
        }
        return runCatching { client.closeConnection(id); true }
            .getOrElse { Log.w(TAG, "closeConnection failed: ${it.message}"); false }
    }

    fun closeConnections(): Boolean {
        val client = ensurePingClient() ?: run {
            Log.w(TAG, "closeConnections: no command client (paused/down)")
            return false
        }
        return runCatching { client.closeConnections(); true }
            .getOrElse { Log.w(TAG, "closeConnections failed: ${it.message}"); false }
    }

    // ═══════════════════════ Native Connections accumulators ═══════════════════════
    // §3.2 — connections приходят ДЕЛЬТАМИ (writeConnectionEvents), не снапшотом.
    // Аккумулятор держится в Kotlin, эмитит в Dart полный снапшот.
    //
    // §170 — ОТДЕЛЬНЫЙ Connections на КАЖДЫЙ клиент (screen / profiler). Раньше
    // был ОДИН общий → screenClient и profilerClient (оба на CommandConnections)
    // дёргали `applyEvents`/`filterState`/`iterator` одного `Connections` из ДВУХ
    // независимых gRPC-горутин ядра → ядро падало `fatal error: concurrent map
    // iteration and map write` (libbox command_types.go:170, ApplyEvents по
    // connectionMap без мьютекса) → SIGABRT, весь процесс. Два аккумулятора =
    // две независимые map = горутины не пересекаются, гонки нет. Оба эмитят в
    // один ccConnectionsSink (Dart broadcast, SnapshotEmitter coalesce'ит дубль
    // когда Stats+Live открыты разом — безвредно).
    private val screenAccumulator = AtomicReference<Connections?>(null)
    private val profilerAccumulator = AtomicReference<Connections?>(null)

    private fun ensureAccumulator(ref: AtomicReference<Connections?>) {
        if (ref.get() == null) {
            runCatching { ref.compareAndSet(null, Connections()) }
                .onFailure { Log.w(TAG, "ensureAccumulator failed: ${it.message}") }
        }
    }

    // ═══════════════════════ Handlers ═══════════════════════
    // Базовый no-op handler — все 11 колбэков в try/catch fail-safe. Конкретные
    // клиенты переопределяют только нужные write*.

    private abstract inner class BaseHandler(protected val gen: Int) : CommandClientHandler {
        override fun connected() { runCatching { Log.d(TAG, "connected gen=$gen") } }
        override fun disconnected(message: String) {
            runCatching { Log.d(TAG, "disconnected gen=$gen: $message") }
        }
        override fun clearLogs() { runCatching { } }
        override fun setDefaultLogLevel(level: Int) { runCatching { } }
        override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) { runCatching { } }
        override fun updateClashMode(newMode: String?) { runCatching { } }
        override fun writeLogs(messageList: LogIterator?) { runCatching { } }
        override fun writeStatus(message: StatusMessage?) { runCatching { } }
        override fun writeGroups(groups: OutboundGroupIterator?) { runCatching { } }
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) { runCatching { } }
        override fun writeConnectionEvents(message: ConnectionEvents?) { runCatching { } }
        // §261 — CommandClientHandler расширен writeDNSQuery. Только ProfilerHandler
        // слушает DNS реально; остальные (status/screen/ping) — no-op.
        override fun writeDNSQuery(query: DnsQuery?) { runCatching { } }
    }

    /// statusClient — только writeStatus + реконнект на disconnected.
    private inner class StatusHandler(gen: Int) : BaseHandler(gen) {
        override fun disconnected(message: String) {
            runCatching {
                Log.d(TAG, "status disconnected gen=$gen: $message")
                if (gen == statusGen.get() && tunnelAlive) {
                    scheduleReconnect(RECONNECT_BACKOFF_START_MS) { if (tunnelAlive) connectStatus() }
                }
            }
        }

        override fun writeStatus(message: StatusMessage?) {
            runCatching {
                if (gen != statusGen.get()) return  // устаревшее поколение
                val m = message ?: return
                if (BoxVpnService.ccStatusSink == null) return
                val snap = HashMap<String, Any>(10)
                snap["uplink"] = m.getUplink()
                snap["downlink"] = m.getDownlink()
                snap["uplinkTotal"] = m.getUplinkTotal()
                snap["downlinkTotal"] = m.getDownlinkTotal()
                snap["memory"] = m.getMemory()
                snap["goroutines"] = m.getGoroutines()
                snap["connectionsIn"] = m.getConnectionsIn()
                snap["connectionsOut"] = m.getConnectionsOut()
                statusEmitter.offer(snap)
            }.onFailure { Log.w(TAG, "writeStatus failed: ${it.message}") }
        }
    }

    /// screenClient — outbounds (плоский node-list) + groups (дерево) + connections.
    private inner class ScreenHandler(gen: Int) : BaseHandler(gen) {
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) {
            runCatching {
                if (gen != screenGen.get()) return
                val it = outbounds ?: return
                if (BoxVpnService.ccOutboundsSink == null) return
                val list = ArrayList<Map<String, Any>>()
                while (it.hasNext()) {
                    val item = it.next()
                    list.add(mapOf(
                        "tag" to item.getTag(),
                        "type" to item.getType(),
                        "urlTestDelay" to item.getURLTestDelay(),
                        "urlTestTime" to item.getURLTestTime(),
                    ))
                }
                outboundsEmitter.offer(list)
            }.onFailure { Log.w(TAG, "writeOutbounds failed: ${it.message}") }
        }

        override fun writeGroups(groups: OutboundGroupIterator?) {
            runCatching {
                if (gen != screenGen.get()) return
                val it = groups ?: return
                if (BoxVpnService.ccGroupsSink == null) return
                val list = ArrayList<Map<String, Any>>()
                while (it.hasNext()) list.add(serializeGroup(it.next()))
                groupsEmitter.offer(list)
            }.onFailure { Log.w(TAG, "writeGroups failed: ${it.message}") }
        }

        override fun writeConnectionEvents(message: ConnectionEvents?) {
            applyConnectionEvents(message, screenGen, gen, screenAccumulator)
        }
    }

    /// profilerClient — только connections (для §048 per-app live).
    /// §261 — profilerClient слушает connections И DNS через мультиплекс
    /// (оба — команды в options). writeConnectionEvents — дельты соединений;
    /// writeDNSQuery — per-event DNS-резолв (SPEC 018 v2), тело 1:1 из бывшего
    /// DnsHandler.onQuery. JNI-no-throw (§050/§151): body в runCatching.
    private inner class ProfilerHandler(gen: Int) : BaseHandler(gen) {
        override fun writeConnectionEvents(message: ConnectionEvents?) {
            applyConnectionEvents(message, profilerGen, gen, profilerAccumulator)
        }

        override fun writeDNSQuery(query: DnsQuery?) {
            runCatching {
                val q = query ?: return
                if (BoxVpnService.ccDnsQueriesSink == null) return
                // §180 — processInfo: атрибуция к приложению ИЗ ЯДРА (не connId-сшивка).
                var pkg = ""
                var processPath = ""
                runCatching {
                    val pi = q.getProcessInfo()
                    if (pi != null) {
                        processPath = pi.getProcessPath() ?: ""
                        val pkgIt = pi.packageNames()
                        if (pkgIt != null && pkgIt.hasNext()) pkg = pkgIt.next() ?: ""
                    }
                }
                // §180 — answers[] (Q3): ВЕСЬ response.Answer (CNAME-hops + A/AAAA),
                // включён через setDNSIncludeAnswers(true). Итератор как chain().
                val answers = ArrayList<Map<String, Any>>()
                runCatching {
                    val it = q.answers()
                    while (it != null && it.hasNext()) {
                        val a = it.next() ?: continue
                        answers.add(mapOf(
                            "name" to a.getName(),
                            "type" to a.getType(),
                            "rdata" to a.getRData(),
                            "ttl" to a.getTTL(),
                        ))
                    }
                }
                // rc.10 — DNS-сервер + тип (какой сервер резолвил, на всех путях
                // вкл. провалы). Имена с DNS заглавными (gomobile-нейминг).
                var dnsServer = ""
                var dnsServerType = ""
                runCatching {
                    dnsServer = q.getDNSServer() ?: ""
                    dnsServerType = q.getDNSServerType() ?: ""
                }
                // rc.10 — outbound() = StringIterator (как chain()/detour()):
                // канал DNS-сервера, селектор развёрнут в активный узел. Пусто на
                // cached. Шлём списком (Dart соберёт outboundChain).
                val outbound = ArrayList<String>()
                runCatching {
                    val it = q.outbound()
                    while (it != null && it.hasNext()) {
                        val s = it.next() ?: continue
                        if (s.isNotEmpty()) outbound.add(s)
                    }
                }
                // §315 (kernel SPEC 035) — трасса DNS-группы: через какую группу
                // шёл запрос, хронология проб (кто опрошен, исход, RTT), был ли
                // веер и режим выживания. Каждый блок в своём runCatching: старое
                // ядро без этих полей не должно ронять весь эмит события.
                val groupPath = ArrayList<String>()
                runCatching {
                    val it = q.groupPath()
                    while (it != null && it.hasNext()) {
                        val s = it.next() ?: continue
                        if (s.isNotEmpty()) groupPath.add(s)
                    }
                }
                val attempts = ArrayList<Map<String, Any>>()
                runCatching {
                    val it = q.attempts()
                    while (it != null && it.hasNext()) {
                        val a = it.next() ?: continue
                        attempts.add(mapOf(
                            "server" to a.server,
                            "serverType" to a.serverType,
                            "outcome" to a.outcome,
                            // gomobile: RTT капитализирован (getRTTMs)
                            "rttMs" to a.rttMs,
                        ))
                    }
                }
                var fanned = false
                var survival = false
                runCatching {
                    fanned = q.fanned
                    survival = q.survival
                }
                // §180 — rcode КАК ЕСТЬ (Q1): getRcode() signed int. -1 = «нет
                // ответа» (timeout), физически ≠ 65535. НЕ конвертим — Dart мапит
                // rcode==-1 ДО toUInt.
                dnsQueriesEmitter.offer(mapOf(
                    "domain" to q.getDomain(),
                    "queryType" to q.getQueryType(),
                    "rcode" to q.getRcode(),
                    "ttl" to q.getTTL(),
                    "source" to q.getSource(),
                    "failed" to q.getFailed(),
                    "error" to q.getError(),
                    "packageName" to pkg,
                    "processPath" to processPath,
                    "dnsServer" to dnsServer,
                    "dnsServerType" to dnsServerType,
                    "outbound" to outbound,
                    "answers" to answers,
                    // §315 — трасса группы (пусто/false на не-групповых путях)
                    "groupPath" to groupPath,
                    "attempts" to attempts,
                    "fanned" to fanned,
                    "survival" to survival,
                ))
            }.onFailure { Log.w(TAG, "writeDNSQuery failed: ${it.message}") }
        }
    }

    /// §175 — pingClient: подписок нет, только unary `urlTestOutbound`. Все
    /// колбэки — no-op из BaseHandler (fail-safe try/catch).
    private inner class PingHandler : BaseHandler(0)

    /// §3.2 — применить дельты к аккумулятору, эмитить снапшот. getReset()=replace.
    ///
    /// КРИТИЧНО (§122): `ConnectionEvents` — это ДЕЛЬТА между вызовами. Аккумулятор
    /// ОБЯЗАН применять КАЖДОЕ событие по порядку, иначе рассинхрон навсегда.
    /// Раньше тут стоял ранний `if (ccConnectionsSink == null) return` — он
    /// отбрасывал дельты, пока никто в Dart не слушал `connections` (главный
    /// экран слушает только status+groups, НЕ connections). Симптом: главный
    /// видит N соединений (из status), а Stats при открытии — 0/мало, потому что
    /// все «created»-дельты до подписки были потеряны и аккумулятор пуст.
    /// Фикс: накапливать ВСЕГДА (пока screenClient жив), эмитить — только если
    /// есть Dart-подписчик (sink). Тогда Stats при подписке получит ПОЛНЫЙ снапшот.
    private fun applyConnectionEvents(
        message: ConnectionEvents?,
        genRef: AtomicInteger,
        gen: Int,
        accRef: AtomicReference<Connections?>,
    ) {
        runCatching {
            if (gen != genRef.get()) return
            val events = message ?: return
            val acc = accRef.get() ?: run { ensureAccumulator(accRef); accRef.get() } ?: return
            // applyEvents учитывает getReset() внутри (replace при reset). ВСЕГДА —
            // даже без Dart-подписчика, иначе пропуск дельты ломает аккумулятор.
            acc.applyEvents(events)
            // §176 — FilterState(ALL): отдаём ВСЁ, что знает ядро — живые И
            // закрытые (closedAt>0). Раньше Active резал closed-фазу ДО эмита →
            // коротко-живущий conn (open+close в одном applyEvents-батче)
            // отфильтровывался как ClosedAt!=0 → Dart его вообще не видел (ни
            // open, ни close) → профайлер терял короткие соединения.
            // Политику показа теперь владеет КАЖДЫЙ Dart-потребитель:
            //   profiler — берёт всё (closed = tcpClose-событие);
            //   ConnectionsView — closedAt>0 напрямую (было: seenIds-diff);
            //   Stats — фильтрует closedAt==0 (срез активных).
            // Памяти не растит: ядро эвиктит closed через closedConnectionMaxAge
            // (5 мин, evictClosedConnections внутри ApplyEvents). §170-риск не
            // растёт — TTL ограничивает map ядра, не наш acc.
            acc.filterState(Libbox.ConnectionStateAll.toInt())
            // Эмиссия в Dart — только если кто-то слушает. Накопление выше уже
            // случилось; §193 — re-emit при подписке отдаёт накопленное новому
            // подписчику (см. reEmitScreenConnections), закрывая потерю стартового
            // reset-снапшота (connections — single-shot, pull в ядре нет).
            if (BoxVpnService.ccConnectionsSink == null) return
            connectionsEmitter.offer(serializeConnections(acc))
        }.onFailure { Log.w(TAG, "applyConnectionEvents failed: ${it.message}") }
    }

    /// §193 — сериализация аккумулятора Connections в список Map для Dart. Единый
    /// код для applyConnectionEvents (дельты) и reEmitScreenConnections (подписка).
    private fun serializeConnections(acc: Connections): List<Map<String, Any>> {
        val list = ArrayList<Map<String, Any>>()
        val it = acc.iterator()
        while (it.hasNext()) {
            val c = it.next()
            // §122 — ProcessInfo (app-attribution): package для иконки +
            // processPath. getProcessInfo() может быть null/кинуть — best-effort.
            var pkg = ""
            var processPath = ""
            runCatching {
                val pi = c.getProcessInfo()
                if (pi != null) {
                    processPath = pi.getProcessPath() ?: ""
                    val pkgIt = pi.packageNames()
                    if (pkgIt != null && pkgIt.hasNext()) pkg = pkgIt.next() ?: ""
                }
            }
            // §174 — outbound-цепочка (Clash `chains`): только через итератор
            // `chain()` (selector→urltest→node). best-effort.
            val chains = ArrayList<String>()
            runCatching {
                val chainIt = c.chain()
                while (chainIt != null && chainIt.hasNext()) {
                    chainIt.next()?.let { chains.add(it) }
                }
            }
            // §178 — detour-хвост (ядро SPEC 017): chain()=роутинг, detour()=транспорт
            // (node→WARP). Полный физ.путь = chain[0] ⊕ detour. best-effort.
            val detours = ArrayList<String>()
            runCatching {
                val detourIt = c.detour()
                while (detourIt != null && detourIt.hasNext()) {
                    detourIt.next()?.let { detours.add(it) }
                }
            }
            // uplink/downlink = НАКОПЛЕННЫЙ итог (Total), не дельта за тик.
            list.add(mapOf(
                "id" to c.getID(),
                "network" to c.getNetwork(),
                "domain" to c.getDomain(),
                "destination" to c.getDestination(),
                "rule" to c.getRule(),
                "uplink" to c.getUplinkTotal(),
                "downlink" to c.getDownlinkTotal(),
                "uplinkDelta" to c.getUplink(),
                "downlinkDelta" to c.getDownlink(),
                "outbound" to c.getOutbound(),
                "outboundType" to c.getOutboundType(),
                "protocol" to c.getProtocol(),
                "chains" to chains,
                "detours" to detours,
                "packageName" to pkg,
                "processPath" to processPath,
                "createdAt" to c.getCreatedAt(),
                "closedAt" to c.getClosedAt(),
            ))
        }
        return list
    }

    /// §193 — переэмитить текущий screenAccumulator новому connections-подписчику.
    /// Зовётся из VpnPlugin.onListen (connections-канал) при появлении sink.
    /// Закрывает корень: connections — single-shot reset-снапшот от ядра (pull
    /// в libbox нет), и при повторном открытии Stats screenClient НЕ
    /// пересоздаётся (refcount>0) → нового reset нет. Накопленный acc жив —
    /// отдаём его сразу. Идемпотентно: пустой/null acc → пустой list, безопасно.
    fun reEmitScreenConnections() {
        runCatching {
            val acc = screenAccumulator.get() ?: return
            connectionsEmitter.offer(serializeConnections(acc))
        }.onFailure { Log.w(TAG, "reEmitScreenConnections failed: ${it.message}") }
    }

    // ═══════════════════════ Emitters (по образцу core-log drainer) ═══════════════════════

    private val statusEmitter = SnapshotEmitter { BoxVpnService.ccStatusSink }
    private val outboundsEmitter = SnapshotEmitter { BoxVpnService.ccOutboundsSink }
    private val groupsEmitter = SnapshotEmitter { BoxVpnService.ccGroupsSink }
    private val connectionsEmitter = SnapshotEmitter { BoxVpnService.ccConnectionsSink }
    // §180 — DNS: событийный (НЕ coalesce), батч-доставка.
    private val dnsQueriesEmitter = EventEmitter { BoxVpnService.ccDnsQueriesSink }

    /// Дросселированный эмиттер: queue + drop-newest + single Runnable + main-Handler + batch.
    /// Для status/outbounds/groups/connections эмитим ПОСЛЕДНИЙ снапшот (coalesce —
    /// промежуточные не нужны, UI рисует актуальное). sink.success на main-looper.
    private inner class SnapshotEmitter(private val sinkProvider: () -> EventChannel.EventSink?) {
        private val queue = LinkedBlockingQueue<Any>()
        private val scheduled = AtomicBoolean(false)

        fun offer(snapshot: Any) {
            // coalesce: держим только последний снапшот (drop старые).
            // §219 — после clear() размер всегда 0, проверка QUEUE_MAX была
            // избыточна (в отличие от EventEmitter.offer без предварит. clear).
            queue.clear()
            queue.offer(snapshot)
            if (scheduled.compareAndSet(false, true)) {
                mainHandler.post(drainer)
            }
        }

        private val drainer = Runnable {
            scheduled.set(false)
            val sink = sinkProvider() ?: run { queue.clear(); return@Runnable }
            val latest = queue.poll() ?: return@Runnable
            queue.clear()
            runCatching { sink.success(latest) }
                .onFailure { Log.w(TAG, "emitter sink.success failed: ${it.message}") }
        }
    }

    /// §180 — событийный эмиттер для DNS: НЕ coalesce (в отличие от SnapshotEmitter,
    /// который держит только последний снапшот). DNS-события дискретны — потеря
    /// промежуточного резолва = пропавший домен в Live. Копим в очереди, drain
    /// отдаёт БАТЧ списком (sink.success(List<Map>)), главный-Handler как у снапшота.
    /// drop-newest при переполнении QUEUE_MAX (наблюдатель, не аудит — как буфер
    /// observable ядра 256). Контракт sink: Dart-сторона разворачивает список.
    private inner class EventEmitter(private val sinkProvider: () -> EventChannel.EventSink?) {
        private val queue = LinkedBlockingQueue<Any>()
        private val scheduled = AtomicBoolean(false)

        fun offer(event: Any) {
            if (queue.size < QUEUE_MAX) queue.offer(event)
            if (scheduled.compareAndSet(false, true)) {
                mainHandler.post(drainer)
            }
        }

        private val drainer = Runnable {
            scheduled.set(false)
            val sink = sinkProvider() ?: run { queue.clear(); return@Runnable }
            val batch = ArrayList<Any>()
            queue.drainTo(batch)
            if (batch.isEmpty()) return@Runnable
            runCatching { sink.success(batch) }
                .onFailure { Log.w(TAG, "dns emitter sink.success failed: ${it.message}") }
        }
    }
}
