// §393 A6 — каскад смены `tag_prefix` на regex-фильтры Направлений: общий
// обработчик для экрана подписки и экрана папки.
//
// Оба экрана рисуют один и тот же `SubscriptionSettingsTab` и до §393 A6
// одинаково писали префикс в обход всего остального (`entry.tagPrefix = v`).
// Каскад живёт ЗДЕСЬ, а не в двух копиях: расхождение обработчиков — ровно
// тот класс, что породил §275 (см. `DirectionMutations`).
//
// Модель разбора — `models/direction_tag_prefix.dart`; запись Направлений —
// только через `DirectionMutations.update` (§275: голый
// `SettingsStorage.updateDirection` мимо ресинка контроллера запрещён).

import 'package:flutter/material.dart';

import '../../controllers/subscription_controller.dart';
import '../../models/direction.dart';
import '../../models/direction_tag_prefix.dart';
import '../../services/direction_mutations.dart';
import '../../services/l10n/locale_controller.dart';

/// Итог каскада — для тестов и для строки уведомления.
class TagPrefixCascadeOutcome {
  const TagPrefixCascadeOutcome({
    required this.healed,
    required this.ambiguous,
  });

  static const none = TagPrefixCascadeOutcome(healed: [], ambiguous: []);

  /// Направления, чьи фильтры переписаны (уже записаны в storage).
  final List<Direction> healed;

  /// Направления, где старый префикс виден внутри regex-конструкции —
  /// НЕ тронуты, пользователь правит руками.
  final List<Direction> ambiguous;

  bool get isEmpty => healed.isEmpty && ambiguous.isEmpty;
}

/// Пересчитать Направления под смену префикса [oldPrefix] → [newPrefix].
///
/// Однозначные (литеральные) вхождения переписываются и СРАЗУ уезжают в
/// storage через [DirectionMutations.update]; неоднозначные только
/// возвращаются вызывающему. [sub] — контроллер для зеркального ресинка
/// (§275), может быть null в тестах/до готовности UI.
///
/// Возвращает [TagPrefixCascadeOutcome.none], когда трогать нечего.
Future<TagPrefixCascadeOutcome> applyTagPrefixCascade({
  required List<Direction> directions,
  required String oldPrefix,
  required String newPrefix,
  SubscriptionController? sub,
}) async {
  final cascade = analyzeTagPrefixChange(
    directions: directions,
    oldPrefix: oldPrefix,
    newPrefix: newPrefix,
  );
  if (cascade.isEmpty) return TagPrefixCascadeOutcome.none;

  final healed = <Direction>[];
  final ambiguous = <Direction>[];
  for (final impact in cascade.impacts) {
    final next = impact.healed;
    if (next != null) {
      await DirectionMutations.update(next, sub);
      healed.add(next);
    }
    // Направление может быть в обоих списках сразу: один фильтр переписан
    // литералом, второй остался конструкцией — обе половины правды нужны.
    if (impact.ambiguous) ambiguous.add(impact.direction);
  }
  return TagPrefixCascadeOutcome(healed: healed, ambiguous: ambiguous);
}

/// EN-текст уведомления (AGENTS.md L8 — UI только на английском; строки
/// проходят через каталог `getLocalText`). Пустой итог → null: call-site
/// ничего не показывает.
String? tagPrefixCascadeMessage(TagPrefixCascadeOutcome outcome) {
  if (outcome.isEmpty) return null;
  String names(List<Direction> ds) => ds.map((d) => d.displayLabel).join(', ');
  final parts = <String>[
    if (outcome.healed.isNotEmpty)
      getLocalText.s('Direction filters updated to the new prefix: %s',
          names(outcome.healed)),
    if (outcome.ambiguous.isNotEmpty)
      getLocalText.s(
          'Check the filter of: %s — the old prefix is part of a regex '
          'construct there and was left as is.',
          names(outcome.ambiguous)),
  ];
  return parts.join(' ');
}

/// Показать итог каскада транзиентным SnackBar'ом. Ничего не показывает,
/// когда каскад пуст.
void showTagPrefixCascadeSnackBar(
    BuildContext context, TagPrefixCascadeOutcome outcome) {
  final msg = tagPrefixCascadeMessage(outcome);
  if (msg == null) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
  );
}
