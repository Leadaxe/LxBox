// §279 Phase 4 — sealed-иерархия хранимых пользовательских сообщений.
//
// Хранимые ошибки/статусы (`lastError`, `SubscriptionEntry.status` и т.п.) —
// типизированные объекты, НЕ отрендеренные строки: рендер происходит в момент
// показа (`render(l)` в build) — смена локали мгновенно перерендеривает
// хранимое состояние. Машинные поверхности (Tasker, AppLog, Debug API,
// notification-labels) используют `renderEn()` — пиненный английский рендер.
//
// Это ЕДИНСТВЕННЫЙ файл, где разрешён прямой доступ к `L10n.en`
// (rendering-locality-правило в tool/l10n/hardcoded_check.dart). En-мосты
// для соседних иерархий (NodeWarning/ValidationIssue/StopReason) живут здесь
// же extension'ами по той же причине.

import 'node_warning.dart';
import 'stop_reason.dart';
import 'validation.dart';
import '../services/l10n/l10n.dart';

/// Пользовательское сообщение с ленивым рендером. Equatable по данным
/// (runtimeType + [props]) — dedup/сравнение не зависят от локали.
sealed class UiMsg {
  const UiMsg();

  String render(AppLocalizations l);

  /// Фиксированный английский рендер для machine-поверхностей (automation,
  /// AppLog, Debug API, notification-labels). Единственный санкционированный
  /// путь UiMsg → String вне build.
  String renderEn() => render(L10n.en);

  List<Object?> get props => const [];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UiMsg &&
          runtimeType == other.runtimeType &&
          propsEquals(props, other.props));

  @override
  int get hashCode => Object.hashAll([runtimeType, ...props]);

  @override
  String toString() => '$runtimeType(${props.join(', ')})';
}

/// Deep-равенство списков props (публичный — переиспользуется соседними
/// иерархиями с data-равенством).
bool propsEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ─────────────────────────── En-мосты соседних иерархий ───────────────────────

/// Machine-рендер NodeWarning (emitWarnings/AppLog — spec §4.4).
extension NodeWarningRenderEn on NodeWarning {
  String renderEn() => message(L10n.en);
}

/// Machine-рендер ValidationIssue (AppLog).
extension ValidationIssueRenderEn on ValidationIssue {
  String renderEn() => message(L10n.en);
}

/// Machine-рендер StopReason (Debug API `lastStartError`, AppLog).
extension StopReasonRenderEn on StopReason {
  String renderEn() => message(L10n.en);
}

// ──────────────────────────────── Подклассы ───────────────────────────────────

/// Passthrough OS/kernel/library-английского (диагностический payload не
/// переводится — spec §8).
final class RawMsg extends UiMsg {
  final String detail;
  const RawMsg(this.detail);

  @override
  List<Object?> get props => [detail];

  @override
  String render(AppLocalizations l) => detail;
}

/// `formatUserError(TimeoutException)` — "timeout 10s" / "timeout 5.8s".
final class TimeoutError extends UiMsg {
  final int ms;
  const TimeoutError(this.ms);

  @override
  List<Object?> get props => [ms];

  @override
  String render(AppLocalizations l) {
    final s = (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);
    return l.errTimeoutShort(s);
  }
}

/// Фреймы вида `<префикс>: <detail>`, где detail — вложенный [UiMsg]
/// (обычно [RawMsg]-payload или результат formatUserError).
enum ErrPrefix {
  /// "platform error: {detail}"
  platformError,

  /// "Reload failed: {detail}"
  reloadFailed,

  /// "Switch failed: {detail}"
  switchFailed,

  /// "Failed to parse config: {detail}"
  parseConfigFailed,

  /// "Failed to read file: {detail}"
  readFileFailed,

  /// "File error: {detail}"
  fileError,

  /// "Error: {detail}"
  error,
}

final class PrefixedMsg extends UiMsg {
  final ErrPrefix prefix;
  final UiMsg detail;
  const PrefixedMsg(this.prefix, this.detail);

  @override
  List<Object?> get props => [prefix, detail];

  @override
  String render(AppLocalizations l) {
    final d = detail.render(l);
    return switch (prefix) {
      ErrPrefix.platformError => l.errPlatformError(d),
      ErrPrefix.reloadFailed => l.errReloadFailed(d),
      ErrPrefix.switchFailed => l.errSwitchFailed(d),
      ErrPrefix.parseConfigFailed => l.errParseConfigFailed(d),
      ErrPrefix.readFileFailed => l.errReadFileFailed(d),
      ErrPrefix.fileError => l.errFileError(d),
      ErrPrefix.error => l.subErrorSnack(d),
    };
  }
}

