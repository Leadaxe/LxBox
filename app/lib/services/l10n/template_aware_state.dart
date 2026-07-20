import 'package:flutter/widgets.dart';

import 'locale_controller.dart';

/// §279 Phase 2 (спека §7.2, решение 15) — единый мини-паттерн для экранов,
/// держащих `WizardTemplate?`-поле (или производные от шаблона display-данные).
///
/// Проблема: fetch в `initState` — снапшот локали на момент открытия экрана.
/// Rebuild MaterialApp при смене языка сохраняет Element tree и State,
/// `initState` не перезапускается — экран (включая сидящие в глубине стека)
/// навсегда остался бы на старом языке. Механизм, не конвенция: fetch
/// перенесён в `didChangeDependencies`, ключуясь на `Localizations.localeOf`.
///
/// Контракт:
/// - [onLocaleTemplateFetch] вызывается ДО первого build (`first: true`) —
///   экран запускает свой полный `_load()`;
/// - и снова при каждой смене ambient-локали (`first: false`) — экран
///   перечитывает ТОЛЬКО template-derived display-состояние (пользовательские
///   буферы не трогаются). Кэш TemplateLoader к этому моменту тёплый
///   (LocaleController прогревает ДО notifyListeners) — refetch мгновенный.
/// - Guard от дублирующихся конкурентных load'ов: тег запоминается синхронно,
///   повторный didChangeDependencies с тем же тегом — no-op.
mixin TemplateAwareState<T extends StatefulWidget> on State<T> {
  String? _templateLocaleTag;

  /// Тег локали, под который выполнен последний fetch (null до первого).
  String? get templateLocaleTag => _templateLocaleTag;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // maybeLocaleOf — виджет-тесты могут pump'ать экран без Localizations;
    // тогда ключуемся на effectiveTag контроллера (то же значение в проде).
    final tag = Localizations.maybeLocaleOf(context)?.languageCode ??
        LocaleController.I.effectiveTag;
    if (tag == _templateLocaleTag) return;
    final first = _templateLocaleTag == null;
    _templateLocaleTag = tag; // sync — guard от дублей до завершения fetch'а
    onLocaleTemplateFetch(first: first);
  }

  /// Запустить fetch шаблона/производных данных. [first] — до первого build
  /// (полная загрузка экрана); иначе — смена локали (refetch display-данных).
  void onLocaleTemplateFetch({required bool first});
}
