import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/node_identity.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/import_rules.dart';

/// §322 × §302 — правило импорта может переписать `server`/`uuid`, и в конфиг
/// уходит патч, а не исходный узел. Значит идентичность узла ПОСЛЕ правил
/// другая, и состав пула автовыбора обязан считаться от неё же — иначе
/// синонимы указывают на адрес, которого в конфиге уже нет.
void main() {
  NodeSpec node({String server = '1.1.1.1', String uuid = 'u-1'}) =>
      parseUri('vless://$uuid@$server:443?type=tcp&security=none#N')!;

  group('nodeIdentityKey учитывает патч §302', () {
    test('без патча — по самому узлу', () {
      expect(nodeIdentityKey(node()), 'vless|1.1.1.1|443|u-1');
    });

    test('патч сменил server → ключ по патчу', () {
      final n = node();
      final rule = ImportRule(
        conditions: [
          ImportRuleCondition(
              path: 'tag',
              op: ImportRuleOperator.contains,
              pattern: 'N')
        ],
        action: ImportRuleAction.replace,
        targetPath: 'server',
        replacement: '9.9.9.9',
      );
      final out = applyRulesToNode(n, [rule]);
      n.patchedJson = out.patchedJson;

      expect(out.patchedJson, isNotNull, reason: 'правило должно сработать');
      expect(nodeIdentityKey(n), 'vless|9.9.9.9|443|u-1');
      // Исходная идентичность доступна отдельно — по ней ищем «было → стало».
      expect(nodeIdentityKeyRaw(n), 'vless|1.1.1.1|443|u-1');
    });

    test('патч сменил uuid → ключ по патчу', () {
      final n = node();
      final rule = ImportRule(
        conditions: [
          ImportRuleCondition(
              path: 'tag',
              op: ImportRuleOperator.contains,
              pattern: 'N')
        ],
        action: ImportRuleAction.replace,
        targetPath: 'uuid',
        replacement: 'u-new',
      );
      final n2 = node();
      n2.patchedJson = applyRulesToNode(n, [rule]).patchedJson;
      expect(nodeIdentityKey(n2), 'vless|1.1.1.1|443|u-new');
    });

    test('группа §322 ключа не имеет даже с патчем', () {
      final a = AutoSelectSpec(
          id: 'x', tag: 't', label: 'l')
        ..patchedJson = {'type': 'urltest', 'server': 'nonsense'};
      expect(nodeIdentityKey(a), isNull);
    });
  });
}