/// Фиксированные фразы без параметров (ключ → ARB-строка).
enum ErrKey {
  // ── home_controller / config_io ──
  failedToStartVpn,
  stopTimedOut,
  stopTimedOutReconnectAborted,
  connectionTimedOut,
  tunnelNotResponding,
  failedToSaveConfig,
  configIsEmpty,
  clipboardIsEmpty,
  failedToParseConfig,
  failedToReadFile,
  fileIsEmpty,
  // ── subscription_controller add-пути ──
  invalidMasqueConfig,
  invalidWarpConfigObfuscated,
  invalidWarpConfig,
  invalidWireguardConfig,
  noWgInVpnLink,
  couldNotParseDirectLink,
  inputNotRecognized,
  noValidOutboundsInJson,
  // ── humanizeError generic ──
  noConnection,
  requestTimedOut,
  cantParseResponse,
  // ── папки / источники ──
  folderNotFound,
  notAFolder,
  serverNotFound,
  invalidSubscription,
  notASubscription,
  noSourceProvided,
  couldNotLoadNewSource,
  noServersFoundInInput,
  noServersFoundAtUrl,
  memberParseKeepCurrent,
  detourSelf,
  detourLoopInFolder,
  onlySingleServersCanBeMoved,
}

final class ErrMsg extends UiMsg {
  final ErrKey key;
  const ErrMsg(this.key);

  @override
  List<Object?> get props => [key];

  @override
  String render(AppLocalizations l) => switch (key) {
        ErrKey.failedToStartVpn => l.errFailedToStartVpn,
        ErrKey.stopTimedOut => l.errStopTimedOut,
        ErrKey.stopTimedOutReconnectAborted => l.errStopTimedOutReconnect,
        ErrKey.connectionTimedOut => l.errConnectionTimedOut,
        ErrKey.tunnelNotResponding => l.errTunnelNotResponding,
        ErrKey.failedToSaveConfig => l.errFailedToSaveConfig,
        ErrKey.configIsEmpty => l.errConfigIsEmpty,
        ErrKey.clipboardIsEmpty => l.errClipboardIsEmpty,
        ErrKey.failedToParseConfig => l.errFailedToParseConfig,
        ErrKey.failedToReadFile => l.errFailedToReadFile,
        ErrKey.fileIsEmpty => l.errFileIsEmpty,
        ErrKey.invalidMasqueConfig => l.errInvalidMasqueConfig,
        ErrKey.invalidWarpConfigObfuscated => l.errInvalidWarpConfigObfuscated,
        ErrKey.invalidWarpConfig => l.errInvalidWarpConfig,
        ErrKey.invalidWireguardConfig => l.errInvalidWireguardConfig,
        ErrKey.noWgInVpnLink => l.errNoWgInVpnLink,
        ErrKey.couldNotParseDirectLink => l.errCouldNotParseDirectLink,
        ErrKey.inputNotRecognized => l.errInputNotRecognized,
        ErrKey.noValidOutboundsInJson => l.errNoValidOutboundsInJson,
        ErrKey.noConnection => l.errNoConnection,
        ErrKey.requestTimedOut => l.errRequestTimedOut,
        ErrKey.cantParseResponse => l.errCantParseResponse,
        ErrKey.folderNotFound => l.errFolderNotFound,
        ErrKey.notAFolder => l.errNotAFolder,
        ErrKey.serverNotFound => l.errServerNotFound,
        ErrKey.invalidSubscription => l.errInvalidSubscription,
        ErrKey.notASubscription => l.errNotASubscription,
        ErrKey.noSourceProvided => l.errNoSourceProvided,
        ErrKey.couldNotLoadNewSource => l.errCouldNotLoadNewSource,
        ErrKey.noServersFoundInInput => l.errNoServersFoundInInput,
        ErrKey.noServersFoundAtUrl => l.errNoServersFoundAtUrl,
        ErrKey.memberParseKeepCurrent => l.errMemberParseKeepCurrent,
        ErrKey.detourSelf => l.errDetourSelf,
        ErrKey.detourLoopInFolder => l.errDetourLoopInFolder,
        ErrKey.onlySingleServersCanBeMoved => l.errOnlySingleServersMove,
      };
}

/// `humanizeError(SocketException)` с извлечённым хостом.
final class NoConnectionToHost extends UiMsg {
  final String host;
  const NoConnectionToHost(this.host);

  @override
  List<Object?> get props => [host];

  @override
  String render(AppLocalizations l) => l.errNoConnectionToHost(host);
}

/// `humanizeError(TimeoutException)` с известной длительностью.
final class TimedOutAfter extends UiMsg {
  final int seconds;
  const TimedOutAfter(this.seconds);

  @override
  List<Object?> get props => [seconds];

