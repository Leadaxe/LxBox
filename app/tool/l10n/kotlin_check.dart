import 'dart:io';

import 'src/check_common.dart';

// §279 (спека §9.5) — grep-tier гвард нативных строк Android.
//
// Скан android/app/src/main: строковый литерал внутри аргументов
// setContentTitle/setContentText/addAction/setShortLabel/setLongLabel/
// Toast.makeText/NotificationChannel в .kt — находка (R.string-ссылки и
// переменные легальны); android:label="<raw>" без @string в манифесте —
// находка. Аргументы читаются до парной ')' (строковый контекст учитывается),
// многострочные вызовы покрыты; литералы без букв пропускаются.
//
// До Phase 6 (экстракция в strings.xml ещё не сделана) — REPORT-ONLY:
// находки идут warnings, default exit 0; --strict переводит их в fail —
// wiring тот же, что у остальных checker'ов.

const String _root = 'android/app/src/main';

final RegExp _call = RegExp(
    r'(setContentTitle|setContentText|addAction|setShortLabel|setLongLabel|'
    r'Toast\.makeText|NotificationChannel)\s*\(');
final RegExp _stringLit = RegExp(r'"((?:[^"\\]|\\.)*)"');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _manifestLabel = RegExp(r'android:label\s*=\s*"([^"]*)"');

/// Аргументный сегмент вызова: от '(' до парной ')', кавычки учитываются,
/// окно ограничено — grep-tier, не парсер Kotlin.
String _argSegment(String content, int openParen) {
  var depth = 0;
  var inString = false;
  final limit =
      (openParen + 800) < content.length ? openParen + 800 : content.length;
  for (var i = openParen; i < limit; i++) {
    final c = content[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') inString = true;
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return content.substring(openParen + 1, i);
    }
  }
  return content.substring(openParen + 1, limit);
}

int _lineOf(String content, int offset) =>
    '\n'.allMatches(content.substring(0, offset)).length + 1;

void main(List<String> args) {
  ensureAppCwd();
  final strict = parseStrict(args);
  final r = CheckReporter('kotlin_check', strict: strict);

  var ktFiles = 0;
  final dir = Directory(_root);
  if (!dir.existsSync()) {
    r.fail('$_root not found');
    exit(r.finish());
  }
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.kt')) continue;
    ktFiles++;
    final content = e.readAsStringSync();
    final path = e.path.replaceAll('\\', '/');
    for (final m in _call.allMatches(content)) {
      final seg = _argSegment(content, m.end - 1);
      for (final lit in _stringLit.allMatches(seg)) {
        final text = lit.group(1)!;
        if (text.isEmpty || !_letter.hasMatch(text)) continue;
        r.warn('$path:${_lineOf(content, m.start)}: string literal "$text" '
            'in ${m.group(1)}(...) — use R.string');
      }
    }
  }

  final manifest = File('$_root/AndroidManifest.xml');
  if (manifest.existsSync()) {
    final content = manifest.readAsStringSync();
    for (final m in _manifestLabel.allMatches(content)) {
      final value = m.group(1)!;
      if (value.startsWith('@')) continue;
      r.warn('$_root/AndroidManifest.xml:${_lineOf(content, m.start)}: '
          'android:label="$value" — use @string resource');
    }
  } else {
    r.fail('$_root/AndroidManifest.xml not found');
  }

  final mode = strict ? 'strict' : 'report-only';
  stdout.writeln('kotlin_check ($mode): ${r.warnings.length} finding(s) '
      'in $ktFiles .kt file(s) + manifest');
  exit(r.finish(extraRows: [
    MapEntry('kt files', '$ktFiles'),
    MapEntry('mode', mode),
  ]));
}
