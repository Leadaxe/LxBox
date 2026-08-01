import 'dart:convert';

/// §302 — правило обработки узлов подписки на импорте/обновлении.
///
/// Живёт per-subscription (`SubscriptionServers.importRules`) и применяется к
/// УЖЕ РАЗОБРАННЫМ узлам — к их каноническому sing-box JSON (`NodeSpec.emit`),
/// а не к тексту тела. Это принципиально: `emit` одинаков для всех форматов
/// подписки (URI-строки, Xray-JSON, INI/Amnezia), поэтому одно правило
/// работает везде, а не требует отдельной реализации под каждый формат.
///
/// Структура правила:
///
///     if  <условия, объединённые AND | OR>
///     then Disable | Replace <путь> = <значение с карманами>
///
/// Условие — `<путь> <оператор> <паттерн>`, оператор `contains` (дефолт) /
/// `equals` / `matches` (regex), с необязательным отрицанием (`negate`).
/// Карманы (`$1`…`$9`) дают группы захвата из `matches`-условия по ТОМУ ЖЕ
/// пути, что и цель замены.

/// Путь по JSON узла в точечной нотации: `tag`, `server_port`,
/// `tls.utls.fingerprint`, `transport.headers.Host`.
///
/// Если путь указывает не на лист (например `tls.utls`), поддерево
/// сериализуется в компактный JSON и правило работает с ним как с текстом.
/// Несуществующий путь = `null`: условие по нему не матчится (кроме `negate`),
/// замена по нему не применяется.
typedef JsonPath = String;

enum ImportRuleOperator {
  contains,
  equals,
  matches;

  static ImportRuleOperator fromName(String? s) => switch (s) {
        'equals' => ImportRuleOperator.equals,
        'matches' => ImportRuleOperator.matches,
        _ => ImportRuleOperator.contains, // дефолт + толерантность к мусору
      };
}

enum ImportRuleMatchMode {
  /// Достаточно одного сработавшего условия.
  any,

  /// Должны сработать все условия.
  all;

  static ImportRuleMatchMode fromName(String? s) =>
      s == 'any' ? ImportRuleMatchMode.any : ImportRuleMatchMode.all;
}

enum ImportRuleAction {
  replace,
  disable,

  /// §332 — принудительно включить узел: снять disable-отметку, в том числе
  /// ручную (§283). Правила последовательные, последнее сработавшее
  /// enable/disable побеждает — «включить всё» первым правилом сбрасывает
  /// прошлые отключения, дальше можно выборочно выключать (и наоборот:
  /// «выключить всё» + точечные enable = whitelist).
  enable;

  static ImportRuleAction fromName(String? s) => switch (s) {
        'disable' => ImportRuleAction.disable,
        'enable' => ImportRuleAction.enable,
        _ => ImportRuleAction.replace,
      };
}

/// Режим записи для [ImportRuleAction.replace].
enum ImportRuleReplaceMode {
  /// Записать значение целиком (с раскрытыми карманами).
  set,

  /// Найти внутри текущего значения паттерн и заменить только его.
  substitute;

  static ImportRuleReplaceMode fromName(String? s) =>
      s == 'substitute' ? ImportRuleReplaceMode.substitute : ImportRuleReplaceMode.set;
}

/// Одно условие правила.
class ImportRuleCondition {
  final JsonPath path;
  final ImportRuleOperator op;
  final String pattern;

  /// Инвертировать результат («не содержит», «не равно», «не совпадает»).
  final bool negate;

  /// Регистрозависимость. Дефолт `false` — согласуется с §301 (node-фильтры
  /// регистронезависимы), но переопределяемо на условии.
  final bool caseSensitive;

  const ImportRuleCondition({
    this.path = '',
    this.op = ImportRuleOperator.contains,
    this.pattern = '',
    this.negate = false,
    this.caseSensitive = false,
  });

