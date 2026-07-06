/// Результат `validateConfig(config)` — §3.5 спеки 026.
///
/// Fatal → UI отказывается запускать VPN. Warn → debug log.
enum Severity { fatal, warn }

sealed class ValidationIssue {
  const ValidationIssue();
  Severity get severity;
  String get message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ValidationIssue &&
          runtimeType == other.runtimeType &&
          message == other.message);

  @override
  int get hashCode => Object.hash(runtimeType, message);

  @override
  String toString() => '$runtimeType($message)';
}

final class DanglingOutboundRef extends ValidationIssue {
  final String rule;
  final String tag;
  const DanglingOutboundRef(this.rule, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  String get message => 'Rule "$rule" references missing outbound "$tag".';
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
  String get message =>
      'Outbound "$owner" detour references missing outbound "$tag".';
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
  String get message => '$field references missing DNS server "$tag".';
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
  String get message {
    if (culprits.isEmpty) {
      return 'Routing loop between groups: ${cycle.join(" → ")} → '
          '${cycle.first} — fix group membership to start the VPN.';
    }
    if (culprits.length == 1) {
      final c = culprits.single;
      return 'Routing loop: "${c.tag}" points back into "${c.detour}" — '
          'change or remove its detour to start the VPN.';
    }
    final tags = culprits.map((c) => '"${c.tag}"').join(', ');
    return 'Routing loop: ${culprits.length} nodes point back into their '
        'own chain — change or remove their detours to start the VPN: $tags.';
  }
}

final class EmptyUrltestGroup extends ValidationIssue {
  final String tag;
  const EmptyUrltestGroup(this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  String get message => 'URL-test group "$tag" has no outbounds.';
}

final class InvalidDefault extends ValidationIssue {
  final String group;
  final String tag;
  const InvalidDefault(this.group, this.tag);

  @override
  Severity get severity => Severity.fatal;

  @override
  String get message =>
      'Selector "$group" default "$tag" is not in the options list.';
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
/// `toString()` НЕ начинается с "Exception:" — `humanizeError` обрезает такой
/// префикс, а нам нужен полный перечень для пользователя.
class FatalValidationException implements Exception {
  final List<ValidationIssue> issues;
  const FatalValidationException(this.issues);

  @override
  String toString() {
    final n = issues.length;
    final head = n == 1
        ? 'Config invalid: '
        : 'Config invalid ($n issues): ';
    return head + issues.map((i) => i.message).join('; ');
  }
}
