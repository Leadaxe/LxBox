import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'sha256.dart';

// §279 (спека §9.3) — ratchet-скан hardcoded display-строк, вынесен из
// hardcoded_check.dart в библиотеку: логика тестируема из
// test/tool/hardcoded_scan_test.dart (entrypoint `dart run
// tool/l10n/hardcoded_check.dart` стабилен для CI).
//
// AST-скан по синтаксису, без резолюции типов. Display-позиции:
//   - первый позиционный аргумент Text(...);
//   - именованные аргументы tooltip:/labelText:/hintText:/helperText: у любого
//     вызова (semanticLabel сознательно НЕ входит);
//   - SnackBarAction(label:), Tab(text:); SnackBar(content:)/AlertDialog(...)
//     покрыты правилом Text — строка туда попадает только внутри Text(...);
//   - хелперы из tool/l10n/l10n_helpers.json (display-параметры snack/dialog
//     хелперов; новый хелпер обязан регистрироваться там).
//
// В display-позиции скан рекурсивно спускается в ветки ternary
// (`cond ? 'A' : 'B'`), switch-expression и скобки — каждая строковая ветка
// является самостоятельным сайтом (Phase 7 hardening: раньше литерал внутри
// ternary в display-позиции проходил мимо ratchet).
//
// §607 — идентификатор в display-позиции (`Text(label)`, `Text(_line!)`)
// прослеживается до значений: инициализатор и присваивания локальной
// переменной в объемлющем теле функции, для поля — во всём классе. Каждое
// строковое значение — самостоятельный сайт (раньше литерал, положенный в
// переменную, проходил мимо ratchet).
//
// Пропускаются литералы: пустые/без букв (пунктуация, юниты) и строки с
// комментарием `// l10n-exempt` на той же строке или строкой выше.

const Set<String> _displayNamedArgs = {
  'tooltip', 'labelText', 'hintText', 'helperText',
};
const Map<String, Set<String>> _calleeNamed = {
  'SnackBarAction': {'label'},
  'Tab': {'text'},
};
const Map<String, Set<int>> _calleePositional = {
  'Text': {0},
};

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

/// Display-параметры зарегистрированного snack/dialog-хелпера
/// (tool/l10n/l10n_helpers.json).
class DisplayHelper {
  DisplayHelper(this.positional, this.named);
  final Set<int> positional;
  final Set<String> named;
}

/// Найденный hardcoded display-литерал.
class HardcodedSite {
  HardcodedSite(this.file, this.line, this.hash, this.preview);
  final String file;
  final int line;

  /// Первые 12 hex sha256 канонизированного текста (`${...}` → `{}`).
  final String hash;
  final String preview;
}

/// Канонизированный текст литерала: интерполяции заменяются позиционным
/// `{}` (rename переменной не меняет hash), adjacent strings склеиваются.
/// null — не строковый литерал.
String? canonicalLiteral(Expression e) {
  if (e is SimpleStringLiteral) return e.value;
  if (e is AdjacentStrings) {
    final buf = StringBuffer();
    for (final s in e.strings) {
      final part = canonicalLiteral(s);
      if (part == null) return null;
      buf.write(part);
    }
    return buf.toString();
  }
  if (e is StringInterpolation) {
    final buf = StringBuffer();
    for (final el in e.elements) {
      if (el is InterpolationString) {
        buf.write(el.value);
      } else {
        buf.write('{}');
      }
    }
    return buf.toString();
  }
  return null;
}

/// Парсит [content] (путь [path] — только для сообщений) и возвращает все
/// hardcoded display-сайты. Ядро `hardcoded_check.dart`.
List<HardcodedSite> scanForHardcodedStrings({
  required String path,
  required String content,
  Map<String, DisplayHelper> helpers = const {},
}) {
  final parsed =
      parseString(content: content, path: path, throwIfDiagnostics: false);
  final sites = <HardcodedSite>[];
  parsed.unit.accept(_ScanVisitor(
      path, parsed.lineInfo, content.split('\n'), helpers, sites));
  return sites;
}

class _ScanVisitor extends RecursiveAstVisitor<void> {
  _ScanVisitor(this.file, this.lineInfo, this.lines, this.helpers, this.sites);

