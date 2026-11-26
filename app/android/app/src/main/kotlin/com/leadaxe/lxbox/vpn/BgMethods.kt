package com.leadaxe.lxbox.vpn

import android.content.Context
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/// §747 — сервисная половина обработчиков `VpnPlugin`: тела методов, которым
/// нужна память или права процесса `:bg` (файлы настроек, состояние туннеля,
/// ядро, сервисный клиент ядра, Taildrop, `protect` сервиса).
///
/// Зовёт [BgControlProvider]: быстрый метод — на потоке пула Binder, долгий —
/// на своём потоке (ответ кадром канала событий). Имя метода — то же, что у
/// `MethodChannel` (служебные — без пары в Dart). Обработчики, которые ходят
/// в ядро через клиент экрана, — в [BgCcMethods]. Ответ — значение
/// `MethodChannel` той же формы, что раньше отдавал `VpnPlugin`; отказ,
/// который Dart видел как `PlatformException`, — [BgError].
///
/// Сторона окна сюда не ссылается: она знает только имена методов
/// (`BgClient.call` / `forward`).
object BgMethods {
    private const val TAG = "BgMethods"

    /// §639 — сколько Quit ждёт Stopped от штатной остановки сервиса.
    private const val QUIT_STOP_BUDGET_MS = 3_000L

    /// §707 итер. 9 — файлы SharedPreferences rc.3, только для удаления.
    private const val LEGACY_TAILDROP_PREFS = "lxbox_taildrop"
    private const val LEGACY_NOTIFICATION_BUTTONS_PREFS = "lxbox_notification_buttons"

    // §207 — allowlist имён pprof-профилей (до `?`). Пропускаем наружу
    // только их, не произвольный path. Зеркало Go net/http/pprof.
    private val PPROF_PROFILES = setOf(
        "goroutine", "profile", "heap", "allocs",
        "block", "mutex", "threadcreate",
    )

