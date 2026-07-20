import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'src/check_common.dart';
import 'src/hardcoded_scan.dart';
import 'src/sha256.dart';

// §279 (спека §9.3) — ratchet против новых hardcoded display-строк.
//
// AST-скан lib/ (минус lib/l10n/gen/) по синтаксису, без резолюции типов.
// Display-позиции и рекурсия в ternary/switch-ветки — см.
// src/hardcoded_scan.dart (логика вынесена в библиотеку и покрыта
// test/tool/hardcoded_scan_test.dart). Self-check-эвристика кандидатов
// в хелперы (String-параметр → ScaffoldMessenger) — позднее ужесточение.
//
// Baseline tool/l10n/hardcoded_baseline.json: {file: [hash...]} — hash =
// первые 12 hex sha256 канонизированного текста (каждая ${...}-интерполяция
// заменена на "{}" позиционно; rename переменной hash не меняет).
// Режимы: --write-baseline регенерирует; default сравнивает: рост числа
// сайтов файла → fail со списком новых; удаление — тихо (baseline сужают
// через --write-baseline); замена hash'а в файле легальна, пока счётчик
// файла не растёт (hotfix-путь).

// §285 — rendering-locality-правила, FAIL-режим (getLocalText-эпоха):
//   - `renderEn(` — только в allowlist-файлах (render_allowlist.json:
//     machine-поверхности — automation, Debug API, AppLog-сайты,
//     notification-push, emitWarnings) плюс модельные иерархии, где определён
//     сам renderEn() (lib/models/);
//   - прямой `GetLocalText.en` вне lib/models/ → fail (единственный
//     санкционированный путь на machine-поверхностях — renderEn());
//   - паттерн «поле `WizardTemplate?` + заполнение в initState» → fail
//     (спека, решение 15: fetch шаблона — в didChangeDependencies).
//
// §285 — `.render()` (UiMsg → String через ambient getLocalText активной
// локали) больше НЕ гейтится по каталогу: он не требует BuildContext и
// безопасен из сервисов/контроллеров (прежнее правило было привязано к
// context.l/AppLocalizations-параметру, которых больше нет).

const String _baselinePath = 'tool/l10n/hardcoded_baseline.json';
const String _helpersPath = 'tool/l10n/l10n_helpers.json';
const String _renderAllowlistPath = 'tool/l10n/render_allowlist.json';

/// Каталог модельных иерархий, где определён `renderEn()` и разрешён прямой
/// `GetLocalText.en` (ui_msg/validation/stop_reason/node_warning).
const String _modelsDir = 'lib/models/';

class _RenderAllowlist {
  _RenderAllowlist(this.renderEn);
  final List<String> renderEn;

  static _RenderAllowlist load() {
    final raw = jsonDecode(File(_renderAllowlistPath).readAsStringSync())
        as Map<String, dynamic>;
    return _RenderAllowlist(
      ((raw['renderEn'] as List?) ?? const []).cast<String>(),
    );
  }

  static bool _match(List<String> prefixes, String file) =>
      prefixes.any((p) => p.endsWith('/') ? file.startsWith(p) : file == p);

  bool renderEnAllowed(String file) =>
      file.startsWith(_modelsDir) || _match(renderEn, file);
}

Map<String, DisplayHelper> _loadHelpers() {
  final raw = jsonDecode(File(_helpersPath).readAsStringSync())
      as Map<String, dynamic>;
  final helpers = raw['helpers'] as Map<String, dynamic>;
  return helpers.map((name, cfg) {
    final m = cfg as Map<String, dynamic>;
    return MapEntry(
      name,
      DisplayHelper(
        ((m['positional'] as List?) ?? const []).cast<int>().toSet(),
        ((m['named'] as List?) ?? const []).cast<String>().toSet(),
      ),
    );
  });
}

/// §9.4 — visitor rendering-locality-правил (отдельный от ratchet-скана:
/// пишет напрямую в [CheckReporter], не в baseline).
class _LocalityVisitor extends RecursiveAstVisitor<void> {
  _LocalityVisitor(this.file, this.lineInfo, this.allow, this.r);

  final String file;
  final LineInfo lineInfo;
  final _RenderAllowlist allow;
  final CheckReporter r;

  int _line(AstNode e) => lineInfo.getLocation(e.offset).lineNumber;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'renderEn') {
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
    // §285 — прямой `GetLocalText.en` (пиненный английский рендерер) легален
    // только в модельных иерархиях, где определён renderEn(); везде ещё —
    // идти через renderEn() (санкционированный machine-surface путь).
    if (node.prefix.name == 'GetLocalText' &&
        node.identifier.name == 'en' &&
        !file.startsWith(_modelsDir)) {
      r.fail('$file:${_line(node)}: direct `GetLocalText.en` — go through '
          'renderEn() (only $_modelsDir* may reference the pinned English '
          'renderer directly)');
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
  final sitesByFile = <String, List<HardcodedSite>>{};
  for (final path in files) {
    final content = File(path).readAsStringSync();
    // Ratchet-скан (src/hardcoded_scan.dart — вкл. рекурсию в ternary/switch).
    final sites = scanForHardcodedStrings(
        path: path, content: content, helpers: helpers);
    // §9.4 — rendering-locality (fail-режим с Phase 4).
    final parsed =
        parseString(content: content, path: path, throwIfDiagnostics: false);
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
