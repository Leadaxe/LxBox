import 'dart:convert';
import 'dart:io';

// §279 — общая обвязка l10n-checker'ов: CWD-гвард, репортер failures/warnings
// с --strict-эскалацией, отчёт в GITHUB_STEP_SUMMARY, канонический JSON.

/// Все checker'ы запускаются из `app/` (так их зовёт CI, working-directory: app).
void ensureAppCwd() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync() ||
      !pubspec.readAsStringSync().contains('name: lxbox')) {
    stderr.writeln(
        'Run from the app/ directory (pubspec.yaml with "name: lxbox" not found in CWD).');
    exit(2);
  }
}

bool parseStrict(List<String> args) => args.contains('--strict');

class CheckReporter {
  CheckReporter(this.name, {required this.strict});

  final String name;
  final bool strict;
  final List<String> failures = [];
  final List<String> warnings = [];

  void fail(String msg) => failures.add(msg);
  void warn(String msg) => warnings.add(msg);

  /// Печатает все сообщения + итоговую строку, дописывает markdown-таблицу в
  /// GITHUB_STEP_SUMMARY (если переменная выставлена) и возвращает exit-код:
  /// failures всегда фатальны, warnings — только под --strict.
  int finish({List<MapEntry<String, String>> extraRows = const []}) {
    for (final f in failures) {
      stdout.writeln('FAIL: $f');
    }
    for (final w in warnings) {
      stdout.writeln('warn: $w');
    }
    final strictNote =
        strict && warnings.isNotEmpty ? ' (strict: warnings are fatal)' : '';
    stdout.writeln(
        '[$name] failures: ${failures.length}, warnings: ${warnings.length}$strictNote');

    final rows = <MapEntry<String, String>>[
      MapEntry('failures', '${failures.length}'),
      MapEntry('warnings', '${warnings.length}'),
      ...extraRows,
    ];
    appendStepSummary(_markdown(rows));

    return failures.isNotEmpty || (strict && warnings.isNotEmpty) ? 1 : 0;
  }

  String _markdown(List<MapEntry<String, String>> rows) {
    final b = StringBuffer('### $name\n\n| metric | value |\n|---|---|\n');
    for (final r in rows) {
      b.writeln('| ${_mdEscape(r.key)} | ${_mdEscape(r.value)} |');
    }
    final details = [
      ...failures.map((f) => 'FAIL: $f'),
      ...warnings.map((w) => 'warn: $w'),
    ];
    if (details.isNotEmpty) {
      b.writeln('\n<details><summary>details (${details.length})</summary>\n');
      for (final d in details.take(30)) {
        b.writeln('- ${_mdEscape(d)}');
      }
      if (details.length > 30) {
        b.writeln('- ... ${details.length - 30} more');
      }
      b.writeln('\n</details>');
    }
    return b.toString();
  }
}

String _mdEscape(String s) =>
    s.replaceAll('|', r'\|').replaceAll('\n', ' ');

void appendStepSummary(String markdown) {
  final path = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync('$markdown\n', mode: FileMode.append);
}

/// Канонический вид генерируемых JSON-артефактов (en.json, baseline):
/// отсортированные ключи, отступ 2, завершающий перевод строки — детерминизм
/// нужен для byte-equal сравнения в CI.
String canonicalJson(Map<String, Object?> map) {
  final sorted = <String, Object?>{
    for (final k in map.keys.toList()..sort()) k: map[k],
  };
  return '${const JsonEncoder.withIndent('  ').convert(sorted)}\n';
}

/// Рекурсивный список .dart-файлов под [root] (пути с '/'-сепаратором,
/// относительные к CWD), минус каталоги из [excludeDirs] (префиксы путей).
List<String> dartFilesUnder(String root,
    {List<String> excludeDirs = const []}) {
  final result = <String>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return result;
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final p = e.path.replaceAll('\\', '/');
    if (excludeDirs.any((x) => p == x || p.startsWith('$x/'))) continue;
    result.add(p);
  }
  result.sort();
  return result;
}