  final String file;
  final LineInfo lineInfo;
  final List<String> lines;
  final Map<String, DisplayHelper> helpers;
  final List<HardcodedSite> sites;
  final Set<int> _seenOffsets = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _handleCall(node.methodName.name, node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // toSource() вместо NamedType.name — API последнего стабилен хуже.
    final type = node.constructorName.type.toSource();
    _handleCall(type.split('<').first.split('.').last, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (_displayNamedArgs.contains(node.name.label.name)) {
      _check(node.expression);
    }
    super.visitNamedExpression(node);
  }

  void _handleCall(String callee, ArgumentList args) {
    final positional = <int>{
      ...?_calleePositional[callee],
      ...?helpers[callee]?.positional,
    };
    final named = <String>{
      ...?_calleeNamed[callee],
      ...?helpers[callee]?.named,
    };
    if (positional.isEmpty && named.isEmpty) return;

    var idx = 0;
    for (final a in args.arguments) {
      if (a is NamedExpression) {
        if (named.contains(a.name.label.name)) _check(a.expression);
      } else {
        if (positional.contains(idx)) _check(a);
        idx++;
      }
    }
  }

  void _check(Expression e) {
    // Phase 7 hardening: литерал может прятаться в ветке ternary/switch
    // (или в скобках) прямо в display-позиции — каждая ветка проверяется
    // как самостоятельный сайт.
    if (e is ParenthesizedExpression) {
      _check(e.expression);
      return;
    }
    if (e is ConditionalExpression) {
      _check(e.thenExpression);
      _check(e.elseExpression);
      return;
    }
    if (e is SwitchExpression) {
      for (final c in e.cases) {
        _check(c.expression);
      }
      return;
    }
    if (e is PostfixExpression && e.operator.lexeme == '!') {
      _check(e.operand);
      return;
    }
    if (e is SimpleIdentifier) {
      _checkIdentifier(e);
      return;
    }
    final text = canonicalLiteral(e);
    if (text == null || text.trim().isEmpty) return;
    if (!_letter.hasMatch(text)) return; // пунктуация/юниты: '—', '·'
    if (!_seenOffsets.add(e.offset)) return;
    final line = lineInfo.getLocation(e.offset).lineNumber;
    if (_exempt(line)) return;
    final short = text.length > 60 ? '${text.substring(0, 57)}...' : text;
    sites.add(
        HardcodedSite(file, line, sha256Hex(text).substring(0, 12), short));
  }

  /// Имена, которые уже прослеживаются (защита от циклов `a = b; b = a`).
  final Set<String> _tracing = {};

  /// §607 — значения, которые может принимать идентификатор [id]: локальная
  /// переменная — в ближайшем объемлющем теле функции, где она объявлена;
  /// иначе поле — во всём объемлющем классе/миксине/расширении.
  void _checkIdentifier(SimpleIdentifier id) {
    final name = id.name;
    if (!_tracing.add(name)) return;
    try {
      for (AstNode? n = id.parent; n != null; n = n.parent) {
        if (n is FunctionBody) {
          final values = _valuesOf(n, name);
          if (values != null) {
            values.forEach(_check);
            return;
          }
        } else if (n is ClassDeclaration ||
            n is MixinDeclaration ||
            n is ExtensionDeclaration) {
          _valuesOf(n, name, fieldsOnly: true)?.forEach(_check);
          return;
        }
      }
    } finally {
      _tracing.remove(name);
    }
  }

  /// Инициализаторы объявлений [name] и правые части `name = …` внутри
  /// [scope]; null — объявления [name] в [scope] нет.
  /// [fieldsOnly] — в классе объявлением считается только поле: одноимённая
  /// локальная переменная другого метода — не то же самое.
  List<Expression>? _valuesOf(
    AstNode scope,
    String name, {
    bool fieldsOnly = false,
  }) {
    final c = _ValueCollector(name, fieldsOnly: fieldsOnly);
    scope.accept(c);
    return c.declared ? c.values : null;
  }

  bool _exempt(int line) {
    bool has(int i) =>
        i >= 0 && i < lines.length && lines[i].contains('// l10n-exempt');
    return has(line - 1) || has(line - 2); // та же строка или строкой выше
  }
}

class _ValueCollector extends RecursiveAstVisitor<void> {
  _ValueCollector(this.name, {required this.fieldsOnly});
  final String name;
  final bool fieldsOnly;
  bool declared = false;
  final List<Expression> values = [];

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name &&
        (!fieldsOnly || node.parent?.parent is FieldDeclaration)) {
      declared = true;
      final init = node.initializer;
      if (init != null) values.add(init);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final lhs = node.leftHandSide;
    if (lhs is SimpleIdentifier && lhs.name == name) {
      values.add(node.rightHandSide);
    }
    super.visitAssignmentExpression(node);
  }
}
