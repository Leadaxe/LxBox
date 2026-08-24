import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart' show initializeDateFormatting;
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'services/app_log.dart';
import 'services/l10n/locale_controller.dart';
import 'services/automation/automation_dispatcher.dart';
import 'services/automation/event_emitter.dart';
import 'services/clash_log_pump.dart';
import 'services/crash_banner_state.dart';
import 'services/install_source.dart';
import 'services/oom_reports.dart';
import 'services/stderr_reader.dart';
import 'services/subscription/subscription_identity.dart';
import 'services/debug/bootstrap.dart' as debug_bootstrap;
import 'services/nav/home_return_observer.dart';
import 'services/settings_storage.dart';
import 'services/template_loader.dart';
import 'services/version_info.dart';
import 'services/wifi_history_listener.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // §141 P1.9b — error boundary ставим ПЕРВЫМ делом, до init-await'ов. Раньше
  // он стоял после 4 await (VersionInfo/Identity/AppLog/...): брось любой из
  // них — краш до установки boundary, ошибка нигде не залогирована. Теперь
  // boundary активен с самого старта. AppLog.I пишет в in-memory ring и до
  // initPersistent, так что логирование здесь безопасно.
  //
  // Top-level error boundary (night T2-1). Любой uncaught Flutter-error
  // (build/layout/paint) и async error роутятся в AppLog как error-entry,
  // чтобы были видны на DebugScreen и в /logs endpoint'е. Red-screen
  // заменён на компактный fallback чтобы юзер видел описание, а не голый
  // stacktrace.
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.I.error(
      'Flutter error: ${details.exceptionAsString()}'
      '${details.context != null ? " @ ${details.context}" : ""}',
    );
    if (kDebugMode) prevOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.I.error('Uncaught async: $error');
    return true;
  };
  ErrorWidget.builder = (details) => _FallbackErrorWidget(details: details);

  // §141 P1.9b — init-await'ы обёрнуты: краш одного из них больше не валит
  // запуск целиком. Логируем и продолжаем best-effort — UI поднимется и
  // покажет диагностику (лучше частично-инициализированного app, чем чёрный
  // экран). Порядок сохранён (зависимости: Identity ← VersionInfo).
  try {
    // VersionInfo загружает PackageInfo → sync доступ к версии для About /
    // UpdateChecker (см. §066). Раньше версия дублировалась hardcoded const'ом
    // в AboutScreen — поднимать вручную легко забыть (произошло на v1.8.0).
    await VersionInfo.I.init();
    // §390 — Канал установки (GitHub / Play / F-Droid). До runApp: от него
    // зависит адрес «где взять новую версию», а снек об апдейте показывается
    // на первом кадре. Резолв дешёвый — dart-define, иначе один native-вызов.
    await InstallSourceResolver.init();
    // §118 — идентичность фетча подписок (UA override + HWID + device-meta).
    // После VersionInfo (UA дефолт зависит от версии), до runApp — `_fetch`
    // читает значения синхронно.
    await SubscriptionIdentity.init();
    // §038 — подгружаем persistent warning+error entries предыдущей сессии
    // (из обоих файлов applog.txt + corelog.txt — §043) до runApp, чтобы
    // Debug-экран сразу видел pre-crash JVM-events.
    await AppLog.I.initPersistent();
    // §189 — native_prefs: первый старт seed'ит JSON из native (bootstrap),
    // последующие — sync JSON⇒native (диск-истина перезаливает оперативку).
    // ДО UI (UI читает native-тумблеры из JSON-зеркала) и ДО возможного
    // авто-старта VPN. best-effort: ошибка не валит запуск (try выше).
    await SettingsStorage.bootstrapAndSyncNativePrefs();
    // §279 — язык приложения: применить сохранённую настройку ДО runApp
    // (первый кадр локализован) и ДО seed-миграций ниже (seed-time метки
    // резолвятся через активную локаль — TemplateLoader.load() кладёт кэш
    // под effectiveTag). Observer ловит смену языка устройства при
    // setting=='system' (didChangeLocales). best-effort (try выше).
    await LocaleController.I.bootstrap(await SettingsStorage.getAppLanguage());
    WidgetsBinding.instance.addObserver(LocaleController.I);
    // §279 Phase 5 — intl date-symbols для ru (format_utils.formatTime и др.
    // используют DateFormat под Intl.defaultLocale). ДО первого кадра, чтобы
    // DateFormat('ru') не бросил до того, как flutter_localizations прогреет
    // локаль сам. best-effort (try выше).
    await initializeDateFormatting('ru');
    // §125 F0 — one-shot миграция enabled_groups[] → directions[] (seed состава
    // Направлений из template на первом запуске). Идемпотентна. ДО первого билда
    // конфига, чтобы билдер (после F1) читал directions[] как source-of-truth.
    // best-effort: ошибка не валит запуск (try выше).
    final directionsTemplate = await TemplateLoader.load();
    await SettingsStorage.migrateDirectionsIfNeeded(
      directionsTemplate.groupTemplates,
      // §327 — `@urltest_*` в шаблоне auto-Направления резолвятся по default_value.
      varDefaults: {
        for (final v in directionsTemplate.vars) v.name: v.defaultValue,
      },
    );
    // §393 D1 — цепочки из старого storage (ключ `chains` без `order`)
    // получают позиции общего списка источников: встают в его конец, взаимный
    // порядок сохранён. Идемпотентна, ДО первого билда — билдер читает
    // цепочки уже в порядке общего списка.
    await SettingsStorage.migrateChainOrderIfNeeded();
    // §229 — вызов one-shot ремапа preset_id (§228) убран: миграция удалена,
    // отработала у всех, кто обновлялся начиная с v2.10.0.
    // §043 — pump sing-box logs из Kotlin EventChannel "lxbox/coreLog" в
    // AppLog как DebugSource.core. Идемпотентно (повторный attach no-op).
    ClashLogPump.I.attach();
    // §051 Phase 3 — register handler для native `onWifiSeen` events.
    // Если `auto_record_wifi_history` ON в storage — sync'нёт state с
    // native observer'ом (start callback). Default OFF, no-op до toggle.
    unawaited(WifiHistoryListener.I.init());
    // §047 — register incoming automation-intent dispatcher (native
    // LxBoxIntentReceiver → этот handler → shared action-handlers). Пассивен
    // пока receiver disabled. Подгружаем emit-gates из storage (default OFF).
    registerAutomationBridge();
    unawaited(AutomationEventEmitter.I.reload());
    // §316 — краш-репорты ядра. Ротация архива (ядро только докладывает
    // файлы и размер папки не ограничивает) + проверка «падало ли в прошлый
    // раз» для плашки на главном. Не блокируем старт: обе операции —
    // чтение/удаление файлов, к первому кадру отношения не имеют.
    unawaited(CrashReports.prune().then((removed) {
      if (removed > 0) AppLog.I.info('Pruned $removed old crash report(s)');
      return CrashBannerState.I.refresh();
    }));
    // §318 — OOM-снимки ядра. Ядро не ограничивает их ни числом, ни
    // размером (один снимок ~750 КБ), и на тест-устройстве папка доросла до
    // 427 МБ. Чистим на старте по той же причине, что и краши: в
    // Diagnostics пользователь может не заходить годами. Баннера тут нет —
    // OOM-снимок штатен и внимания не требует (§318 §3).
    unawaited(OomReports.prune().then((removed) {
      if (removed > 0) AppLog.I.info('Pruned $removed old OOM report(s)');
    }));
    // Первый read `appStartedAt` фиксирует момент старта для /device и /ping.
    // ignore: unused_local_variable
    final _ = debug_bootstrap.appStartedAt;
  } catch (e, st) {
    AppLog.I.error('Startup init failed (continuing best-effort): $e\n$st');
  }

  // §220 — ориентация: default портрет (как всегда было), toggle «Allow
  // rotation» в App Settings → General снимает фиксацию. Планшетный фидбэк.
  await applyAllowRotationSetting();
  runApp(const LxBoxApp());
}

