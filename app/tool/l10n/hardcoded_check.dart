import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'src/check_common.dart';
import 'src/sha256.dart';

// §279 (спека §9.3) — ratchet против новых hardcoded display-строк.
//
// AST-скан lib/ (минус lib/l10n/gen/) по синтаксису, без резолюции типов.
// Display-позиции:
//   - первый позиционный аргумент Text(...);
//   - именованные аргументы tooltip:/labelText:/hintText:/helperText: у любого
//     вызова (semanticLabel сознательно НЕ входит);
//   - SnackBarAction(label:), Tab(text:); SnackBar(content:)/AlertDialog(...)
//     покрыты правилом Text — строка туда попадает только внутри Text(...);
//   - хелперы из tool/l10n/l10n_helpers.json (display-параметры snack/dialog
//     хелперов; новый хелпер обязан регистрироваться там). Self-check-эвристика
//     кандидатов (String-параметр → ScaffoldMessenger) — позднее ужесточение.
//
// Пропускаются литералы: пустые/без букв (пунктуация, юниты) и строки с
// комментарием `// l10n-exempt` на той же строке или строкой выше.
//
// Baseline tool/l10n/hardcoded_baseline.json: {file: [hash...]} — hash =
// первые 12 hex sha256 канонизированного текста (каждая ${...}-интерполяция
// заменена на "{}" позиционно; rename переменной hash не меняет).
// Режимы: --write-baseline регенерирует; default сравнивает: рост числа
// сайтов файла → fail со списком новых; удаление — тихо (baseline сужают
// через --write-baseline); замена hash'а в файле легальна, пока счётчик
// файла не растёт (hotfix-путь).

// §279 Phase 4 (спека §9.4) — rendering-locality-правила, FAIL-режим:
//   - `.render(` легален только в lib/screens|lib/widgets ИЛИ внутри функции,
//     принимающей AppLocalizations параметром (render-path по построению);
//   - `renderEn(` — только в allowlist-файлах (render_allowlist.json:
//     machine-поверхности — automation, Debug API, AppLog-сайты,
//     notification-push, emitWarnings);
//   - `L10n.current` вне allowlist → fail; `L10n.en` вне lib/models/ui_msg.dart
//     → fail (единственный санкционированный путь — renderEn());
//   - паттерн «поле `WizardTemplate?` + заполнение в initState» → fail
//     (спека, решение 15: fetch шаблона — в didChangeDependencies).

const String _baselinePath = 'tool/l10n/hardcoded_baseline.json';
const String _helpersPath = 'tool/l10n/l10n_helpers.json';
const String _renderAllowlistPath = 'tool/l10n/render_allowlist.json';

/// Единственный файл, где разрешён прямой `L10n.en` и определён `renderEn()`.
const String _uiMsgFile = 'lib/models/ui_msg.dart';

class _RenderAllowlist {
  _RenderAllowlist(this.renderEn, this.l10nCurrent);
  final List<String> renderEn;
  final List<String> l10nCurrent;

  static _RenderAllowlist load() {
    final raw = jsonDecode(File(_renderAllowlistPath).readAsStringSync())
        as Map<String, dynamic>;
    return _RenderAllowlist(
      ((raw['renderEn'] as List?) ?? const []).cast<String>(),
      ((raw['l10nCurrent'] as List?) ?? const []).cast<String>(),
    );
  }

  static bool _match(List<String> prefixes, String file) =>
      prefixes.any((p) => p.endsWith('/') ? file.startsWith(p) : file == p);

  bool renderEnAllowed(String file) =>
      file == _uiMsgFile || _match(renderEn, file);
  bool l10nCurrentAllowed(String file) => _match(l10nCurrent, file);
}

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

class _Helper {
  _Helper(this.positional, this.named);
  final Set<int> positional;
  final Set<String> named;
}

Map<String, _Helper> _loadHelpers() {
  final raw = jsonDecode(File(_helpersPath).readAsStringSync())
      as Map<String, dynamic>;
  final helpers = raw['helpers'] as Map<String, dynamic>;
  return helpers.map((name, cfg) {
    final m = cfg as Map<String, dynamic>;
    return MapEntry(
      name,
      _Helper(
        ((m['positional'] as List?) ?? const []).cast<int>().toSet(),
        ((m['named'] as List?) ?? const []).cast<String>().toSet(),
      ),
    );
  });
}

