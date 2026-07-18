// §279 Phase 4 / §285 — sealed-иерархия хранимых пользовательских сообщений.
//
// Хранимые ошибки/статусы (`lastError`, `SubscriptionEntry.status` и т.п.) —
// типизированные объекты, НЕ отрендеренные строки: рендер происходит в момент
// показа (`render()` в build через глобальный getLocalText) — смена локали
// мгновенно перерендеривает хранимое состояние. Машинные поверхности (Tasker,
// AppLog, Debug API, notification-labels) используют `renderEn()` — пиненный
// английский рендер (GetLocalText.en, dict=null → английский ключ).
//
// En-мосты для соседних иерархий (NodeWarning/ValidationIssue/StopReason)
// живут здесь же extension'ами (renderEn-allowlist-правило в
// tool/l10n/hardcoded_check.dart).

import 'stop_reason.dart';
import 'validation.dart';
import '../services/l10n/get_local_text.dart';
import '../services/l10n/locale_controller.dart';

/// Пользовательское сообщение с ленивым рендером. Equatable по данным
/// (runtimeType + [props]) — dedup/сравнение не зависят от локали.
sealed class UiMsg {
  const UiMsg();

  /// §285 — тело рендера подкласса. [t] — локализатор: глобальный getLocalText
  /// (активная локаль) для [render], пиненный английский [GetLocalText.en] для
  /// [renderEn]. Одно тело обслуживает обе поверхности. Публичный (а не
  /// приватный) — вложенные UiMsg/соседние иерархии композируют его напрямую,
  /// пробрасывая тот же [t] (Dart-приватность пофайловая).
  String renderWith(GetLocalText t);

  /// §285 — рендер активной локали через глобальный t.
  String render() => renderWith(getLocalText);

  /// Фиксированный английский рендер для machine-поверхностей (automation,
  /// AppLog, Debug API, notification-labels). Единственный санкционированный
  /// путь UiMsg → String вне build. [GetLocalText.en] — пиненный английский
  /// локализатор (dict=null → печатает английский ключ независимо от локали).
  String renderEn() => renderWith(GetLocalText.en);

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

// §285 — renderEn() соседних иерархий (NodeWarning/ValidationIssue/StopReason)
// теперь живёт в их собственных base-классах (message()/_message(t)/renderEn()),
// см. node_warning.dart / validation.dart / stop_reason.dart.

// ──────────────────────────────── Подклассы ───────────────────────────────────

/// Passthrough OS/kernel/library-английского (диагностический payload не
/// переводится — spec §8).
final class RawMsg extends UiMsg {
  final String detail;
  const RawMsg(this.detail);

  @override
  List<Object?> get props => [detail];

  @override
  String renderWith(GetLocalText t) => detail;
}

/// `formatUserError(TimeoutException)` — "timeout 10s" / "timeout 5.8s".
final class TimeoutError extends UiMsg {
  final int ms;
  const TimeoutError(this.ms);

  @override
  List<Object?> get props => [ms];

