// §279 — рукописный holder поверх генерируемого gen_l10n (lib/l10n/gen/).
//
// Политика доступа: виджеты — `context.l`; сервисы/контроллеры — lazy-рендер
// (типизированные объекты), `L10n.current` — только немедленное потребление;
// `L10n.en` — machine-поверхности (renderEn, Phase 4).

import 'package:flutter/widgets.dart';

import '../../l10n/gen/app_localizations.dart';

export '../../l10n/gen/app_localizations.dart';

class L10n {
  L10n._();

  /// Активная локаль. Eager-инициализация английским: error boundary и
  /// _FallbackErrorWidget ставятся в main() ДО инициализации стораджа —
  /// late-поле дало бы LateInitializationError внутри crash-handler'а.
  /// Переприсваивается только LocaleController'ом (владелец пайплайна).
  static AppLocalizations current = lookupAppLocalizations(const Locale('en'));

  /// Пиненный английский инстанс для machine-поверхностей (логи, automation,
  /// notification-labels — renderEn()). Никогда не переприсваивается.
  static final AppLocalizations en = lookupAppLocalizations(const Locale('en'));
}

extension L10nBuildContext on BuildContext {
  /// Канонический доступ к строкам в виджетах: `context.l.commonCancel`.
  AppLocalizations get l => AppLocalizations.of(this);
}
