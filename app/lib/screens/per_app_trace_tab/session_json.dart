import '../../services/traffic_profiler.dart';

Map<String, Object?> sessionToJson(Session s) => {
      ...s.toMetaJson(),
      'events': s.events.map((e) => e.toJson()).toList(),
      'by_domain': s.byDomain.values.map((d) => d.toJson()).toList(),
      'by_ip': s.byIp.values.map((i) => i.toJson()).toList(),
    };
