package com.leadaxe.lxbox.vpn

import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast
import androidx.annotation.RequiresApi
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.R

class LxBoxTileService : TileService() {

    companion object {
        private const val TAG = "LxBoxTileService"

        /// Weak-ref на текущий bound TileService — выставляется в
        /// onStartListening, сбрасывается в onStopListening. Нужно чтобы
        /// `refreshTile` мог напрямую вызвать `renderTile()` на живом
        /// инстансе, не полагаясь на `requestListeningState` (система
        /// которая «уже слушает» молчит и не передёргивает render).
        @Volatile
        private var instanceRef: java.lang.ref.WeakReference<LxBoxTileService>? = null

        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        /// Перерисовывает плитку. Сначала пытается напрямую через bound
        /// instance — это работает всегда когда шторка открыта/тайл виден.
        /// Дополнительно дёргает `requestListeningState` чтобы поднять
        /// instance если он ещё не bound.
        ///
        /// На API < 30 (наша primary tier — Android 11+) тихо no-op:
        /// QS-tile фича не входит в гарантированный набор для best-effort
        /// устройств 8-10, и любой сбой здесь не должен валить старт VPN.
        fun refreshTile(ctx: android.content.Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
            try {
                instanceRef?.get()?.let { svc ->
                    mainHandler.post { runCatching { svc.renderTile() } }
                }
                requestListeningState(
                    ctx,
                    ComponentName(ctx, LxBoxTileService::class.java),
                )
            } catch (e: Throwable) {
                // Throwable, не Exception — ловим и Error (NoClassDefFoundError,
                // VerifyError на проблемных OEM/Android-версиях).
                Log.w(TAG, "refreshTile failed: ${e.message}")
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        instanceRef = java.lang.ref.WeakReference(this)
        renderTile()
    }

    override fun onStopListening() {
        super.onStopListening()
        // Если текущий ref указывает на нас — обнуляем.
        if (instanceRef?.get() === this) instanceRef = null
    }

    override fun onClick() {
        super.onClick()
        val cur = BoxVpnService.currentStatus
        Log.d(TAG, "onClick — currentStatus=${cur.name}")
        when (cur) {
            VpnStatus.Stopped -> {
                // Optimistic: рисуем сразу финальное состояние «Started»
                // (синяя + Connected), как будто действие уже произошло.
                // BoxVpnService через broadcast → refreshTile отдаст
                // реальный статус когда он будет известен.
                renderTile(VpnStatus.Started)
                connectOrPromptConsent()
            }
            VpnStatus.Started -> {
                renderTile(VpnStatus.Stopped)
                BoxVpnService.stop(applicationContext)
            }
            // Starting / Stopping — игнор, чтобы не плодить race'ы.
            else -> {
                Log.d(TAG, "onClick ignored in transient state ${cur.name}")
                renderTile()
            }
        }
    }

    private fun connectOrPromptConsent() {
        val needConsent = VpnService.prepare(applicationContext) != null
        if (!needConsent) {
            BoxVpnService.start(applicationContext)
            return
        }
        // VpnService.prepare показывает диалог только из Activity. Из tile
        // его не вызвать — открываем MainActivity, она дёргает prepare()
        // штатным путём и стартует сервис после RESULT_OK. Toast объясняет
        // юзеру почему app внезапно открылся.
        Toast.makeText(
            applicationContext,
            R.string.qc_first_open,
            Toast.LENGTH_SHORT,
        ).show()
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            putExtra("action", "connect")
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34+ — обновлённый API с PendingIntent для более жёсткого
            // background-launch контроля.
            val pi = android.app.PendingIntent.getActivity(
                applicationContext,
                0,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                    android.app.PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    /// `override` — если передан, рисуем именно его (optimistic flip
    /// в onClick). Иначе берём реальный `BoxVpnService.currentStatus`.
    private fun renderTile(override: VpnStatus? = null) {
        val tile = qsTile ?: return
        val effective = override ?: BoxVpnService.currentStatus
        val (state, subtitle) = when (effective) {
            VpnStatus.Started -> Tile.STATE_ACTIVE to "Connected"
            // ACTIVE (а не INACTIVE) на Starting — чтобы тап на серую плитку
            // мгновенно менял цвет, юзер видит реакцию на тап.
            VpnStatus.Starting -> Tile.STATE_ACTIVE to "Connecting…"
            // INACTIVE на Stopping — симметрично: тап на синюю флипает в
            // серую сразу, юзер видит «отжалось» и subtitle подтверждает.
            VpnStatus.Stopping -> Tile.STATE_INACTIVE to "Stopping…"
            VpnStatus.Stopped -> Tile.STATE_INACTIVE to "Disconnected"
        }
        tile.state = state
        tile.label = "L×Box"
        // Tile.setSubtitle добавлен в API 29 (Android 10). Извлечено в
        // @RequiresApi-helper чтобы ART class verifier на API < 29 не
        // встретил ссылку на отсутствующий метод и не отказался грузить
        // класс целиком (NoSuchMethodError при первом обращении).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            applySubtitle(tile, subtitle)
        }
        try {
            tile.icon = Icon.createWithResource(this, R.drawable.ic_lxbox_tile)
        } catch (_: Exception) {
            // Если по каким-то причинам ресурс не нашёлся, оставляем системный
            // дефолт — не критично.
        }
        tile.updateTile()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun applySubtitle(tile: Tile, text: String) {
        tile.subtitle = text
    }
}
