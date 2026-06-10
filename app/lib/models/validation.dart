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
