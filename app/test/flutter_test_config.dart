import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lxbox/models/custom_rule.dart' show debugSetRuleConditionTable;
import 'package:lxbox/services/contract/rule_conditions.dart';

/// §757 — общий пролог каждого тестового файла: таблица условий правила
/// маршрута (`registry/rule_conditions.json` из ассетов контракта).
///
/// Кодек правил и предикаты модели читают её на любом пути (хранение,
/// бэкап, сборка), а большинство тестов реестр контракта не грузит. Реестр
/// здесь НЕ загружается и не меняется — таблица кладётся в запасную копию
/// модели (`ruleConditionTable`), которую загрузка реестра перекрывает.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final f = File('assets/contract/registry/rule_conditions.json');
  if (f.existsSync()) {
    debugSetRuleConditionTable(RuleConditionTable.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>));
  }
  await testMain();
}
