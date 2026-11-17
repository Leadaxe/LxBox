package com.leadaxe.lxbox.vpn

/// §745 — держатель одного лениво создаваемого клиента: создать, только пока
/// [started] истинно, не больше одного экземпляра при гонке; закрыть —
/// идемпотентно, из любого потока. Обобщён по типу клиента, чтобы логику
/// проверял JVM-тест без libbox и Android ([UiCoreSession] подставляет
/// `BoxCommandClient`).
internal class ClientHolder<T : Any>(
    private val started: () -> Boolean,
    private val create: () -> T,
    private val shutdown: (T) -> Unit,
) {
    @Volatile
    var client: T? = null
        private set

    /// Клиент, если он есть или его можно создать ([started]); иначе null.
    /// Создание — под замком с повторной проверкой: два потока не получат два
    /// экземпляра. [create] не блокирует (подключение уходит на полосу).
    fun ensure(): T? {
        client?.let { return it }
        if (!started()) return null
        synchronized(this) {
            client?.let { return it }
            if (!started()) return null
            return create().also { client = it }
        }
    }

    /// Снять клиента и закрыть его. Ссылка обнуляется под замком, [shutdown]
    /// идёт уже без него: он синхронно ходит в ядро и не должен держать
    /// [ensure] главного потока. Повторный вызов — no-op. [run] исполняет
    /// закрытие: по умолчанию — здесь же, в потоке вызывающего.
    fun close(run: (() -> Unit) -> Unit = { it() }) {
        val c = synchronized(this) { client.also { client = null } } ?: return
        run { runCatching { shutdown(c) } }
    }
}

/// §745 — держатель клиента ядра роли UI ([BoxCommandClient]): сторона UI сама
/// создаёт и закрывает свой клиент `command.sock`, сервис о нём не знает.
///
/// [ensure] создаёт клиента и сразу поднимает статус-стрим, если клиента ещё
/// нет и туннель в статусе `Started`. Зовёт `VpnPlugin`: на broadcast
/// `Started` (до передачи события в Dart), при attach движка и в каждом
/// обработчике `cc*` роли UI — страховка от гонки «Dart прочитал `Started`
/// через `getVpnStatus` раньше, чем пришёл broadcast».
///
/// Закрытие — `shutdownAll()` и обнуление. [closeForCoreStop] синхронный: слушатель
/// `CoreSession` «перед закрытием» (поток остановки; клиент должен отключиться
/// до закрытия командного сервера). [closeOffMain] — broadcast `Stopped` и
/// detach движка, оба на главном потоке.
///
/// Пока нет движка Flutter, клиента нет: статус-стрим не тикает в пустоту при
/// старте с плитки или автозапуске.
object UiCoreSession {

    /// Приёмник WARN-строк журнала приложения для клиента UI (сбой
    /// подключения статус-клиента). Журнал ведёт сервис — это остаток общей
    /// памяти между сторонами; назначает `BoxApplication.initUiSide`, чтобы
    /// сторона UI не ссылалась на `BoxService`. null — строка только в logcat.
    @Volatile
    internal var warningSink: ((String) -> Unit)? = null

    /// Старт туннеля (`TunnelState.startedElapsedMs`), для которого сервис уже
    /// начал закрывать командный сервер. Между этим моментом и статусом
    /// `Stopped` статус ещё `Started`, но клиента создавать нельзя: он
    /// подключился бы к закрывающемуся серверу. Новый старт получает новое
    /// время — запрет снимается сам.
    @Volatile
    private var closingStart = -1L

    private val holder = ClientHolder(
        started = {
            val s = TunnelState.snapshot
            s.status == VpnStatus.Started && s.startedElapsedMs != closingStart
        },
        create = {
            BoxCommandClient { text -> warningSink?.invoke(text) }.also { it.startStatus() }
        },
        shutdown = { it.shutdownAll() },
    )

    val client: BoxCommandClient? get() = holder.client

    /// Клиент UI открыт.
    val isUp: Boolean get() = holder.client != null

    fun ensure(): BoxCommandClient? = holder.ensure()

    /// Слушатель `CoreSession` «перед закрытием»: синхронно закрыть клиента и
    /// не создавать нового до следующего старта туннеля.
    fun closeForCoreStop() {
        closingStart = TunnelState.startedElapsedMs
        holder.close()
    }

    /// То же с главного потока: ссылка снимается сразу (следующий [ensure]
    /// создаст нового клиента), а `shutdownAll()` — вызовы в ядро — уходит в
    /// свою нить, как `cancelPing` (§732: главный поток в ядро не ходит).
    fun closeOffMain() = holder.close { task ->
        Thread(task, "lxbox-cc-close").apply { isDaemon = true }.start()
    }
}
