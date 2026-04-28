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
import com.leadaxe.lxbox.MainActivity
import com.leadaxe.lxbox.R

class LxBoxTileService : TileService() {

    companion object {
        private const val TAG = "LxBoxTileService"

        /// Просит систему пере-bind'ить tile если она его слушает (видна
        /// шторка). Без этого tile-state застревает между переходами VPN.
        /// no-op если tile не виден / не добавлен в шторку.
        fun refreshTile(ctx: android.content.Context) {
            try {
                requestListeningState(
                    ctx,
                    ComponentName(ctx, LxBoxTileService::class.java),
                )
            } catch (e: Exception) {
                Log.w(TAG, "requestListeningState failed: ${e.message}")
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        renderTile()
    }

    override fun onClick() {
        super.onClick()
        Log.d(TAG, "onClick — currentStatus=${BoxVpnService.currentStatus.name}")
        when (BoxVpnService.currentStatus) {
            VpnStatus.Stopped -> connectOrPromptConsent()
            VpnStatus.Started -> BoxVpnService.stop(applicationContext)
            // Starting / Stopping — игнор, чтобы не плодить race'ы.
            else -> Log.d(TAG, "onClick ignored in transient state ${BoxVpnService.currentStatus.name}")
        }
        // Re-render сразу, реальный статус доедет следующим setStatus().
        renderTile()
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

    private fun renderTile() {
        val tile = qsTile ?: return
        when (BoxVpnService.currentStatus) {
            VpnStatus.Started -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "L×Box"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Connected"
                }
            }
            VpnStatus.Starting -> {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "L×Box"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Connecting…"
                }
            }
            VpnStatus.Stopping -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "L×Box"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Stopping…"
                }
            }
            VpnStatus.Stopped -> {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "L×Box"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Disconnected"
                }
            }
        }
        try {
            tile.icon = Icon.createWithResource(this, R.mipmap.ic_launcher)
        } catch (_: Exception) {
            // Если по каким-то причинам ресурс не нашёлся, оставляем системный
            // дефолт — не критично.
        }
        tile.updateTile()
    }
}
