import 'dart:convert';
import 'dart:io';

import 'src/check_common.dart';
import 'src/ui_scan.dart';

// §285 Ф3 — CI-гейт natural-key локализации (заменил мёртвый arb_check).
// Держит call-site'ы getLocalText в lib/ и словарь assets/l10n/ui/ru.json в
// синхроне: missing/orphan-ключи (warn, strict→fail), shape (.s↔String /
// .plural↔полный plural-объект) и арность плейсхолдеров (fail всегда).
// Динамические (не-литеральные) ключи валидировать нельзя — только считаются.
//
// Логика скана+валидации — src/ui_scan.dart (чистая, покрыта
// test/tool/ui_check_test.dart). Набор plural-форм берётся из
// RuPluralResolver.forms (lib) — не дублируется, живёт в синхроне.

const String _dictPath = 'assets/l10n/ui/ru.json';

void main(List<String> args) {
  ensureAppCwd();
  final strict = parseStrict(args);
  final r = CheckReporter('ui_check', strict: strict);

  // Словарь.
  final dictFile = File(_dictPath);
  if (!dictFile.existsSync()) {
    r.fail('$_dictPath missing');
    exit(r.finish());
  }
  Map<String, dynamic> dict;
  try {
    dict = jsonDecode(dictFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    r.fail('$_dictPath: invalid JSON: $e');
    exit(r.finish());
  }

  // Скан lib/ — собираем все обращения к локализатору.
  final files = dartFilesUnder('lib');
  final uses = <UiKeyUse>[];
  var dynamicCount = 0;
  for (final path in files) {
    final res =
        scanForUiKeys(path: path, content: File(path).readAsStringSync());
    uses.addAll(res.uses);
    dynamicCount += res.dynamicKeys.length;
  }

  final v = validateUiKeys(
    uses: uses,
    dynamicCount: dynamicCount,
    dict: dict,
    forms: ruForms(),
  );

  // Раскладываем находки по уровням: shape/arity/usage-conflict — fail всегда;
  // missing/orphan/orphan-special — warn (strict→fail).
  for (final f in v.findings) {
    switch (f.kind) {
      case UiFindingKind.usageConflict:
      case UiFindingKind.shape:
      case UiFindingKind.arity:
        r.fail(f.message);
      case UiFindingKind.missing:
      case UiFindingKind.orphan:
      case UiFindingKind.orphanSpecial:
        r.warn(f.message);
    }
  }

  stdout.writeln('[ui_check] keys: ${v.keys}, missing: ${v.missing}, '
      'orphan: ${v.orphan}, arity-errors: ${v.arityErrors}, '
      'dynamic-skipped: ${v.dynamicSkipped}');

  exit(r.finish(extraRows: [
    MapEntry('dict keys', '${dict.length}'),
    MapEntry('literal keys', '${v.keys}'),
    MapEntry('missing', '${v.missing}'),
    MapEntry('orphan', '${v.orphan}'),
    MapEntry('arity errors', '${v.arityErrors}'),
    MapEntry('dynamic skipped', '${v.dynamicSkipped}'),
    MapEntry('dart files scanned', '${files.length}'),
  ]));
}
