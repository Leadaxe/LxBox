// §279 — единственный владелец пайплайна смены локали. Все пути записи
// `app_language` сходятся сюда (picker, Debug API side-effect registry,
// restore → reloadFromStorage, системная смена → didChangeLocales) —
// обходных записей нет by construction (прецедент §275).

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../rule_name_resolver.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'l10n.dart';

class LocaleController extends ChangeNotifier with WidgetsBindingObserver {
  static final LocaleController I = LocaleController();

  static const supportedTags = ['en', 'ru'];
  static const supportedLocales = [Locale('en'), Locale('ru')];

  /// 'system' | 'en' | 'ru' (зеркало var `app_language`).
  String setting = 'system';

  Locale? _lastApplied;

  Locale get effective => setting == 'system'
      ? _resolve(PlatformDispatcher.instance.locale)
      : Locale(setting);

  String get effectiveTag => effective.languageCode;

  static Locale _resolve(Locale device) =>
      supportedTags.contains(device.languageCode)
          ? Locale(device.languageCode)
          : const Locale('en');

  /// main()-старт: применить сохранённую настройку ДО runApp (первый кадр
  /// локализован) без прогрева шаблона — init ниже по main() сам грузит
  /// template под effectiveTag — и без notify (слушателей ещё нет).
  void bootstrap(String stored) {
    setting = stored;
    final loc = effective;
    _lastApplied = loc;
    L10n.current = lookupAppLocalizations(loc);
  }

  /// Регистрируется в main(): WidgetsBinding.instance.addObserver(I).
  /// При setting=='system' смена языка устройства без этого перештамповывала
  /// бы native-поверхности, но не Flutter-UI (MaterialApp.locale перечитывается
  /// только в build, которого не случалось бы).
  @override
  void didChangeLocales(List<Locale>? locales) {
    if (setting != 'system') return;
    final now = effective;
    // Тот же пайплайн минус персист (настройка не менялась — язык устройства).
    if (now != _lastApplied) unawaited(_applyLocale(now));
  }

  Future<void> set(String v) async {
    setting = SettingsStorage.appLanguageValues.contains(v) ? v : 'system';
    // JSON-var + best-effort native-зеркало — внутри setAppLanguage.
    await SettingsStorage.setAppLanguage(setting);
    await _applyLocale(effective);
  }

  /// После backup-restore (UI и Debug API): перечитать `app_language` из
  /// стораджа и применить. Идемпотентно — no-op если ничего не изменилось.
  Future<void> reloadFromStorage() async {
    final stored = await SettingsStorage.getAppLanguage();
    if (stored == setting && _lastApplied == effective) return;
    setting = stored;
    await _applyLocale(effective);
  }

  Future<void> _applyLocale(Locale loc) async {
    _lastApplied = loc;
    L10n.current = lookupAppLocalizations(loc);
    // Прогрев ДО notifyListeners: каждый rebuild видит тёплый кэш новой
    // локали, cachedOrNull не null ни в один момент переключения.
    await TemplateLoader.reload(loc.languageCode);
    // Display-зеркала билдера пере-дерайвятся без ребилда конфига.
    RuleNameResolver.I.relocalize(TemplateLoader.cachedOrNull(loc.languageCode));
    // Слить staged lazy-persist правки (LazyPersistMixin пишет в _cache,
    // диск — отложенно; полный rebuild ниже не должен их потерять).
    await SettingsStorage.flushToDisk();
    notifyListeners(); // → полный rebuild MaterialApp (merged Listenable)
  }
}
