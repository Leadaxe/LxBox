import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/lx_backup.dart';

// Конформанс-раннер корпуса LX Backup (SPEC 103, фаза 4), сторона LxBox.
// Тот же набор гоняет Go (core/backup/corpus_test.go).
//
// Перенос настроек между приложениями имеет смысл ровно настолько, насколько
// обе стороны одинаково понимают битую ссылку, непереносимую переменную и
// чужой блок extensions. Расхождение здесь = пользователь получит на телефоне
// не то, что видел на десктопе.

const _contractRoot = 'contract';

void main() {
  final root = Directory('$_contractRoot/corpus/backup');
  if (!root.existsSync()) return; // контракт не синхронизирован

  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.backup.json'))
      .map((f) =>
          f.path.substring(0, f.path.length - '.backup.json'.length))
      .toList()
    ..sort();

  group('contract corpus: LX Backup', () {
    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      test(name, () {
        final raw = File('$base.backup.json').readAsStringSync();
        final expected = jsonDecode(File('$base.expected.json').readAsStringSync())
            as Map<String, dynamic>;

        final file = parseLxBackup(raw, knownOutbounds: {'proxy', 'direct'});

        // Коды предупреждений — часть контракта: они отвечают на вопрос
        // «что не применилось», и расхождение означает, что одна из сторон
        // молчит о потере.
        final gotCodes = file.warnings.map((w) => w.code).toSet().toList()..sort();
        final wantCodes =
            ((expected['warnings'] as List?) ?? const []).cast<String>().toList()
              ..sort();
        expect(gotCodes, wantCodes, reason: 'коды предупреждений');

        final wantRules =
            ((expected['rules'] as List?) ?? const []).cast<Map<String, dynamic>>();
        expect(file.rules, hasLength(wantRules.length), reason: 'число правил');
        for (var i = 0; i < wantRules.length; i++) {
          expect(file.rules[i].name, wantRules[i]['name'], reason: 'имя правила #$i');
          expect(file.rules[i].enabled, wantRules[i]['enabled'],
              reason: 'состояние правила ${wantRules[i]['name']}');
        }

        final wantVars = (expected['vars'] as Map?)?.cast<String, dynamic>();
        if (wantVars != null) {
          expect(file.vars, wantVars.map((k, v) => MapEntry(k, '$v')));
        }

        if (expected['route_final_applied'] == false) {
          expect(file.routeFinal, isNull);
        }

        // Импортёр обязан сохранить блоб ДРУГОГО приложения; свой он
        // применяет полями. Ожидание сформулировано относительно импортёра,
        // поэтому фикстура одна на обе стороны.
        if (expected['foreign_extensions_kept_other_app'] == true) {
          expect(file.foreignExtensions.containsKey(kLxAppLauncher), isTrue,
              reason: 'блоб extensions.$kLxAppLauncher не сохранён — '
                  'обратный экспорт обеднеет');
          expect(file.foreignExtensions.containsKey(kLxAppLxBox), isFalse,
              reason: 'собственный блоб положен в чужие — он должен '
                  'применяться полями');
        }
      });
    }
  });
}
