import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W7 — СНЯТЬ ссылки РУКОПИСНЫМ `toUri` до его удаления.
///
/// Не проверка, а инструмент, и он ОДНОРАЗОВЫЙ по смыслу: как только
/// рукописный эмит удалён, снять снимок «до» больше негде. Отсюда и порядок
/// волны — сперва прогон этого дампа, и только потом правка `node_spec.dart`.
///
/// Снимок нужен ради критерия 5.2 спеки: `toUri()` у нас ОДНОВРЕМЕННО форма
/// хранения ручного узла (`rawSource`), и ссылка, сохранённая прежними
/// версиями приложения, обязана и дальше читаться в ТО ЖЕ тело. Новый вид
/// ссылки при этом законен — проверяется чтение старой, а не совпадение
/// текстов.
///
/// Запуск: `LX_EMIT_DUMP=1 flutter test test/parser/emit_before480_dump_test.dart`.
/// Без переменной не делает ничего.
void main() {
  final on = Platform.environment['LX_EMIT_DUMP'] != null;

  test('дамп ссылок рукописного эмита', () async {
    if (!on) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);

    final dir = Directory('test/fixtures');
    for (final scheme in dir.listSync().whereType<Directory>()) {
      final f = File('${scheme.path}/pipeline_identity_before.json');
      if (!f.existsSync()) continue;
      final raw = jsonDecode(f.readAsStringSync()) as Map;
      final cases = (raw['cases'] as Map?)?.cast<String, dynamic>();
      if (cases == null) continue;

      final out = <String, dynamic>{};
      for (final e in cases.entries) {
        final c = (e.value as Map).cast<String, dynamic>();
        final uri = c['uri'] as String?;
        if (uri == null) continue;
        final spec = parseUri(uri);
        if (spec == null) continue;
        // Ссылка, которую отдавал РУКОПИСНЫЙ эмит на этом теле.
        final oldUri = spec.toUri();
        // И тело, в которое ЭТА ССЫЛКА читалась. Именно оно эталон: между
        // ним и `body` лежит потеря рукописного эмита (он не умел писать
        // `plugin`, `pinSHA256`, `disable_sni`, ронял `?ed=` в хвосте пути),
        // и требовать от новой волны восстановить то, чего в тексте ссылки
        // нет, было бы требованием невозможного.
        final reread = parseUri(oldUri);
        out[e.key] = {
          'body': jsonDecode(jsonEncode(c['body'])),
          'uri_before': oldUri,
          'body_of_old_uri': reread == null
              ? null
              : jsonDecode(jsonEncode(reread.emit(TemplateVars.empty).map)),
        };
      }
      if (out.isEmpty) continue;
      File('${scheme.path}/emit_before480.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
              '_note': '§480 W7 — ссылки РУКОПИСНОГО `toUri`, снятые до его '
                  'удаления. Проверяется ЧТЕНИЕ: старая ссылка обязана '
                  'разбираться в то же тело (rawSource ручных узлов). Текст '
                  'новой ссылки может отличаться — это не ошибка.',
              'cases': out,
            })}\n',
      );
    }
  });
}
