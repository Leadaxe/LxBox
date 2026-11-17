package com.leadaxe.lxbox.vpn

/// §745 — держатель одного лениво создаваемого клиента: создать, только пока
/// [started] истинно, не больше одного экземпляра при гонке; закрыть —
/// идемпотентно, из любого потока. Обобщён по типу клиента, чтобы логику
/// проверял JVM-тест без libbox и Android ([ScreenCoreSession] подставляет
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
    /// [ensure]. Повторный вызов — no-op. [run] исполняет закрытие: по
    /// умолчанию — здесь же, в потоке вызывающего.
    fun close(run: (() -> Unit) -> Unit = { it() }) {
        val c = synchronized(this) { client.also { client = null } } ?: return
        run { runCatching { shutdown(c) } }
    }
}

/// §745/§747 — держатель клиента ядра экрана ([BoxCommandClient]): статус-стрим,
/// экранный и профайлерный клиенты, пинг, Tailscale, входящие Taildrop, тест
/// соединения — всё, что показывает окно.
///
/// §747 (итерация 2) — клиент живёт в `:bg`, рядом с ядром: окно `libbox` не
/// грузит, данные получает кадрами канала событий ([StreamSinks] →
/// [BgEventPipe]), а вызовы `cc*` приходят в `BgCcMethods`.
///
/// [ensure] создаёт клиента и поднимает статус-стрим, когда туннель `Started`
/// **и** окно подключено ([UiPresence]): без окна показывать некому, и
/// статус-стрим не тикает в пустоту при старте с плитки или автозапуске. Зовут:
/// `BoxService` после `Started`, [UiPresence] при подключении окна и каждый
/// обработчик `cc*`, который что-то запускает или читает.
///
/// Закрытие — `shutdownAll()` и обнуление:
/// - [closeForCoreStop] — синхронно, первым шагом закрытия командного сервера
///   (`BoxService.closeCommandServerAtomic`): порядок «клиент экрана → сервисный
///   клиент → сервер» внутри одного процесса, как в 745;
/// - [closeOffThread] — окно отключилось или его процесс умер.
object ScreenCoreSession {

    /// Старт туннеля (`TunnelState.startedElapsedMs`), для которого сервис уже
    /// начал закрывать командный сервер. Между этим моментом и статусом
    /// `Stopped` статус может быть ещё `Started` (перезапуск ядра, отказ на
    /// старте), но клиента создавать нельзя: он подключился бы к закрывающемуся
    /// серверу. Новый старт получает новое время — запрет снимается сам.
    @Volatile
    private var closingStart = -1L

    private val holder = ClientHolder(
        started = {
            val s = TunnelState.snapshot
            s.status == VpnStatus.Started && s.startedElapsedMs != closingStart &&
                UiPresence.isAttached
        },
        create = {
            // WARN-строки клиента (сбой подключения статус-клиента) — в журнал
            // приложения, который ведёт сервис.
            BoxCommandClient { text -> BoxService.appLogWarning(text) }.also { it.startStatus() }
        },
        shutdown = { it.shutdownAll() },
    )

    val client: BoxCommandClient? get() = holder.client

    fun ensure(): BoxCommandClient? = holder.ensure()

    /// Закрытие командного сервера началось: синхронно закрыть клиента и не
    /// создавать нового до следующего старта туннеля.
    fun closeForCoreStop() {
        closingStart = TunnelState.startedElapsedMs
        holder.close()
    }

    /// Окна больше нет: ссылка снимается сразу, `shutdownAll()` — вызовы в
    /// ядро — уходит в свою нить (вызывающий — поток Binder или главный).
    fun closeOffThread() = holder.close { task ->
        Thread(task, "lxbox-cc-close").apply { isDaemon = true }.start()
    }
}