    fun handle(ctx: Context, method: String, raw: Map<*, *>?): Any? {
        val a = BgArgs(raw)
        // Обработчики, которые ходят в ядро (клиент экрана, проба, проверка
        // конфига), — отдельным набором.
        val cc = BgCcMethods.handle(ctx, method, a)
        if (cc !== BgCcMethods.NOT_HANDLED) return cc
        return when (method) {
            // ───────────── состояние туннеля ─────────────
            // Снимок с меткой порядка — окно ведёт по нему свою копию
            // `TunnelState` и отвечает Dart на `getVpnStatus`.
            "tunnelSnapshot" -> BgEvents.wireToMap(TunnelState.wire())
            "getTunnelUptimeMs" -> {
                // §187 — прошедшие мс с реального старта туннеля. Монотонные
                // часы общие для процессов, но считаем там же, где метка.
                val started = TunnelState.startedElapsedMs
                if (started > 0L) SystemClock.elapsedRealtime() - started else 0L
            }
            // §069: runtime applied value (от последнего establish()).
            "getCurrentSessionAllowBypass" -> TunnelState.sessionAllowBypass
            "isForeignVpnActive" -> isForeignVpnActive()

            // ───────────── команды сервису ─────────────
            // Идут той же полосой, что запись настроек и «конфиг сохранён»:
            // сервис стартует и перезагружается уже с новыми значениями.
            "startVpnService" -> { BoxVpnService.start(ctx); true }
            "startVpnHeadless" -> {
                // §192 — proxy-режим без TUN: prepare не нужен (и зря рвёт чужой
                // VPN). Стартуем напрямую, консент не требуется.
                val needConsent = BootReceiver.hasTun(ctx) && VpnService.prepare(ctx) != null
                if (needConsent) {
                    mapOf("started" to false, "needs_consent" to true)
                } else {
                    BoxVpnService.start(ctx)
                    mapOf("started" to true, "needs_consent" to false)
                }
            }
            "stopVPN" -> stopVpn(ctx)
            "stopVpnNative" -> { BoxVpnService.stop(ctx); true }
            "forceStopVPN" -> { BoxVpnService.forceStop(ctx); true }
            "reloadVPN" -> { BoxVpnService.reload(ctx); true }
            "resetNetwork" -> { BoxVpnService.resetNetwork(ctx); true }
            "clearDnsCache" -> { BoxVpnService.clearDnsCache(ctx); true }
            "clearStaleNotification" -> { BoxVpnService.clearStaleNotification(ctx); true }
            // §638 — первая половина Quit: снять «VPN желателен» и будильник
            // сторожа. Окно закрывается только после этого подтверждения —
            // иначе сторож поднял бы VPN вопреки «VPN service will stop».
            "quitPrepare" -> {
                BootReceiver.setVpnDesired(ctx, false)
                VpnWatchdog.disarm(ctx)
                true
            }
            "quitApp" -> quitApp(ctx)
            // Файл конфига переписан окном — сбросить кэш.
            "configSaved" -> { ConfigManager.invalidate(); true }

            // ───────────── подписи уведомления ─────────────
            "setNotificationTitle" -> {
                val title = a.get<String>("title")
                    ?: ctx.getString(com.leadaxe.lxbox.R.string.app_name)
                // §223 — лейбл поменялся при живом туннеле → перерисовать шторку.
                val changed = title != ConfigManager.notificationTitle
                ConfigManager.setNotificationTitle(title)
                if (changed) BoxVpnService.updateNotification(ctx)
                true
            }
            "setNotificationText" -> {
                val text = a.str("text")
                val changed = text != ConfigManager.notificationText // §223
                ConfigManager.setNotificationText(text)
                if (changed) BoxVpnService.updateNotification(ctx)
                true
            }

            // ───────────── настройки (файлы `boxvpn_boot`, кэши) ─────────────
            "setAutoStart" -> { BootReceiver.setEnabled(ctx, a.bool("enabled", false)); true }
            "getAutoStart" -> BootReceiver.isEnabled(ctx)
            "setKeepOnExit" -> { BootReceiver.setKeepOnExit(ctx, a.bool("enabled", false)); true }
            "getKeepOnExit" -> BootReceiver.isKeepOnExit(ctx)
            "setNotificationStop" -> {
                BootReceiver.setNotificationStop(ctx, a.bool("enabled", true))
                BoxVpnService.updateNotification(ctx)
                true
            }
            "getNotificationStop" -> BootReceiver.isNotificationStop(ctx)
            "setNotificationRestart" -> {
                BootReceiver.setNotificationRestart(ctx, a.bool("enabled", true))
                BoxVpnService.updateNotification(ctx)
                true
            }
            "getNotificationRestart" -> BootReceiver.isNotificationRestart(ctx)
            "setNotificationSend" -> {
                BootReceiver.setNotificationSend(ctx, a.bool("enabled", true))
                BoxVpnService.updateNotification(ctx)
                true
            }
            "getNotificationSend" -> BootReceiver.isNotificationSend(ctx)
            "setCoreLogsEnabled" -> { BootReceiver.setCoreLogsEnabled(ctx, a.bool("enabled", false)); true }
            "getCoreLogsEnabled" -> BootReceiver.isCoreLogsEnabled(ctx)
            // §345 — verbose core-логи: persist + немедленное применение
            // (volatile в BoxService читается на каждой строке writeDebugMessage).
            "setCoreLogsVerbose" -> {
                val enabled = a.bool("enabled", false)
                BootReceiver.setCoreLogsVerbose(ctx, enabled)
                BoxService.coreLogsVerbose = enabled
                true
            }
            "getCoreLogsVerbose" -> BootReceiver.isCoreLogsVerbose(ctx)
            "setAllowBypass" -> { BootReceiver.setAllowBypass(ctx, a.bool("enabled", false)); true }
            "getAllowBypass" -> BootReceiver.isAllowBypass(ctx)
            "setAutoRedirect" -> { BootReceiver.setAutoRedirect(ctx, a.bool("enabled", false)); true }
            "getAutoRedirect" -> BootReceiver.isAutoRedirect(ctx)
            "setHasTun" -> { BootReceiver.setHasTun(ctx, a.bool("enabled", true)); true }
            "getHasTun" -> BootReceiver.hasTun(ctx)
            "getBackgroundMode" -> BootReceiver.getBackgroundMode(ctx)
            "setBackgroundMode" -> {
                BootReceiver.setBackgroundMode(ctx, a.str("mode", BootReceiver.BG_MODE_NEVER))
                null
            }
            "getMemoryLimit" -> BootReceiver.getMemoryLimit(ctx)
            "setMemoryLimit" -> {
                // §271 — persist + мгновенное применение к работающему ядру
                // (`reloadSetupOptions` читает только OOM-поля и сразу зовёт
                // debug.SetMemoryLimit). Ядро не загружено — значение прочтёт
                // `Libbox.setup` при загрузке.
                BootReceiver.setMemoryLimit(ctx, a.str("value", BootReceiver.MEMORY_LIMIT_AUTO))
                BoxApplication.reloadMemoryLimit(ctx)
                null
            }
            // §279 Phase 6 — язык приложения: pref + LocaleManager-пуш + relabel
            // нативных поверхностей + локаль ядра.
            "setAppLanguage" -> { L10n.applySetting(ctx, a.str("tag", "system")); true }
            "getAppLanguageState" -> L10n.appLanguageState(ctx)
            // Строка ресурса на языке приложения — для тостов окна.
            "l10nString" -> L10n.str(ctx, a.int("id", 0))
            "retryShortcutRelabel" -> { QuickShortcuts.retryPendingRelabel(ctx); true }
            // §047 Automation API.
            "setAutomationEnabled" -> { LxBoxIntentReceiver.setEnabled(ctx, a.bool("enabled", false)); true }
            // §721 — тумблер «AI assistant control».
            "setAppFunctionsEnabled" -> {
                com.leadaxe.lxbox.appfunctions.AppFunctionsGate.setEnabled(ctx, a.bool("enabled", false))
                true
            }
            // §047 Шаг 2 — активная нода/группа + списки в native-кеш.
            "setAutomationActiveState" -> {
                val edit = AutomationCache.prefs(ctx).edit()
                    .putString(AutomationCache.KEY_ACTIVE_NODE, a.get<String>("node"))
                    .putString(AutomationCache.KEY_ACTIVE_GROUP, a.get<String>("group"))
                // Списки — JSON-массив строк. null → не трогаем.
                a.get<List<String>>("nodes")?.let {
                    edit.putString(AutomationCache.KEY_ALL_NODES, org.json.JSONArray(it).toString())
                }
                a.get<List<String>>("groups")?.let {
                    edit.putString(AutomationCache.KEY_ALL_GROUPS, org.json.JSONArray(it).toString())
                }
                edit.apply()
                true
            }
            "deleteLegacyPrefs" -> runCatching {
                ctx.deleteSharedPreferences(LEGACY_TAILDROP_PREFS)
                ctx.deleteSharedPreferences(LEGACY_NOTIFICATION_BUTTONS_PREFS)
                true
            }.getOrDefault(false)

            // ───────────── ядро процесса `:bg` ─────────────
            "setQuicKnob" -> setQuicKnob(ctx, a.get<String>("knob"), a.bool("disabled", false))
            "pprofProfile" -> pprofProfile(a.str("pathAndQuery", "goroutine?debug=2"))
            // §242/§507 — память процесса с ядром.
            "getMemoryInfo" -> try {
                collectProcessMemoryInfo(ctx)
            } catch (t: Throwable) {
                Log.e(TAG, "getMemoryInfo failed", t)
                throw BgError("MEMINFO_FAILED", t.message ?: t.javaClass.simpleName)
            }

            // ───────────── Path MTU (§725): нужен `protect` сервиса ─────────────
            "pathMtuNetwork" -> PathMtuProbe.network()
            "pathMtuResolve" -> PathMtuProbe.resolve(a.str("host").trim())
            "pathMtuProbe" -> PathMtuProbe.probeCall(
                a.str("ip"), a.int("size", 0), a.int("timeoutMs", 1000), a.int("seq", 0),
            )

            // ───────────── Taildrop ─────────────
            "taildropSave" -> taildropSave(ctx, a.str("tag"), a.str("name"), a.get<String>("target"))
            "taildropDismissReceived" -> { Taildrop.dismissReceived(ctx, a.str("tag"), a.str("name")); true }
            "taildropSendUris" -> {
                val uris = a.strings("uris").map { android.net.Uri.parse(it) }
                val items = Taildrop.openUris(ctx, uris)
                if (items.isEmpty()) {
                    mapOf("status" to "error", "error" to "cant_read")
                } else if (Taildrop.send(ctx, a.str("tag"), a.str("peer_id"), a.str("peer_name"), items)) {
                    mapOf("status" to "started", "count" to items.size)
                } else {
                    mapOf("status" to "error", "error" to "vpn_off")
                }
            }
            "ccTaildropSendBytes" -> taildropSendBytes(ctx, a)
            "taildropServiceStats" -> TaildropServiceFiles.stats()
            "taildropBuildServiceFile" -> {
                val commands = a.get<List<Any?>>("commands") ?: emptyList()
                val spec = TaildropServiceFiles.spec(ctx)
                if (spec == null) {
                    mapOf("error" to "no_registry")
                } else {
                    when (val b = TaildropServiceFiles.build(
                        spec, org.json.JSONArray(commands), System.currentTimeMillis(),
                        java.security.SecureRandom(),
                    )) {
                        is TaildropServiceFiles.Built.Ok -> mapOf("name" to b.name, "bytes" to b.bytes)
                        is TaildropServiceFiles.Built.TooLarge ->
                            mapOf("error" to "too_large", "size" to b.size, "max_bytes" to b.maxBytes)
                        TaildropServiceFiles.Built.Unsupported -> mapOf("error" to "unsupported_format")
                    }
                }
            }
            "taildropClipState" -> TaildropClip.state(ctx)
            "setTaildropTags" -> {
                // §707 итер. 9 (контракт 1.1.159) — множества ВЫКЛЮЧЕННЫХ тегов.
                val enabled = BootReceiver.setTaildropTags(
                    ctx, a.strings("commands_off"), a.strings("autosave_off"),
                )
                if (enabled && Taildrop.autoSaveSupported()) Taildrop.sweepInboxesAsync(ctx)
                true
            }

            // ───────────── openconnect (§654 C): сервисный клиент ядра ─────────────
            // Значения формы (пароли, коды) приходят только этим вызовом и в
            // лог не пишутся.
            "ccGetOpenConnectStatus" -> openConnect()?.openConnectSnapshot()
            "ccSubmitOpenConnectForm" -> {
                val values = (a.get<List<Any?>>("values") ?: emptyList()).mapNotNull { e ->
                    val m = e as? Map<*, *> ?: return@mapNotNull null
                    val k = m["key"] as? String ?: return@mapNotNull null
                    k to (m["value"] as? String ?: "")
                }
                val cc = openConnect()
                if (cc == null) NO_CLIENT else cc.submitOpenConnectForm(a.str("tag"), a.str("challenge_id"), values)
            }
            "ccCancelOpenConnectChallenge" -> {
                val cc = openConnect()
                if (cc == null) NO_CLIENT else cc.cancelOpenConnectChallenge(a.str("tag"), a.str("challenge_id"))
            }
            "ccStartOpenConnectCallback" -> {
                val cc = openConnect()
                if (cc == null) NO_CLIENT
                else cc.startOpenConnectCallback(
                    a.str("tag"), a.str("challenge_id"), a.int("port", 8020), a.strings("prefixes"),
                )
            }
            "ccStopOpenConnectCallback" -> { openConnect()?.stopOpenConnectCallback(); true }

            // ───────────── §750 — операции ассистента для Debug API окна ─────────────
            // Тумблер «AI assistant control» здесь НЕ проверяется: у Debug API
            // свой доступ. Ошибка операции — успех с `{error: {code, message}}`.
            // Индекс (`index`, JSON) Dart собирает по требованию и шлёт
            // аргументом — здесь он не хранится и в лог не пишется.
            "assistantOverview" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.overview(ctx, a.str("index"))
            }
            "assistantListExits" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.listExits(ctx, a.str("direction"), a.get<String>("query"))
            }
            "assistantCheckUrl" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.checkUrl(ctx, a.str("url"), a.get<String>("app"))
            }
            "assistantCheckExit" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.checkExit(ctx, a.str("direction"))
            }
            "assistantFindApps" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.findApps(ctx, a.str("query"))
            }
            "assistantAppRoute" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.appRoute(ctx, a.str("index"), a.str("app"))
            }
            "assistantSelectExit" -> assistant {
                com.leadaxe.lxbox.appfunctions.AssistantCore.selectExit(ctx, a.str("direction"), a.str("exit"))
            }

            // ───────────── обратный вызов `:bg` → Dart (`UiCalls`) ─────────────
            "uiCallAck" -> { UiCalls.onAck(a.long("id", 0L)); true }
            "uiCallReply" -> {
                UiCalls.onReply(
                    a.long("id", 0L), a.str("kind"), a.get<Any>("value"),
                    a.get<String>("code"), a.get<String>("message"),
                )
                true
            }

            // ───────────── окно ─────────────
            // Движок отключён («окно закрыто»).
            "uiDetached" -> { UiPresence.detached(ctx); true }

            else -> throw BgError("BG_UNKNOWN_METHOD", method)
        }
    }

    /// Операции окна, исполняемые корутинами (§750): отменяются, когда окна
    /// больше нет (раньше их отменяло отключение движка) — проверка адреса не
    /// доигрывает впустую и снимает свой признак «занято» сразу.
    private val windowJobs = kotlinx.coroutines.SupervisorJob()
    private val windowScope =
        kotlinx.coroutines.CoroutineScope(windowJobs + kotlinx.coroutines.Dispatchers.Default)

    /// Окно отключилось или умерло: отменить его идущие операции.
    fun cancelWindowJobs() {
        for (job in windowJobs.children.toList()) job.cancel()
    }

    /// Исполнить операцию ассистента и дождаться её. Ошибка операции — не
    /// отказ вызова, а ответ `{error: {code, message}}`, как было в `VpnPlugin`.
    private fun assistant(op: suspend () -> Any?): Any? = try {
        runBlocking { windowScope.async { op() }.await() }
    } catch (e: com.leadaxe.lxbox.appfunctions.AssistantError) {
        mapOf("error" to mapOf("code" to e.code, "message" to (e.message ?: "")))
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw BgError(BgControlProvider.ERROR_CALL_FAILED, "cancelled: the window is gone")
    } catch (t: Throwable) {
        Log.w(TAG, "assistant call failed: ${t.javaClass.simpleName}")
        mapOf("error" to mapOf("code" to "core_error", "message" to "Internal error."))
    }

    /// §745 — openconnect целиком живёт на сервисном клиенте ядра (слушатель SSO
    /// работает и при закрытом окне).
    private fun openConnect(): OpenConnectControl? = CoreSession.client

    /// Ответ вызова «null — успех, иначе текст ошибки», когда клиента ядра нет.
    /// До 747 выражение `клиент?.вызов() ?: "no command client"` отдавало эту
    /// строку и при успехе (вызов отвечает null) — исправлено: только без клиента.
    private const val NO_CLIENT = "no command client"

    /// Blocking stop: ждём, пока setStatus(Stopped) реально отработает, чтобы
    /// Dart мог последовательно сделать `await stopVPN()` → `await startVPN()`.
    /// §415 — бюджет `STOP_AWAIT_TIMEOUT_MS`; не уложились — `false`.
    /// Ожидание живёт здесь, в `:bg`: completer завершает `BoxService.setStatus`.
    private fun stopVpn(ctx: Context): Boolean = try {
        val done = runBlocking {
            withTimeoutOrNull(BoxVpnService.STOP_AWAIT_TIMEOUT_MS) {
                BoxVpnService.stopAwait(ctx).await()
            }
        }
        if (done == null) {
            Log.w(TAG, "[vpn] stopVPN: ${BoxVpnService.STOP_AWAIT_TIMEOUT_MS}ms timeout — native did not report Stopped")
        }
        done != null
    } catch (e: Exception) {
        Log.e(TAG, "[vpn] stopVPN: exception $e")
        false
    }

    /// `quitApp`, сервисная половина. §638: признак «VPN желателен» и
    /// будильник сторожа снимаются, иначе сторож поднимет VPN сам. §639:
    /// сервис останавливается штатным путём (уведомление снимается на
    /// Stopping), ждём Stopped не дольше [QUIT_STOP_BUDGET_MS], затем
    /// страховочно снимаем уведомление. После ответа `:bg` завершается сам
    /// (§747 G); свой процесс окно завершает само.
    private fun quitApp(ctx: Context): Boolean {
        BootReceiver.setVpnDesired(ctx, false)
        VpnWatchdog.disarm(ctx)
        val stopped = runCatching {
            runBlocking {
                withTimeoutOrNull(QUIT_STOP_BUDGET_MS) { BoxVpnService.stopAwait(ctx).await() }
            }
        }.getOrNull()
        if (stopped == null) {
            Log.w(TAG, "[vpn §639] quitApp: Stopped not reported in ${QUIT_STOP_BUDGET_MS}ms")
        }
        ServiceNotification.cancelServiceNotification()
        BgLifecycle.quit(ctx)
        return stopped != null
    }

    /// Есть ли сейчас активный ЧУЖОЙ VPN (другое приложение)?
    ///
    /// `getOwnerUid()` публичен с API 30: на Android 10 обращение бросает
    /// `NoSuchMethodError` — гейт на R, ловим Throwable. На 24-29 деталь
    /// недоступна — считаем чужим (лишний вопрос юзеру безопаснее молчаливого
    /// отзыва чужого туннеля).
    private fun isForeignVpnActive(): Boolean {
        if (TunnelState.status != VpnStatus.Stopped) return false
        val cm = BoxApplication.connectivity
        return try {
            val n = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(n) ?: return false
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                caps.ownerUid == android.os.Process.myUid()
            ) {
                Log.d(TAG, "[vpn §361] skipping our own orphaned VPN network (uid=${caps.ownerUid})")
                return false
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "isForeignVpnActive: $t")
            false
        }
    }

    /// §341 — диагностические env-ручки quic-go (GSO/ECN offload): Go-side
    /// os.Setenv, эффект — на следующем (ре)коннекте QUIC-аутбаундов.
    /// §747 — значение запоминается: ядро грузится лениво и в каждом новом
    /// процессе `:bg` заново, ручки применяются при загрузке
    /// (`BoxApplication.ensureLibbox`).
    private fun setQuicKnob(ctx: Context, knob: String?, disabled: Boolean): Boolean {
        if (knob != "gso" && knob != "ecn") return false
        NativeCache.setQuicKnobDisabled(ctx, knob, disabled)
        if (!BoxApplication.libboxLoaded) return true
        return try {
            BoxApplication.applyQuicKnob(knob, disabled)
            true
        } catch (t: Throwable) {
            // Старый AAR без экспорта — не роняем канал, отвечаем false.
            Log.e(TAG, "setQuicKnob($knob) failed", t)
            false
        }
    }

    /// §207 — снимок pprof ядра. CPU `profile?seconds=N` держит соединение N
    /// секунд → read-timeout масштабируем; прочие снимки мгновенны (5s). Окно
    /// зовёт долгим вызовом: ответ идёт кадром канала событий, размер профиля
    /// пределом Binder не ограничен.
    private fun pprofProfile(pathAndQuery: String): ByteArray {
        val name = pathAndQuery.substringBefore('?')
        try {
            if (name !in PPROF_PROFILES) {
                throw IllegalArgumentException("unknown pprof profile: $name")
            }
            val secs = if (name == "profile") {
                Regex("seconds=(\\d+)").find(pathAndQuery)
                    ?.groupValues?.get(1)?.toIntOrNull()
                    ?.coerceIn(1, 60) ?: 10
            } else 0
            val readTimeout = if (name == "profile") secs * 1000 + 5000 else 5000
            BoxApplication.ensureLibbox()
            return PProfClient.fetch(pathAndQuery, readTimeoutMs = readTimeout)
        } catch (t: Throwable) {
            Log.e(TAG, "pprofProfile($pathAndQuery) failed", t)
            throw BgError("PPROF_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    /// §707 — сохранить принятый файл (в Downloads или в [target]) и ответить
    /// `{status, where?, name?, error?}`.
    private fun taildropSave(ctx: Context, tag: String, name: String, target: String?): Map<String, Any> {
        val uri = target?.let { android.net.Uri.parse(it) }
        val (err, savedName) = runCatching {
            if (uri == null) Taildrop.saveToDownloads(ctx, tag, name)
            else Taildrop.save(ctx, tag, name, uri) to null
        }.getOrElse { (it.message ?: "failed") to null }
        if (err == null) Taildrop.dismissReceived(ctx, tag, name)
        return if (err == null) mapOf(
            "status" to "saved",
            "where" to (if (uri == null) "downloads" else "document"),
            "name" to (savedName ?: ""),
        )
        else mapOf("status" to "error", "error" to err)
    }

    /// §707 итер. 5 — Debug API: отправка из байтов / заметки с ожиданием итога.
    private fun taildropSendBytes(ctx: Context, a: BgArgs): Map<String, Any> {
        val tag = a.str("tag")
        val peerId = a.str("peer_id")
        val peerName = a.str("peer_name")
        val text = a.get<String>("text")
        val name = a.str("name")
        val waitMs = a.long("wait_ms", 60_000L)
        val bytes = a.get<ByteArray>("bytes")
        val item = when {
            text != null -> Taildrop.noteItem(text)
            bytes != null && name.isNotEmpty() ->
                Taildrop.Item(name, bytes.size.toLong(), java.io.ByteArrayInputStream(bytes))
            else -> null
        }
        if (item == null || tag.isEmpty() || peerId.isEmpty()) {
            return mapOf("status" to "error", "error" to "bad arguments")
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        val outcome = java.util.concurrent.atomic.AtomicReference<Pair<String, String?>>(null)
        val started = Taildrop.send(ctx, tag, peerId, peerName, listOf(item)) { status, err ->
            outcome.set(status to err)
            latch.countDown()
        }
        return if (!started) {
            mapOf("status" to "error", "error" to "vpn_off", "name" to item.name)
        } else if (!latch.await(waitMs, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            mapOf("status" to "in_progress", "name" to item.name)
        } else {
            val (status, err) = outcome.get()
            mapOf("status" to status, "error" to (err ?: ""), "name" to item.name)
        }
    }

    /// §242/§507 — PSS-разбивка процесса `:bg` (в нём ядро) для Stats → Memory.
    ///
    /// `Debug.getMemoryInfo()` на Android 10+ не заполняет `otherStats`;
    /// документация Android говорит брать `ActivityManager.getProcessMemoryInfo`.
    /// Если AMS пуст (rate-limit Q+, эмулятор без memtrack) — запас
    /// `Debug.getMemoryInfo`; для нулевых `summary.*` — грубые поля той же
    /// структуры. Значения в байтах (фреймворк отдаёт KB).
    private fun collectProcessMemoryInfo(context: Context): Map<String, Any> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as? android.app.ActivityManager
        val fromAm = runCatching {
            am?.getProcessMemoryInfo(intArrayOf(android.os.Process.myPid()))
                ?.firstOrNull()
        }.getOrNull()
        val mi = if (fromAm != null && fromAm.totalPss > 0) {
            fromAm
        } else {
            android.os.Debug.MemoryInfo().also { android.os.Debug.getMemoryInfo(it) }
        }

        fun kb(statName: String, fallbackKb: Int = 0): Long {
            val parsed = mi.getMemoryStat(statName)?.toLongOrNull() ?: 0L
            val value = if (parsed > 0L) parsed else fallbackKb.toLong()
            return value * 1024L
        }

        return hashMapOf(
            "totalPss" to kb("summary.total-pss", mi.totalPss),
            // Swap — только summary.total-swap: getTotalSwappedOut{,Pss} @hide.
            "totalSwap" to kb("summary.total-swap"),
            "javaHeap" to kb("summary.java-heap", mi.dalvikPss),
            "nativeHeap" to kb("summary.native-heap", mi.nativePss),
            "code" to kb("summary.code"),
            "stack" to kb("summary.stack"),
            "graphics" to kb("summary.graphics"),
            "privateOther" to kb("summary.private-other", mi.otherPss),
            "system" to kb("summary.system"),
            // Аллоцированный native heap (Go-память ядра + прочая нативка) —
            // прямой счётчик malloc, не PSS-категория.
            "nativeHeapAllocated" to android.os.Debug.getNativeHeapAllocatedSize(),
            "nativeHeapSize" to android.os.Debug.getNativeHeapSize(),
        )
    }
}