  @override
  String render(AppLocalizations l) => l.errTimedOutAfter(seconds);
}

/// `humanizeError(HttpException)` — короткое описание по HTTP-коду.
final class HttpStatusMsg extends UiMsg {
  final int code;
  const HttpStatusMsg(this.code);

  @override
  List<Object?> get props => [code];

  @override
  String render(AppLocalizations l) {
    if (code == 401 || code == 403) return l.errHttpAccessDenied(code);
    if (code == 404) return l.errHttpNotFound;
    if (code == 410) return l.errHttpGone;
    if (code == 429) return l.errHttpRateLimited;
    if (code >= 500 && code < 600) return l.errHttpServerError(code);
    if (code >= 400 && code < 500) return l.errHttpRejected(code);
    return l.errHttpPlain(code);
  }
}

/// §141 P0.1 — рендер [FatalValidationException] (список fatal-issues).
final class ValidationFatalMsg extends UiMsg {
  final List<ValidationIssue> issues;
  const ValidationFatalMsg(this.issues);

  @override
  List<Object?> get props => [issues.length, ...issues];

  @override
  String render(AppLocalizations l) {
    final joined = issues.map((i) => i.message(l)).join('; ');
    return issues.length == 1
        ? l.errConfigInvalidOne(joined)
        : l.errConfigInvalidMany(issues.length, joined);
  }
}

/// §279 — обёртка [StopReason] для хранения в `HomeState.lastError`.
final class StopReasonMsg extends UiMsg {
  final StopReason reason;
  const StopReasonMsg(this.reason);

  @override
  List<Object?> get props => [reason];

  @override
  String render(AppLocalizations l) => reason.message(l);
}

/// Ошибка ping/URLTest: `<target> → <host> — <reason>` (или без host).
/// target/host — wire-значения (тег ноды, хост URL), не переводятся;
/// джойнеры — пунктуация (spec §4.6).
final class ProbeErrorMsg extends UiMsg {
  final String target;
  final String host; // '' → без части "→ host"
  final UiMsg reason;
  const ProbeErrorMsg(this.target, this.host, this.reason);

  @override
  List<Object?> get props => [target, host, reason];

  @override
  String render(AppLocalizations l) {
    final label = host.isEmpty ? target : '$target → $host';
    return '$label — ${reason.render(l)}';
  }
}

// ─────────────────────── Статусы подписки (SubscriptionEntry) ─────────────────

/// Прогресс-баннер генерации конфига ("Building config...").
final class SubStatusBuildingConfig extends UiMsg {
  const SubStatusBuildingConfig();

  @override
  String render(AppLocalizations l) => l.subProgressBuildingConfig;
}

final class SubStatusFetching extends UiMsg {
  const SubStatusFetching();

  @override
  String render(AppLocalizations l) => l.subStatusFetching;
}

final class SubStatusJsonOutbound extends UiMsg {
  const SubStatusJsonOutbound();

  @override
  String render(AppLocalizations l) => l.subStatusJsonOutbound;
}

/// `{n} nodes` / `{n} +{d}⚙ nodes`, опционально с суффиксом `(cached)`.
final class SubStatusNodes extends UiMsg {
  final int nodes;
  final int detours;
  final bool cached;
  const SubStatusNodes(this.nodes, {this.detours = 0, this.cached = false});

  @override
  List<Object?> get props => [nodes, detours, cached];

  @override
  String render(AppLocalizations l) {
    final base = detours > 0
        ? l.subNodesCountWithDetour(nodes, detours)
        : l.subEntryNodesCount(nodes);
    return cached ? l.subStatusCached(base) : base;
  }
}

/// `{n} nodes (update failed)` / `{n} nodes (update failed: 0 parsed)`.
final class SubStatusUpdateFailed extends UiMsg {
  final int nodes;
  final bool zeroParsed;
  const SubStatusUpdateFailed(this.nodes, {this.zeroParsed = false});

  @override
  List<Object?> get props => [nodes, zeroParsed];

  @override
  String render(AppLocalizations l) => zeroParsed
      ? l.subStatusUpdateFailedZero(nodes)
      : l.subStatusUpdateFailed(nodes);
}

/// `0 nodes` / `0 nodes — {hint}`; hint — английская диагностика парсера
/// (machine-строка, passthrough).
final class SubStatusZeroNodes extends UiMsg {
  final String? hint;
  const SubStatusZeroNodes([this.hint]);

  @override
  List<Object?> get props => [hint];

  @override
  String render(AppLocalizations l) {
    final h = hint;
    return (h == null || h.isEmpty)
        ? l.subStatusZeroNodes
        : l.subStatusZeroNodesHint(h);
  }
}
