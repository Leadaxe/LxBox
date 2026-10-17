import '../../services/format_utils.dart';
import '../../services/process_name.dart';
import '../../services/traffic_profiler.dart';
import '../../vpn/cc_channel.dart';

/// §662 — тон бейджа протокола в заголовке карточки (цвет берёт виджет из
/// ColorScheme). Цвета как в ленте профайлера (§160/§177).
enum DetailBadgeTone { primary, secondary, tertiary, error, outline }

/// §662 — откуда карточка: Conns или лента профайлера (пустой заголовок).
enum DetailOrigin { connection, event }

/// §662 — общие поля карточки соединения: одна карточка для Conns
/// (`CcConnection`) и ленты профайлера (`TrafficEvent`). Модели не сливаются
/// (живое соединение / записанное событие) — адаптеры сводят их сюда, а
/// `detail_sheet.dart` рисует. Пустая строка = строка скрыта.
class ConnectionDetailData {
  const ConnectionDetailData({
    required this.title,
    required this.origin,
    this.badgeLabel = '',
    this.badgeTone = DetailBadgeTone.primary,
    this.closed = false,
    this.package = '',
    this.processPath = '',
    this.source = '',
    this.inbound = '',
    this.inboundType = '',
    this.host = '',
    this.address = '',
    this.port = '',
    this.network = '',
    this.protocol = '',
    this.kind = '',
    this.route = '',
    this.rule = '',
    this.chain = const [],
    this.detour = const [],
    this.outbound = '',
    this.outboundType = '',
    this.upBytes,
    this.downBytes,
    this.started,
    this.duration,
    this.id = '',
    this.json = const {},
  });

  /// `host:port` (host = домен, иначе адрес). Пусто → `(connection)` /
  /// `(event)` по [origin].
  final String title;
  final DetailOrigin origin;

  /// `TCP` / `UDP` / `DNS`; закрытое — с `·` и тоном outline.
  final String badgeLabel;
  final DetailBadgeTone badgeTone;

  /// Соединение закрыто: в заголовке подпись `TCP closed` рядом с бейджем
  /// `TCP·` (учит читать точку, §662); у Conns кнопка Close недоступна.
  final bool closed;

  final String package;

  /// Путь процесса, если он есть и не совпадает с [package].
  final String processPath;

  final String source;
  final String inbound;
  final String inboundType;

  final String host;

  /// Адрес назначения без порта. У Conns это хост-часть `destination` —
  /// бывает и доменом, поэтому не «IP».
  final String address;
  final String port;

  final String network;
  final String protocol;

  /// Вид события профайлера (`tcpOpen`, `dnsResolve`…). У Conns пусто.
  final String kind;

  final String route;
  final String rule;
  final List<String> chain;
  final List<String> detour;
  final String outbound;
  final String outboundType;

  /// null — байтов нет, группа Traffic скрыта.
  final int? upBytes;
  final int? downBytes;

  final DateTime? started;
  final Duration? duration;

  final String id;

  /// Что кладёт в буфер Copy JSON.
  final Map<String, Object?> json;

  static String _title(String host, String address, String port) {
    final h = host.isNotEmpty ? host : address;
    return port.isNotEmpty && h.isNotEmpty ? '$h:$port' : h;
  }

  /// [now] — для длительности живого соединения (тесты подставляют своё).
  factory ConnectionDetailData.fromConnection(
    CcConnection c, {
    required bool closed,
    DateTime? now,
  }) {
    final address = hostOf(c.destination);
    final port = portOf(c.destination);
    final (label, tone) = switch (c.network) {
      'udp' => ('UDP', DetailBadgeTone.secondary),
      'tcp' => ('TCP', DetailBadgeTone.primary),
      final n => (n.toUpperCase(), DetailBadgeTone.primary),
    };
    DateTime? started;
    Duration? duration;
    if (c.createdAt > 0) {
      started = DateTime.fromMillisecondsSinceEpoch(c.createdAt);
      final end = closed && c.closedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(c.closedAt)
          : (now ?? DateTime.now());
      final d = end.difference(started);
      if (!d.isNegative) duration = d;
    }
    return ConnectionDetailData(
      title: _title(c.domain, address, port),
      origin: DetailOrigin.connection,
      badgeLabel: label.isEmpty ? '' : (closed ? '$label·' : label),
      badgeTone: closed ? DetailBadgeTone.outline : tone,
      closed: closed,
      package: c.packageName,
      processPath: c.processPath != c.packageName ? c.processPath : '',
      source: c.source,
      inbound: c.inbound,
      inboundType: c.inboundType,
      host: c.domain,
      address: address,
      port: port,
      network: c.network,
      protocol: c.protocol,
      route: c.routingLineOf(),
      rule: c.rule,
      chain: c.chains,
      detour: c.detours,
      outbound: c.outbound,
      outboundType: c.outboundType,
      upBytes: c.uplink,
      downBytes: c.downlink,
      started: started,
      duration: duration,
      id: c.id,
      json: {
        'id': c.id,
        'network': c.network,
        'protocol': c.protocol,
        'domain': c.domain,
        'destination': c.destination,
        if (c.source.isNotEmpty) 'source': c.source,
        if (c.inbound.isNotEmpty) 'inbound': c.inbound,
        if (c.inboundType.isNotEmpty) 'inboundType': c.inboundType,
        'rule': c.rule,
        'outbound': c.outbound,
        'outboundType': c.outboundType,
        'chains': c.chains,
        'detours': c.detours,
        if (c.packageName.isNotEmpty) 'packageName': c.packageName,
        if (c.processPath.isNotEmpty) 'processPath': c.processPath,
        'uplink': c.uplink,
        'downlink': c.downlink,
        'createdAt': c.createdAt,
        'closedAt': c.closedAt,
      },
    );
  }

  factory ConnectionDetailData.fromEvent(TrafficEvent e) {
    final process = (e.process ?? '').trim();
    final package = packageNameFromProcess(process);
    final host = (e.domain ?? '').trim();
    final address = (e.ip ?? '').trim();
    final port = e.port?.toString() ?? '';
    final (label, tone) = switch (e.kind) {
      TrafficEventKind.dnsResolve => ('DNS', DetailBadgeTone.tertiary),
      TrafficEventKind.dnsFail => ('DNS', DetailBadgeTone.error),
      TrafficEventKind.tcpOpen => ('TCP', DetailBadgeTone.primary),
      TrafficEventKind.tcpClose => ('TCP·', DetailBadgeTone.outline),
      TrafficEventKind.udpOpen => ('UDP', DetailBadgeTone.secondary),
    };
    return ConnectionDetailData(
      title: _title(host, address, port),
      origin: DetailOrigin.event,
      badgeLabel: label,
      closed: e.kind == TrafficEventKind.tcpClose,
      badgeTone: tone,
      package: package,
      processPath: process != package ? process : '',
      source: e.source ?? '',
      inbound: e.inbound ?? '',
      inboundType: e.inboundType ?? '',
      host: host,
      address: address,
      port: port,
      network: e.network ?? '',
      protocol: e.protocol ?? '',
      kind: e.kind.name,
      route: e.routingLine,
      rule: e.rule ?? '',
      chain: e.outboundChain,
      detour: e.detourChain,
      outbound: e.outboundChain.isNotEmpty ? e.outboundChain.first : '',
      outboundType: e.outboundType ?? '',
      upBytes: e.upBytes,
      downBytes: e.downBytes,
      started: e.ts,
      duration: e.duration,
      id: e.connId ?? '',
      json: e.toJson(),
    );
  }
}