class _Site {
  _Site(this.file, this.line, this.hash, this.preview);
  final String file;
  final int line;
  final String hash;
  final String preview;
}

String? _canonicalLiteral(Expression e) {
  if (e is SimpleStringLiteral) return e.value;
  if (e is AdjacentStrings) {
    final buf = StringBuffer();
    for (final s in e.strings) {
      final part = _canonicalLiteral(s);
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

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.file, this.lineInfo, this.lines, this.helpers, this.sites);

  final String file;
  final LineInfo lineInfo;
  final List<String> lines;
  final Map<String, _Helper> helpers;
  final List<_Site> sites;
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
    final text = _canonicalLiteral(e);
    if (text == null || text.trim().isEmpty) return;
    if (!_letter.hasMatch(text)) return; // пунктуация/юниты: '—', '·'
    if (!_seenOffsets.add(e.offset)) return;
    final line = lineInfo.getLocation(e.offset).lineNumber;
    if (_exempt(line)) return;
    final short =
        text.length > 60 ? '${text.substring(0, 57)}...' : text;
    sites.add(_Site(file, line, sha256Hex(text).substring(0, 12), short));
  }

  bool _exempt(int line) {
    bool has(int i) =>
        i >= 0 && i < lines.length && lines[i].contains('// l10n-exempt');
    return has(line - 1) || has(line - 2); // та же строка или строкой выше
  }
}

/// §9.4 — visitor rendering-locality-правил (отдельный от ratchet-скана:
/// пишет напрямую в [CheckReporter], не в baseline).
class _LocalityVisitor extends RecursiveAstVisitor<void> {
  _LocalityVisitor(this.file, this.lineInfo, this.allow, this.r);

  final String file;
  final LineInfo lineInfo;
  final _RenderAllowlist allow;
  final CheckReporter r;

  bool get _isWidgetDir =>
      file.startsWith('lib/screens/') || file.startsWith('lib/widgets/');

  int _line(AstNode e) => lineInfo.getLocation(e.offset).lineNumber;

