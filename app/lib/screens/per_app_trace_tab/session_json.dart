import '../../services/traffic_profiler.dart';

/// §044/new-profiler — экспорт **списка событий**. Profiler/Live работают с
/// rolling-buffer'ом событий. Экспортируем видимый отфильтрованный список +
/// пересчитанные на лету агрегаты (тем же `computeTraceAggregates`, что и
/// `TraceExplorer`).
///
/// [events] — уже отфильтрованный набор (что юзер видит на экране, то и в JSON).
Map<String, Object?> eventsToJson(List<TrafficEvent> events) {
  final agg = computeTraceAggregates(events);
  return {
    'exported_at': DateTime.now().toIso8601String(),
    'event_count': events.length,
    'events': events.map((e) => e.toJson()).toList(),
    'by_domain': agg.byDomain.values.map((d) => d.toJson()).toList(),
    'by_ip': agg.byIp.values.map((i) => i.toJson()).toList(),
  };
}
