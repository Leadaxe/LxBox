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

final class UnknownField extends ValidationIssue {
  final String path;
  const UnknownField(this.path);

  @override
  Severity get severity => Severity.warn;

  @override
  String get message => 'Unknown field at "$path".';
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
