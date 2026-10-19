import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/builder/preset_node_loop.dart';

// Конформанс-раннер корпуса обхода узлов (контракт 1.1.119, LxBox §643):
// `corpus/template/for_each_node/` (бывший `for_each/`, §578) и
// `corpus/template/for_each_node_do/` — по формату README «Разделы
// for_each_node/ и for_each_node_do/»:
//
//   <case>.preset.json   {"_comment": "…", "preset": {...}, "nodes": [...]}
//   <case>.vars.json      значения переменных ПРЕСЕТА строками (как в записи)
//   <case>.expected.json  {"load"?, "rules": [...], "dns_servers": [...],
//                          "dns_rules": [...], "warnings": [...]}
//
// `preset` несёт только ключи языка — оболочку (`preset_id`, `ui`) добавляет
// этот раннер. `nodes` — узлы конфига в порядке файла: `{tag, body,
// enabled?, in_config?, skip_tailscale_presets?, allow_local?, allow_lan?,
// allow_gateway?}` (§656); `enabled: false` /
// `in_config: false` отсеиваются здесь (сборка LxBox их до обхода не
// доводит). `load: reject` = исключение [parsePresetNodeLoop] — той же
// функции, которой загрузчик шаблона разбирает обход
// (`validateTemplateConstructs`).

const _kSections = ['for_each_node', 'for_each_node_do'];

class _LoopCase {
  _LoopCase({
    required this.presetJson,
    required this.nodes,
    required this.varsValues,
    required this.expected,
  });

  final Map<String, dynamic> presetJson;
  final List<PresetNode> nodes;
  final Map<String, String> varsValues;
  final Map<String, dynamic> expected;
}

_LoopCase _loadCase(String base) {
  final preset = jsonDecode(File('$base.preset.json').readAsStringSync())
      as Map<String, dynamic>;
  final varsRaw = jsonDecode(File('$base.vars.json').readAsStringSync())
      as Map<String, dynamic>;
  final expected = jsonDecode(File('$base.expected.json').readAsStringSync())
      as Map<String, dynamic>;

  return _LoopCase(
    presetJson: Map<String, dynamic>.from(
        preset['preset'] as Map<String, dynamic>? ?? const {}),
    nodes: <PresetNode>[
      for (final n in (preset['nodes'] as List? ?? const []))
        if ((n as Map<String, dynamic>)['enabled'] != false &&
            n['in_config'] != false)
          PresetNode(
            tag: n['tag'] as String,
            body: Map<String, dynamic>.from(n['body'] as Map),
            // §656 (контракт 1.1.126) — поля записи узла кладутся в
            // пространство обхода.
            skipTailscalePresets:
                n['skip_tailscale_presets'] as bool? ?? false,
            allowLocal: n['allow_local'] as bool? ?? false,
            allowLan: n['allow_lan'] as bool? ?? false,
            allowGateway: n['allow_gateway'] as bool? ?? false,
          ),
    ],
    varsValues: {
      for (final e in varsRaw.entries) e.key: e.value as String,
    },
    expected: expected,
  );
}

/// Вердикт загрузки: [parsePresetNodeLoop] бросил — пресет отвергнут.
/// Глобальных переменных у кейса нет (README: только ключи пресета).
TemplateIfError? _loadError(Map<String, dynamic> presetJson) {
  try {
    parsePresetNodeLoop(presetJson, const {}, path: 'corpus');
    return null;
  } on TemplateIfError catch (e) {
    return e;
  }
}

Map<String, dynamic> _runCase(_LoopCase c) {
  final preset = SelectableRule.fromJson(<String, dynamic>{
    'preset_id': 'corpus-node-loop',
    'ui': {'label': 'corpus'},
    ...c.presetJson,
  });
  final rule = CustomRulePreset(
    name: 'corpus',
    presetId: 'corpus-node-loop',
    varsValues: c.varsValues,
  );

  final warns = TemplateWarnings();
  final fragments = collectTemplateWarnings(
    warns,
    () => expandPreset(rule, preset, nodes: c.nodes),
  );

  return {
    'rules': fragments.routingRules,
    'dns_servers': fragments.dnsServers,
    'dns_rules': fragments.dnsRules,
    'warnings': ({...fragments.warnings, ...warns.codes}.toList()..sort()),
  };
}

bool _jsonEqual(dynamic a, dynamic b) =>
    const DeepCollectionEquality().equals(a, b);

void main() {
  if (corpusSuiteUnavailable(
      'test/contract/template_node_loop_corpus_test.dart')) {
    return;
  }

  for (final section in _kSections) {
    final root = Directory('$kVendorRoot/corpus/template/$section');
    test('корпус $section присутствует', () {
      expect(root.existsSync(), isTrue,
          reason: 'нет каталога ${root.path} — контракт 1.1.119 не синхронизирован');
    });
    if (!root.existsSync()) continue;

    final bases = root
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.preset.json'))
        .map((f) => f.path.substring(0, f.path.length - '.preset.json'.length))
        .toList()
      ..sort();

    group('contract corpus: template $section', () {
      // §588 — гейт «правило без условий» читает списки полей-условий из
      // реестра; без реестра гейт не срабатывает (правило как написано).
      setUpAll(loadTestRegistry);
      for (final base in bases) {
        final name = base.substring(root.path.length + 1);
        test(name, () {
          final c = _loadCase(base);
          final wantReject = c.expected['load'] == 'reject';
          final err = _loadError(c.presetJson);

          if (wantReject) {
            expect(err, isNotNull,
                reason: 'кейс объявлен как load: reject, но обход принят');
            // Отвергнутый пресет фрагментов не даёт.
            for (final k in const ['rules', 'dns_servers', 'dns_rules']) {
              expect(c.expected[k] ?? const [], isEmpty, reason: k);
            }
            return;
          }
          expect(err, isNull, reason: 'обход отвергнут: $err');

          final got = _runCase(c);
          for (final k in const ['rules', 'dns_servers', 'dns_rules']) {
            expect(
              _jsonEqual(got[k], c.expected[k] ?? const []),
              isTrue,
              reason: '$k: получено ${jsonEncode(got[k])}, '
                  'ожидалось ${jsonEncode(c.expected[k])}',
            );
          }
          final expectedWarnings =
              ((c.expected['warnings'] as List?) ?? const [])
                  .cast<String>()
                  .toList()
                ..sort();
          expect(got['warnings'], expectedWarnings, reason: 'warnings');
        });
      }
    });
  }
}
