/// Результат `validateConfig(config)` — §3.5 спеки 026.
///
/// Fatal → UI отказывается запускать VPN. Warn → debug log.
library;

import '../services/l10n/l10n.dart' show AppLocalizations;

enum Severity { fatal, warn }

sealed class ValidationIssue {
  const ValidationIssue();
  Severity get severity;

  /// §279 — рендер в момент показа (UI — `message(context.l)`, логи —
  /// `renderEn()` из ui_msg.dart). Теги/поля — wire-значения, не переводятся.
  String message(AppLocalizations l);

  /// Поля данных подкласса — равенство/hashCode по данным, не по строке
  /// (§279: строка locale-зависима).
  List<Object?> get props => const [];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ValidationIssue &&
          runtimeType == other.runtimeType &&
          _propsEqual(props, other.props));

  @override
  int get hashCode => Object.hashAll([runtimeType, ...props]);

  @override
  String toString() => '$runtimeType(${props.join(', ')})';
}

bool _propsEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class DanglingOutboundRef extends ValidationIssue {
  final String rule;
  final String tag;
  const DanglingOutboundRef(this.rule, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [rule, tag];

  @override
  String message(AppLocalizations l) => l.warnDanglingOutboundRef(rule, tag);
}

/// §084 H1 — outbound с `detour`, ссылающимся на несуществующий tag.
/// Возникает напр. когда override-detour хранит bare-tag, а целевой
/// outbound эмитится prefixed (§080), или при ручном редактировании JSON.
/// sing-box core реджектит такой config при старте → fatal.
final class DanglingDetourRef extends ValidationIssue {
  final String owner; // tag outbound'а с битым detour
  final String tag;   // на что ссылается (отсутствует в конфиге)
  const DanglingDetourRef(this.owner, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [owner, tag];

  @override
  String message(AppLocalizations l) => l.warnDanglingDetourRef(owner, tag);
}

/// §121 — `dns.final` или `route.default_domain_resolver` ссылается на
/// DNS-сервер, отсутствующий в `dns.servers`. Возникает напр. когда сервер
/// был выбран резольвером, а потом исчез (выключили пресет, чьи серверы это
/// были). sing-box core реджектит такой config при старте → fatal.
final class DanglingDnsServerRef extends ValidationIssue {
  final String field; // 'dns.final' | 'route.default_domain_resolver'
  final String tag;
  const DanglingDnsServerRef(this.field, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [field, tag];

  @override
  String message(AppLocalizations l) => l.warnDanglingDnsServerRef(field, tag);
}

/// §141 P1.8a / §254 — цикл в detour-графе (включая self-reference
/// `A.detour=A` и кольца через selector/urltest-группы: группа зависит от
/// ВСЕХ членов — так же считает и ядро при топосортировке старта).
/// `DanglingDetourRef` ловит ссылку на ОТСУТСТВУЮЩИЙ tag, но цикл из
/// существующих tag'ов он пропускает. Ядро отклоняет такой конфиг на старте
/// (`circular outbound dependency`). Fatal.
///
/// §254 — конфиг НЕ правится автоматически: детектор называет минимальный
/// набор нод-виновников ([culprits], алгоритм окраски в validator.dart),
/// устранение — за пользователем.
final class DetourCycle extends ValidationIssue {
  /// Репрезентативный цикл: теги в порядке обхода (последний замыкает на
  /// первый). Показывается при раскрытии в UI.
  final List<String> cycle;

  /// Минимальный набор рёбер к устранению: нода + её detour-цель. Пустой
  /// только для колец из одних групп (selector→selector, конструируемо лишь
  /// правкой JSON руками) — там устранение = состав групп, не detour.
  final List<({String tag, String detour})> culprits;

  const DetourCycle(this.cycle, {this.culprits = const []});

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [
        // Списки схлопываем в строки — _propsEqual сравнивает элементы по `==`.
        cycle.join('\u0000'),
        culprits.map((c) => '${c.tag}\u0000${c.detour}').join('\u0001'),
      ];

  @override
  String message(AppLocalizations l) {
    if (culprits.isEmpty) {
      return l.warnDetourCycleGroups('${cycle.join(" → ")} → ${cycle.first}');
    }
    if (culprits.length == 1) {
      final c = culprits.single;
      return l.warnDetourCycleSingle(c.tag, c.detour);
    }
    final tags = culprits.map((c) => '"${c.tag}"').join(', ');
    return l.warnDetourCycleMulti(culprits.length, tags);
  }
}

final class EmptyUrltestGroup extends ValidationIssue {
  final String tag;
  const EmptyUrltestGroup(this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [tag];

  @override
  String message(AppLocalizations l) => l.warnEmptyUrltestGroup(tag);
}

final class InvalidDefault extends ValidationIssue {
  final String group;
  final String tag;
  const InvalidDefault(this.group, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  List<Object?> get props => [group, tag];

  @override
  String message(AppLocalizations l) => l.warnInvalidDefault(group, tag);
}

class ValidationResult {
  final List<ValidationIssue> issues;
  const ValidationResult(this.issues);

  bool get hasFatal => issues.any((i) => i.severity == Severity.fatal);
  bool get isOk => !hasFatal;

  List<ValidationIssue> get fatal =>
      issues.where((i) => i.severity == Severity.fatal).toList();
  List<ValidationIssue> get warnings =>
      issues.where((i) => i.severity == Severity.warn).toList();

  static const ok = ValidationResult([]);
}

/// §141 P0.1 — бросается при `hasFatal`, чтобы реализовать документированный
/// контракт «Fatal → UI отказывается запускать VPN» (см. doc-комментарий
/// `Severity` выше). Раньше fatal-issues только логировались, а невалидный
/// `configJson` всё равно доезжал до ядра → зацикленный фейл-старт + битый
/// конфиг персистился как source-of-truth.
///
/// Перехватывается в `SubscriptionController.generateConfig` (try/catch →
/// `_lastError = humanizeError(e)`, возврат `null`). Все 24+ callsite уже
/// делают `if (config != null)` skip-check, так что save не происходит.
///
/// §279 — пользовательский рендер списка issues живёт в `ValidationFatalMsg`
/// (ui_msg.dart): `humanizeError` заворачивает исключение в него, показ —
/// в момент build. `toString()` — только диагностический маркер для логов.
class FatalValidationException implements Exception {
  final List<ValidationIssue> issues;
  const FatalValidationException(this.issues);

  @override
  String toString() =>
      'FatalValidationException(${issues.length}: '
      '${issues.map((i) => i.runtimeType).join(', ')})';
}