  @override
  String renderWith(GetLocalText t) {
    final s = (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);
    return t.s("timeout %ss", s);
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
  String renderWith(GetLocalText t) {
    final d = detail.renderWith(t);
    return switch (prefix) {
      ErrPrefix.platformError => t.s("platform error: %s", d),
      ErrPrefix.reloadFailed => t.s("Reload failed: %s", d),
      ErrPrefix.switchFailed => t.s("Switch failed: %s", d),
      ErrPrefix.parseConfigFailed => t.s("Failed to parse config: %s", d),
      ErrPrefix.readFileFailed => t.s("Failed to read file: %s", d),
      ErrPrefix.fileError => t.s("File error: %s", d),
      ErrPrefix.error => t.s("Error: %s", d),
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
  String renderWith(GetLocalText t) => switch (key) {
        ErrKey.failedToStartVpn => t.s("Failed to start VPN"),
        ErrKey.stopTimedOut => t.s("Stop timed out"),
        ErrKey.stopTimedOutReconnectAborted => t.s("Stop timed out — reconnect aborted"),
        ErrKey.connectionTimedOut => t.s("Connection timed out"),
        ErrKey.tunnelNotResponding => t.s("Connection lost — VPN tunnel is not responding"),
        ErrKey.failedToSaveConfig => t.s("Failed to save config"),
        ErrKey.configIsEmpty => t.s("Config is empty"),
        ErrKey.clipboardIsEmpty => t.s("Clipboard is empty"),
        ErrKey.failedToParseConfig => t.s("Failed to parse config"),
        ErrKey.failedToReadFile => t.s("Failed to read file"),
        ErrKey.fileIsEmpty => t.s("File is empty"),
        ErrKey.invalidMasqueConfig => t.s("Invalid MASQUE config"),
        ErrKey.invalidWarpConfigObfuscated => t.s("Invalid WARP config (obfuscated)"),
        ErrKey.invalidWarpConfig => t.s("Invalid WARP config"),
        ErrKey.invalidWireguardConfig => t.s("Invalid WireGuard config"),
        ErrKey.noWgInVpnLink => t.s("No WireGuard/AmneziaWG config in vpn:// link"),
        ErrKey.couldNotParseDirectLink => t.s("Could not parse direct link"),
        ErrKey.inputNotRecognized => t.s("Input is not a subscription URL, proxy link, or outbound JSON"),
        ErrKey.noValidOutboundsInJson => t.s("No valid outbounds in JSON"),
        ErrKey.noConnection => t.s("No connection — check network or URL"),
        ErrKey.requestTimedOut => t.s("Request timed out — server slow or unreachable"),
        ErrKey.cantParseResponse => t.s("Can't parse response (invalid format)"),
        ErrKey.folderNotFound => t.s("Folder not found"),
        ErrKey.notAFolder => t.s("Not a folder"),
        ErrKey.serverNotFound => t.s("Server not found"),
        ErrKey.invalidSubscription => t.s("Invalid subscription"),
        ErrKey.notASubscription => t.s("Not a subscription"),
        ErrKey.noSourceProvided => t.s("No source provided"),
        ErrKey.couldNotLoadNewSource => t.s("Couldn't load new source — keeping current subscription"),
        ErrKey.noServersFoundInInput => t.s("No servers found in input"),
        ErrKey.noServersFoundAtUrl => t.s("No servers found at this URL"),
        ErrKey.memberParseKeepCurrent => t.s("Could not parse server config — keeping current"),
        ErrKey.detourSelf => t.s("A server cannot detour through itself"),
        ErrKey.detourLoopInFolder => t.s("This would create a detour loop inside the folder"),
        ErrKey.onlySingleServersCanBeMoved => t.s("Only single servers can be moved"),
      };
}

/// `humanizeError(SocketException)` с извлечённым хостом.
final class NoConnectionToHost extends UiMsg {
  final String host;
  const NoConnectionToHost(this.host);

  @override
  List<Object?> get props => [host];

  @override
  String renderWith(GetLocalText t) => t.s("No connection to %s — check network or URL", host);
}

/// `humanizeError(TimeoutException)` с известной длительностью.
final class TimedOutAfter extends UiMsg {
  final int seconds;
  const TimedOutAfter(this.seconds);

  @override
  List<Object?> get props => [seconds];

  @override
  String renderWith(GetLocalText t) => t.s("Timed out after %ds — server slow or unreachable", seconds);
}

/// `humanizeError(HttpException)` — короткое описание по HTTP-коду.
final class HttpStatusMsg extends UiMsg {
  final int code;
  const HttpStatusMsg(this.code);

  @override
  List<Object?> get props => [code];

  @override
  String renderWith(GetLocalText t) {
    if (code == 401 || code == 403) return t.s("Access denied (%d) — check subscription token", code);
    if (code == 404) return t.s("Not found (404) — subscription URL may be removed");
    if (code == 410) return t.s("Gone (410) — subscription deleted by provider");
    if (code == 429) return t.s("Rate limited (429) — try again later");
    if (code >= 500 && code < 600) return t.s("Server error (%d) — provider is down, try later", code);
    if (code >= 400 && code < 500) return t.s("Request rejected (%d)", code);
    return t.s("HTTP %d", code);
  }
}

/// §141 P0.1 — рендер [FatalValidationException] (список fatal-issues).
final class ValidationFatalMsg extends UiMsg {
  final List<ValidationIssue> issues;
  const ValidationFatalMsg(this.issues);

  @override
  List<Object?> get props => [issues.length, ...issues];

  @override
  String renderWith(GetLocalText t) {
    final joined = issues.map((i) => i.messageWith(t)).join('; ');
    return issues.length == 1
        ? t.s("Config invalid: %s", joined)
        : t.plural("Config invalid (%1\$d issues): %2\$s", issues.length, joined);
  }
}

/// §279 — обёртка [StopReason] для хранения в `HomeState.lastError`.
final class StopReasonMsg extends UiMsg {
  final StopReason reason;
  const StopReasonMsg(this.reason);

  @override
  List<Object?> get props => [reason];

  @override
  String renderWith(GetLocalText t) => reason.messageWith(t);
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
  String renderWith(GetLocalText t) {
    final label = host.isEmpty ? target : '$target → $host';
    return '$label — ${reason.renderWith(t)}';
  }
}

// ─────────────────────── Статусы подписки (SubscriptionEntry) ─────────────────

/// Прогресс-баннер генерации конфига ("Building config...").
final class SubStatusBuildingConfig extends UiMsg {
  const SubStatusBuildingConfig();

  @override
  String renderWith(GetLocalText t) => t.s("Building config...");
}

final class SubStatusFetching extends UiMsg {
  const SubStatusFetching();

  @override
  String renderWith(GetLocalText t) => t.s("Fetching...");
}

final class SubStatusJsonOutbound extends UiMsg {
  const SubStatusJsonOutbound();

  @override
  String renderWith(GetLocalText t) => t.s("JSON outbound");
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
  String renderWith(GetLocalText t) {
    final base = detours > 0
        ? t.plural("%1\$d +%2\$d⚙ nodes", nodes, detours)
        : t.plural("%d nodes", nodes);
    return cached ? t.s("%s (cached)", base) : base;
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
  String renderWith(GetLocalText t) => zeroParsed
      ? t.plural("%d nodes (update failed: 0 parsed)", nodes)
      : t.plural("%d nodes (update failed)", nodes);
}

/// `0 nodes` / `0 nodes — {hint}`; hint — английская диагностика парсера
/// (machine-строка, passthrough).
final class SubStatusZeroNodes extends UiMsg {
  final String? hint;
  const SubStatusZeroNodes([this.hint]);

  @override
  List<Object?> get props => [hint];

  @override
  String renderWith(GetLocalText t) {
    final h = hint;
    return (h == null || h.isEmpty)
        ? t.s("0 nodes")
        : t.s("0 nodes — %s", h);
  }
}
