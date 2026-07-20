import 'dart:io';

import 'src/check_common.dart';

// §279 (спека §9.5) — grep-tier гвард нативных строк Android.
//
// Скан android/app/src/main: строковый литерал внутри аргументов
// setContentTitle/setContentText/addAction/setShortLabel/setLongLabel/
// Toast.makeText/NotificationChannel/stopAndAlert в .kt — находка
// (R.string-ссылки и переменные легальны); присваивание литерала в
// tile.label/tile.subtitle — находка; android:label="<raw>" без @string в
// манифесте — находка. Аргументы читаются до парной ')' (строковый контекст
// учитывается), многострочные вызовы покрыты; литералы без букв пропускаются.
//
// Исключение: литералы с префиксом `alert:` — структурный wire-протокол
// (`alert:permission_location:...`, парсится Dart-side в StopReason, §4.5
// спеки 279), английский навсегда — не находка.
//
// Phase 6 (§279) выполнена: экстракция в strings.xml закончена, CI зовёт
// checker с --strict — любая новая находка фатальна.
//
// + parity-гвард values/strings.xml ↔ values-ru/strings.xml: каждый
// translatable en-ключ обязан иметь ru-перевод, ru без en-ключа (orphan) —
// находка, translatable="false" в ru — находка, наборы %-placeholder'ов
// (%1$s и т.п.) у пары ключей обязаны совпадать.

const String _root = 'android/app/src/main';

final RegExp _call = RegExp(
    r'(setContentTitle|setContentText|addAction|setShortLabel|setLongLabel|'
    r'Toast\.makeText|NotificationChannel|stopAndAlert)\s*\(');
final RegExp _tileAssign =
    RegExp(r'\btile\.(?:label|subtitle)\s*=\s*"((?:[^"\\]|\\.)*)"');
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

final RegExp _stringRes = RegExp(
    r'<string\s+name="([^"]+)"([^>]*)>(.*?)</string>',
    dotAll: true);
final RegExp _placeholder = RegExp(r'%(?:\d+\$)?[sdf]');

class _Res {
  _Res(this.value, this.translatable);
  final String value;
  final bool translatable;
}

Map<String, _Res> _parseStrings(String content) {
  final map = <String, _Res>{};
  for (final m in _stringRes.allMatches(content)) {
    map[m.group(1)!] = _Res(
      m.group(3)!,
      !m.group(2)!.contains('translatable="false"'),
    );
  }
  return map;
}

/// §279 — parity values/strings.xml ↔ values-ru/strings.xml (см. шапку).
void _checkResourceParity(CheckReporter r) {
  final enFile = File('$_root/res/values/strings.xml');
  final ruFile = File('$_root/res/values-ru/strings.xml');
  if (!enFile.existsSync()) {
    r.fail('${enFile.path} not found');
    return;
  }
  if (!ruFile.existsSync()) {
    r.fail('${ruFile.path} not found');
    return;
  }
  final en = _parseStrings(enFile.readAsStringSync());
  final ru = _parseStrings(ruFile.readAsStringSync());
  for (final e in en.entries) {
    final ruRes = ru[e.key];
    if (!e.value.translatable) {
      if (ruRes != null) {
        r.warn('values-ru/strings.xml: "${e.key}" duplicates a '
            'translatable="false" string — remove it');
      }
      continue;
    }
    if (ruRes == null) {
      r.warn('values-ru/strings.xml: missing translation for "${e.key}"');
      continue;
    }
    final enSet =
        _placeholder.allMatches(e.value.value).map((m) => m.group(0)!).toSet();
    final ruSet =
        _placeholder.allMatches(ruRes.value).map((m) => m.group(0)!).toSet();
    if (enSet.length != ruSet.length || !enSet.containsAll(ruSet)) {
      r.warn('strings.xml: placeholder mismatch for "${e.key}" '
          '(en: $enSet, ru: $ruSet)');
    }
  }
  for (final k in ru.keys) {
    if (!en.containsKey(k)) {
      r.warn('values-ru/strings.xml: orphan key "$k" (not in values/)');
    }
  }
}

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
        // Структурный wire-префикс (см. шапку) — не display-строка.
        if (text.startsWith('alert:')) continue;
        r.warn('$path:${_lineOf(content, m.start)}: string literal "$text" '
            'in ${m.group(1)}(...) — use R.string');
      }
    }
    for (final m in _tileAssign.allMatches(content)) {
      final text = m.group(1)!;
      if (text.isEmpty || !_letter.hasMatch(text)) continue;
      r.warn('$path:${_lineOf(content, m.start)}: string literal "$text" '
          'assigned to tile.label/subtitle — use L10n.str(R.string)');
    }
  }

  _checkResourceParity(r);

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
