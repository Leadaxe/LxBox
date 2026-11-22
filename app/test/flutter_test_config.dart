import 'dart:async';

import 'support/test_globals.dart' show installRuleConditionTable;

/// §757 — общий пролог каждого тестового файла: таблица условий правила
/// маршрута (см. [installRuleConditionTable]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installRuleConditionTable();
  await testMain();
}