  /// Компилированный regex для [ImportRuleOperator.matches]; `null` для
  /// прочих операторов и при битом паттерне.
  RegExp? get compiledPattern {
    if (op != ImportRuleOperator.matches || pattern.isEmpty) return null;
    try {
      return RegExp(pattern, caseSensitive: caseSensitive);
    } catch (_) {
      return null;
    }
  }

  /// Условие пригодно к применению: есть паттерн, а для `matches` он ещё и
  /// компилируется. Пустой путь допустим — это поиск по всему JSON узла
  /// (см. [readJsonPath]), удобно когда неизвестно, в каком поле искать.
  bool get isUsable {
    if (pattern.isEmpty) return false;
    if (op == ImportRuleOperator.matches) return compiledPattern != null;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'op': op.name,
        'pattern': pattern,
        if (negate) 'negate': true,
        if (caseSensitive) 'case_sensitive': true,
      };

  factory ImportRuleCondition.fromJson(Map<String, dynamic> j) =>
      ImportRuleCondition(
        path: (j['path'] as String?) ?? '',
        op: ImportRuleOperator.fromName(j['op'] as String?),
        pattern: (j['pattern'] as String?) ?? '',
        negate: (j['negate'] as bool?) ?? false,
        caseSensitive: (j['case_sensitive'] as bool?) ?? false,
      );

  ImportRuleCondition copyWith({
    JsonPath? path,
    ImportRuleOperator? op,
    String? pattern,
    bool? negate,
    bool? caseSensitive,
  }) =>
      ImportRuleCondition(
        path: path ?? this.path,
        op: op ?? this.op,
        pattern: pattern ?? this.pattern,
        negate: negate ?? this.negate,
        caseSensitive: caseSensitive ?? this.caseSensitive,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImportRuleCondition &&
          path == other.path &&
          op == other.op &&
          pattern == other.pattern &&
          negate == other.negate &&
          caseSensitive == other.caseSensitive);

  @override
  int get hashCode => Object.hash(path, op, pattern, negate, caseSensitive);
}

class ImportRule {
  final List<ImportRuleCondition> conditions;

  /// Как объединяются [conditions]: все (`all`) или любое (`any`).
  final ImportRuleMatchMode matchMode;

  final ImportRuleAction action;

  /// Цель замены — путь по JSON узла. Только для [ImportRuleAction.replace].
  final JsonPath targetPath;

  /// Новое значение. Поддерживает карманы `$1`…`$9` из `matches`-условия по
  /// тому же пути. Пустое в режиме [ImportRuleReplaceMode.set] очищает поле,
  /// в `substitute` — вырезает найденный фрагмент.
  final String replacement;

  final ImportRuleReplaceMode replaceMode;

  /// В режиме `substitute` — что именно искать внутри значения. Пусто →
  /// берётся паттерн первого условия по тому же пути.
  final String substitutePattern;

  /// Per-rule вкл/выкл (плюс общий тумблер набора на подписке).
  final bool enabled;

  const ImportRule({
    this.conditions = const [],
    this.matchMode = ImportRuleMatchMode.all,
    this.action = ImportRuleAction.replace,
    this.targetPath = '',
    this.replacement = '',
    this.replaceMode = ImportRuleReplaceMode.set,
    this.substitutePattern = '',
    this.enabled = true,
  });

  /// Правило участвует в применении: включено, есть хотя бы одно пригодное
  /// условие, а для Replace — ещё и цель.
  ///
  /// §307 — пустая цель допустима в режиме `substitute`: это замена по всему
  /// узлу (симметрия с пустым путём условия). Нужен паттерн поиска — явный
  /// [substitutePattern] либо пригодное условие с пустым путём, иначе движку
  /// нечего искать. В режиме `set` пустая цель по-прежнему непригодна
  /// (весь узел строкой не затирается).
  bool get isUsable {
    if (!enabled) return false;
    if (!conditions.any((c) => c.isUsable)) return false;
    if (action == ImportRuleAction.replace && targetPath.isEmpty) {
      if (replaceMode != ImportRuleReplaceMode.substitute) return false;
      final hasNeedle = substitutePattern.isNotEmpty ||
          conditions.any((c) => c.isUsable && c.path.isEmpty);
      if (!hasNeedle) return false;
    }
    return true;
  }

