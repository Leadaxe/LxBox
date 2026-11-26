import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../../models/config_node.dart';
import '../../models/server_list.dart';
import '../../models/source_chain.dart';
import '../app_log.dart';
import '../builder/node_link_pool.dart';
import '../builder/node_link_resolve.dart' show NodeLinkTargets;
import '../settings_storage.dart';
import 'chain_form_validation.dart';
import 'chain_takeover.dart';

/// §761 — сохранённая цепочка, которую сборка выбрасывает: кольцо или
/// конфликт под перезапись `detour` ядра (цепочки, сохранённые до ядра
/// v1.14.4-lx.37-rc.2, — типично `[узел, Направление со всеми узлами]`).
class ChainTrouble {
  const ChainTrouble({
    required this.chain,
    required this.failure,
    required this.message,
  });

  final SourceChain chain;
  final ChainTakeoverFailure failure;

  /// Что не так и что сделать — тот же текст, что у находки редактора.
  final String message;
}

/// Узлы, группы и цепочки собранного конфига — по [ParsedConfig].
ChainBodies chainBodiesOfParsed(ParsedConfig config) => {
      for (final n in config.byTag.values)
        n.tag: (
          section: n.kind == 'endpoint' ? 'endpoints' : 'outbounds',
          body: n.raw,
        ),
    };

/// Выпадающие цепочки из [chains]: каждая включённая проверяется той же
/// проверкой, что редактор ([chainOnePathFailure]), по последнему собранному
/// конфигу [bodies]. Позиции — финальными тегами через [pool] и [lists].
List<ChainTrouble> findChainTroubles({
  required List<SourceChain> chains,
  required ChainBodies bodies,
  NodeLinkTargets? pool,
  List<ServerList> lists = const [],
}) {
  if (bodies.isEmpty) return const [];
  final out = <ChainTrouble>[];
  for (final c in chains) {
    if (!c.enabled || c.hops.length < 2) continue;
    final state = ChainFormState.of(c, pool: pool, lists: lists);
    final f = chainOnePathFailure(state, bodies, originalTag: c.tag);
    if (f == null) continue;
    final message = chainOnePathMessage(f);
    if (message == null) continue;
    out.add(ChainTrouble(chain: c, failure: f, message: message));
  }
  return out;
}

/// Отметка «скрыто»: хеш собранного конфига (узлы, группы, цепочки) и
/// найденных отказов. Любая правка конфига или цепочек даёт новую отметку —
/// плашка возвращается, если цепочка так и не исправлена.
String chainTroubleStamp(List<ChainTrouble> troubles, ChainBodies bodies) {
  final tags = bodies.keys.toList()..sort();
  final payload = jsonEncode({
    'bodies': [for (final t in tags) bodies[t]!.body],
    'troubles': [
      for (final t in troubles) [t.chain.tag, ...t.chain.toCanonJson().values],
    ],
  });
  return sha256.convert(utf8.encode(payload)).toString();
}

/// §761 — плашка «цепочка не собирается» на главном экране. Как
/// `CrashBannerState`: отдельный notifier, читается при старте и после
/// каждой сборки конфига (обновление подписки, импорт, правка).
class ChainTroubleState extends ChangeNotifier {
  ChainTroubleState._();

  static final ChainTroubleState I = ChainTroubleState._();

  List<ChainTrouble> _troubles = const [];
  String _stamp = '';
  String _dismissed = '';

  /// Что показать: пусто, если отказов нет или плашку скрыли при этом же
  /// состоянии конфига.
  List<ChainTrouble> get visible =>
      _stamp.isNotEmpty && _stamp == _dismissed ? const [] : _troubles;

  /// Перепроверить сохранённые цепочки по собранному конфигу [config].
  /// Best-effort: ошибка — молчим (диагностика не должна ломать экран).
  Future<void> refresh(ParsedConfig config, List<ServerList> lists) async {
    try {
      final chains = await SettingsStorage.getChains();
      final directions = await SettingsStorage.getDirections();
      final bodies = chainBodiesOfParsed(config);
      final troubles = findChainTroubles(
        chains: chains,
        bodies: bodies,
        pool: computeNodeLinkPool(lists, directions: directions),
        lists: lists,
      );
      final dismissed = await SettingsStorage.getDismissedChainTroubleStamp();
      _apply(troubles,
          troubles.isEmpty ? '' : chainTroubleStamp(troubles, bodies),
          dismissed);
    } catch (e) {
      AppLog.I.warning('Chain trouble check failed: $e');
    }
  }

  /// «Скрыть» — до следующего изменения конфига или цепочек.
  Future<void> dismiss() async {
    if (_stamp.isEmpty) return;
    try {
      await SettingsStorage.setDismissedChainTroubleStamp(_stamp);
    } catch (e) {
      AppLog.I.warning('Chain trouble stamp save failed: $e');
    }
    _dismissed = _stamp;
    notifyListeners();
  }

  void _apply(List<ChainTrouble> troubles, String stamp, String dismissed) {
    _troubles = troubles;
    _stamp = stamp;
    _dismissed = dismissed;
    notifyListeners();
  }

  @visibleForTesting
  void setForTest(List<ChainTrouble> troubles,
      {String stamp = 's', String dismissed = ''}) {
    _apply(troubles, stamp, dismissed);
  }
}
