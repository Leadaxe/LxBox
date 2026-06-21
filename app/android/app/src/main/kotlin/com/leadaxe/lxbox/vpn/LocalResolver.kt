package com.leadaxe.lxbox.vpn

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.runBlocking
import java.net.InetAddress
import java.net.UnknownHostException
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/// §049 F26 fix: полноценный LocalResolver, портированный 1:1 из reference
/// (`bg/LocalResolver.kt` 1.13.11).
///
/// Старый impl использовал `InetAddress.getAllByName(domain)` — это идёт через
/// system resolver, который при `tun.auto_route = true` мог рекурсивно
/// пройти ЧЕРЕЗ tun → sing-box → LocalResolver → loop. На SDK ≥ Q (Android 10+)
/// `DnsResolver.getInstance().query(defaultNetwork, ...)` использует **underlying
/// network** (не tun) — DNS-запрос гарантированно идёт мимо нашего tun, без
/// recursion-риска.
///
/// `raw()` теперь true на API ≥ Q — sing-box может отдавать raw DNS-байты
/// для transport'ов которые требуют точный байтовый ответ (DoH wire-format,
/// etc). Старый impl всегда возвращал errorCode(1) на raw exchange.
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3

    /// §151 F3 — DNS RCODE SERVFAIL (RFC 1035 §4.1.1). Отдаём ядру при
    /// отсутствии underlying-сети (`defaultNetwork == null`) вместо throw.
    private const val RCODE_SERVFAIL = 2

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        // §151 F3 — `defaultNetwork` штатно null в окне смены/потери сети, а
        // exchange() зовётся на каждый DNS-запрос. Раньше `error(...)` бросал
        // IllegalStateException (ловится gomobile — Go-метод возвращает error —
        // но даёт шумный Go-error на каждый резолв). Чище — вернуть ядру
        // корректный SERVFAIL через ctx. Явный non-null тип нужен, чтобы
        // вложенные замыкания callback'а захватили `defaultNetwork` как
        // `Network`, а не nullable (иначе smart-cast не пробрасывается).
        val dn = DefaultNetworkMonitor.defaultNetwork
        if (dn == null) {
            ctx.errorCode(RCODE_SERVFAIL)
            return
        }
        val defaultNetwork: android.net.Network = dn
        return runBlocking {
            suspendCoroutine { continuation ->
                val signal = CancellationSignal()
                ctx.onCancel(signal::cancel)
                val callback = object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) {
                            ctx.rawSuccess(answer)
                        } else {
                            ctx.errorCode(rcode)
                        }
                        continuation.resume(Unit)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        when (val cause = error.cause) {
                            is ErrnoException -> {
                                ctx.errnoCode(cause.errno)
                                continuation.resume(Unit)
                                return
                            }
                        }
                        continuation.tryResumeWithException(error)
                    }
                }
                DnsResolver.getInstance().rawQuery(
                    defaultNetwork,
                    message,
                    DnsResolver.FLAG_NO_RETRY,
                    Dispatchers.IO.asExecutor(),
                    signal,
                    callback,
                )
            }
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        // §151 F3 — см. exchange(): null defaultNetwork → SERVFAIL ядру, не throw.
        // Явный non-null тип, чтобы вложенные замыкания захватили корректно.
        val dn = DefaultNetworkMonitor.defaultNetwork
        if (dn == null) {
            ctx.errorCode(RCODE_SERVFAIL)
            return
        }
        val defaultNetwork: android.net.Network = dn
        return runBlocking {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                suspendCoroutine { continuation ->
                    val signal = CancellationSignal()
                    ctx.onCancel(signal::cancel)
                    val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                        @Suppress("ThrowableNotThrown")
                        override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                            if (rcode == 0) {
                                ctx.success(
                                    @Suppress("UNCHECKED_CAST")
                                    (answer as Collection<InetAddress?>)
                                        .mapNotNull { it?.hostAddress }
                                        .joinToString("\n"),
                                )
                            } else {
                                ctx.errorCode(rcode)
                            }
                            continuation.resume(Unit)
                        }

                        override fun onError(error: DnsResolver.DnsException) {
                            when (val cause = error.cause) {
                                is ErrnoException -> {
                                    ctx.errnoCode(cause.errno)
                                    continuation.resume(Unit)
                                    return
                                }
                            }
                            continuation.tryResumeWithException(error)
                        }
                    }
                    val type = when {
                        network.endsWith("4") -> DnsResolver.TYPE_A
                        network.endsWith("6") -> DnsResolver.TYPE_AAAA
                        else -> null
                    }
                    if (type != null) {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            type,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback,
                        )
                    } else {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback,
                        )
                    }
                }
            } else {
                // Pre-Q fallback: defaultNetwork.getAllByName() binds к underlying
                // network тоже (Network class это умеет с API 21+).
                val answer = try {
                    defaultNetwork.getAllByName(domain)
                } catch (_: UnknownHostException) {
                    ctx.errorCode(RCODE_NXDOMAIN)
                    return@runBlocking
                }
                ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            }
        }
    }
}
