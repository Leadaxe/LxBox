// §279 — единственный владелец пайплайна смены локали. Все пути записи
// `app_language` сходятся сюда (picker, Debug API side-effect registry,
// restore → reloadFromStorage, системная смена → didChangeLocales) —
// обходных записей нет by construction (прецедент §275).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show Intl;

import '../rule_name_resolver.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'get_local_text.dart';
import 'plural_resolver.dart';

/// §285 — глобальный доступ к natural-key локализатору (аналог `L10n.current`,
/// но без BuildContext). Работает в сервисах/контроллерах/парсерах. Пока
/// (Ф1) ARB-система жива — этот геттер существует рядом, инертно, до миграции
/// call-site'ов на следующих фазах.
GetLocalText get getLocalText => LocaleController.I.text;

class LocaleController extends ChangeNotifier with WidgetsBindingObserver {
  static final LocaleController I = LocaleController();

  static const supportedTags = ['en', 'ru'];
  static const supportedLocales = [Locale('en'), Locale('ru')];

  /// 'system' | 'en' | 'ru' (зеркало var `app_language`).
  String setting = 'system';

  Locale? _lastApplied;

  // §285 — natural-key локализатор активной локали. Eager-инициализация
  // fallback-инстансом (dict=null → печатает английский ключ): доступен из
  // getLocalText ДО первой загрузки словаря (как L10n.current с английским).
  // Переприсваивается в _applyLocale после загрузки assets/l10n/<tag>/ui.json.
  GetLocalText _text = GetLocalText(null, const EnPluralResolver());
  GetLocalText get text => _text;

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
  ///
  /// Словарь `_text` прогревается ЗДЕСЬ (а не только в _applyLocale): при
  /// холодном старте с сохранённым 'ru' ни один пайплайн (set/reload/
  /// didChangeLocales) не срабатывает, поэтому без этого первый кадр печатал
  /// английский ключ (fallback dict=null), пока юзер не переключал язык
  /// вручную. `await` в main() держит первый кадр до готовности словаря.
  /// best-effort: сбой загрузки → _text остаётся fallback'ом (английский
  /// ключ), запуск не блокируется. Template/relocalize сюда не тянем — их
  /// грузит init ниже по main() (первый TemplateLoader.load), notify не нужен
  /// (слушателей ещё нет).
  Future<void> bootstrap(String stored) async {
    setting = stored;
    final loc = effective;
    _lastApplied = loc;
    // §279 Phase 5 — intl-форматтеры дат (format_utils) берут локаль отсюда.
    Intl.defaultLocale = loc.toLanguageTag();
    try {
      _text = await _buildGetLocalText(loc.languageCode);
    } catch (_) {
      // best-effort — fallback-локализатор (английский ключ) остаётся.
    }
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
    // §279 Phase 5 — intl-форматтеры дат (format_utils) берут локаль отсюда.
    Intl.defaultLocale = loc.toLanguageTag();
    // §279 — прогрев шаблона/зеркал best-effort: его сбой (или зависание
    // загрузки ассета) НЕ должен блокировать переключение языка. getLocalText
    // словарь переключается ниже (_buildGetLocalText) + rebuild MaterialApp;
    // шаблонные метки в худшем случае догрузятся при следующем чтении кэша.
    try {
      // §285 — natural-key словарь новой локали. Сбой (нет файла / битый JSON)
      // best-effort: _text остаётся с dict=null → печатает английский ключ.
      _text = await _buildGetLocalText(loc.languageCode);
      // Прогрев ДО notifyListeners: каждый rebuild видит тёплый кэш новой
      // локали, cachedOrNull не null ни в один момент переключения.
      await TemplateLoader.reload(loc.languageCode);
      // Display-зеркала билдера пере-дерайвятся без ребилда конфига.
      RuleNameResolver.I
          .relocalize(TemplateLoader.cachedOrNull(loc.languageCode));
      // Слить staged lazy-persist правки (LazyPersistMixin пишет в _cache,
      // диск — отложенно; полный rebuild ниже не должен их потерять).
      await SettingsStorage.flushToDisk();
    } catch (_) {
      // best-effort — язык всё равно применяем (notify ниже безусловен).
    }
    notifyListeners(); // → полный rebuild MaterialApp (merged Listenable)
  }

  /// §285 — собрать GetLocalText для [tag]: resolver по языку + словарь из
  /// `assets/l10n/<tag>/ui.json`. Для 'en' (и любого отсутствующего файла) словарь
  /// = null → чистый fallback на английский ключ (английский базовый и живёт в
  /// коде — отдельного словаря для него нет by design).
  /// Бросить может (нет ассета / битый JSON) — вызывается под общим try
  /// _applyLocale, где сбой не блокирует переключение языка.
  static Future<GetLocalText> _buildGetLocalText(String tag) async {
    final resolver =
        tag == 'ru' ? const RuPluralResolver() : const EnPluralResolver();
    if (tag == 'en') return GetLocalText(null, resolver);
    try {
      final raw = await rootBundle.loadString('assets/l10n/$tag/ui.json');
      final dict = jsonDecode(raw) as Map<String, dynamic>;
      return GetLocalText(dict, resolver);
    } on FlutterError {
      // Ассета нет в бандле → fallback-локализатор (английский ключ).
      return GetLocalText(null, resolver);
    }
  }
}
