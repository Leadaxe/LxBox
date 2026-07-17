import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/template_loader.dart';

/// §279 — TemplateLoader: кэш по тегу локали, mid-flight смена локали не
/// отравляет кэш, overlay-ассеты бандлятся и парсятся.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'en';
  });

  tearDown(() {
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
  });

  test('load() stores result under the tag read at start (mid-flight switch)',
      () async {
    LocaleController.I.setting = 'en';
    final inFlight = TemplateLoader.load();
    // Смена локали пока load() в полёте — результат обязан лечь под СВОЙ
    // (старый) тег, не под новый.
    LocaleController.I.setting = 'ru';
    await inFlight;
    expect(TemplateLoader.cachedOrNull('en'), isNotNull);
    expect(TemplateLoader.cachedOrNull('ru'), isNull,
        reason: 'in-flight load старой локали не должен занять слот новой');

    await TemplateLoader.reload('ru');
    expect(TemplateLoader.cachedOrNull('ru'), isNotNull);
    // Оба тега сосуществуют — invalidate-гонки нет by construction.
    expect(TemplateLoader.cachedOrNull('en'), isNotNull);
  });

  test('cachedOrNull defaults to effectiveTag', () async {
    LocaleController.I.setting = 'en';
    expect(TemplateLoader.cachedOrNull(), isNull);
    await TemplateLoader.load();
    expect(TemplateLoader.cachedOrNull(), isNotNull);
    LocaleController.I.setting = 'ru';
    expect(TemplateLoader.cachedOrNull(), isNull);
  });

  test('ru overlay localizes display fields, config subtree untouched',
      () async {
    LocaleController.I.setting = 'en';
    final en = await TemplateLoader.load();
    LocaleController.I.setting = 'ru';
    final ru = await TemplateLoader.load();
    expect(TemplateLoader.cachedOrNull('ru'), same(ru));

    // Display-поля реально переведены (не совпадают с en).
    SelectableRule byId(WizardTemplate t, String id) =>
        t.selectableRules.firstWhere((r) => r.presetId == id);
    expect(byId(en, 'block-ads').label, 'Block Ads');
    expect(byId(ru, 'block-ads').label, isNot(byId(en, 'block-ads').label));

    WizardVar varByName(WizardTemplate t, String name) =>
        t.vars.firstWhere((v) => v.name == name);
    expect(varByName(en, 'tls_fragment').title, 'TLS Fragment');
    expect(varByName(ru, 'tls_fragment').title,
        isNot(varByName(en, 'tls_fragment').title));

    // Magic-ноды (§3.5.3) переведены.
    expect(ru.groupTemplates.magicNodes['auto']?.title,
        isNot(en.groupTemplates.magicNodes['auto']?.title));

    // Machine-подмножество (config) overlay НЕ трогает — байт-в-байт.
    expect(jsonEncode(ru.config), jsonEncode(en.config));
  });

  // §3.4b спеки 279 — забытая per-file запись ассета в pubspec красит CI:
  // flutter test бандлит pubspec-ассеты, отсутствующий файл здесь упадёт.
  test('every declared template overlay asset loads and parses', () async {
    for (final tag in LocaleController.supportedTags) {
      if (tag == 'en') {
        // en-зеркало — тоже заявленный ассет (для checkers), валидный JSON.
        final raw =
            await rootBundle.loadString('assets/l10n/template/en.json');
        expect(jsonDecode(raw), isA<Map<String, dynamic>>());
        continue;
      }
      final raw =
          await rootBundle.loadString('assets/l10n/template/$tag.json');
      expect(jsonDecode(raw), isA<Map<String, dynamic>>(),
          reason: 'overlay $tag.json обязан быть валидным JSON-объектом');
    }
  });
}