/// §220 — применяет сохранённый `allow_rotation`-флаг к preferred
/// orientations. OFF (default) — жёсткий portraitUp, прежнее поведение.
/// ON — пустой список = «нет предпочтений»: ориентацию решает система по
/// своему auto-rotate (уважает системный rotation-lock). Вызывается на
/// старте (до runApp) и из App Settings при переключении toggle'а —
/// применяется мгновенно, рестарт не нужен.
Future<void> applyAllowRotationSetting() async {
  var allow = false;
  try {
    allow = await SettingsStorage.getAllowRotation();
  } catch (_) {
    // Storage недоступен — безопасный дефолт (портрет).
  }
  await SystemChrome.setPreferredOrientations(
    allow ? const <DeviceOrientation>[] : const [DeviceOrientation.portraitUp],
  );
}

/// Fallback-widget для UI-ошибок (replace Flutter's red screen).
/// Показывает краткое описание + подсказку открыть Debug → Logs.
class _FallbackErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FallbackErrorWidget({required this.details});

  @override
  Widget build(BuildContext context) {
    // В release сборке showDialog недоступен из ErrorWidget.builder
    // (context может быть без Material ancestor). Рендерим minimal UI.
    return Container(
      color: const Color(0xFF2A1515),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 40),
          const SizedBox(height: 12),
          // getLocalText (не Localizations.of): ErrorWidget.builder может
          // рендерить без Localizations-ancestor'а (краш до/вне MaterialApp).
          Text(
            getLocalText.s("Something went wrong in this section.\nCheck Debug → Logs."),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 12),
            Text(
              details.exceptionAsString(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// Global theme notifier — allows changing theme from anywhere.
class ThemeNotifier extends ChangeNotifier {
  ThemeNotifier() {
    _load();
  }

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  static const _key = 'app_theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    _mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}

final themeNotifier = ThemeNotifier();

class LxBoxApp extends StatelessWidget {
  const LxBoxApp({super.key});

  static const _seed = Colors.indigo;

  @override
  Widget build(BuildContext context) {
    // §279 — merged Listenable: смена локали = механизм themeNotifier
    // (rebuild единственного MaterialApp, без remount и подъёма контроллеров).
    return AnimatedBuilder(
      animation: Listenable.merge([themeNotifier, LocaleController.I]),
      builder: (context, _) {
        // §285 — getLocalText отслеживает применяемую локаль через
        // LocaleController._applyLocale (dict-reload на каждую смену); отдельного
        // per-build присваивания активного локализатора не требуется.
        return MaterialApp(
          title: 'L×Box',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: _seed),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: _seed,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: themeNotifier.mode,
          // §279 — ВСЕГДА подаём явную локаль (effective уже резолвит
          // 'system' по языку устройства через PlatformDispatcher). Ранее
          // 'system' давал locale: null, и Flutter полагался на собственный
          // резолв null-локали; при runtime-переходе явная→null (напр. ru →
          // «как в системе» на устройстве с English) Localizations не
          // пересчитывал локаль — UI застревал на прежнем русском. Явное
          // значение форсит пересборку Localizations на каждую смену.
          locale: LocaleController.I.effective,
          supportedLocales: LocaleController.supportedLocales,
          // §285 — только Flutter-встроенные делегаты (Material/Widgets/
          // Cupertino chrome). Строки приложения идут через getLocalText,
          // не через Localizations-делегат.
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // §076: global observer срабатывает на возврат на home (root)
          // — auto-rebuild config'а если configDirty.
          navigatorObservers: [homeReturnObserver],
          home: const HomeScreen(),
        );
      },
    );
  }
}
