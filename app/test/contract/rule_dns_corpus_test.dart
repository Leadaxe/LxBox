import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/contract/registry.dart';

import '../contract_paths.dart';

// Конформанс-раннер корпуса DNS-зеркала правила маршрута (контракт 1.1.139,
// задача 135; норма TEMPLATE_LANG §6.11), сторона LxBox. Тот же набор гоняет
// лаунчер (`core/build/contract_rule_dns_test.go`).
//
// Запись правила (`rule`, форма бэкапа 1.0) → штатный кодек → штатная сборка
// зеркал (`applyAllCustomRules`) → итоговое DNS-правило (`dnsMirrorRule`, тот
// же шаг, что в `applyCustomDns`). Ключи матчера (`rule_dns_mirror_match`) —
// выбор стороны, снимаются до сравнения. Порядок правил и элементов `answer`
// нормативен, порядок ключей — нет.

/// Кейсы, которые сторона пока не проходит по известной причине.
const Map<String, String> _pendingCases = {};

void main() {
  if (corpusSuiteUnavailable('test/contract/rule_dns_corpus_test.dart')) {
    return;
  }

  setUpAll(loadTestRegistry);

  final root = Directory('$kVendorRoot/corpus/rule_dns');
  if (!root.existsSync()) return; // контракт не синхронизирован

  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.rule.json'))
      .map((f) => f.path.substring(0, f.path.length - '.rule.json'.length))
      .toList()
    ..sort();

  group('contract corpus: rule_dns', () {
    test('корпус не пуст', () => expect(cases, isNotEmpty));

    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      test(name, skip: _pendingCases[name], () {
        final input = jsonDecode(File('$base.rule.json').readAsStringSync())
            as Map<String, dynamic>;
        final expected =
            jsonDecode(File('$base.expected.json').readAsStringSync())
                as Map<String, dynamic>;
        final matchKeys =
            ContractRegistry.I.allowlistValues('rule_dns_mirror_match');
        expect(matchKeys, isNotNull,
            reason: 'в реестре нет списка rule_dns_mirror_match');

        final rule = ruleFromRecord(
                Map<String, dynamic>.from(input['rule'] as Map),
                unknownAsVerbatim: true)
            .value;
        expect(rule, isNotNull, reason: 'кодек не прочитал запись правила');

        // Наборы srs считаются скачанными.
        final srsPaths = <String, String>{
          if (rule is CustomRuleSrs) rule.id: '/corpus/${rule.id}.srs',
        };
        final mirrors = applyAllCustomRules(RuleSetRegistry(), [rule!], const [],
                srsPaths: srsPaths)
            .dnsMirrors;
        // Сервер правила считается выпущенным в `dns.servers`.
        final servers = {
          for (final m in mirrors)
            if (m.serverTag.isNotEmpty) m.serverTag,
        };
        final actual = [
          for (final m in mirrors)
            if (dnsMirrorRule(m, servers) case final r?)
              {
                for (final e in r.entries)
                  if (!matchKeys!.contains(e.key)) e.key: e.value,
              },
        ];

        final want = expected['dns_rules'] as List;
        expect(
          const DeepCollectionEquality().equals(actual, want),
          isTrue,
          reason: 'получено: ${jsonEncode(actual)}\n'
              'ожидалось: ${jsonEncode(want)}',
        );
      });
    }
  });
}
