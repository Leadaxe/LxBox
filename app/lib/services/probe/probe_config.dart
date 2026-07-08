import 'dart:convert';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/server_list.dart';
import '../../models/singbox_entry.dart';

/// §236 — probe-конфиг для headless-сессии: ВСЕ члены папки (включая
/// выключенных) как outbounds/endpoints, БЕЗ inbound'ов (openTun не
/// вызывается), минимальный DNS (local) для резолва доменных адресов.
///
/// Detour-политика папки НЕ применяется — тестируем сами ноды; собственные
/// chained-цепочки члена (⚙ из raw) сохраняются, как в боевом билдере.
class ProbeConfig {
  const ProbeConfig({
    required this.configJson,
    required this.tagByMember,
    required this.brokenByMember,
  });

  /// null = нет ни одной тестируемой ноды (все члены битые/папка пуста).
  final String? configJson;

  /// memberIndex → tag ноды в probe-конфиге (по нему зовём probeUrlTest).
  final Map<int, String> tagByMember;

  /// memberIndex → причина, почему член НЕ попал в конфиг:
  /// 'broken' (raw не парсится) | 'invalid: …' (emit бросил).
  final Map<int, String> brokenByMember;
}

/// Тег локального DNS-резолвера в probe-конфиге.
const kProbeDnsTag = 'local-dns';

ProbeConfig buildProbeConfig(FolderServers folder) {
  final outbounds = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': kDirectOutboundTag},
  ];
  final endpoints = <Map<String, dynamic>>[];
  final tagByMember = <int, String>{};
  final brokenByMember = <int, String>{};
  final usedTags = <String>{kDirectOutboundTag, kProbeDnsTag};

  String allocate(String base) {
    final b = base.isEmpty ? 'node' : base;
    if (usedTags.add(b)) return b;
    for (var i = 2;; i++) {
      final candidate = '$b-$i';
      if (usedTags.add(candidate)) return candidate;
    }
  }

  for (var i = 0; i < folder.members.length; i++) {
    final node = folder.members[i].node;
    if (node == null) {
      brokenByMember[i] = 'broken';
      continue;
    }
    try {
      final raw = node.getEntries(null);
      // Зеркалим ServerListBuild: детуры первыми (main ссылается на tag).
      for (final d in raw.detours) {
        d.map['tag'] = allocate(d.tag);
      }
      final mainTag = allocate(node.tag);
      raw.main.map['tag'] = mainTag;
      if (raw.detours.isNotEmpty) {
        raw.main.map['detour'] = raw.detours.first.tag;
      }
      for (final e in raw.all) {
        switch (e) {
          case Outbound():
            outbounds.add(e.map);
          case Endpoint():
            endpoints.add(e.map);
        }
      }
      tagByMember[i] = mainTag;
    } catch (e) {
      brokenByMember[i] = 'invalid: $e';
    }
  }

  if (tagByMember.isEmpty) {
    return ProbeConfig(
      configJson: null,
      tagByMember: tagByMember,
      brokenByMember: brokenByMember,
    );
  }

  final config = <String, dynamic>{
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': kProbeDnsTag},
      ],
    },
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': {
      // Адреса серверов бывают доменами — ядру нужен резолвер по умолчанию.
      'default_domain_resolver': kProbeDnsTag,
    },
  };
  return ProbeConfig(
    configJson: jsonEncode(config),
    tagByMember: tagByMember,
    brokenByMember: brokenByMember,
  );
}
