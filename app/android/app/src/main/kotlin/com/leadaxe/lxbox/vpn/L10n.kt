package com.leadaxe.lxbox.vpn

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import android.util.Log
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.Libbox
import java.util.Locale

/// §279 Phase 6 (спека §6.2) — резолвер локали нативных поверхностей.
///
/// Работает при мёртвом Flutter: выбор языка лежит в `boxvpn_boot`
/// SharedPreferences (`app_language` = "system" | "en" | "ru") — derived cache
/// от var `app_language` в lxbox_settings.json (истина — Dart-сторадж, §6.5).
///
/// Контекст оборачивается В МОМЕНТ РЕНДЕРА (`createConfigurationContext`),
/// никогда не кэшируется — все нативные поверхности (шторка, QS-тайл,
/// shortcuts, automation-активити, тосты) зовут [str] на каждую отрисовку.
object L10n {
    private const val TAG = "L10n"

    /// Валидные значения настройки (зеркало `SettingsStorage.appLanguageValues`).
    private val KNOWN = setOf("system", "en", "ru")

    const val SETTING_SYSTEM = "system"

    /// Текущее значение настройки (неизвестное → "system").
    fun setting(base: Context): String {
        val v = BootReceiver.getAppLanguage(base)
        return if (v in KNOWN) v else SETTING_SYSTEM
    }

    /// Контекст, resolving ресурсы под выбранной локалью. При "system"
    /// возвращает base как есть (система/пер-app-локали 33+ уже применены).
    fun ctx(base: Context): Context {
        val s = setting(base)
        if (s == SETTING_SYSTEM) return base
        val cfg = Configuration(base.resources.configuration)
        cfg.setLocale(Locale(s))
        return base.createConfigurationContext(cfg)
    }

    fun str(base: Context, id: Int, vararg args: Any): String =
        if (args.isEmpty()) ctx(base).getString(id)
        else ctx(base).getString(id, *args)

    /// §279 (спека §6.3) — MethodChannel `setAppLanguage`: pref →
    /// LocaleManager-пуш (33+) + last_pushed_locale-зеркало → relabel всех
    /// нативных поверхностей. "system" обязан пушить ПУСТОЙ список — иначе
    /// PlatformDispatcher навсегда возвращал бы последний явный выбор и
    /// «System default» была бы мёртвой опцией (спека §6.4).
    fun applySetting(base: Context, raw: String) {
        val s = if (raw in KNOWN) raw else SETTING_SYSTEM
        BootReceiver.setAppLanguage(base, s)
        if (Build.VERSION.SDK_INT >= 33) {
            // Извлечено в @RequiresApi-helper: ART class verifier на старых
            // API не должен встречать ссылку на LocaleManager (конвенция репо,
            // см. LxBoxTileService.applySubtitle).
            runCatching { pushApplicationLocales(base, s) }
                .onFailure { Log.w(TAG, "LocaleManager push failed: ${it.message}") }
        }
        refreshSurfaces(base)
    }

    @RequiresApi(33)
    private fun pushApplicationLocales(base: Context, s: String) {
        val lm = base.getSystemService(LocaleManager::class.java) ?: return
        lm.applicationLocales = if (s == SETTING_SYSTEM) {
            LocaleList.getEmptyLocaleList()
        } else {
            LocaleList.forLanguageTags(s)
        }
        // Зеркало последнего НАШЕГО пуша ("" = пустой список) —
        // трёхсторонний reconciliation на Dart-старте (спека §6.4).
        BootReceiver.setLastPushedLocale(base, if (s == SETTING_SYSTEM) "" else s)
    }

    /// §279 (спека §6.3, шаги 1–5) — перештамповка всех нативных поверхностей
    /// на активную локаль. Зовётся из setAppLanguage-handler'а и из
    /// [LocaleChangedReceiver] (системная смена при setting=="system").
    fun refreshSurfaces(base: Context) {
        // 1. Идемпотентный resubmit notification-канала (rename).
        runCatching { ServiceNotification.createChannel(base) }
            .onFailure { Log.w(TAG, "channel resubmit failed: ${it.message}") }
        // 2. Перерисовка шторки существующим update-путём (builder
        //    реконструируется целиком на каждый show — см. ServiceNotification).
        //    Broadcast долетает только до работающего сервиса — иначе no-op.
        runCatching { BoxVpnService.updateNotification(base) }
            .onFailure { Log.w(TAG, "notification relabel failed: ${it.message}") }
        // 3. Shortcuts: updateShortcuts — оба ярлыка + pinned-копии.
        runCatching { QuickShortcuts.relabel(base) }
            .onFailure { Log.w(TAG, "shortcuts relabel failed: ${it.message}") }
        // 4. QS-тайл.
        runCatching { LxBoxTileService.refreshTile(base) }
            .onFailure { Log.w(TAG, "tile refresh failed: ${it.message}") }
        // 5. Локаль ядра.
        applyLibboxLocale(base)
    }

    /// §279 (спека §6.3, шаг 5) — mid-run переключение локали строк ядра.
    /// Верифицировано по исходникам sing-box-lx: `locale.Set` хранит текущую
    /// локаль в atomic-указателе, читаемом В МОМЕНТ форматирования строки
    /// (experimental/locale/locale.go) — mid-run вызов поддержан. Окно: уже
    /// отформатированные/закэшированные строки остаются на прежнем языке до
    /// следующего рендера ядром (device-verification pending).
    fun applyLibboxLocale(base: Context) {
        val s = setting(base)
        runCatching {
            if (s == SETTING_SYSTEM) {
                // Как в BoxApplication.onCreate: libbox 1.14 строг к
                // комбинации язык+регион → fallback на голый язык.
                runCatching {
                    Libbox.setLocale(
                        Locale.getDefault().toLanguageTag().replace("-", "_"))
                }.recoverCatching {
                    Libbox.setLocale(Locale.getDefault().language)
                }.getOrThrow()
            } else {
                Libbox.setLocale(s)
            }
        }.onFailure { Log.w(TAG, "Libbox.setLocale failed: ${it.message}") }
    }

    /// §279 (спека §6.4) — снимок per-app-локалей для Dart-reconciliation.
    /// API < 33 / сбой → {"supported": false} (Dart делает no-op).
    fun appLanguageState(base: Context): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 33) return mapOf("supported" to false)
        return runCatching { readAppLanguageState(base) }
            .getOrElse { mapOf("supported" to false) }
    }

    @RequiresApi(33)
    private fun readAppLanguageState(base: Context): Map<String, Any?> {
        val lm = base.getSystemService(LocaleManager::class.java)
            ?: return mapOf("supported" to false)
        return mapOf<String, Any?>(
            "supported" to true,
            "applicationLocales" to lm.applicationLocales.toLanguageTags(),
            "lastPushedLocale" to BootReceiver.getLastPushedLocale(base),
        )
    }
}
