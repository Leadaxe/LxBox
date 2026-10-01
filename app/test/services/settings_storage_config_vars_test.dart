import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';

/// §604 — запись переменной шаблона через `setVar` поднимает «конфиг
/// устарел»: список config-var совпадает с переменными секций шаблона.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_config_vars_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getApplicationDocumentsPath') {
            return tmp.path;
          }
          return null;
        });
    SettingsStorage.resetCacheForTesting();
    SettingsStorage.configDirty = false;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SettingsStorage.configDirty = false;
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore */
    }
  });

  test('каждая переменная секций шаблона — config-var', () {
    final t =
        jsonDecode(File('assets/wizard_template.json').readAsStringSync())
            as Map<String, dynamic>;
    final names = <String>{
      for (final s in t['sections'] as List)
        for (final v in ((s as Map)['vars'] as List? ?? const []))
          if (v is Map && v['name'] is String) v['name'] as String,
    };
    expect(names, isNotEmpty);
    expect(names.difference(SettingsStorage.configVarKeys), isEmpty);
  });

  test('setVar(tls_fragment) поднимает configDirty', () async {
    await SettingsStorage.setVar('tls_fragment', 'true');
    expect(SettingsStorage.configDirty, true);
  });

  test('не-config var (раскладка списка) флаг не поднимает', () async {
    await SettingsStorage.setVar('node_list_two_columns', 'true');
    expect(SettingsStorage.configDirty, false);
  });
}
