import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';

/// §279 — LocaleController: set() персистит + нотифицирует; невалидное
/// хранимое значение → 'system'; reloadFromStorage идемпотентен.
///
/// Pattern стораджа: mocked path_provider + resetCacheForTesting (как в
/// settings_storage_test.dart). Native-зеркало setAppLanguage падает в
/// MissingPluginException и глотается (best-effort by design).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_locale_ctrl_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore — async AppLog write может race'ить с delete */
    }
  });

  test('set() persists, warms template cache, updates getLocalText and notifies',
      () async {
    var notified = 0;
    void listener() => notified++;
    LocaleController.I.addListener(listener);
    addTearDown(() => LocaleController.I.removeListener(listener));

    await LocaleController.I.set('ru');

    expect(LocaleController.I.setting, 'ru');
    expect(LocaleController.I.effectiveTag, 'ru');
    expect(await SettingsStorage.getAppLanguage(), 'ru');
    expect(notified, 1);
    // Прогрев ДО notify: кэш нового тега тёплый в момент rebuild.
    expect(TemplateLoader.cachedOrNull('ru'), isNotNull);
    // §285 — глобальный getLocalText переключился на ru-словарь: известный
    // ключ рендерится по-русски (fallback на английский ключ означал бы, что
    // словарь не загрузился).
    expect(getLocalText.s('Cancel'), 'Отмена');
    // Пиненный английский рендерер machine-поверхностей неизменен.
    expect(GetLocalText.en.s('Cancel'), 'Cancel');
  });

  test('set() with unknown value falls back to system', () async {
    await LocaleController.I.set('klingon');
    expect(LocaleController.I.setting, 'system');
    expect(await SettingsStorage.getAppLanguage(), 'system');
  });

  test('invalid stored value resolves to system', () async {
    await SettingsStorage.setVar('app_language', 'klingon');
    expect(await SettingsStorage.getAppLanguage(), 'system');
    await LocaleController.I.reloadFromStorage();
    expect(LocaleController.I.setting, 'system');
  });

  test('reloadFromStorage applies restored value and is idempotent', () async {
    await LocaleController.I.set('en');
    // Имитация restore: значение меняется в сторадже мимо контроллера
    // (replaceRaw-путь); reload обязан подхватить.
    await SettingsStorage.setVar('app_language', 'ru');
    var notified = 0;
    void listener() => notified++;
    LocaleController.I.addListener(listener);
    addTearDown(() => LocaleController.I.removeListener(listener));

    await LocaleController.I.reloadFromStorage();
    expect(LocaleController.I.setting, 'ru');
    expect(notified, 1);

    // Повторный вызов без изменений — no-op (без лишнего notify).
    await LocaleController.I.reloadFromStorage();
    expect(notified, 1);
  });

  test('app_language export → import round-trip preserves value', () async {
    await LocaleController.I.set('ru');
    final exported = await SettingsStorage.exportRaw();

    // Свежий сторадж (новое устройство) + restore.
    SettingsStorage.resetCacheForTesting();
    LocaleController.I.setting = 'system';
    await SettingsStorage.replaceRaw(exported);
    await LocaleController.I.reloadFromStorage();

    expect(await SettingsStorage.getAppLanguage(), 'ru');
    expect(LocaleController.I.setting, 'ru');
  });
}
