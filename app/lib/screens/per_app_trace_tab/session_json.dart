import '../../services/traffic_profiler.dart';

Map<String, Object?> sessionToJson(Session s) => {
      ...s.toMetaJson(),
      'events': s.events.map((e) => e.toJson()).toList(),
      'by_domain': s.byDomain.values.map((d) => d.toJson()).toList(),
      'by_ip': s.byIp.values.map((i) => i.toJson()).toList(),
    };

/// §044/new-profiler — экспорт **списка событий** (не `Session`). Profiler/Live
/// не имеют `Session`-объекта — только rolling-buffer событий. Экспортируем
/// видимый отфильтрованный список + пересчитанные на лету агрегаты (тем же
/// `computeTraceAggregates`, что и `Session._recompute` / `TraceExplorer`).
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
