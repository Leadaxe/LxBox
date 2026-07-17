/// Предупреждения узла — типизированные, агрегируемые, рендер по локали.
///
/// Плюсуются в `NodeSpec.warnings` (mutable list, §2.4 спеки 026) при
/// парсинге и при emit'е (fallback'ах типа XHTTP → httpupgrade). UI
/// (`subscription_detail_screen`) рендерит по severity через `message(l)`;
/// machine-поверхности (emitWarnings/AppLog) — `renderEn()` (ui_msg.dart).
library;

import '../services/l10n/l10n.dart' show AppLocalizations;

enum WarningSeverity { info, warning, error }

sealed class NodeWarning {
  const NodeWarning();

  /// §279 — рендер в момент показа; интерполяции (scheme/transport/field) —
  /// wire-идентификаторы, не переводятся.
  String message(AppLocalizations l);
  WarningSeverity get severity;

  /// Поля данных подкласса для равенства/hashCode. Dedup — по runtimeType +
  /// данным, НЕ по отрендеренной строке (§279: строка locale-зависима,
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
  String toString() => '$runtimeType(${props.join(', ')})';
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
  String message(AppLocalizations l) =>
      l.warnUnsupportedTransport(name, fallback);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

final class UnsupportedProtocolWarning extends NodeWarning {
  final String scheme;
  const UnsupportedProtocolWarning(this.scheme);

  @override
  List<Object?> get props => [scheme];

  @override
  String message(AppLocalizations l) => l.warnUnsupportedProtocol(scheme);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class MissingFieldWarning extends NodeWarning {
  final String field;
  const MissingFieldWarning(this.field);

  @override
  List<Object?> get props => [field];

  @override
  String message(AppLocalizations l) => l.warnMissingField(field);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class DeprecatedFlowWarning extends NodeWarning {
  final String flow;
  const DeprecatedFlowWarning(this.flow);

  @override
  List<Object?> get props => [flow];

  @override
  String message(AppLocalizations l) => l.warnDeprecatedFlow(flow);

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
  String message(AppLocalizations l) => l.warnVisionWithTransport(transport);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

final class InsecureTlsWarning extends NodeWarning {
  const InsecureTlsWarning();

  @override
  String message(AppLocalizations l) => l.warnInsecureTls;

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
  String message(AppLocalizations l) => l.warnNaiveBuildTag;

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
  String message(AppLocalizations l) {
    final why = switch (reason) {
      XhttpResetReason.invalidEnumValue =>
        l.warnXhttpReasonInvalidEnum(value, field),
      XhttpResetReason.invalidPlacementValue =>
        l.warnXhttpReasonInvalidValue(value),
      XhttpResetReason.placementRequiresPacketUp =>
        l.warnXhttpReasonPlacementPacketUp,
      XhttpResetReason.getRequiresPacketUp => l.warnXhttpReasonGetPacketUp,
    };
    return l.warnXhttpParamReset(field, why);
  }

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}
