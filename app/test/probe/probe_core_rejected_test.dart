import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

import '../parser/engine_test_setup.dart';

/// §723 — узел, который отвергло ядро, не роняет пинг всего списка:
/// хранимый вердикт `core_rejected` не пускает узел в пробный конфиг, а отказ
/// ядра на старте пробы вынимает названный узел и повторяет старт.
void main() {
  setUpAll(loadEngineSections);

  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  const reason = 'decode key: illegal base64 data at input byte 24';

  /// Теги outbound'ов каждого `probeStart` по порядку вызовов (без `direct`).
  final starts = <List<String>>[];

  /// Ответ ядра на `probeStart` по тегам конфига: '' — принят.
  String Function(List<String> tags) answer = (_) => '';

  List<NodeSpec?> nodes() => [
        for (final name in ['Alpha', 'Beta', 'Gamma'])
          FolderMember(
                  raw: 'vless://u@${name.toLowerCase()}.example:443'
                      '?type=ws&security=tls#$name')
              .node,
      ];

  setUp(() {
    starts.clear();
    answer = (_) => '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'probeStart':
          final config = jsonDecode((call.arguments as Map)['config'] as String)
              as Map<String, dynamic>;
          final tags = [
            for (final o in config['outbounds'] as List)
              if ((o as Map)['type'] != 'direct') o['tag'] as String,
          ];
          starts.add(tags);
          final error = answer(tags);
          return {'error': error, 'runId': error.isEmpty ? starts.length : 0};
        case 'probeUrlTest':
          return {'delay': 120, 'error': ''};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<(String, Map<int, ProbeResult>)> run(List<NodeSpec?> list) async {
    final results = <int, ProbeResult>{};
    final err = await ProbeRunner(concurrency: 2).run(
      list,
      url: 'https://example.com/gen204',
      timeoutMs: 3000,
      onResult: (i, r) => results[i] = r,
    );
    return (err, results);
  }

  String initError(List<String> tags, String tag) =>
      'start or reload service: initialize outbound[${tags.indexOf(tag) + 1}] '
      'vless[$tag]: $reason';

  test('хранимый вердикт core_rejected: узел в конфиг не идёт, остальные измерены',
      () async {
    final list = nodes();
    list[1]!.warnings.insert(0, StoredWarning.coreRejected(reason).toWarning());

    final (err, results) = await run(list);

    expect(err, isEmpty);
    expect(starts, [
      ['Alpha', 'Gamma'],
    ]);
    expect(results[1]!.status, ProbeStatus.invalid);
    expect(results[1]!.message, '$kProbeCoreRejectedPrefix$reason');
    expect(results[0]!.status, ProbeStatus.ok);
    expect(results[2]!.status, ProbeStatus.ok);
  });

  test('ядро отвергло узел на старте пробы: узел вынут, старт повторён', () async {
    answer = (tags) => tags.contains('Beta') ? initError(tags, 'Beta') : '';

    final (err, results) = await run(nodes());

    expect(err, isEmpty);
    expect(starts, [
      ['Alpha', 'Beta', 'Gamma'],
      ['Alpha', 'Gamma'],
    ]);
    expect(results[1]!.status, ProbeStatus.invalid);
    expect(results[1]!.message, '$kProbeCoreRejectedPrefix$reason');
    expect(results[0]!.status, ProbeStatus.ok);
    expect(results[2]!.status, ProbeStatus.ok);
  });

  test('отказ ядра без названного узла — ошибка на весь прогон, как раньше',
      () async {
    answer = (_) => 'start or reload service: initialize cache-file: timeout';

    final (err, results) = await run(nodes());

    expect(err, contains('cache-file'));
    expect(starts, hasLength(1));
    expect(results, isEmpty);
  });

  test('ядро отвергает узел за узлом — прогон останавливается на пределе',
      () async {
    answer = (tags) => initError(tags, tags.first);
    final many = <NodeSpec?>[
      for (var i = 0; i < kProbeMaxCoreRejects + 3; i++)
        FolderMember(
                raw: 'vless://u@h$i.example:443?type=ws&security=tls#N$i')
            .node,
    ];

    final (err, results) = await run(many);

    expect(err, contains(reason));
    expect(starts, hasLength(kProbeMaxCoreRejects + 1));
    expect(
      results.values.where((r) => r.status == ProbeStatus.invalid),
      hasLength(kProbeMaxCoreRejects),
    );
  });
}
