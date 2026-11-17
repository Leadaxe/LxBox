package com.leadaxe.lxbox.vpn

import android.os.SystemClock

/// §742 — единственный владелец состояния туннеля (раньше — четыре поля в
/// `BoxVpnService.companion`). Читается с обеих сторон границы процессов
/// (сервис, плагин, плитка, автоматизация, AppFunctions) без зависимости от
/// класса Android-сервиса.
///
/// Состояние — один неизменяемый [Snapshot] в одном `@Volatile` поле: читатель
/// никогда не увидит несогласованную пару (статус уже `Stopped`, метка
/// `revoked` ещё прежняя). Запись — только `internal`-методами, каждый заменяет
/// снимок целиком; методы записи `@Synchronized`, чтобы параллельные записи
/// разных полей с разных потоков не теряли друг друга. Чтение — без блокировки.
///
/// Побочных эффектов здесь нет: `TaildropClip.onVpnStopped` на переходе в
/// `Stopped` зовёт сервис (`BoxVpnService.setCurrentStatus`) после записи.
object TunnelState {

    /// Неизменяемый снимок состояния туннеля.
    ///
    /// - [status] — зеркало живого статуса сервиса. `VpnPlugin.getVpnStatus`
    ///   читает его, чтобы Flutter пересинхронизировался после re-attach
    ///   (процесс убит, а сервис выжил из-за keep-on-exit).
    /// - [revoked] — §276: «последний Stopped пришёл из onRevoke». Нужно для
    ///   pull-пути (`getVpnStatus` на resume): broadcast'ятся только переходы,
    ///   и без этого поля UI, вернувшийся из фона после перехвата, увидел бы
    ///   голый Stopped и показал нейтральный Disconnected (кейс, помеченный
    ///   в §003 как «намеренно не покрыто»).
    /// - [startedElapsedMs] — §187: время старта туннеля
    ///   (`SystemClock.elapsedRealtime()`, монотонные часы — не прыгают при
    ///   смене системного времени/таймзоны). Живёт в процессе сервиса →
    ///   переживает swipe (туннель keep-alive не перезапускался) → даёт честный
    ///   uptime после cold-start, когда Dart-`connectedSince` обнулился бы на
    ///   «сейчас». 0 = не запущен.
    /// - [sessionAllowBypass] — §069: значение `allow_bypass` при последнем
    ///   `establish()`. Отражает то, что **сейчас applied** в
    ///   `VpnService.Builder.allowBypass()`, в отличие от persisted
    ///   `BootReceiver.isAllowBypass()`, который меняется до `establish()`
    ///   reload. Сбрасывается в `BoxVpnService.onDestroy()`, чтобы UI warning
    ///   исчезал, когда сервис умирает.
    data class Snapshot(
        val status: VpnStatus = VpnStatus.Stopped,
        val revoked: Boolean = false,
        val startedElapsedMs: Long = 0L,
        val sessionAllowBypass: Boolean = false,
    )

    @Volatile
    private var state: Snapshot = Snapshot()

    /// Часы §187; подменяются в unit-тесте (там нет Android).
    @Volatile
    internal var clock: () -> Long = { SystemClock.elapsedRealtime() }

    val snapshot: Snapshot get() = state
    val status: VpnStatus get() = state.status
    val revoked: Boolean get() = state.revoked
    val startedElapsedMs: Long get() = state.startedElapsedMs
    val sessionAllowBypass: Boolean get() = state.sessionAllowBypass

    /// Переход статуса (зовёт `BoxVpnService.setCurrentStatus`).
    @Synchronized
    internal fun setStatus(s: VpnStatus, revoked: Boolean = false) {
        val cur = state
        // §276 — Starting/Started снимают метку: туннель снова наш. На
        // Stopped метка приходит из setStatus (true только от onRevoke).
        val newRevoked = when (s) {
            VpnStatus.Starting, VpnStatus.Started -> false
            else -> revoked
        }
        // §187 — фиксируем старт ОДИН раз на переходе в Started (не
        // перетирать при дедуп-повторе). Сброс на Stopped → uptime обнулится.
        val newStarted = when (s) {
            VpnStatus.Started ->
                if (cur.startedElapsedMs == 0L) clock() else cur.startedElapsedMs
            VpnStatus.Stopped -> 0L
            else -> cur.startedElapsedMs /* Starting/Stopping — не трогаем */
        }
        state = cur.copy(status = s, revoked = newRevoked, startedElapsedMs = newStarted)
        seq++
    }

    /// §747 — новый процесс-владелец: вернуть метку §276, пережившую смену
    /// процесса (её хранит `NativeCache`). Только пока туннель `Stopped`:
    /// `Starting` / `Started` метку снимают, как и раньше.
    @Synchronized
    internal fun restoreRevoked() {
        if (state.status != VpnStatus.Stopped || state.revoked) return
        state = state.copy(revoked = true)
        seq++
    }

    /// §069 — snapshot `allow_bypass` при `establish()` / сброс в onDestroy.
    @Synchronized
    internal fun setSessionAllowBypass(v: Boolean) {
        state = state.copy(sessionAllowBypass = v)
        seq++
    }

    // ───────────── §747 — снимок для другого процесса и его копия ─────────────

    /// Снимок с меткой порядка: [epoch] — запуск процесса-владельца (`:bg`),
    /// [seq] — номер записи в нём. Едет в `BROADCAST_STATUS` и в ответе вызова
    /// `tunnelSnapshot`; по метке копия в `:ui` отбрасывает устаревшее (ответ
    /// вызова, обогнанный broadcast'ом, и наоборот).
    data class Wire(val epoch: Long, val seq: Long, val snapshot: Snapshot)

    /// Номер последней записи владельца. Читается и пишется под замком объекта.
    private var seq = 0L

    /// Метка запуска процесса-владельца: монотонные часы на момент первого
    /// обращения. У перезапущенного `:bg` она больше прежней.
    private val epoch: Long by lazy { clock() }

    /// Метка последнего принятого копией снимка.
    private var mirrorEpoch = Long.MIN_VALUE
    private var mirrorSeq = Long.MIN_VALUE

    /// Сторона владельца: согласованная пара «снимок + метка».
    @Synchronized
    fun wire(): Wire = Wire(epoch, seq, state)

    /// Сторона окна (`:ui`): принять снимок владельца, если он новее уже
    /// принятого. Пишут только приёмник `BROADCAST_STATUS` и первичный запрос
    /// снимка (`VpnPlugin`); в процессе-владельце не зовётся. `true` — принят.
    @Synchronized
    internal fun acceptMirror(w: Wire): Boolean {
        val newer = w.epoch > mirrorEpoch || (w.epoch == mirrorEpoch && w.seq > mirrorSeq)
        if (!newer) return false
        mirrorEpoch = w.epoch
        mirrorSeq = w.seq
        state = w.snapshot
        return true
    }

    /// Только для unit-тестов: вернуть начальное состояние.
    @Synchronized
    internal fun resetForTest() {
        state = Snapshot()
        seq = 0L
        mirrorEpoch = Long.MIN_VALUE
        mirrorSeq = Long.MIN_VALUE
    }
}
