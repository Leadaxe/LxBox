/// §757 — таблица условий простого правила маршрута
/// (`registry/rule_conditions.json`, контракт 1.1.179, TASKS_LXBOX §182 п. 1.4).
///
/// Единственный источник для формы правила и для сборки: идёт ли ключ в
/// inline-набор (`set`), в DNS-зеркало (`dns`), доменный ли он (`group`).
/// Имён ключей условий в коде сборки нет — они приходят отсюда.
///
/// Слой: чистый Dart, без Flutter. Грузит [ContractRegistry] (файл в
/// `_kStandaloneShared`), разбор — [RuleConditionTable.fromJson].
library;

/// §757 — один ключ тела правила в таблице условий.
final class RuleConditionKey {
  const RuleConditionKey({
    required this.key,
    required this.conditionId,
    required this.field,
    this.dns = false,
    this.set = false,
    this.group,
    this.conflicts = const [],
    this.values = const [],
    this.open = false,
  });

  /// Ключ тела (ключ ядра; у `refs` — поле записи-источника наборов).
  final String key;

  /// `id` условия, которому принадлежит ключ.
  final String conditionId;

  /// Вид поля формы: `refs` | `lines` | `cidr_lines` | `ports` | `bool` |
  /// `enum_multi` | `processes`.
  final String field;

  /// Ключ переносится в DNS-зеркало правила (§6.11).
  final bool dns;

  /// У простого правила с `refs` ключ уходит в inline-набор узла (§6.13 п. 2).
  final bool set;

  /// `domain` | `address` | null.
  final String? group;

  /// Ключи, с которыми форма не даёт сочетать этот в одном простом правиле.
  final List<String> conflicts;

  /// Значения `enum_multi`; [open] — допустимы и значения вне списка.
  final List<String> values;
  final bool open;

  bool get isDomain => group == kGroupDomain;

  /// Поле `refs` — ссылки на наборы, не ключ ядра.
  bool get isRefs => field == kFieldRefs;

  /// Значение — один флаг, а не список.
  bool get isBool => field == kFieldBool;

  /// Значение — список чисел (порты).
  bool get isIntList => field == kFieldPorts;

  static const kGroupDomain = 'domain';
  static const kGroupAddress = 'address';
  static const kFieldRefs = 'refs';
  static const kFieldBool = 'bool';
  static const kFieldPorts = 'ports';
}

/// §757 — условие формы: группа ключей, связанных «любое из».
final class RuleCondition {
  const RuleCondition({
    required this.id,
    required this.label,
    required this.order,
    required this.keys,
    this.oneOf = false,
    this.platforms,
    this.forms,
  });

  final String id;
  final String label;
  final int order;
  final List<RuleConditionKey> keys;

  /// В условии выбирается один ключ.
  final bool oneOf;

  /// ОС, где ядро читает условие; null — везде.
  final List<String>? platforms;

  /// Чьи формы показывают условие; null — `launcher` и `lxbox`.
  final List<String>? forms;

  bool shownIn(String form) => forms == null || forms!.contains(form);

  bool availableOn(String platform) =>
      platforms == null || platforms!.contains(platform);
}

/// §757 — разобранная таблица условий.
final class RuleConditionTable {
  RuleConditionTable._(this.conditions, this._byKey);

  /// Служебные ключи тела — вне таблицы, но тело с ними остаётся деревом
  /// (примечание `note` файла таблицы: `type`, `mode`, `rules`, `invert`,
  /// `rule_set`, `outbound`, `action`, `method`). Перечислены здесь, потому
  /// что в файле они даны текстом, а не списком.
  static const serviceKeys = <String>{
    kType,
    kMode,
    kRules,
    kInvert,
    kRuleSet,
    ...targetKeys,
  };

  /// Ключи цели правила — только у корня дерева (TASKS_LXBOX §182 п. 1.1).
  static const targetKeys = <String>{'outbound', 'action', 'method'};

  static const kType = 'type';
  static const kMode = 'mode';
  static const kRules = 'rules';
  static const kInvert = 'invert';
  static const kRuleSet = 'rule_set';

  /// Условия по `order`.
  final List<RuleCondition> conditions;
  final Map<String, RuleConditionKey> _byKey;

  /// Описание ключа тела; null — ключа нет в таблице.
  RuleConditionKey? key(String bodyKey) => _byKey[bodyKey];

  bool isConditionKey(String bodyKey) => _byKey.containsKey(bodyKey);

  /// Все ключи таблицы в порядке условий и ключей внутри условия.
  Iterable<RuleConditionKey> get keys => conditions.expand((c) => c.keys);

  RuleCondition? condition(String id) {
    for (final c in conditions) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Ключ поля ссылок на наборы (`field: refs`).
  String get refsKey => keys
      .firstWhere(
        (k) => k.isRefs,
        orElse: () => const RuleConditionKey(
          key: 'refs',
          conditionId: '',
          field: RuleConditionKey.kFieldRefs,
        ),
      )
      .key;

  /// Разбор `registry/rule_conditions.json`. Запись без `key`/`field` или
  /// условие без `id` пропускаются: реестр, едущий впереди клиента, не
  /// роняет загрузку. Ключ, встреченный второй раз, — первый выигрывает.
  factory RuleConditionTable.fromJson(Map<String, dynamic> json) {
    final out = <RuleCondition>[];
    final byKey = <String, RuleConditionKey>{};
    for (final raw in (json['conditions'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String || id.isEmpty) continue;
      final keys = <RuleConditionKey>[];
      for (final k in (raw['keys'] as List?) ?? const []) {
        if (k is! Map) continue;
        final name = k['key'];
        final field = k['field'];
        if (name is! String || name.isEmpty || field is! String) continue;
        if (byKey.containsKey(name)) continue;
        final entry = RuleConditionKey(
          key: name,
          conditionId: id,
          field: field,
          dns: k['dns'] == true,
          set: k['set'] == true,
          group: k['group'] is String ? k['group'] as String : null,
          conflicts: _strings(k['conflicts']),
          values: _strings(k['values']),
          open: k['open'] == true,
        );
        keys.add(entry);
        byKey[name] = entry;
      }
      out.add(
        RuleCondition(
          id: id,
          label: raw['label'] is String ? raw['label'] as String : id,
          order: raw['order'] is num ? (raw['order'] as num).toInt() : 0,
          keys: List.unmodifiable(keys),
          oneOf: raw['one_of'] == true,
          platforms: raw['platforms'] is List
              ? _strings(raw['platforms'])
              : null,
          forms: raw['forms'] is List ? _strings(raw['forms']) : null,
        ),
      );
    }
    // Стабильная сортировка по order: равные остаются в порядке файла.
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final c = a.$2.order.compareTo(b.$2.order);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return RuleConditionTable._(
      List.unmodifiable([for (final e in indexed) e.$2]),
      Map.unmodifiable(byKey),
    );
  }

  static List<String> _strings(Object? v) =>
      v is List ? List.unmodifiable(v.whereType<String>()) : const [];
}
