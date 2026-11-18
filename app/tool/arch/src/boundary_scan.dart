// §742 C — чистые функции разбора для tool/arch/boundary_check.dart
// (вынесены, чтобы test/tool/boundary_check_test.dart мог их импортировать).

// §747 F — имена сервисной стороны (процесс `:bg`), которых файл стороны окна
// (процесс `:ui`) не касается. Слева от имени не буква: `UiCoreSession` не
// совпадает с `CoreSession`. Объекты Taildrop — только обращение через точку:
// типы libbox `TaildropInbox…` клиент ядра окна использует законно.
final _serviceSideNameRe = RegExp(
  r'(?<![A-Za-z0-9_])(CoreSession|ScreenCoreSession|ServiceCommandClient|'
  r'BoxCommandClient|StreamSinks|ProbeSession|PProfClient|BootReceiver|'
  r'NativeCache|AutomationCache|ConfigManager|BoxService|BgMethods|'
  r'BgCcMethods|BgLifecycle|BgEventPipe|UiPresence|UiHold|UiCalls|AutomationRelay|L10n|'
  r'AssistantCore|AssistantBridge|AppFunctionsGate|LxBoxAppFunctions)\b',
);
final _taildropObjectRe = RegExp(
  r'(?<![A-Za-z0-9_])(Taildrop|TaildropClip|TaildropServiceFiles)\.',
);
final _boxVpnServiceMemberRe = RegExp(
  r'(?<![A-Za-z0-9_])BoxVpnService(?:\.(\w+)|::class)',
);
final _constantNameRe = RegExp(r'^[A-Z][A-Z0-9_]*$');

/// §747 F — нарушение в строке файла стороны окна (уже без комментариев) или
/// null. Сторона окна живёт в другом процессе: память сервисной стороны ей
/// недоступна, а её классы в процессе окна были бы пустой копией. До сервиса
/// она дотягивается только вызовом `BgClient` (имя метода — строка) и файлом
/// конфига (`ConfigFile`). Из `BoxVpnService` разрешены одни константы
/// (`BROADCAST_STATUS`, `EXTRA_*`): значение подставляется при компиляции.
String? uiServiceSideUse(String codeLine) {
  final name = _serviceSideNameRe.firstMatch(codeLine);
  if (name != null) return 'сервисная сторона: ${name.group(1)}';
  final taildrop = _taildropObjectRe.firstMatch(codeLine);
  if (taildrop != null) return 'сервисная сторона: ${taildrop.group(1)}';
  for (final m in _boxVpnServiceMemberRe.allMatches(codeLine)) {
    final member = m.group(1);
    if (member == null) return 'BoxVpnService::class';
    if (!_constantNameRe.hasMatch(member)) return 'BoxVpnService.$member';
  }
  return null;
}

final _coreInWindowRe = RegExp(
  r'\bio\.nekohasekai\.libbox\b|(?<![A-Za-z0-9_])Libbox\.|\bensureLibbox\b',
);

/// §747 (итерация 2) — нарушение в строке файла стороны окна (уже без
/// комментариев) или null: окно ядро не грузит вовсе. Любой `import
/// io.nekohasekai.libbox…`, обращение `Libbox.…` или вызов `ensureLibbox`
/// в процессе окна означал бы загрузку `libbox.so` и второй среды Go ради
/// того, что уже есть в `:bg`.
String? uiCoreUse(String codeLine) {
  final m = _coreInWindowRe.firstMatch(codeLine);
  return m == null ? null : 'ядро в процессе окна: ${m.group(0)}';
}

final _xmlCommentRe = RegExp(r'<!--.*?-->', dotAll: true);
final _componentTagRe = RegExp(
  r'<(activity|service|receiver|provider)(\s[^<>]*)?>',
);
final _attrNameRe = RegExp(r'\bandroid:name\s*=\s*"([^"]*)"');
final _attrProcessRe = RegExp(r'\bandroid:process\s*=\s*"([^"]*)"');

/// §747 F — компоненты манифеста без явного процесса: у каждого
/// `<activity>`, `<service>`, `<receiver>`, `<provider>` должен стоять
/// `android:process` со значением `:ui` или `:bg`. `<activity-alias>` атрибута
/// не имеет (живёт в процессе цели) и не проверяется. Возвращает по строке на
/// нарушение; комментарии XML не считаются.
List<String> manifestProcessViolations(String manifestXml) {
  final xml = manifestXml.replaceAll(_xmlCommentRe, '');
  final out = <String>[];
  for (final m in _componentTagRe.allMatches(xml)) {
    final attrs = m.group(2) ?? '';
    final name = _attrNameRe.firstMatch(attrs)?.group(1) ?? '?';
    final process = _attrProcessRe.firstMatch(attrs)?.group(1);
    if (process == ':ui' || process == ':bg') continue;
    out.add(
      '<${m.group(1)} $name>: '
      '${process == null ? 'нет android:process' : 'android:process="$process"'}',
    );
  }
  return out;
}

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