  /// Условия, годные к вычислению (битые молча пропускаются).
  List<ImportRuleCondition> get usableConditions =>
      conditions.where((c) => c.isUsable).toList();

  Map<String, dynamic> toJson() => {
        'conditions': [for (final c in conditions) c.toJson()],
        if (matchMode != ImportRuleMatchMode.all) 'match': matchMode.name,
        'action': action.name,
        if (targetPath.isNotEmpty) 'target_path': targetPath,
        if (replacement.isNotEmpty) 'replacement': replacement,
        if (replaceMode != ImportRuleReplaceMode.set)
          'replace_mode': replaceMode.name,
        if (substitutePattern.isNotEmpty) 'substitute': substitutePattern,
        if (!enabled) 'enabled': false,
      };

  factory ImportRule.fromJson(Map<String, dynamic> j) {
    // Миграция v1 (§302 первая версия): плоское правило по ТЕКСТУ строки
    // подписки — {action, pattern, replacement, is_regex, case_sensitive}.
    // Переносим в условие по `tag`: текст строки пользователь писал, глядя на
    // имя узла в списке, и именно оно живёт в tag готового JSON.
    if (j['conditions'] == null && j['pattern'] is String) {
      final legacyPattern = j['pattern'] as String;
      final isRegex = (j['is_regex'] as bool?) ?? false;
      final cs = (j['case_sensitive'] as bool?) ?? false;
      final action = ImportRuleAction.fromName(j['action'] as String?);
      return ImportRule(
        conditions: [
          ImportRuleCondition(
            path: 'tag',
            op: isRegex
                ? ImportRuleOperator.matches
                : ImportRuleOperator.contains,
            pattern: legacyPattern,
            caseSensitive: cs,
          ),
        ],
        action: action,
        targetPath: action == ImportRuleAction.replace ? 'tag' : '',
        replacement: (j['replacement'] as String?) ?? '',
        replaceMode: ImportRuleReplaceMode.substitute,
        substitutePattern: legacyPattern,
        enabled: (j['enabled'] as bool?) ?? true,
      );
    }

    return ImportRule(
      conditions: [
        for (final c in (j['conditions'] as List?) ?? const [])
          if (c is Map<String, dynamic>) ImportRuleCondition.fromJson(c),
      ],
      matchMode: ImportRuleMatchMode.fromName(j['match'] as String?),
      action: ImportRuleAction.fromName(j['action'] as String?),
      targetPath: (j['target_path'] as String?) ?? '',
      replacement: (j['replacement'] as String?) ?? '',
      replaceMode: ImportRuleReplaceMode.fromName(j['replace_mode'] as String?),
      substitutePattern: (j['substitute'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
    );
  }

  ImportRule copyWith({
    List<ImportRuleCondition>? conditions,
    ImportRuleMatchMode? matchMode,
    ImportRuleAction? action,
    JsonPath? targetPath,
    String? replacement,
    ImportRuleReplaceMode? replaceMode,
    String? substitutePattern,
    bool? enabled,
  }) =>
      ImportRule(
        conditions: conditions ?? this.conditions,
        matchMode: matchMode ?? this.matchMode,
        action: action ?? this.action,
        targetPath: targetPath ?? this.targetPath,
        replacement: replacement ?? this.replacement,
        replaceMode: replaceMode ?? this.replaceMode,
        substitutePattern: substitutePattern ?? this.substitutePattern,
        enabled: enabled ?? this.enabled,
      );

  /// Человекочитаемая сводка для списка правил («tag contains ⚡ → Disable»).
  /// Английская — как все UI-строки; локализуется на стороне UI.
  String get summary {
    final parts = [
      for (final c in conditions)
        // Пустой путь = весь узел, показываем как `*`.
        '${c.path.isEmpty ? '*' : c.path} '
            '${c.negate ? 'not ' : ''}${c.op.name} ${c.pattern}',
    ];
    final cond = parts.isEmpty
        ? '(no conditions)'
        : parts.join(matchMode == ImportRuleMatchMode.all ? ' AND ' : ' OR ');
    final act = switch (action) {
      ImportRuleAction.disable => 'Disable',
      ImportRuleAction.enable => 'Enable',
      // Пустая цель = substitute по всему узлу, показываем как `*` (§307).
      ImportRuleAction.replace =>
        '${targetPath.isEmpty ? '*' : targetPath} = $replacement',
    };
    return '$cond → $act';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImportRule &&
          _listEq(conditions, other.conditions) &&
          matchMode == other.matchMode &&
          action == other.action &&
          targetPath == other.targetPath &&
          replacement == other.replacement &&
          replaceMode == other.replaceMode &&
          substitutePattern == other.substitutePattern &&
          enabled == other.enabled);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(conditions),
        matchMode,
        action,
        targetPath,
        replacement,
        replaceMode,
        substitutePattern,
        enabled,
      );

  static bool _listEq(List<ImportRuleCondition> a, List<ImportRuleCondition> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Читает значение по [path] из JSON-мапы узла.
///
/// Возвращает текстовое представление: лист — как есть (числа/булевы через
/// `toString`), не-лист (Map/List) — компактным JSON, чтобы правило могло
/// работать с поддеревом как с текстом. `null` — пути нет.
String? readJsonPath(Map<String, dynamic> map, JsonPath path) {
  // Пустой путь = весь узел: сериализуем JSON целиком, чтобы условие искало
  // по любому полю сразу («не знаю, где лежит — найди везде»).
  if (path.isEmpty) return jsonEncode(map);
  Object? cur = map;
  for (final seg in path.split('.')) {
    if (seg.isEmpty) return null;
    if (cur is Map) {
      if (!cur.containsKey(seg)) return null;
      cur = cur[seg];
      continue;
    }
    if (cur is List) {
      final i = int.tryParse(seg);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
      continue;
    }
    return null;
  }
  if (cur == null) return null;
  if (cur is Map || cur is List) return jsonEncode(cur);
  return cur.toString();
}

/// Записывает [value] по [path], создавая промежуточные мапы при
/// необходимости. Возвращает `false`, если путь пройти нельзя (упирается в
/// не-мапу) — вызывающий тогда ничего не меняет.
///
/// Тип значения сохраняется по месту: если текущее значение было числом или
/// булевым, а новое парсится в тот же тип — пишем типизированно, иначе
/// строкой. Иначе `server_port` превратился бы в строку и сломал конфиг.
bool writeJsonPath(Map<String, dynamic> map, JsonPath path, String value) {
  if (path.isEmpty) return false;
  final segs = path.split('.');
  Map<String, dynamic> cur = map;
  for (var i = 0; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (seg.isEmpty) return false;
    final next = cur[seg];
    if (next is Map<String, dynamic>) {
      cur = next;
    } else if (next == null) {
      final created = <String, dynamic>{};
      cur[seg] = created;
      cur = created;
    } else {
      return false; // упёрлись в лист/список — не перезаписываем вслепую
    }
  }
  final last = segs.last;
  if (last.isEmpty) return false;
  cur[last] = coerceJsonLike(cur[last], value);
  return true;
}

/// Приводит новое строковое значение к типу прежнего, когда это безопасно.
/// Публична: whole-node substitute (§307, import_rules.dart) сохраняет типы
/// листьев тем же правилом.
Object? coerceJsonLike(Object? previous, String value) {
  if (previous is int) {
    final n = int.tryParse(value);
    if (n != null) return n;
  } else if (previous is double) {
    final n = double.tryParse(value);
    if (n != null) return n;
  } else if (previous is bool) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  return value;
}
