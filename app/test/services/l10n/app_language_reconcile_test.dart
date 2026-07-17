// §279 Phase 6 (спека §6.4) — юнит-тесты чистой функции трёхстороннего
// reconciliation app_language ↔ LocaleManager. Ветки нумерованы по спеке.

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/l10n/app_language_reconcile.dart';

AppLanguageReconcileDecision _run(
  String stored,
  String appLocales,
  String? lastPushed,
) =>
    reconcileAppLanguage(
      stored: stored,
      state: AppLanguageNativeState(
        applicationLocales: appLocales,
        lastPushedLocale: lastPushed,
      ),
    );

void main() {
  group('§279 reconcileAppLanguage', () {
    test('ветка 3 — всё совпадает → no-op (явный выбор)', () {
      expect(_run('ru', 'ru', 'ru'), isA<ReconcileNoop>());
      expect(_run('en', 'en', 'en'), isA<ReconcileNoop>());
    });

    test('ветка 3 — всё совпадает → no-op (system, пустой список)', () {
      expect(_run('system', '', ''), isA<ReconcileNoop>());
    });

    test('ветка 1 — системные Settings поменяли язык → система побеждает', () {
      final d = _run('en', 'ru', 'en');
      expect(d, isA<ReconcileSystemWins>());
      expect((d as ReconcileSystemWins).newSetting, 'ru');
    });

    test('ветка 1 — системные Settings сбросили на System → stored=system', () {
      // Мы пушили 'ru', юзер в Settings выбрал «System default» (пустой список).
      final d = _run('ru', '', 'ru');
      expect(d, isA<ReconcileSystemWins>());
      expect((d as ReconcileSystemWins).newSetting, 'system');
    });

    test('ветка 1 — регион-tag из Settings нормализуется (ru-RU → ru)', () {
      final d = _run('system', 'ru-RU', '');
      expect(d, isA<ReconcileSystemWins>());
      expect((d as ReconcileSystemWins).newSetting, 'ru');
    });

    test('ветка 2 — restore/Debug API поменял сторадж → сторадж побеждает', () {
      // Зеркало консистентно с системой (мы пушили 'en'), но в сторадже
      // теперь 'ru' (restore бэкапа при мёртвом приложении).
      expect(_run('ru', 'en', 'en'), isA<ReconcileStorageWins>());
    });

    test('ветка 2 — сторадж стал system при запушенном ru → пере-пуш пустого',
        () {
      expect(_run('system', 'ru', 'ru'), isA<ReconcileStorageWins>());
    });

    test('первый старт (не пушили) + пустой список → выровнять по стораджу',
        () {
      // Пуш ставит зеркало last_pushed_locale даже для system/пустого.
      expect(_run('system', '', null), isA<ReconcileStorageWins>());
      expect(_run('ru', '', null), isA<ReconcileStorageWins>());
    });

    test('первый старт (не пушили) + непустой список → система побеждает', () {
      // Непустой список до первого пуша мог поставить только юзер в Settings.
      final d = _run('system', 'en', null);
      expect(d, isA<ReconcileSystemWins>());
      expect((d as ReconcileSystemWins).newSetting, 'en');
    });

    test('неизвестный язык из Settings (недостижимо) → трактуется как system',
        () {
      final d = _run('ru', 'de-DE', 'ru');
      expect(d, isA<ReconcileSystemWins>());
      expect((d as ReconcileSystemWins).newSetting, 'system');
    });

    test('зеркало с регионом эквивалентно голому тегу (нет ложной ветки 1)',
        () {
      expect(_run('ru', 'ru-RU', 'ru'), isA<ReconcileNoop>());
    });
  });
}
