/// Центральный реестр `route.rule_set` и `route.rules` секций.
///
/// Владеет обоими списками на время сборки конфига. Post-steps (а в будущем
/// и `ServerList.build`) добавляют rule_set'ы и routing rules через API.
/// Builder в конце `buildConfig` делает flush: `route[...] = registry.get...`.
///
/// Ключевая задача — **уникальность tag'ов**. Любое добавление rule_set
/// c занятым tag'ом авто-суффиксится в `"name (2)"`, `"name (3)"` и т.д.
/// Это *defense-in-depth* на случай импорта конфига или программных правок.
/// UI должен валидировать уникальность пользовательских имён самостоятельно
/// (через `AppRule.id`), чтобы юзер не получал сюрпризных суффиксов.
class RuleSetRegistry {
  RuleSetRegistry({
    List<dynamic> initialRuleSets = const [],
    List<dynamic> initialRules = const [],
  }) {
    for (final e in initialRuleSets) {
      if (e is Map<String, dynamic>) _addExisting(e);
    }
    for (final r in initialRules) {
      if (r is Map<String, dynamic>) _rules.add(r);
    }
  }

  final List<Map<String, dynamic>> _ruleSets = [];
  final Set<String> _takenTags = {};
  final List<Map<String, dynamic>> _rules = [];

  /// Insert rule_set entry. Copies [entry] before any mutation so caller's
  /// map stays intact. If `entry['tag']` is already taken, appends
  /// ` (2)`, ` (3)` until free. Writes final tag into the copy and returns it.
  String addRuleSet(Map<String, dynamic> entry) {
    final copy = Map<String, dynamic>.from(entry);
    final requested = (copy['tag'] as String?)?.trim() ?? '';
    final base = requested.isEmpty ? 'unnamed' : requested;
    final tag = _allocateTag(base);
    copy['tag'] = tag;
    _ruleSets.add(copy);
    _takenTags.add(tag);
    return tag;
  }

  /// Insert routing rule (any shape). Порядок в `rules[]` = порядок матчинга
  /// в sing-box, так что caller контролирует приоритет через порядок вызовов.
  void addRule(Map<String, dynamic> rule) {
    _rules.add(Map<String, dynamic>.from(rule));
  }

  /// rule_set entries — для `route.rule_set`.
  List<Map<String, dynamic>> getRuleSets() => List.unmodifiable(_ruleSets);

  /// routing rules — для `route.rules`.
  List<Map<String, dynamic>> getRules() => List.unmodifiable(_rules);

  // ─── internal ───

  /// Добавление с constructor'а: initial entries могут иметь коллизии
  /// (например template уже содержит 'ru-domains' и кто-то передал
  /// initial с ещё одним 'ru-domains'). Применяем тот же auto-suffix.
  void _addExisting(Map<String, dynamic> e) {
    final copy = Map<String, dynamic>.from(e);
    final requested = (copy['tag'] as String?)?.trim() ?? '';
    final base = requested.isEmpty ? 'unnamed' : requested;
    final tag = _allocateTag(base);
    copy['tag'] = tag;
    _ruleSets.add(copy);
    _takenTags.add(tag);
  }

  String _allocateTag(String base) {
    if (!_takenTags.contains(base)) return base;
    var i = 2;
    while (_takenTags.contains('$base ($i)')) {
      i++;
    }
    return '$base ($i)';
  }
}
