import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';
import 'package:lxbox/services/relative_time.dart';

/// §285 — relativeTime через getLocalText. Локализатор инъектируется (DI):
/// en-группа не передаёт `t` → глобальный fallback печатает английский ключ;
/// ru-группа передаёт GetLocalText, собранный из настоящего
/// assets/l10n/ru/ui.json + RuPluralResolver (без глобального LocaleController).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 4, 22, 12, 0, 0);

  group('relativeTime en (night T6-1, §285 — natural keys, fallback)', () {
    // Без `t`: глобальный getLocalText в тесте = fallback → английский ключ.
    String ago(Duration d) => relativeTime(now, now.subtract(d));

    test('<60 sec → "just now"', () {
      expect(ago(const Duration(seconds: 30)), 'just now');
    });
    test('future → "just now" (не пугаем)', () {
      expect(relativeTime(now, now.add(const Duration(minutes: 5))), 'just now');
    });
    test('5 min → "5 min ago"', () {
      expect(ago(const Duration(minutes: 5)), '5 min ago');
    });
    test('2 h → "2h ago"', () {
      expect(ago(const Duration(hours: 2)), '2h ago');
    });
    test('ровно 24ч → yesterday', () {
      expect(ago(const Duration(days: 1)), 'yesterday');
    });
    test('3 дня → "3d ago"', () {
      expect(ago(const Duration(days: 3)), '3d ago');
    });
    test('2 недели → "2w ago"', () {
      expect(ago(const Duration(days: 14)), '2w ago');
    });
    test('2 месяца → "2mo ago"', () {
      expect(ago(const Duration(days: 65)), '2mo ago');
    });
    test('2 года → "2y ago"', () {
      expect(ago(const Duration(days: 800)), '2y ago');
    });
  });

  group('relativeTime ru — DI-инъекция ru-словаря (CLDR-плюралы)', () {
    late GetLocalText ru;

    setUpAll(() async {
      final raw = await rootBundle.loadString('assets/l10n/ru/ui.json');
      final dict = jsonDecode(raw) as Map<String, dynamic>;
      ru = GetLocalText(dict, const RuPluralResolver());
    });

    String ago(Duration d) => relativeTime(now, now.subtract(d), t: ru);

    test('<60 сек → «только что»', () {
      expect(ago(const Duration(seconds: 30)), 'только что');
    });
    test('минуты: one/few/many + 21 (one)', () {
      expect(ago(const Duration(minutes: 1)), '1 минуту назад');
      expect(ago(const Duration(minutes: 2)), '2 минуты назад');
      expect(ago(const Duration(minutes: 5)), '5 минут назад');
      expect(ago(const Duration(minutes: 21)), '21 минуту назад');
    });
    test('часы: one/few/many', () {
      expect(ago(const Duration(hours: 1)), '1 час назад');
      expect(ago(const Duration(hours: 3)), '3 часа назад');
      expect(ago(const Duration(hours: 11)), '11 часов назад');
    });
    test('ровно 24ч → «вчера»', () {
      expect(ago(const Duration(days: 1)), 'вчера');
    });
    test('дни: few/many', () {
      expect(ago(const Duration(days: 3)), '3 дня назад');
      expect(ago(const Duration(days: 6)), '6 дней назад');
    });
    test('недели: one/few', () {
      expect(ago(const Duration(days: 7)), '1 неделю назад');
      expect(ago(const Duration(days: 14)), '2 недели назад');
    });
    test('месяцы: one/few/many', () {
      expect(ago(const Duration(days: 32)), '1 месяц назад');
      expect(ago(const Duration(days: 65)), '2 месяца назад');
      expect(ago(const Duration(days: 300)), '10 месяцев назад');
    });
    test('годы: one/few/many', () {
      expect(ago(const Duration(days: 400)), '1 год назад');
      expect(ago(const Duration(days: 800)), '2 года назад');
      expect(ago(const Duration(days: 1900)), '5 лет назад');
    });
  });
}
