import 'dart:convert';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';

/// §236/§296 — probe-конфиг для headless-сессии: ВСЕ переданные ноды (включая
/// null-слоты для выключенных/битых) как outbounds/endpoints, БЕЗ inbound'ов
/// (openTun не вызывается), минимальный DNS (local) для резолва доменных
/// адресов.
///
/// §296 — вход обобщён с `FolderServers` до `List<NodeSpec?>` (общий probe над
/// всей подсистемой ServerList: папки передают `members.map((m)=>m.node)` —
/// nullable, unfiltered; подписки/серверы — `list.nodes`). Индекс в списке =
/// адрес результата (`onResult`), одинаково для всех видов.
///
/// Detour-политика НЕ применяется — тестируем сами ноды; собственные
/// chained-цепочки ноды (⚙ из raw) сохраняются, как в боевом билдере.
class ProbeConfig {
  const ProbeConfig({
    required this.configJson,
    required this.tagByIndex,
    required this.brokenByIndex,
  });

  /// null = нет ни одной тестируемой ноды (все слоты битые/список пуст).
  final String? configJson;

  /// index → tag ноды в probe-конфиге (по нему зовём probeUrlTest).
  final Map<int, String> tagByIndex;

  /// index → причина, почему нода НЕ попала в конфиг:
  /// 'broken' (null-слот / raw не парсится) | 'invalid: …' (emit бросил).
  final Map<int, String> brokenByIndex;
}

/// Тег локального DNS-резолвера в probe-конфиге.
const kProbeDnsTag = 'local-dns';

ProbeConfig buildProbeConfig(List<NodeSpec?> nodes) {
  final outbounds = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': kDirectOutboundTag},
  ];
  final endpoints = <Map<String, dynamic>>[];
  final tagByIndex = <int, String>{};
  final brokenByIndex = <int, String>{};
  final usedTags = <String>{kDirectOutboundTag, kProbeDnsTag};

  String allocate(String base) {
    final b = base.isEmpty ? 'node' : base;
    if (usedTags.add(b)) return b;
    for (var i = 2;; i++) {
      final candidate = '$b-$i';
      if (usedTags.add(candidate)) return candidate;
    }
  }

  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (node == null) {
      brokenByIndex[i] = 'broken';
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
      tagByIndex[i] = mainTag;
    } catch (e) {
      brokenByIndex[i] = 'invalid: $e';
    }
  }

  if (tagByIndex.isEmpty) {
    return ProbeConfig(
      configJson: null,
      tagByIndex: tagByIndex,
      brokenByIndex: brokenByIndex,
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
    tagByIndex: tagByIndex,
    brokenByIndex: brokenByIndex,
  );
}

/// §284 — минимальный headless-конфиг для WARP-скана: БЕЗ нод (сырая проба идёт
/// по IP напрямую, теги не нужны), только `direct` + local DNS, чтобы ядро
/// поднялось. `openTun` не вызывается (нет inbound'ов, §119-инвариант).
String buildScanProbeConfigJson() => jsonEncode(<String, dynamic>{
      'log': {'level': 'error'},
      'dns': {
        'servers': [
          {'type': 'local', 'tag': kProbeDnsTag},
        ],
      },
      'outbounds': [
        {'type': 'direct', 'tag': kDirectOutboundTag},
      ],
      'route': {'default_domain_resolver': kProbeDnsTag},
    });

