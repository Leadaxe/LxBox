import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/debug_entry.dart';
import '../models/server_list.dart';
import 'app_log.dart';
import 'debug/debug_registry.dart';
import 'settings_storage.dart';
import 'stderr_reader.dart';
import '../vpn/box_vpn_client.dart';

/// Собирает единый файл-дамп для репорта: конфиг + логи + подписки +
/// переменные — всё в одном JSON-файле. Пишет в temp, возвращает path
/// (дальше UI шлёт через Share.shareXFiles).
class DumpBuilder {
  DumpBuilder._();

  static Future<String> build() async {
    final now = DateTime.now();

    String? config;
    try {
      final raw = await BoxVpnClient().getConfig();
      if (raw.isNotEmpty && raw != '{}') config = raw;
    } catch (_) {}

    final vars = await SettingsStorage.getAllVars();
    // Берём live `ServerList`'ы из `SubscriptionController` через
    // DebugRegistry — там после `init()` уже распарсены `nodes` (тело
    // подписки → NodeSpec'ы с warnings'ами). Persisted-снапшот через
    // `SettingsStorage.getServerLists()` сериализует подписки **без**
    // nodes (ноды живут только в памяти после parseFromSource), поэтому
    // dump из storage всегда давал `_node_count: 0` для подписок. Live —
    // ровно то что юзер видит в UI и что используется при build'е конфига.
    //
    // Fallback на storage если registry ещё не bind'ился (Debug API
    // стартует до HomeScreen.initState — ранний dump через debug-API
    // не должен падать).
    final liveSub = DebugRegistry.I.sub;
    final List<ServerList> lists = liveSub != null
        ? liveSub.entries.map((e) => e.list).toList()
        : await SettingsStorage.getServerLists();
    // §038 — содержимое external/stderr.log (Go panic-stacktrace последней
    // сессии libbox, переживает SIGABRT). null если файл отсутствует/пуст.
    final stderr = await StderrReader.read();

    final dump = <String, dynamic>{
      'generated_at': now.toIso8601String(),
      'app': 'lxbox',
      'vars': vars,
      'server_lists': lists.map(_sanitizeList).toList(),
      'config': config == null ? null : _tryDecode(config),
      'debug_log': AppLog.I.entries.map(_entryJson).toList(),
      'stderr_log': stderr,
    };

    final dir = await getTemporaryDirectory();
    final stamp =
        now.toIso8601String().replaceAll(':', '-').substring(0, 19);
    final file = File('${dir.path}/lxbox-dump-$stamp.json');
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(dump));
    return file.path;
  }

  /// `ServerList.toJson()` + node tags (без полного NodeSpec, чтобы файл
  /// не раздуло для подписок с 200+ узлами). Если нужен полный recreate —
  /// есть url, тело тянется заново.
  static Map<String, dynamic> _sanitizeList(ServerList l) {
    final j = l.toJson();
    j['_node_tags'] = l.nodes.map((n) => n.tag).toList();
    j['_node_count'] = l.nodes.length;
    return j;
  }

  static dynamic _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return s;
    }
  }

  static Map<String, dynamic> _entryJson(DebugEntry e) => {
        'time': e.time.toIso8601String(),
        'level': e.level.name,
        'source': e.source == DebugSource.core ? 'core' : 'app',
        'message': e.message,
      };
}
