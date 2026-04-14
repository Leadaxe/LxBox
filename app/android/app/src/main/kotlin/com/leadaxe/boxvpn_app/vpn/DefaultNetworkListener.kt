package com.leadaxe.boxvpn_app.vpn

import android.annotation.TargetApi
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.ObsoleteCoroutinesApi
import kotlinx.coroutines.channels.actor
import kotlinx.coroutines.runBlocking

object DefaultNetworkListener {
    private sealed class Msg {
        class Start(val key: Any, val listener: (Network?) -> Unit) : Msg()
        class Get : Msg() { val response = CompletableDeferred<Network>() }
        class Stop(val key: Any) : Msg()
        class Put(val network: Network) : Msg()
        class Update(val network: Network) : Msg()
        class Lost(val network: Network) : Msg()
    }

    @OptIn(DelicateCoroutinesApi::class, ObsoleteCoroutinesApi::class)
    private val actor = GlobalScope.actor<Msg>(Dispatchers.Unconfined) {
        val listeners = mutableMapOf<Any, (Network?) -> Unit>()
        var network: Network? = null
        val pending = arrayListOf<Msg.Get>()
        for (msg in channel) when (msg) {
            is Msg.Start -> {
                if (listeners.isEmpty()) register()
                listeners[msg.key] = msg.listener
                if (network != null) msg.listener(network)
            }
            is Msg.Get -> {
                if (network == null) pending += msg else msg.response.complete(network)
            }
            is Msg.Stop -> if (listeners.isNotEmpty() && listeners.remove(msg.key) != null && listeners.isEmpty()) {
                network = null; unregister()
            }
            is Msg.Put -> {
                network = msg.network
                pending.forEach { it.response.complete(msg.network) }
                pending.clear()
                listeners.values.forEach { it(network) }
            }
            is Msg.Update -> if (network == msg.network) listeners.values.forEach { it(network) }
            is Msg.Lost -> if (network == msg.network) { network = null; listeners.values.forEach { it(null) } }
        }
    }

    suspend fun start(key: Any, listener: (Network?) -> Unit) = actor.send(Msg.Start(key, listener))
    suspend fun get(): Network = if (fallback) @TargetApi(23) {
        BoxApplication.connectivity.activeNetwork ?: error("missing default network")
    } else Msg.Get().also { actor.send(it) }.response.await()
    suspend fun stop(key: Any) = actor.send(Msg.Stop(key))

    private object Callback : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = runBlocking { actor.send(Msg.Put(network)) }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = runBlocking { actor.send(Msg.Update(network)) }
        override fun onLost(network: Network) = runBlocking { actor.send(Msg.Lost(network)) }
    }

    private var fallback = false
    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        if (Build.VERSION.SDK_INT == 23) {
            removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            removeCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
        }
    }.build()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun register() {
        val cm = BoxApplication.connectivity
        when {
            Build.VERSION.SDK_INT >= 31 -> @TargetApi(31) { cm.registerBestMatchingNetworkCallback(request, Callback, mainHandler) }
            Build.VERSION.SDK_INT >= 28 -> @TargetApi(28) { cm.requestNetwork(request, Callback, mainHandler) }
            Build.VERSION.SDK_INT >= 26 -> @TargetApi(26) { cm.registerDefaultNetworkCallback(Callback, mainHandler) }
            Build.VERSION.SDK_INT >= 24 -> @TargetApi(24) { cm.registerDefaultNetworkCallback(Callback) }
            else -> try { fallback = false; cm.requestNetwork(request, Callback) } catch (_: RuntimeException) { fallback = true }
        }
    }

    private fun unregister() {
        runCatching { BoxApplication.connectivity.unregisterNetworkCallback(Callback) }
    }
}
