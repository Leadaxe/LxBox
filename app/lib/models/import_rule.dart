/// §302 — правило обработки тела подписки на импорте/обновлении.
///
/// Живёт per-subscription (`SubscriptionServers.importRules`), применяется
/// **построчно** к телу ДО парсинга (этап A, `applyImportRules`). Два действия:
///
/// - [ImportRuleAction.replace] — `pattern → replacement` в строке (literal
///   при `isRegex=false`, `RegExp` при `true`). Все вхождения. Работает на
///   любом формате тела (URI-list / INI / JSON — это просто текст).
/// - [ImportRuleAction.disable] — строка, совпавшая с `pattern` (в её
///   послезаменном виде), помечается; контроллер выключает соответствующую
///   ноду через §283 `disabledHashes` (нода видна зачёркнутой, не роутится).
///
/// Порядок в списке значим: правила применяются сверху вниз, replace — до
/// проверки disable. Битый regex → правило скипается (см. [compiledPattern]).
enum ImportRuleAction {
  replace,
  disable;

  static ImportRuleAction fromName(String? s) => switch (s) {
        'disable' => ImportRuleAction.disable,
        _ => ImportRuleAction.replace, // дефолт + толерантность к мусору
      };
}

class ImportRule {
  final ImportRuleAction action;

  /// Строка поиска. Для `isRegex=true` — паттерн `RegExp`; иначе literal.
  final String pattern;

  /// Замена (только для [ImportRuleAction.replace]). Пустая = вырезать
  /// совпавший фрагмент (кейс `&type=raw → ""`). Для disable игнорируется.
  final String replacement;

  /// `pattern`/`replacement` трактуются как regex vs literal.
  final bool isRegex;

  /// Регистрозависимость матча. Дефолт `false` — согласуется с §301
  /// (node-фильтры регистронезависимы), но переопределяемо на правиле
  /// (подмена параметров бывает регистрозависимой).
  final bool caseSensitive;

  /// Per-rule вкл/выкл (плюс общий тумблер набора на подписке).
  final bool enabled;

  const ImportRule({
    this.action = ImportRuleAction.replace,
    this.pattern = '',
    this.replacement = '',
    this.isRegex = false,
    this.caseSensitive = false,
    this.enabled = true,
  });

  /// Компилирует [pattern] в `RegExp` (для `isRegex=false` — literal через
  /// `RegExp.escape`), `null` при невалидном паттерне. Общий helper для
  /// применения (этап A) и live-валидации в редакторе — как `_tryCompileRegex`
  /// билдера (§301): единый источник флага `caseSensitive`.
  RegExp? get compiledPattern {
    if (pattern.isEmpty) return null;
    try {
      final src = isRegex ? pattern : RegExp.escape(pattern);
      return RegExp(src, caseSensitive: caseSensitive);
    } catch (_) {
      return null;
    }
  }

  /// Правило участвует в применении: включено, есть паттерн, паттерн валиден.
  bool get isUsable => enabled && compiledPattern != null;

  Map<String, dynamic> toJson() => {
        'action': action.name,
        'pattern': pattern,
        if (replacement.isNotEmpty) 'replacement': replacement,
        if (isRegex) 'is_regex': true,
        if (caseSensitive) 'case_sensitive': true,
        if (!enabled) 'enabled': false,
      };

  factory ImportRule.fromJson(Map<String, dynamic> j) => ImportRule(
        action: ImportRuleAction.fromName(j['action'] as String?),
        pattern: (j['pattern'] as String?) ?? '',
        replacement: (j['replacement'] as String?) ?? '',
        isRegex: (j['is_regex'] as bool?) ?? false,
        caseSensitive: (j['case_sensitive'] as bool?) ?? false,
        enabled: (j['enabled'] as bool?) ?? true,
      );

  ImportRule copyWith({
    ImportRuleAction? action,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? caseSensitive,
    bool? enabled,
  }) =>
      ImportRule(
        action: action ?? this.action,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        isRegex: isRegex ?? this.isRegex,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        enabled: enabled ?? this.enabled,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImportRule &&
          action == other.action &&
          pattern == other.pattern &&
          replacement == other.replacement &&
          isRegex == other.isRegex &&
          caseSensitive == other.caseSensitive &&
          enabled == other.enabled);

  @override
  int get hashCode => Object.hash(
      action, pattern, replacement, isRegex, caseSensitive, enabled);
}
