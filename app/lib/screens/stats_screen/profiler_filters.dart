import 'profiler_filter.dart';

/// §244 — session-холдер фильтров профайлера (баг B4 с 4PDA: «поставил
/// фильтр, ушёл на другую вкладку, вернулся — фильтр слетел»).
///
/// Раньше каждый tab-State (`live_events_tab` / `per_app_trace_tab`) создавал
/// свой `ProfilerFilter` полем, а вкладки лежат в голом `TabBarView` без
/// keepAlive → уход с вкладки = dispose State = потеря фильтра.
///
/// Теперь фильтры живут статиками на уровне сессии приложения (паттерн
/// `TrafficProfiler.I`): переживают переключение вкладок и уход со
/// Stats-экрана, но НЕ перезапуск приложения. Никакого persist на диск —
/// фильтр ситуативный (диагностика «здесь и сейчас»).
///
/// Session-объекты НЕ диспоузятся (dispose ChangeNotifier'а убил бы notifier
/// для всех будущих State). Слушатели (`TraceExplorer`,
/// `ProfilerFilterSheet`) вешают/снимают addListener/removeListener парно —
/// пересоздание State на session-объекте безопасно.
///
/// Инстансов ДВА и они независимы: у App-вкладки и Profiler-вкладки разные
/// наборы осей (App-вкладка не применяет app-ось — target зафиксирован
/// сессией) и разные user-интенты. При остановке/старте VPN фильтр
/// сознательно НЕ сбрасывается (решение владельца — живёт всю сессию
/// приложения; сброс руками через Filter → Reset all).
class ProfilerFilters {
  ProfilerFilters._();

  /// Фильтр App-вкладки (per-app trace).
  static final ProfilerFilter appTab = ProfilerFilter();

  /// Фильтр Profiler-вкладки (system-wide Live).
  static final ProfilerFilter liveTab = ProfilerFilter();
}
