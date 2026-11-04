import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/taildrop_tags_sync.dart';

import '../parser/engine_test_setup.dart';

/// §707 итер. 9 (контракт 1.1.159) — производные множества итоговых тегов
/// ВЫКЛЮЧЕННЫХ (`taildrop_commands_off_tags`, `taildrop_autosave_off_tags`
/// зеркала): свой сервер в корне, член папки с префиксом `tag_policy`,
/// выключенная запись, узел подписки, тег с суффиксом дедупа из карты сборки.
/// Тега нет в множестве — ядро видит «включено».
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
          bool commandsOff = false,
          bool autosaveOff = false}) =>
      UserServer(
        id: id,
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        disableTaildropCommands: commandsOff,
        disableTaildropAutosave: autosaveOff,
        nodes: [node],
      );

  test('корень, член папки с префиксом, выключенные и подписка', () {
    final lists = <ServerList>[
      server('s1', ts('home'), commandsOff: true, autosaveOff: true),
      server('s2', ts('work'), prefix: 'W', autosaveOff: true),
      // Выключенный сервер — вне конфига, в множества не входит.
      server('s3', ts('off'), enabled: false, commandsOff: true),
      // Полей нет — всё включено, ни в одно множество не входит.
      server('s4', ts('plain')),
      FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '🏠',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: tsRaw('nas'), disableTaildropCommands: true),
          // Выключенный член — не входит.
          FolderMember(
              raw: tsRaw('old'), enabled: false, disableTaildropAutosave: true),
        ],
      ),
      // Выключенная папка целиком — не входит.
      FolderServers(
        id: 'f2',
        name: 'G',
        enabled: false,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: tsRaw('gone'), disableTaildropCommands: true)
        ],
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
    expect(sets.commandsOff, ['home', '🏠 nas']);
    expect(sets.autosaveOff, ['W work', 'home']);
  });

  test('карта сборки: тег с суффиксом дедупа берётся у того же узла', () {
    final a = ts('box');
    final b = ts('box');
    final lists = <ServerList>[
      server('s1', a),
      server('s2', b, autosaveOff: true),
    ];
    final emitted = <String, NodeSpec>{'box': a, 'box-2': b};
    expect(taildropTagSets(lists, emitted: emitted).autosaveOff, ['box-2']);
    expect(
        taildropRecordForTag('box-2', lists, emitted: emitted)?.autosaveOff,
        isTrue);
    expect(
        taildropRecordForTag('box-2', lists, emitted: emitted)?.entryIndex, 1);
    expect(taildropRecordForTag('box-2', lists), isNull);
  });

  test('дедуп без карты: тег ядра не в множестве — ядро видит «включено»', () {
    final a = ts('box');
    final b = ts('box');
    final lists = <ServerList>[
      server('s1', a),
      server('s2', b, commandsOff: true, autosaveOff: true),
    ];
    // До первой сборки тег по префиксу (`box`) с тегом ядра второго узла
    // (`box-2`) не совпадает: у него действует умолчание.
    final sets = taildropTagSets(lists);
    expect(sets.commandsOff, isNot(contains('box-2')));
    expect(sets.autosaveOff, isNot(contains('box-2')));
  });

  test('карта без узла: тег по префиксу записи', () {
    final lists = <ServerList>[
      server('s1', ts('x'), prefix: 'P', commandsOff: true)
    ];
    final sets = taildropTagSets(lists, emitted: {'other': ts('other')});
    expect(sets.commandsOff, ['P x']);
    expect(sets.autosaveOff, isEmpty);
  });

  test('pushTaildropTags отдаёт оба множества целиком', () async {
    final pushed = <TaildropTagSets>[];
    debugTaildropTagsSink = (s) async {
      pushed.add(s);
      return true;
    };
    addTearDown(() => debugTaildropTagsSink = null);
    await pushTaildropTags([server('s1', ts('a'), commandsOff: true)]);
    await pushTaildropTags([server('s1', ts('a'))]);
    expect(pushed, [
      const TaildropTagSets(commandsOff: ['a'], autosaveOff: []),
      const TaildropTagSets(commandsOff: [], autosaveOff: []),
    ]);
  });
}
