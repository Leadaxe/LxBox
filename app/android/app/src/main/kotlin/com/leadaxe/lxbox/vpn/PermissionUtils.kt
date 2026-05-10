package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * §051 — единый helper для permission checks, чтобы не дублировать
 * `if (SDK_INT >= X) checkSelfPermission(name) == GRANTED` паттерн
 * во всех handler'ах.
 *
 * До рефактора 4 копии в `MainActivity` (`checkNotificationPermission`,
 * `checkNearbyWifiPermission`, `checkBackgroundLocationPermission`,
 * preflight в `getCurrentWifiInfoMap`) — drift risk.
 */
object PermissionUtils {

    /// True если permission granted (или [minSdk] не достигнут — тогда
    /// permission concept не existed → implicit grant). Для runtime
    /// permissions с явными SDK gates (POST_NOTIFICATIONS=33,
    /// NEARBY_WIFI_DEVICES=33, ACCESS_BACKGROUND_LOCATION=29) указывайте
    /// `minSdk` чтобы pre-N устройства не валились на checkSelfPermission.
    fun has(ctx: Context, name: String, minSdk: Int = 0): Boolean {
        if (Build.VERSION.SDK_INT < minSdk) return true
        return ctx.checkSelfPermission(name) ==
            PackageManager.PERMISSION_GRANTED
    }
}
