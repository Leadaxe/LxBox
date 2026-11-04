import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/taildrop_tags_sync.dart';

import '../parser/engine_test_setup.dart';

/// §707 итер. 9 — производные множества итоговых тегов Taildrop
/// (`taildrop_commands_tags`, `taildrop_autosave_tags` зеркала): свой сервер
/// в корне, член папки с префиксом `tag_policy`, выключенная запись, узел
/// подписки, тег с суффиксом дедупа из карты сборки.
void main() {
  setUpAll(loadEngineSections);
  var seq = 0;

  TailscaleSpec ts(String tag) =>
      TailscaleSpec(id: 'n${seq++}', tag: tag, label: tag, body: const {});

  String tsRaw(String tag) =>
      jsonEncode({'type': 'tailscale', 'tag': tag, 'auth_key': 'k-$tag'});

  UserServer server(String id, NodeSpec node,
          {String prefix = '',
          bool enabled = true,
          bool commands = false,
          bool autosave = false}) =>
      UserServer(
        id: id,
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        taildropCommands: commands,
        taildropAutosave: autosave,
        nodes: [node],
      );

  test('корень, член папки с префиксом, выключенные и подписка', () {
    final lists = <ServerList>[
      server('s1', ts('home'), commands: true, autosave: true),
      server('s2', ts('work'), prefix: 'W', autosave: true),
      // Выключенный сервер — вне конфига, в множества не входит.
      server('s3', ts('off'), enabled: false, commands: true),
      // Поля выключены — не входит.
      server('s4', ts('plain')),
      FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '🏠',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: tsRaw('nas'), taildropCommands: true),
          // Выключенный член — не входит.
          FolderMember(
              raw: tsRaw('old'), enabled: false, taildropAutosave: true),
        ],
      ),
      // Выключенная папка целиком — не входит.
      FolderServers(
        id: 'f2',
        name: 'G',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: tsRaw('gone'), taildropCommands: true)],
      ),
      // Подписка записи узла не имеет — её узлы не входят никогда.
      SubscriptionServers(
        id: 'sub',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [ts('fromsub')],
      ),
    ];
    final sets = taildropTagSets(lists);
    expect(sets.commands, ['home', '🏠 nas']);
    expect(sets.autosave, ['W work', 'home']);
  });

  test('карта сборки: тег с суффиксом дедупа берётся у того же узла', () {
    final a = ts('box');
    final b = ts('box');
    final lists = <ServerList>[
      server('s1', a),
      server('s2', b, autosave: true),
    ];
    // Без карты (до первой сборки) — тег по префиксу: при дедупе совпадёт
    // с первым узлом, а не со вторым (безопасный отказ до сборки).
    expect(taildropTagSets(lists).autosave, ['box']);
    final emitted = <String, NodeSpec>{'box': a, 'box-2': b};
    expect(taildropTagSets(lists, emitted: emitted).autosave, ['box-2']);
    expect(
        taildropRecordForTag('box-2', lists, emitted: emitted)?.entryIndex, 1);
    expect(taildropRecordForTag('box-2', lists), isNull);
  });

  test('карта без узла: тег по префиксу записи', () {
    final lists = <ServerList>[server('s1', ts('x'), prefix: 'P', commands: true)];
    final sets = taildropTagSets(lists, emitted: {'other': ts('other')});
    expect(sets.commands, ['P x']);
  });

  test('pushTaildropTags отдаёт оба множества целиком', () async {
    final pushed = <TaildropTagSets>[];
    debugTaildropTagsSink = (s) async {
      pushed.add(s);
      return true;
    };
    addTearDown(() => debugTaildropTagsSink = null);
    await pushTaildropTags([server('s1', ts('a'), commands: true)]);
    await pushTaildropTags(const []);
    expect(pushed, [
      const TaildropTagSets(commands: ['a'], autosave: []),
      const TaildropTagSets(commands: [], autosave: []),
    ]);
  });
}
