package com.leadaxe.boxvpn_app.vpn

import android.net.Network
import android.os.Build
import io.nekohasekai.libbox.InterfaceUpdateListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.net.NetworkInterface

object DefaultNetworkMonitor {
    var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null
    private var scope: CoroutineScope? = null

    suspend fun start(scope: CoroutineScope) {
        this.scope = scope
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
                s.launch(Dispatchers.IO) {
                    runCatching { l.updateDefaultInterface(ifName, ni.index, false, false) }
                }
                return
            } catch (_: Exception) {
                Thread.sleep(100)
            }
        }
    }
}