  /// Есть ли у объемлющей функции/метода параметр типа AppLocalizations
  /// (render-path по построению — спека §9.4).
  bool _inL10nParamFunction(AstNode node) {
    for (AstNode? n = node; n != null; n = n.parent) {
      FormalParameterList? params;
      if (n is MethodDeclaration) params = n.parameters;
      if (n is FunctionDeclaration) params = n.functionExpression.parameters;
      if (n is FunctionExpression) params = n.parameters;
      if (params != null && params.toSource().contains('AppLocalizations')) {
        return true;
      }
    }
    return false;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'render' && node.realTarget != null) {
      if (file != _uiMsgFile &&
          !_isWidgetDir &&
          !_inL10nParamFunction(node)) {
        r.fail('$file:${_line(node)}: `.render(` outside lib/screens|lib/'
            'widgets and outside an AppLocalizations-parameter function — '
            'store the typed UiMsg and render at display time');
      }
    } else if (name == 'renderEn') {
      if (!allow.renderEnAllowed(file)) {
        r.fail('$file:${_line(node)}: `renderEn(` outside the machine-surface '
            'allowlist (tool/l10n/render_allowlist.json) — English render is '
            'reserved for automation/AppLog/Debug API/notification surfaces');
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.prefix.name == 'L10n') {
      final member = node.identifier.name;
      if (member == 'current' && !allow.l10nCurrentAllowed(file)) {
        r.fail('$file:${_line(node)}: `L10n.current` outside the allowlist '
            '(tool/l10n/render_allowlist.json) — use context.l in widgets or '
            'a typed UiMsg for stored state');
      } else if (member == 'en' && file != _uiMsgFile) {
        r.fail('$file:${_line(node)}: direct `L10n.en` — go through '
            'renderEn() ($_uiMsgFile is the only sanctioned access point)');
      }
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    // Спека §7.2 / решение 15 — `WizardTemplate? _template` + fetch в
    // initState переживает смену локали (initState не перезапускается) —
    // fetch обязан жить в didChangeDependencies по Localizations.localeOf.
    final templateFields = <String>[];
    for (final m in node.members) {
      if (m is FieldDeclaration &&
          m.fields.type?.toSource() == 'WizardTemplate?') {
        for (final v in m.fields.variables) {
          templateFields.add(v.name.lexeme);
        }
      }
    }
    if (templateFields.isNotEmpty) {
      for (final m in node.members) {
        if (m is MethodDeclaration && m.name.lexeme == 'initState') {
          final body = m.body.toSource();
          for (final f in templateFields) {
            if (RegExp('$f\\s*=[^=]').hasMatch(body) ||
                body.contains('$f = ')) {
              r.fail('$file:${_line(m)}: `WizardTemplate? $f` assigned in '
                  'initState — move the template fetch to '
                  'didChangeDependencies keyed on Localizations.localeOf '
                  '(survives locale switches)');
            }
          }
        }
      }
    }
    super.visitClassDeclaration(node);
  }
}

Map<String, int> _multiset(Iterable<String> items) {
  final m = <String, int>{};
  for (final i in items) {
    m[i] = (m[i] ?? 0) + 1;
  }
  return m;
}

void main(List<String> args) {
  ensureAppCwd();
  sha256SelfTest();
  final writeBaseline = args.contains('--write-baseline');
  // --strict принимается для симметрии CLI; ratchet и так фатален по умолчанию
  final r = CheckReporter('hardcoded_check', strict: parseStrict(args));

  final helpers = _loadHelpers();
  final renderAllow = _RenderAllowlist.load();
  final files = dartFilesUnder('lib', excludeDirs: ['lib/l10n/gen']);
  final sitesByFile = <String, List<_Site>>{};
  for (final path in files) {
    final content = File(path).readAsStringSync();
    final parsed =
        parseString(content: content, path: path, throwIfDiagnostics: false);
    final sites = <_Site>[];
    parsed.unit.accept(
        _Visitor(path, parsed.lineInfo, content.split('\n'), helpers, sites));
    // §9.4 — rendering-locality (fail-режим с Phase 4).
    parsed.unit.accept(_LocalityVisitor(path, parsed.lineInfo, renderAllow, r));
    if (sites.isNotEmpty) sitesByFile[path] = sites;
  }
  final total =
      sitesByFile.values.fold<int>(0, (a, b) => a + b.length);

  if (writeBaseline) {
    final out = <String, Object?>{
      for (final e in sitesByFile.entries)
        e.key: (e.value.map((s) => s.hash).toList()..sort()),
    };
    File(_baselinePath).writeAsStringSync(canonicalJson(out));
    stdout.writeln('wrote $_baselinePath: $total site(s) in '
        '${sitesByFile.length} file(s)');
  } else {
    final Map<String, dynamic> baselineRaw;
    try {
      baselineRaw = jsonDecode(File(_baselinePath).readAsStringSync())
          as Map<String, dynamic>;
    } catch (e) {
      r.fail('$_baselinePath unreadable: $e — regenerate with --write-baseline');
      exit(r.finish());
    }
    for (final e in sitesByFile.entries) {
      final base = ((baselineRaw[e.key] as List?) ?? const []).cast<String>();
      if (e.value.length <= base.length) continue; // shrink/replacement — ок
      final remaining = _multiset(base);
      for (final s in e.value) {
        final left = remaining[s.hash] ?? 0;
        if (left > 0) {
          remaining[s.hash] = left - 1;
        } else {
          r.fail('${s.file}:${s.line}: new hardcoded display string '
              '"${s.preview}" (${s.hash}) — migrate to ARB or annotate '
              '// l10n-exempt: <reason>');
        }
      }
      r.fail('${e.key}: literal site count grew '
          '${base.length} -> ${e.value.length}');
    }
  }

  // сводка по каталогам верхнего уровня lib/<dir>
  final perDir = <String, int>{};
  for (final e in sitesByFile.entries) {
    final seg = e.key.split('/');
    final dir = seg.length > 2 ? '${seg[0]}/${seg[1]}' : 'lib';
    perDir[dir] = (perDir[dir] ?? 0) + e.value.length;
  }
  stdout.writeln('scanned ${files.length} file(s), '
      '$total literal site(s) in ${sitesByFile.length} file(s)');

  exit(r.finish(extraRows: [
    MapEntry('total sites', '$total'),
    MapEntry('files with sites', '${sitesByFile.length}'),
    for (final d in perDir.keys.toList()..sort())
      MapEntry(d, '${perDir[d]}'),
  ]));
}
