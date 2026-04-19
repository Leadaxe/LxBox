/// Предупреждения узла — типизированные, агрегируемые, plain-EN строки.
///
/// Плюсуются в `NodeSpec.warnings` (mutable list, §2.4 спеки 026) при
/// парсинге и при emit'е (fallback'ах типа XHTTP → httpupgrade). UI
/// (`subscription_detail_screen`) рендерит по severity.
enum WarningSeverity { info, warning, error }

sealed class NodeWarning {
  const NodeWarning();

  String get message;
  WarningSeverity get severity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeWarning &&
          runtimeType == other.runtimeType &&
          message == other.message);

  @override
  int get hashCode => Object.hash(runtimeType, message);

  @override
  String toString() => '$runtimeType($message)';
}

final class UnsupportedTransportWarning extends NodeWarning {
  final String name;
  final String fallback;
  const UnsupportedTransportWarning(this.name, this.fallback);

  @override
  String get message =>
      'Transport "$name" is not supported by sing-box; using "$fallback" fallback (node may fail to connect).';

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

final class UnsupportedProtocolWarning extends NodeWarning {
  final String scheme;
  const UnsupportedProtocolWarning(this.scheme);

  @override
  String get message => 'Protocol "$scheme" is not supported.';

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class MissingFieldWarning extends NodeWarning {
  final String field;
  const MissingFieldWarning(this.field);

  @override
  String get message => 'Required field "$field" is missing.';

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class DeprecatedFlowWarning extends NodeWarning {
  final String flow;
  const DeprecatedFlowWarning(this.flow);

  @override
  String get message => 'Flow "$flow" is deprecated.';

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

final class InsecureTlsWarning extends NodeWarning {
  const InsecureTlsWarning();

  @override
  String get message => 'TLS certificate verification is disabled.';

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}
