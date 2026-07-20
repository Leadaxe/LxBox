// §279 Phase 6 (спека §6.4) — трёхсторонний reconciliation `app_language` ↔
// per-app-локали LocaleManager (Android 13+). Чистая логика без платформенных
// зависимостей — юнит-тестируется напрямую; применение — в
// `bootstrapAndSyncNativePrefs` (native_prefs.dart).
//
// Инвариант (спека §6.4): непустой `getApplicationLocales` может происходить
// либо из нашего же пуша (тогда он равен зеркалу `last_pushed_locale`), либо
// из системных Settings (расхождение с зеркалом). Отсюда решение:
//   1. applicationLocales != last_pushed → менял юзер в системных Settings →
//      СИСТЕМА побеждает: значение пишется в сторадж (и зеркало обновляется
//      следующим пушем).
//   2. applicationLocales == last_pushed, но != сторадж → сторадж изменился
//      под ногами (restore, Debug API при мёртвом приложении, hand-edit) →
//      СТОРАДЖ побеждает: значение пере-пушится в LocaleManager.
//   3. Совпадает всё → no-op.

/// Снимок native-состояния per-app-локалей (`getAppLanguageState`).
class AppLanguageNativeState {
  const AppLanguageNativeState({
    required this.applicationLocales,
    required this.lastPushedLocale,
  });

  /// `LocaleManager.getApplicationLocales().toLanguageTags()`;
  /// '' = пустой список (per-app-локали не заданы).
  final String applicationLocales;

  /// Зеркало `boxvpn_boot.last_pushed_locale`: последнее значение, которое МЫ
  /// запушили ('' = пустой список / system); null = ещё ни разу не пушили.
  final String? lastPushedLocale;
}

/// Итог сверки.
sealed class AppLanguageReconcileDecision {
  const AppLanguageReconcileDecision();
}

/// Ничего не делать — всё консистентно.
class ReconcileNoop extends AppLanguageReconcileDecision {
  const ReconcileNoop();
}

/// Юзер менял язык в системных Settings → записать [newSetting]
/// ('system'|'en'|'ru') в сторадж (через SettingsStorage.setAppLanguage —
/// native-зеркало и last_pushed обновятся тем же путём).
class ReconcileSystemWins extends AppLanguageReconcileDecision {
  const ReconcileSystemWins(this.newSetting);
  final String newSetting;
}

/// Сторадж изменился под ногами → пере-пушить хранимое значение в
/// LocaleManager (native setAppLanguage-handler).
class ReconcileStorageWins extends AppLanguageReconcileDecision {
  const ReconcileStorageWins();
}

const _supported = {'en', 'ru'};

/// Нормализация language-tags из LocaleManager к нашему ключу:
/// '' → '' (пусто); 'ru-RU,en' → 'ru'; регистронезависимо.
/// Неизвестный язык (недостижимо при localeConfig из en/ru) → ''.
String _normalizeTags(String tags) {
  final first = tags.split(',').first.trim();
  if (first.isEmpty) return '';
  final lang = first.split('-').first.toLowerCase();
  return _supported.contains(lang) ? lang : '';
}

/// Настройка → тег, который мы пушим ('' = пустой список для 'system').
String _settingToTag(String setting) => setting == 'system' ? '' : setting;

/// Тег → настройка ('' → 'system').
String _tagToSetting(String tag) => tag.isEmpty ? 'system' : tag;

/// Чистая функция решения (см. шапку файла). [stored] — валидированное
/// значение var `app_language` ('system'|'en'|'ru').
AppLanguageReconcileDecision reconcileAppLanguage({
  required String stored,
  required AppLanguageNativeState state,
}) {
  final current = _normalizeTags(state.applicationLocales);
  final storedTag = _settingToTag(stored);
  final rawPushed = state.lastPushedLocale;
  if (rawPushed == null) {
    // Ещё ни разу не пушили (первый старт на 33+ / апгрейд). Непустой список
    // мог поставить только юзер в системных Settings → система побеждает;
    // пустой → выровнять LocaleManager по стораджу (первый пуш ставит зеркало).
    if (current.isNotEmpty) return ReconcileSystemWins(_tagToSetting(current));
    return const ReconcileStorageWins();
  }
  final pushed = _normalizeTags(rawPushed);
  if (current != pushed) {
    // Ветка 1 — системные Settings поменяли per-app-локали после нашего пуша.
    return ReconcileSystemWins(_tagToSetting(current));
  }
  if (storedTag != current) {
    // Ветка 2 — сторадж разошёлся при консистентном зеркале.
    return const ReconcileStorageWins();
  }
  return const ReconcileNoop();
}
