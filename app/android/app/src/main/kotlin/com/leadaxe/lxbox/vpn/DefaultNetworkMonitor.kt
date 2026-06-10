package com.leadaxe.lxbox.vpn

import android.net.Network
import android.os.Build
import io.nekohasekai.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.net.NetworkInterface

object DefaultNetworkMonitor {
    /// §087 — окно debounce для force-reset на смену интерфейса (мс). Android
    /// при переходе шлёт пачку callback'ов; копим тишину и ресетим один раз.
    private const val RESET_DEBOUNCE_MS = 1500L

    var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null
    private var scope: CoroutineScope? = null

    /// §087 — callback на genuine смену интерфейса (BoxService → resetNetwork()).
    private var onNetworkSwitch: (() -> Unit)? = null

    /// §087 — имя последнего реального интерфейса (baseline для детекта смены).
    /// `@Volatile`: пишется из notifySync (attach-thread) и checkUpdate (actor).
    @Volatile
    private var lastIfName: String? = null
    private var resetJob: Job? = null

    suspend fun start(scope: CoroutineScope, onNetworkSwitch: () -> Unit) {
        this.scope = scope
        this.onNetworkSwitch = onNetworkSwitch
        defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            BoxApplication.connectivity.activeNetwork
        } else null

        DefaultNetworkListener.start(this) {
            defaultNetwork = it
            checkUpdate(it)
        }

        if (defaultNetwork == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            defaultNetwork = DefaultNetworkListener.get()
        }
    }

    suspend fun stop() {
        DefaultNetworkListener.stop(this)
        resetJob?.cancel()
        resetJob = null
        onNetworkSwitch = null
        lastIfName = null
        scope = null
        listener = null
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        this.listener = listener
        if (listener != null) notifySync(defaultNetwork, listener)
    }

    private fun notifySync(network: Network?, listener: InterfaceUpdateListener) {
        if (network == null) {
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        val linkProps = BoxApplication.connectivity.getLinkProperties(network)
        val ifName = linkProps?.interfaceName ?: ""
        if (ifName.isEmpty()) {
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        for (attempt in 0 until 10) {
            try {
                val ni = NetworkInterface.getByName(ifName) ?: continue
                lastIfName = ifName  // §087 — baseline для детекта последующих смен
                listener.updateDefaultInterface(ifName, ni.index, false, false)
                return
            } catch (_: Exception) {
                Thread.sleep(50)
            }
        }
        listener.updateDefaultInterface("", -1, false, false)
    }

    private fun checkUpdate(network: Network?) {
        val l = listener ?: return
        val s = scope ?: return  // service already dead — don't touch Go objects
        if (network == null) {
            // §087 — disconnect: НЕ трогаем lastIfName (сохраняем baseline, чтобы
            // switch через "" к ДРУГОМУ интерфейсу всё равно детектился) и НЕ
            // ресетим (нет сети для re-dial).
            s.launch(Dispatchers.IO) {
                runCatching { l.updateDefaultInterface("", -1, false, false) }
            }
            return
        }
        val linkProps = BoxApplication.connectivity.getLinkProperties(network)
        val ifName = linkProps?.interfaceName ?: return
        for (attempt in 0 until 10) {
            try {
                val ni = NetworkInterface.getByName(ifName) ?: continue
                maybeResetOnSwitch(ifName, s)  // §087
                lastIfName = ifName
                s.launch(Dispatchers.IO) {
                    runCatching { l.updateDefaultInterface(ifName, ni.index, false, false) }
                }
                return
            } catch (_: Exception) {
                Thread.sleep(100)
            }
        }
    }

    /// §087 — force-reset стейл-соединений на genuine смену интерфейса.
    ///
    /// `checkUpdate` дёргается из `DefaultNetworkListener` на ЛЮБОЙ
    /// `onCapabilitiesChanged`, поэтому reset только на реальный switch:
    /// `prev → new`, оба непустые и разные. НЕ на первый connect (prev пуст),
    /// capability-update (prev == new) или disconnect (см. ветку network==null).
    /// Иначе — регрессия класса sing-box #3400 (убить весь TCP на каждый чих).
    /// Debounced: пачка переходов схлопывается в один resetNetwork().
    private fun maybeResetOnSwitch(newIfName: String, s: CoroutineScope) {
        val prev = lastIfName
        if (prev.isNullOrEmpty() || newIfName.isEmpty() || prev == newIfName) return
        resetJob?.cancel()
        resetJob = s.launch(Dispatchers.IO) {
            delay(RESET_DEBOUNCE_MS)
            runCatching { onNetworkSwitch?.invoke() }
        }
    }
}
