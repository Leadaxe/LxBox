/// Предупреждения узла — типизированные, агрегируемые, plain-EN строки.
///
/// Плюсуются в `NodeSpec.warnings` (mutable list, §2.4 спеки 026) при
/// парсинге и при emit'е (fallback'ах типа XHTTP → httpupgrade). UI
/// (`subscription_detail_screen`) рендерит по severity.
enum WarningSeverity { info, warning, error }

sealed class NodeWarning {
  const NodeWarning();

  String message();
  WarningSeverity get severity;

  /// Поля данных подкласса для равенства/hashCode. Dedup — по runtimeType +
  /// данным, НЕ по отрендеренной строке (§279: строка станет locale-зависимой,
  /// равенство по ней ломало бы dedup при смене языка).
  List<Object?> get props => const [];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeWarning &&
          runtimeType == other.runtimeType &&
          _propsEqual(props, other.props));

  @override
  int get hashCode => Object.hashAll([runtimeType, ...props]);

  @override
  String toString() => '$runtimeType(${message()})';
}

bool _propsEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class UnsupportedTransportWarning extends NodeWarning {
  final String name;
  final String fallback;
  const UnsupportedTransportWarning(this.name, this.fallback);

  @override
  List<Object?> get props => [name, fallback];

  @override
  String message() =>
      'Transport "$name" is not supported by sing-box; using "$fallback" fallback (node may fail to connect).';

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

final class UnsupportedProtocolWarning extends NodeWarning {
  final String scheme;
  const UnsupportedProtocolWarning(this.scheme);

  @override
  List<Object?> get props => [scheme];

  @override
  String message() => 'Protocol "$scheme" is not supported.';

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class MissingFieldWarning extends NodeWarning {
  final String field;
  const MissingFieldWarning(this.field);

  @override
  List<Object?> get props => [field];

  @override
  String message() => 'Required field "$field" is missing.';

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class DeprecatedFlowWarning extends NodeWarning {
  final String flow;
  const DeprecatedFlowWarning(this.flow);

  @override
  List<Object?> get props => [flow];

  @override
  String message() => 'Flow "$flow" is deprecated.';

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// §115 — `xtls-rprx-vision` валиден только на голом TLS; с любым
/// транспортом (ws/grpc/httpupgrade/xhttp) несовместим — ядро такую
/// комбинацию не поднимет. Парсер гасит flow, warning сообщает почему.
final class VisionWithTransportWarning extends NodeWarning {
  final String transport;
  const VisionWithTransportWarning(this.transport);

  @override
  List<Object?> get props => [transport];

  @override
  String message() =>
      'Flow "xtls-rprx-vision" is incompatible with "$transport" transport — flow dropped.';

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

final class InsecureTlsWarning extends NodeWarning {
  const InsecureTlsWarning();

  @override
  String message() => 'TLS certificate verification is disabled.';

  /// Info, не warning — это часто **намеренный** выбор провайдера (REALITY,
  /// IP-литералы, self-signed). Не должен крадовать XHTTP-fallback и прочие
  /// honestly-warning'и. UI красит info серым.
  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// libbox без `with_naive_outbound` — выставляется defensively после первой
/// runtime-ошибки старта sing-box на naive-узле. Точная upstream-строка:
/// `naive outbound is not included in this build, rebuild with -tags
/// with_naive_outbound`.
final class NaiveBuildTagWarning extends NodeWarning {
  const NaiveBuildTagWarning();

  @override
  String message() =>
      'NaïveProxy is not included in this libbox build (rebuild with -tags with_naive_outbound).';

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

/// §217 — причина сброса XHTTP-параметра (§279: enum вместо free-text —
/// текст рендерится в [XhttpParamResetWarning.message], не хранится).
enum XhttpResetReason {
  /// Значение вне допустимого enum-множества ядра (placement/method).
  invalidEnumValue,

  /// `uplink_data_placement` вне множества body/auto/header/cookie.
  invalidPlacementValue,

  /// header/cookie placement валиден только в packet-up режиме.
  placementRequiresPacketUp,

  /// `uplink_http_method: GET` валиден только в packet-up режиме (meta.go:105).
  getRequiresPacketUp,
}

/// §217 — XHTTP-параметр сброшен на дефолт, потому что его значение ядро
/// приняло бы только в другом режиме (или значение вне допустимого множества).
/// Без сброса одна такая нода роняет ВЕСЬ конфиг fatal при старте
/// (transport/v2rayxhttp/meta.go normalizeMeta). Нода остаётся рабочей.
final class XhttpParamResetWarning extends NodeWarning {
  final String field;
  final XhttpResetReason reason;

  /// Отвергнутое значение — только для invalid*-вариантов, иначе ''.
  final String value;

  const XhttpParamResetWarning(this.field, this.reason, {this.value = ''});

  @override
  List<Object?> get props => [field, reason, value];

  @override
  String message() {
    final why = switch (reason) {
      XhttpResetReason.invalidEnumValue => 'value "$value" is not a valid $field',
      XhttpResetReason.invalidPlacementValue => 'value "$value" is not valid',
      XhttpResetReason.placementRequiresPacketUp =>
        'header/cookie placement requires packet-up mode',
      XhttpResetReason.getRequiresPacketUp => 'GET requires packet-up mode',
    };
    return 'XHTTP "$field" reset to default — $why (would otherwise break the whole config).';
  }

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}
