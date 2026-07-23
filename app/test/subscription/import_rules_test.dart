import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/import_rules.dart';

/// §302 — правила работают над готовым JSON узла (`NodeSpec.emit`), а не над
/// текстом тела: `emit` одинаков для всех форматов подписки, поэтому одно
/// правило работает и для URI-строк, и для Xray-JSON, и для INI.
void main() {
  NodeSpec node(String uri) => parseUri(uri)!;

  // Узел с TLS-fingerprint. ВАЖНО: парсер канонизирует fp на входе (§281,
  // `hellochrome_*` → `chrome`), поэтому для проверок «правило меняет fp»
  // берём значение, которое нормализация не трогает, и правим уже готовый
  // JSON — правила работают именно над ним.
  NodeSpec fpNode(String fp, {String name = 'NL'}) =>
      node('vless://u@h.com:443?security=tls&sni=h.com&fp=$fp&type=ws#$name');

  ImportRuleCondition cond(
    String path,
    ImportRuleOperator op,
    String pattern, {
    bool negate = false,
    bool caseSensitive = false,
  }) =>
      ImportRuleCondition(
        path: path,
        op: op,
        pattern: pattern,
        negate: negate,
        caseSensitive: caseSensitive,
      );

  group('readJsonPath', () {
    test('лист, вложенный путь, отсутствие пути', () {
      final map = node('vless://u@h.com:443?security=tls&sni=x.com#A')
          .emit(TemplateVars.empty)
          .map;
      expect(readJsonPath(map, 'tag'), 'A');
      expect(readJsonPath(map, 'server'), 'h.com');
      expect(readJsonPath(map, 'tls.server_name'), 'x.com');
      expect(readJsonPath(map, 'nope'), isNull);
      expect(readJsonPath(map, 'tls.nope.deep'), isNull);
    });

    test('число отдаётся строкой, поддерево — компактным JSON', () {
      final map = node('vless://u@h.com:8443?security=tls&sni=x.com#A')
          .emit(TemplateVars.empty)
          .map;
      expect(readJsonPath(map, 'server_port'), '8443');
      final tls = readJsonPath(map, 'tls');
      expect(tls, startsWith('{'));
      expect(tls, contains('x.com'));
    });
  });

  group('writeJsonPath', () {
    test('пишет лист и создаёт промежуточные мапы', () {
      final map = <String, dynamic>{'tag': 'A'};
      expect(writeJsonPath(map, 'tag', 'B'), isTrue);
      expect(map['tag'], 'B');
      expect(writeJsonPath(map, 'tls.utls.fingerprint', 'chrome'), isTrue);
      expect((map['tls'] as Map)['utls'], {'fingerprint': 'chrome'});
    });

    test('сохраняет тип значения (порт остаётся числом)', () {
      final map = <String, dynamic>{'server_port': 443, 'ok': true};
      writeJsonPath(map, 'server_port', '8443');
      writeJsonPath(map, 'ok', 'false');
      expect(map['server_port'], 8443);
      expect(map['ok'], false);
    });

    test('не перезаписывает лист как мапу', () {
      final map = <String, dynamic>{'tag': 'A'};
      expect(writeJsonPath(map, 'tag.deep', 'x'), isFalse);
      expect(map['tag'], 'A');
    });
  });

  group('условия', () {
    test('contains по tag — регистронезависим по умолчанию', () {
      final rule = ImportRule(
        conditions: [cond('tag', ImportRuleOperator.contains, 'nl')],
        action: ImportRuleAction.disable,
      );
      expect(applyRulesToNode(fpNode('chrome', name: 'NL-01'), [rule]).disabled,
          isTrue);
      expect(applyRulesToNode(fpNode('chrome', name: 'DE-01'), [rule]).disabled,
          isFalse);
    });

    test('caseSensitive различает регистр', () {
      final rule = ImportRule(
        conditions: [
          cond('tag', ImportRuleOperator.contains, 'nl', caseSensitive: true)
        ],
        action: ImportRuleAction.disable,
      );
      expect(applyRulesToNode(fpNode('chrome', name: 'NL'), [rule]).disabled,
          isFalse);
      expect(applyRulesToNode(fpNode('chrome', name: 'nl'), [rule]).disabled,
          isTrue);
    });

    test('equals требует полного совпадения', () {
      final rule = ImportRule(
        conditions: [cond('tag', ImportRuleOperator.equals, 'NL')],
        action: ImportRuleAction.disable,
      );
      expect(applyRulesToNode(fpNode('chrome', name: 'NL'), [rule]).disabled,
          isTrue);
      expect(applyRulesToNode(fpNode('chrome', name: 'NL-01'), [rule]).disabled,
          isFalse);
    });

    test('negate инвертирует — и ловит отсутствие поля', () {
      final rule = ImportRule(
        conditions: [
          cond('tls.utls.fingerprint', ImportRuleOperator.contains, 'chrome',
              negate: true)
        ],
        action: ImportRuleAction.disable,
      );
      // fp=chrome → условие с negate ложно, узел не трогаем.
      expect(applyRulesToNode(fpNode('chrome'), [rule]).disabled, isFalse);
      // fp=firefox → negate истинно.
      expect(applyRulesToNode(fpNode('firefox'), [rule]).disabled, isTrue);
      // поля нет вовсе (без TLS) → negate тоже истинно.
      expect(applyRulesToNode(node('vless://u@h.com:443#A'), [rule]).disabled,
          isTrue);
    });

    test('AND требует всех условий, OR — любого', () {
      final conds = [
        cond('tag', ImportRuleOperator.contains, 'NL'),
        cond('server', ImportRuleOperator.contains, 'zzz'),
      ];
      final and = ImportRule(
          conditions: conds,
          matchMode: ImportRuleMatchMode.all,
          action: ImportRuleAction.disable);
      final or = ImportRule(
          conditions: conds,
          matchMode: ImportRuleMatchMode.any,
          action: ImportRuleAction.disable);
      final n = fpNode('chrome', name: 'NL');
      expect(applyRulesToNode(n, [and]).disabled, isFalse,
          reason: 'server не содержит zzz');
      expect(applyRulesToNode(n, [or]).disabled, isTrue,
          reason: 'tag содержит NL');
    });

    test('битый regex делает правило непригодным (узел не трогаем)', () {
      final rule = ImportRule(
        conditions: [cond('tag', ImportRuleOperator.matches, '[')],
        action: ImportRuleAction.disable,
      );
      expect(rule.isUsable, isFalse);
      expect(applyRulesToNode(fpNode('chrome'), [rule]).disabled, isFalse);
    });
  });

  group('Replace', () {
    test('set пишет значение целиком', () {
      final rule = ImportRule(
        conditions: [
          cond('tls.utls.fingerprint', ImportRuleOperator.contains, 'firefox')
        ],
        action: ImportRuleAction.replace,
        targetPath: 'tls.utls.fingerprint',
        replacement: 'chrome',
      );
      final out = applyRulesToNode(fpNode('firefox'), [rule]);
      expect(out.patchedJson, isNotNull);
      expect(readJsonPath(out.patchedJson!, 'tls.utls.fingerprint'), 'chrome');
    });

    test('карманы из matches подставляются в замену', () {
      final rule = ImportRule(
        conditions: [
          cond('tag', ImportRuleOperator.matches, r'^(NL)-\d+$'),
        ],
        action: ImportRuleAction.replace,
        targetPath: 'tag',
        replacement: r'$1',
      );
      final out = applyRulesToNode(fpNode('chrome', name: 'NL-01'), [rule]);
      expect(readJsonPath(out.patchedJson!, 'tag'), 'NL');
    });

    test('substitute вырезает фрагмент, остальное значение сохраняется', () {
      // Убрать ⚡ из имени: tag matches ^(.*)⚡(.*)$ → tag = $1$2.
      final rule = ImportRule(
        conditions: [
          cond('tag', ImportRuleOperator.matches, r'^(.*)⚡(.*)$'),
        ],
        action: ImportRuleAction.replace,
        targetPath: 'tag',
        replacement: r'$1$2',
      );
      final out = applyRulesToNode(fpNode('chrome', name: 'DE⚡Berlin'), [rule]);
      expect(readJsonPath(out.patchedJson!, 'tag'), 'DEBerlin');
    });

    test('substitute-режим по подстроке без regex', () {
      final rule = ImportRule(
        conditions: [cond('tag', ImportRuleOperator.contains, '⚡')],
        action: ImportRuleAction.replace,
        targetPath: 'tag',
        replaceMode: ImportRuleReplaceMode.substitute,
        replacement: '',
      );
      final out = applyRulesToNode(fpNode('chrome', name: 'DE⚡Berlin'), [rule]);
      expect(readJsonPath(out.patchedJson!, 'tag'), 'DEBerlin');
    });

    test('порт остаётся числом после замены', () {
      final rule = ImportRule(
        conditions: [cond('server_port', ImportRuleOperator.equals, '443')],
        action: ImportRuleAction.replace,
        targetPath: 'server_port',
        replacement: '8443',
      );
      final out = applyRulesToNode(fpNode('chrome'), [rule]);
      expect(out.patchedJson!['server_port'], 8443);
      expect(out.patchedJson!['server_port'], isA<int>());
    });

    test('замена того же значения — не считается изменением', () {
      final rule = ImportRule(
        conditions: [cond('tag', ImportRuleOperator.contains, 'NL')],
        action: ImportRuleAction.replace,
        targetPath: 'tag',
        replacement: 'NL',
      );
      final out = applyRulesToNode(fpNode('chrome', name: 'NL'), [rule]);
      expect(out.changed, isFalse);
    });

    test('emit узла отдаёт патч (замена доезжает до конфига)', () {
      final n = fpNode('firefox');
      final rule = ImportRule(
        conditions: [
          cond('tls.utls.fingerprint', ImportRuleOperator.contains, 'firefox')
        ],
        action: ImportRuleAction.replace,
        targetPath: 'tls.utls.fingerprint',
        replacement: 'chrome',
      );
      final out = applyRulesToNode(n, [rule]);
      n.patchedJson = out.patchedJson;
      expect(
        readJsonPath(n.emit(TemplateVars.empty).map, 'tls.utls.fingerprint'),
        'chrome',
      );
    });
  });

  group('applyImportRules по списку узлов', () {
    test('индексы выключенных + следы замен', () {
      final nodes = [
        fpNode('chrome', name: 'NL-1'),
        fpNode('chrome', name: 'DE-1'),
        fpNode('firefox', name: 'NL-2'),
      ];
      final rules = [
        ImportRule(
          conditions: [cond('tag', ImportRuleOperator.contains, 'DE')],
          action: ImportRuleAction.disable,
        ),
        ImportRule(
          conditions: [
            cond('tls.utls.fingerprint', ImportRuleOperator.contains, 'firefox')
          ],
          action: ImportRuleAction.replace,
          targetPath: 'tls.utls.fingerprint',
          replacement: 'chrome',
        ),
      ];
      final res = applyImportRules(nodes, rules);
      expect(res.disabledIndexes, {1});
      expect(res.outcomes[2]!.replacements.single, contains('chrome'));
      expect(res.outcomes.containsKey(0), isFalse, reason: 'узел не затронут');
    });

    test('выключенное правило игнорируется', () {
      final res = applyImportRules([
        fpNode('chrome', name: 'NL')
      ], [
        ImportRule(
          conditions: [cond('tag', ImportRuleOperator.contains, 'NL')],
          action: ImportRuleAction.disable,
          enabled: false,
        )
      ]);
      expect(res.isEmpty, isTrue);
    });

    test('правила применяются по порядку — следующее видит патч', () {
      final rules = [
        ImportRule(
          conditions: [cond('tag', ImportRuleOperator.contains, 'raw')],
          action: ImportRuleAction.replace,
          targetPath: 'tag',
          replacement: 'stage1',
        ),
        ImportRule(
          conditions: [cond('tag', ImportRuleOperator.contains, 'stage1')],
          action: ImportRuleAction.replace,
          targetPath: 'tag',
          replacement: 'stage2',
        ),
      ];
      final out = applyRulesToNode(fpNode('chrome', name: 'raw'), rules);
      expect(readJsonPath(out.patchedJson!, 'tag'), 'stage2');
    });
  });

  group('сериализация', () {
    test('round-trip нового формата', () {
      final rule = ImportRule(
        conditions: [
          cond('tls.utls.fingerprint', ImportRuleOperator.matches,
              r'^hello(.*)$'),
          cond('tag', ImportRuleOperator.contains, 'NL', negate: true),
        ],
        matchMode: ImportRuleMatchMode.any,
        action: ImportRuleAction.replace,
        targetPath: 'tls.utls.fingerprint',
        replacement: r'$1',
        replaceMode: ImportRuleReplaceMode.substitute,
        substitutePattern: 'hello',
        enabled: false,
      );
      expect(ImportRule.fromJson(rule.toJson()), rule);
    });

    test('миграция старого плоского правила → условие по tag', () {
      // v1: {action, pattern, is_regex, case_sensitive} по тексту строки.
      final migrated = ImportRule.fromJson({
        'action': 'disable',
        'pattern': '⚡',
      });
      expect(migrated.conditions.single.path, 'tag');
      expect(migrated.conditions.single.op, ImportRuleOperator.contains);
      expect(migrated.conditions.single.pattern, '⚡');
      expect(migrated.action, ImportRuleAction.disable);
      // И сразу работает: узел с ⚡ в имени гасится.
      expect(
          applyRulesToNode(fpNode('chrome', name: 'HU⚡Budapest'), [migrated])
              .disabled,
          isTrue);
    });

    test('миграция v1 replace несёт substitute-семантику', () {
      final migrated = ImportRule.fromJson({
        'action': 'replace',
        'pattern': 'hellochrome_120',
        'replacement': 'chrome',
      });
      expect(migrated.replaceMode, ImportRuleReplaceMode.substitute);
      expect(migrated.targetPath, 'tag');
    });
  });
}
