import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('ru template parses with overlay applied (placeholder = English)',
      () async {
    LocaleController.I.setting = 'ru';
    final t = await TemplateLoader.load();
    // ru.json пока пуст ({}) — шаблон валиден и остаётся английским.
    expect(t.vars, isNotEmpty);
    expect(TemplateLoader.cachedOrNull('ru'), same(t));
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
