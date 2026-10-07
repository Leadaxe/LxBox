import '../models/config_node.dart';
import '../vpn/cc_channel.dart' show CcTailscaleStatus;
import 'contract/body_sanitizer.dart' show exitCapableByRegistry;
import 'tailscale_network.dart' show tailscalePathLabel;

/// Задача 579 — псевдо-направление NETWORKS главного экрана.
///
/// Показывает узлы, которые не попали ни в один список выбора: запись в
/// `endpoints[]` собранного конфига, тип `tailscale`, реестр не считает узел
/// выходом (`exit_capable_when` ложно — в теле нет `exit_node`). В конфиг и
/// хранилище не пишется; группы с таким тегом у ядра нет.

/// Название в перечне направлений. Не переводится.
const String kNetworksLabel = 'NETWORKS'; // l10n-exempt: fixed name

/// Значение пункта NETWORKS в перечне направлений. Не тег: символ U+0001 в
/// теге группы пользователь не задаст, поэтому настоящее направление с тегом
/// `NETWORKS` с псевдо-направлением не совпадёт.
const String kNetworksDirectionValue = '\u0001networks';

final Expando<List<String>> _cache = Expando<List<String>>('networks579');
final Expando<List<String>> _allCache = Expando<List<String>>('tailscale608');

/// Теги узлов NETWORKS в порядке конфига. Пусто — псевдо-направления нет.
/// Результат кешируется на экземпляр [model] (он неизменяем, §091).
List<String> networksNodeTags(ParsedConfig model) =>
    _cache[model] ??= List.unmodifiable([
      for (final n in model.nodes)
        if (n.kind == 'endpoint' &&
            n.type == 'tailscale' &&
            !exitCapableByRegistry(n.raw))
          n.tag,
    ]);

/// §608 — все Tailscale-endpoint'ы конфига: узлы NETWORKS и узлы с exit
/// node. По ним держится подписка на поток статуса главного экрана.
List<String> tailscaleNodeTags(ParsedConfig model) =>
    _allCache[model] ??= List.unmodifiable([
      for (final n in model.nodes)
        if (n.kind == 'endpoint' && n.type == 'tailscale') n.tag,
    ]);

/// Что показать в строке узла NETWORKS на месте задержки.
enum TailnetStateKind {
  /// VPN выключен: состояния нет.
  none,

  /// VPN включён, записи об узле от ядра ещё нет.
  starting,

  /// `BackendState` = `Running`.
  running,

  /// `BackendState` = `NeedsLogin`.
  signInNeeded,

  /// `BackendState` = `Stopped`.
  stopped,

  /// Прочее значение: показывается `StateText` ядра как есть.
  other,
}

class TailnetRowState {
  const TailnetRowState(this.kind, [this.text = '']);

  final TailnetStateKind kind;

  /// Текст ядра для [TailnetStateKind.other] (`StateText`, пустой —
  /// `BackendState`).
  final String text;

  /// Цвет предупреждения: вход не выполнен или узел остановлен.
  bool get isWarning =>
      kind == TailnetStateKind.signInNeeded || kind == TailnetStateKind.stopped;

  @override
  bool operator ==(Object other) =>
      other is TailnetRowState && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'TailnetRowState($kind, $text)';
}

/// Состояние строки узла [tag] по записям потока ядра [byTag].
TailnetRowState tailnetRowState({
  required bool tunnelUp,
  required String tag,
  required Map<String, CcTailscaleStatus> byTag,
}) {
  if (!tunnelUp) return const TailnetRowState(TailnetStateKind.none);
  final s = byTag[tag];
  if (s == null) return const TailnetRowState(TailnetStateKind.starting);
  switch (s.backendState) {
    case 'Running':
      return const TailnetRowState(TailnetStateKind.running);
    case 'NeedsLogin':
      return const TailnetRowState(TailnetStateKind.signInNeeded);
    case 'Stopped':
      return const TailnetRowState(TailnetStateKind.stopped);
  }
  return TailnetRowState(
    TailnetStateKind.other,
    s.stateText.isNotEmpty ? s.stateText : s.backendState,
  );
}

/// §608 — имя действующего exit node для метки `via` в строке узла: первое
/// непустое из `hostName`, первой метки MagicDNS-имени, первого адреса.
/// `null` — записи ядра нет или exit node не выбран.
String? tailnetExitName(CcTailscaleStatus? s) {
  final e = s?.exitNode;
  if (e == null) return null;
  if (e.hostName.isNotEmpty) return e.hostName;
  final dns = e.dnsNameClean;
  if (dns.isNotEmpty) return dns.split('.').first;
  return e.firstIp.isEmpty ? null : e.firstIp;
}

/// §613 — путь до действующего exit node для строки узла (`direct
/// 1.2.3.4:41641`, `peer relay`, `relay fra`). `null` — выхода нет или путь
/// `NONE` / ядро старше lx.12: строка как в §608.
String? tailnetExitPath(CcTailscaleStatus? s) {
  final e = s?.exitNode;
  if (e == null) return null;
  final label = tailscalePathLabel(e);
  return label.isEmpty ? null : label;
}

/// §608 — предупреждение в строке Tailscale-узла.
enum TailnetNoteKind {
  /// Действующий exit node офлайн.
  exitOffline,

  /// Ключ устройства истекает меньше чем через [kTailnetKeyWarnDays] суток.
  keyExpires,

  /// Срок ключа прошёл.
  keyExpired,
}

/// §608 — за сколько суток до истечения ключа строка начинает предупреждать.
const int kTailnetKeyWarnDays = 7;

class TailnetNote {
  const TailnetNote(this.kind, [this.days = 0]);

  final TailnetNoteKind kind;

  /// Для [TailnetNoteKind.keyExpires]: целые сутки до истечения (вниз);
  /// `0` — меньше суток.
  final int days;

  @override
  bool operator ==(Object other) =>
      other is TailnetNote && other.kind == kind && other.days == days;

  @override
  int get hashCode => Object.hash(kind, days);

  @override
  String toString() => 'TailnetNote($kind, $days)';
}

/// §608 — предупреждение строки узла по записи ядра [s]. `null` — VPN
/// выключен, записи нет или предупреждать не о чем. [withExit] — строка
/// узла с exit node: офлайн-выход важнее срока ключа. `keyExpiry == 0` —
/// истечение ключа отключено, метки нет.
TailnetNote? tailnetRowNote({
  required bool tunnelUp,
  required CcTailscaleStatus? s,
  required DateTime now,
  required bool withExit,
}) {
  if (!tunnelUp || s == null) return null;
  if (withExit && s.exitNode != null && !s.exitNode!.online) {
    return const TailnetNote(TailnetNoteKind.exitOffline);
  }
  final expiry = s.self?.keyExpiry ?? 0;
  if (expiry <= 0) return null;
  final left = DateTime.fromMillisecondsSinceEpoch(expiry * 1000).difference(now);
  if (left <= Duration.zero) return const TailnetNote(TailnetNoteKind.keyExpired);
  if (left >= const Duration(days: kTailnetKeyWarnDays)) return null;
  return TailnetNote(TailnetNoteKind.keyExpires, left.inDays);
}
