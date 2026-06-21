package com.leadaxe.lxbox.automation

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// §047 Шаг 2 — headless edit-Activity для частых команд (Start / Stop /
/// Toggle). Host (Tasker / MacroDroid) показывает их **отдельными строками** в
/// списке плагинов (через `activity-alias` с разными label в манифесте). Тап по
/// строке открывает эту activity, но UI не рисуется — мы сразу формируем готовый
/// bundle и `setResult`, как «one-tap» плагин (как у VPN Hotspot).
///
/// Какую команду отдавать — определяется alias'ом, через который нас открыли
/// (`componentName.className`), сматченным в [ALIAS_CMD]. Кастомные команды с
/// extra (switch-node и т.п.) — в [LocaleSettingEditActivity] под «Custom…».
class LocaleQuickActionActivity : Activity() {

    companion object {
        /// alias FQN → (cmd, blurb). Alias'ы объявлены в манифесте.
        private val ALIAS_CMD = mapOf(
            "com.leadaxe.lxbox.automation.LocaleStartAlias" to ("start-vpn" to "Start VPN"),
            "com.leadaxe.lxbox.automation.LocaleStopAlias" to ("stop-vpn" to "Stop VPN"),
            "com.leadaxe.lxbox.automation.LocaleToggleAlias" to ("toggle-vpn" to "Toggle VPN"),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Имя alias'а, через который host нас открыл.
        val alias = intent.component?.className
        val entry = ALIAS_CMD[alias] ?: ("toggle-vpn" to "Toggle VPN")
        val (cmd, blurb) = entry

        val data = Intent().apply {
            putExtra(
                LocaleApi.EXTRA_BUNDLE,
                LocaleApi.buildSettingBundle(cmd, emptyMap()),
            )
            putExtra(LocaleApi.EXTRA_STRING_BLURB, blurb)
        }
        setResult(RESULT_OK, data)
        finish()   // UI не показываем — мгновенный one-tap плагин.
    }
}
