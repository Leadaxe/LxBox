// §742 C — чистые функции разбора для tool/arch/boundary_check.dart
// (вынесены, чтобы test/tool/boundary_check_test.dart мог их импортировать).

/// Убирает комментарии из строк исходника (Dart / Kotlin): целиковые `//`,
/// `///`, блоки `/* … */` (в том числе `/** … */` на несколько строк) и
/// хвостовые `// …`. Номера строк сохраняются: на выходе столько же строк,
/// сколько на входе. `//` и `/*` считаются комментарием, только если слева
/// чётное число кавычек (грубо: `'http://…'` не режется).
List<String> stripComments(List<String> lines) {
  final out = <String>[];
  var inBlock = false;
  for (final raw in lines) {
    final b = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      if (inBlock) {
        final end = raw.indexOf('*/', i);
        if (end < 0) {
          i = raw.length;
        } else {
          inBlock = false;
          i = end + 2;
        }
        continue;
      }
      if (raw.startsWith('/*', i) && _quotesEven(raw.substring(0, i))) {
        inBlock = true;
        i += 2;
        continue;
      }
      if (raw.startsWith('//', i) && _quotesEven(raw.substring(0, i))) {
        break;
      }
      b.write(raw[i]);
      i++;
    }
    out.add(b.toString());
  }
  return out;
}

bool _quotesEven(String s) {
  var single = 0, dbl = 0;
  for (final c in s.codeUnits) {
    if (c == 0x27) single++;
    if (c == 0x22) dbl++;
  }
  return single.isEven && dbl.isEven;
}

final _importRe = RegExp(
  r'''^\s*(?:import|export|part)\s+(?:'([^']+)'|"([^"]+)")''',
);

/// Путь из строки `import|export|part '…'`, иначе null.
String? importTarget(String codeLine) {
  final m = _importRe.firstMatch(codeLine);
  if (m == null) return null;
  return m.group(1) ?? m.group(2);
}

/// Приводит import-путь файла [fromFile] (относительно app/, напр.
/// `lib/vpn/x.dart`) к пути относительно app/ (`lib/...`). `dart:` и чужие
/// `package:` → null; `package:lxbox/a.dart` → `lib/a.dart`; относительный
/// путь разрешается от каталога файла.
String? resolveImport(String fromFile, String target) {
  if (target.startsWith('dart:')) return null;
  if (target.startsWith('package:lxbox/')) {
    return 'lib/${target.substring('package:lxbox/'.length)}';
  }
  if (target.startsWith('package:')) return null;
  final parts = fromFile.split('/')..removeLast();
  for (final seg in target.split('/')) {
    if (seg == '.' || seg.isEmpty) continue;
    if (seg == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// Каталог верхнего уровня `lib/` для пути `lib/<dir>/…` (иначе null).
String? layerOf(String? resolved) {
  if (resolved == null || !resolved.startsWith('lib/')) return null;
  final rest = resolved.substring(4).split('/');
  return rest.length > 1 ? rest.first : null;
}

final _channelLiteralRe = RegExp(
  r'''\b(?:Method|Event|BasicMessage)Channel\(\s*r?['"](?!\$)''',
);
final _channelOpenRe = RegExp(r'\b(?:Method|Event|BasicMessage)Channel\(\s*$');
final _literalStartRe = RegExp(r'''^\s*r?['"](?!\$)''');

/// Строка [i] (уже без комментариев) создаёт канал со строковым литералом
/// имени. Интерполяция `'${Const.x}…'` / `'$x…'` литералом не считается;
/// перенос после `Channel(` разбирается по следующей строке.
bool isChannelLiteral(List<String> code, int i) {
  final line = code[i];
  if (_channelLiteralRe.hasMatch(line)) return true;
  if (_channelOpenRe.hasMatch(line) && i + 1 < code.length) {
    return _literalStartRe.hasMatch(code[i + 1]);
  }
  return false;
}
