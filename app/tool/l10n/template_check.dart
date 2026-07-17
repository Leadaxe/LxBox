import 'dart:convert';
import 'dart:io';

import 'package:lxbox/services/l10n/template_overlay.dart';

import 'src/check_common.dart';
import 'src/sha256.dart';

// §279 (спека §9.1) — проверки шаблонного overlay-слоя.
//
// 1. `assets/l10n/template/en.json` — генерируемое зеркало display-строк
//    wizard_template.json. Схема адресов живёт в ОДНОМ месте —
//    lib/services/l10n/template_overlay.dart (TemplateOverlay.extract);
//    checker обязан находить файл byte-equal свежей экстракции в каноническом
//    виде (сортированные ключи, отступ 2, trailing newline). Регенерация:
//    `--write-en`.
// 2. Каждый не-en файл `assets/l10n/template/<tag>.json` — объектный формат
//    { "<address>": { "text": "...", "src": "<hash>" } }, где src — первые
//    8 hex-символов sha256 от UTF-8 текущего английского значения по этому
//    адресу. Расхождение src = протухший перевод: warning, под --strict — fail.
//    После пересмотра перевода src регенерируется `--accept <tag>:<key>`.
// 3. Неизвестный ключ / пустой text / text с ведущим '@' или содержащий '{'
//    — безусловный fail: '@' в начале значения был бы прочитан подстановкой
//    vars как ссылка (порядок overlay-до-preset_expand контрактный).
// 4. Отсутствующие ключи (en-ключ без перевода) — warning, под --strict fail.

const String _templatePath = 'assets/wizard_template.json';
const String _overlayDir = 'assets/l10n/template';
const String _enPath = '$_overlayDir/en.json';

String _srcHash(String enValue) => sha256Hex(enValue).substring(0, 8);

String _preview(List<String> keys, [int max = 5]) {
  final head = keys.take(max).join(', ');
  return keys.length > max ? '$head, ... +${keys.length - max}' : head;
}

void main(List<String> args) {
  ensureAppCwd();
  sha256SelfTest();
  final strict = parseStrict(args);
  final writeEn = args.contains('--write-en');
  final accepts = <String>{};
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--accept') accepts.add(args[i + 1]);
  }
  final r = CheckReporter('template_check', strict: strict);

  final Map<String, String> extracted;
  try {
    final template = jsonDecode(File(_templatePath).readAsStringSync())
        as Map<String, dynamic>;
    extracted = TemplateOverlay.extract(template);
  } catch (e) {
    r.fail('extraction from $_templatePath failed: $e');
    exit(r.finish());
  }

  // -- en.json: byte-equal генерируемому зеркалу --------------------------
  final canonical = canonicalJson(extracted);
  final enFile = File(_enPath);
  if (writeEn) {
    enFile
      ..createSync(recursive: true)
      ..writeAsStringSync(canonical);
    stdout.writeln('wrote $_enPath (${extracted.length} keys)');
  } else if (!enFile.existsSync()) {
    r.fail('$_enPath missing — generate it: '
        'dart run tool/l10n/template_check.dart --write-en');
  } else if (enFile.readAsStringSync() != canonical) {
    Map<String, dynamic> committed = const {};
    try {
      committed = jsonDecode(enFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    final added =
        extracted.keys.where((k) => !committed.containsKey(k)).toList();
    final removed =
        committed.keys.where((k) => !extracted.containsKey(k)).toList();
    final changed = extracted.keys
        .where((k) => committed.containsKey(k) && committed[k] != extracted[k])
        .toList();
    final parts = <String>[
      if (added.isNotEmpty) 'missing from committed: ${_preview(added)}',
      if (removed.isNotEmpty) 'stale in committed: ${_preview(removed)}',
      if (changed.isNotEmpty) 'value drift: ${_preview(changed)}',
    ];
    if (parts.isEmpty) parts.add('formatting drift (keys and values match)');
    r.fail('$_enPath is not byte-equal to fresh extraction '
        '(${parts.join('; ')}) — regenerate with --write-en');
  }

  // -- локальные overlay-файлы -------------------------------------------
  var localeCount = 0, staleTotal = 0, missingTotal = 0;
  final dir = Directory(_overlayDir);
  final localeFiles = !dir.existsSync()
      ? <File>[]
      : (dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') && !f.path.endsWith('/en.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)));

  for (final f in localeFiles) {
    localeCount++;
    final tag = f.uri.pathSegments.last.replaceAll('.json', '');
    final Map<String, dynamic> raw;
    try {
      raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      r.fail('$tag.json: invalid JSON: $e');
      continue;
    }
    var rewritten = false;
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!extracted.containsKey(key)) {
        r.fail('$tag.json: unknown key "$key" (not extractable from template)');
        continue;
      }
      if (value is! Map || value['text'] is! String) {
        r.fail('$tag.json: "$key": entry must be {"text": "...", "src": "..."}');
        continue;
      }
      final text = value['text'] as String;
      if (text.isEmpty) {
        r.fail('$tag.json: "$key": empty text');
      }
      if (text.startsWith('@')) {
        r.fail('$tag.json: "$key": text must not start with "@" '
            '(would be read as a template var reference)');
      }
      if (text.contains('{')) {
        r.fail('$tag.json: "$key": text must not contain "{"');
      }
      final want = _srcHash(extracted[key]!);
      if (accepts.contains('$tag:$key')) {
        value['src'] = want;
        rewritten = true;
      } else if (value['src'] != want) {
        staleTotal++;
        r.warn('$tag.json: "$key": stale src '
            '(have ${value['src'] ?? 'none'}, en is $want) — re-review the '
            'translation, then run --accept $tag:$key');
      }
    }
    final missing = extracted.keys.where((k) => !raw.containsKey(k)).length;
    if (missing > 0) {
      missingTotal += missing;
      r.warn('$tag.json: $missing key(s) untranslated (silent en fallback)');
    }
    if (rewritten) {
      // канонический вид: сортированные ключи, поля entry в порядке text,src
      final out = <String, Object?>{
        for (final k in raw.keys)
          k: (raw[k] is Map)
              ? {
                  'text': (raw[k] as Map)['text'],
                  'src': (raw[k] as Map)['src'],
                }
              : raw[k],
      };
      f.writeAsStringSync(canonicalJson(out));
      stdout.writeln('updated src hashes in ${f.path}');
    }
  }

  exit(r.finish(extraRows: [
    MapEntry('en keys', '${extracted.length}'),
    MapEntry('locale files', '$localeCount'),
    MapEntry('stale keys', '$staleTotal'),
    MapEntry('missing keys', '$missingTotal'),
  ]));
}
