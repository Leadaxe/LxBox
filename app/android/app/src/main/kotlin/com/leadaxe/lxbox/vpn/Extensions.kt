package com.leadaxe.lxbox.vpn

import android.net.IpPrefix
import android.os.Build
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.StringIterator
import java.net.InetAddress
import kotlin.coroutines.Continuation

fun StringIterator.toList(): List<String> {
    return mutableListOf<String>().apply {
        while (hasNext()) {
            add(next())
        }
    }
}

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
fun RoutePrefix.toIpPrefix(): IpPrefix = IpPrefix(InetAddress.getByName(address()), prefix())

/// §049 F26 fix: helper для DnsResolver.Callback'ов в LocalResolver. Защита от
/// двойного resume (если sing-box ctx.cancel + onError одновременно отстреляли).
/// Identical к reference's `ktx/Continuations.kt`.
fun <T> Continuation<T>.tryResumeWithException(exception: Throwable) {
    try {
        resumeWith(Result.failure(exception))
    } catch (_: IllegalStateException) {
    }
}
