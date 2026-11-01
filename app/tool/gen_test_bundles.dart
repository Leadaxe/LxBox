// Сборки тест-файлов для CI: K точек входа вместо одной на файл.
//
// `flutter test` компилирует и стартует каждый `_test.dart` отдельно — на
// полном прогоне это бóльшая часть процессорного времени. Сборка импортирует
// пачку тест-файлов и объявляет каждый своей группой, так что компиляция и
// старт идут K раз, а не по числу файлов.
//
// Тесты писались под свежий изолят на файл, поэтому перед каждым файлом и
// после него сборка зовёт `resetTestGlobals` (test/support/test_globals.dart):
// хранилище, синглтоны, path_provider, моки каналов — к состоянию свежего
// процесса. Файл, которому этого мало, попадает в [kExcluded] с причиной и
// идёт отдельной точкой входа.
//
// Раскладка: файлы по пути (соседи по каталогу рядом), режутся на K
// непрерывных кусков равного веса; вес — размер файла плюс надбавка за
// widget-тесты (они дольше остальных).
//
// Каталог test_bundle/ генерируется и в git не входит. Рядом кладётся
// excluded.txt — список исключённых файлов для командной строки.
//
// Запуск (из app/):
//   dart run tool/gen_test_bundles.dart [--bundles 8]
//   flutter test test_bundle $(cat test_bundle/excluded.txt)

import 'dart:io';

/// Файлы, которые в сборку не входят: путь от app/ → причина.
const kExcluded = <String, String>{};

const _outDir = 'test_bundle';

/// Признаки тестового биндинга во файле (или в импортированном им локальном
/// помощнике): `testWidgets`, явный `ensureInitialized`, `WidgetTester`.
final _bindingRe = RegExp(
    r'\btestWidgets\(|TestWidgetsFlutterBinding|WidgetTester\b|'
    r'AutomatedTestWidgetsFlutterBinding');
final _relImportRe = RegExp(r"^import\s+'([^':]+\.dart)'", multiLine: true);
final _widgetTestRe = RegExp(r'\btestWidgets\(');

void main(List<String> args) {
  var bundles = 8;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--bundles' && i + 1 < args.length) {
      bundles = int.parse(args[++i]);
    } else {
      stderr.writeln('usage: dart run tool/gen_test_bundles.dart '
          '[--bundles K]');
      exitCode = 64;
      return;
    }
  }

  final all = Directory('test')
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((f) => f.path.replaceAll(r'\', '/'))
      .where((p) => p.endsWith('_test.dart'))
      .toList()
    ..sort();

  for (final p in kExcluded.keys) {
    if (!all.contains(p)) {
      stderr.writeln('kExcluded: файла нет — $p (убрать из списка)');
      exitCode = 1;
      return;
    }
  }

  final files = [
    for (final p in all)
      if (!kExcluded.containsKey(p)) _TestFile.read(p),
  ];

  final out = Directory(_outDir);
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync();

  final chunks = _split(files, bundles);
  for (var i = 0; i < chunks.length; i++) {
    File('$_outDir/bundle${i}_test.dart')
        .writeAsStringSync(_render(chunks[i]));
  }
  File('$_outDir/excluded.txt')
      .writeAsStringSync(kExcluded.keys.map((p) => '$p\n').join());

  stdout.writeln('Сборок ${chunks.length}, файлов ${files.length}, '
      'исключено ${kExcluded.length} из ${all.length}');
  for (var i = 0; i < chunks.length; i++) {
    final w = chunks[i].fold<int>(0, (s, f) => s + f.weight);
    stdout.writeln('  bundle$i: ${chunks[i].length} файлов, вес ${w ~/ 1000}k, '
        '${chunks[i].first.path} … ${chunks[i].last.path}');
  }
}

class _TestFile {
  _TestFile(this.path, this.weight, this.binding);

  final String path;
  final int weight;
  final bool binding;

  factory _TestFile.read(String path) {
    final text = File(path).readAsStringSync();
    var binding = _bindingRe.hasMatch(_code(text));
    if (!binding) {
      final dir = File(path).parent.path;
      for (final m in _relImportRe.allMatches(text)) {
        final helper = File('$dir/${m.group(1)}');
        if (helper.existsSync() &&
            _bindingRe.hasMatch(_code(helper.readAsStringSync()))) {
          binding = true;
          break;
        }
      }
    }
    final widgetTests = _widgetTestRe.allMatches(text).length;
    return _TestFile(path, 2000 + text.length + 3000 * widgetTests, binding);
  }
}

/// Текст без строчных комментариев: «НЕ вызываем ensureInitialized» в
/// комментарии — не признак биндинга.
String _code(String text) => text.replaceAll(RegExp(r'//[^\n]*'), '');

/// Непрерывные куски примерно равного веса.
List<List<_TestFile>> _split(List<_TestFile> files, int k) {
  final total = files.fold<int>(0, (s, f) => s + f.weight);
  final chunks = <List<_TestFile>>[];
  var current = <_TestFile>[];
  var acc = 0;
  for (final f in files) {
    current.add(f);
    acc += f.weight;
    // Граница куска — когда набран его пропорциональный вес.
    if (chunks.length < k - 1 && acc >= total * (chunks.length + 1) / k) {
      chunks.add(current);
      current = <_TestFile>[];
    }
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

String _render(List<_TestFile> files) {
  final b = StringBuffer()
    ..writeln('// Сгенерировано tool/gen_test_bundles.dart — не править.')
    ..writeln('// ignore_for_file: directives_ordering')
    ..writeln("import 'package:flutter_test/flutter_test.dart';")
    ..writeln()
    ..writeln("import '../test/support/test_globals.dart';");
  for (var i = 0; i < files.length; i++) {
    b.writeln("import '../${files[i].path}' as t$i;");
  }
  b
    ..writeln()
    ..writeln('void main() {')
    ..writeln('  captureTestGlobals();');
  for (var i = 0; i < files.length; i++) {
    final f = files[i];
    b.writeln("  _file('${f.path}', t$i.main"
        "${f.binding ? '' : ', binding: false'});");
  }
  b
    ..writeln('}')
    ..writeln()
    ..writeln('/// Файл — своя группа; сброс глобального состояния идёт до')
    ..writeln('/// `setUpAll` файла и после его `tearDownAll` (setUpAll — по')
    ..writeln('/// порядку объявления, tearDownAll — в обратном).')
    ..writeln('void _file(String path, void Function() body, '
        '{bool binding = true}) {')
    ..writeln('  group(path, () {')
    ..writeln('    setUpAll(() => resetTestGlobals(binding: binding));')
    ..writeln('    tearDownAll(() => resetTestGlobals(binding: binding));')
    ..writeln('    body();')
    ..writeln('  });')
    ..writeln('}');
  return b.toString();
}
