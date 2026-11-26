part of '../cc_channel.dart';

/// §579/§581 — запись `TailscaleEndpointStatus` ядра: тег endpoint'а,
/// `BackendState` (`Running`, `NeedsLogin`, `Stopped`, …), `StateText` и
/// (§581) полное состояние для вкладки Network.
///
/// Имена устройств, адреса, имя сети и ссылка входа — данные пользователя: в
/// журнал, дамп поддержки и Debug API не попадают (§581 раздел 9).
class CcTailscaleStatus {
  const CcTailscaleStatus({
    required this.tag,
    required this.backendState,
    required this.stateText,
    this.authUrl = '',
    this.networkName = '',
    this.magicDnsSuffix = '',
    this.keyAuth = false,
    this.self,
    this.exitNode,
    this.userGroups = const [],
    this.health = const [],
    this.canShareFiles = true,
    this.unreadFileCount = 0,
  });

  final String tag;
  final String backendState;
  final String stateText;
  final String authUrl;
  final String networkName;
  final String magicDnsSuffix;
  final bool keyAuth;

  /// Свой узел.
  final CcTailscalePeer? self;

  /// Действующий exit node; `null` — выхода нет.
  final CcTailscalePeer? exitNode;

  /// Устройства сети по владельцам (свой узел сюда не входит).
  final List<CcTailscaleUserGroup> userGroups;

  /// §613 (ядро SPEC 115) — предупреждения бэкенда (нет DERP, exit node
  /// офлайн и т.п.), текст ядра; пусто — предупреждать не о чем.
  final List<String> health;

  /// §707 — у узла есть право Taildrop (file sharing включён в админке
  /// tailnet). Нет поля в записи — считается, что есть.
  final bool canShareFiles;

  /// §707 — принятые, но не просмотренные файлы.
  final int unreadFileCount;

  /// Все устройства сети без своего узла.
  List<CcTailscalePeer> get peers => [
        for (final g in userGroups) ...g.peers,
      ];

  factory CcTailscaleStatus.fromMap(Map<String, dynamic> m) {
    final self = m['self'];
    final exit = m['exit_node'];
    return CcTailscaleStatus(
      tag: '${m['tag'] ?? ''}',
      backendState: '${m['backend_state'] ?? ''}',
      stateText: '${m['state_text'] ?? ''}',
      authUrl: '${m['auth_url'] ?? ''}',
      networkName: '${m['network_name'] ?? ''}',
      magicDnsSuffix: '${m['magic_dns_suffix'] ?? ''}',
      keyAuth: m['key_auth'] == true,
      self: self is Map ? CcTailscalePeer.fromMap(CcChannel._asMap(self)) : null,
      exitNode:
          exit is Map ? CcTailscalePeer.fromMap(CcChannel._asMap(exit)) : null,
      userGroups: [
        for (final g in CcChannel._asList(m['user_groups']))
          if (g is Map) CcTailscaleUserGroup.fromMap(CcChannel._asMap(g)),
      ],
      health: [
        for (final h in CcChannel._asList(m['health']))
          if (h != null && '$h'.isNotEmpty) '$h',
      ],
      canShareFiles: m['can_share_files'] != false,
      unreadFileCount: CcTailscalePeer._int(m['unread_file_count']),
    );
  }

  /// Сообщение канала — список map'ов; всё прочее и записи без тега
  /// отбрасываются.
  static List<CcTailscaleStatus> listFrom(Object? e) => [
        for (final m in CcChannel._asList(e))
          if (m is Map)
            CcTailscaleStatus.fromMap(CcChannel._asMap(m)),
      ].where((s) => s.tag.isNotEmpty).toList();
}

/// §645 — ответ [CcChannel.getTailscaleStatus]: запись endpoint'а; без неё —
/// пропуск тика ([skip]) или метод не поддержан ([notSupported]).
class CcTailscaleStatusPoll {
  const CcTailscaleStatusPoll({this.status, this.unsupported = false});

  final CcTailscaleStatus? status;

  /// Ядро или native без `GetTailscaleStatus`: опрашивать дальше незачем.
  final bool unsupported;

  static const skip = CcTailscaleStatusPoll();
  static const notSupported = CcTailscaleStatusPoll(unsupported: true);
}

/// §581 — устройство сети Tailscale (`TailscalePeer` ядра). Времена —
/// Unix-секунды ядра, 0 — значения нет.
class CcTailscalePeer {
  const CcTailscalePeer({
    this.stableId = '',
    this.hostName = '',
    this.dnsName = '',
    this.os = '',
    this.online = false,
    this.exitNode = false,
    this.exitNodeOption = false,
    this.shareeNode = false,
    this.expired = false,
    this.keyExpiry = 0,
    this.lastSeen = 0,
    this.ips = const [],
    this.path = '',
    this.endpoint = '',
    this.peerRelay = '',
    this.derpRegionCode = '',
    this.lastHandshake = 0,
    this.canReceiveFiles = false,
  });

  final String stableId;
  final String hostName;
  final String dnsName;
  final String os;
  final bool online;

  /// Устройство — действующий exit node этого узла.
  final bool exitNode;

  /// Устройство предлагает себя как exit node.
  final bool exitNodeOption;
  final bool shareeNode;
  final bool expired;
  final int keyExpiry;
  final int lastSeen;
  final List<String> ips;

  /// §613 (ядро SPEC 115) — путь до устройства: [CcTailscalePath]; пусто —
  /// ядро старше lx.12.
  final String path;

  /// Адрес `ip:port` прямого пути.
  final String endpoint;

  /// Устройство-ретранслятор пути `PEER_RELAY`.
  final String peerRelay;

  /// Регион DERP (`fra`): путь `DERP` или домашний регион.
  final String derpRegionCode;

  /// Unix-секунды последнего хендшейка, 0 — не было.
  final int lastHandshake;

  /// §707 — устройство принимает файлы Taildrop (своё и с правом).
  final bool canReceiveFiles;

  /// §707 — цель отправки файлов: в сети, принимает файлы, не расшарено
  /// извне (то же правило у экрана «Поделиться»).
  bool get isTaildropTarget => online && canReceiveFiles && !shareeNode;

  /// MagicDNS-имя без точки в конце.
  String get dnsNameClean =>
      dnsName.endsWith('.') ? dnsName.substring(0, dnsName.length - 1) : dnsName;

  /// Первый адрес (IPv4 идёт первым у ядра); пусто — адресов нет.
  String get firstIp => ips.isEmpty ? '' : ips.first;

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  factory CcTailscalePeer.fromMap(Map<String, dynamic> m) => CcTailscalePeer(
        stableId: '${m['stable_id'] ?? ''}',
        hostName: '${m['host_name'] ?? ''}',
        dnsName: '${m['dns_name'] ?? ''}',
        os: '${m['os'] ?? ''}',
        online: m['online'] == true,
        exitNode: m['exit_node'] == true,
        exitNodeOption: m['exit_node_option'] == true,
        shareeNode: m['sharee_node'] == true,
        expired: m['expired'] == true,
        keyExpiry: _int(m['key_expiry']),
        lastSeen: _int(m['last_seen']),
        ips: [
          for (final ip in CcChannel._asList(m['ips']))
            if (ip != null && '$ip'.isNotEmpty) '$ip',
        ],
        path: '${m['path'] ?? ''}'.toLowerCase(),
        endpoint: '${m['endpoint'] ?? ''}',
        peerRelay: '${m['peer_relay'] ?? ''}',
        derpRegionCode: '${m['derp_region_code'] ?? ''}',
        lastHandshake: _int(m['last_handshake']),
        canReceiveFiles: m['can_receive_files'] == true,
      );
}

/// §707 — входящие Taildrop узла (`TaildropInbox` ядра).
class CcTaildropInbox {
  const CcTaildropInbox({
    required this.tag,
    this.files = const [],
    this.receiving = const [],
  });

  final String tag;

  /// Принятые файлы.
  final List<CcTaildropFile> files;

  /// Файлы, которые принимаются сейчас.
  final List<CcTaildropReceiving> receiving;

  bool get isEmpty => files.isEmpty && receiving.isEmpty;

  factory CcTaildropInbox.fromMap(Map<String, dynamic> m) => CcTaildropInbox(
        tag: '${m['tag'] ?? ''}',
        files: [
          for (final f in CcChannel._asList(m['files']))
            if (f is Map) CcTaildropFile.fromMap(CcChannel._asMap(f)),
        ],
        receiving: [
          for (final f in CcChannel._asList(m['receiving']))
            if (f is Map) CcTaildropReceiving.fromMap(CcChannel._asMap(f)),
        ],
      );
}

/// §707 — принятый файл. [modifiedAt] — Unix-секунды ядра.
class CcTaildropFile {
  const CcTaildropFile({
    required this.name,
    this.size = 0,
    this.senderId = '',
    this.senderName = '',
    this.modifiedAt = 0,
    this.sha256 = '',
  });

  final String name;
  final int size;

  /// Stable ID отправителя (ядро lx.30-rc.2+, пусто после перезапуска ядра).
  final String senderId;
  final String senderName;
  final int modifiedAt;

  /// §707 итер. 5 — sha256 файла на диске, только у
  /// [CcChannel.taildropInboxSnapshot]; пусто — не считался.
  final String sha256;

  factory CcTaildropFile.fromMap(Map<String, dynamic> m) => CcTaildropFile(
        name: '${m['name'] ?? ''}',
        size: CcTailscalePeer._int(m['size']),
        senderId: '${m['sender_id'] ?? ''}',
        senderName: '${m['sender_name'] ?? ''}',
        modifiedAt: CcTailscalePeer._int(m['modified_at']),
        sha256: '${m['sha256'] ?? ''}',
      );
}

/// §707 — файл в приёме. [size] ≤ 0 — размер неизвестен.
class CcTaildropReceiving {
  const CcTaildropReceiving({
    required this.name,
    this.size = 0,
    this.receivedBytes = 0,
    this.senderId = '',
    this.senderName = '',
  });

  final String name;
  final int size;
  final int receivedBytes;
  final String senderId;
  final String senderName;

  /// Доля принятого 0…1; `null` — размер неизвестен.
  double? get progress =>
      size > 0 ? (receivedBytes / size).clamp(0.0, 1.0).toDouble() : null;

  factory CcTaildropReceiving.fromMap(Map<String, dynamic> m) =>
      CcTaildropReceiving(
        name: '${m['name'] ?? ''}',
        size: CcTailscalePeer._int(m['size']),
        receivedBytes: CcTailscalePeer._int(m['received_bytes']),
        senderId: '${m['sender_id'] ?? ''}',
        senderName: '${m['sender_name'] ?? ''}',
      );
}

/// §707 — ответ сохранения / выбора файлов: `status` — `saved`, `started`,
/// `cancelled` или `error`; [where] у сохранения — `downloads` | `document`.
class CcTaildropResult {
  const CcTaildropResult({
    required this.status,
    this.where = '',
    this.error = '',
    this.name = '',
  });

  final String status;
  final String where;
  final String error;

  /// §707 итер. 5 — имя файла: у сохранения в Downloads — имя записи
  /// (занятое получает суффикс), у отправки из байтов — отправленное.
  final String name;

  factory CcTaildropResult.fromMap(Map<String, dynamic> m) => CcTaildropResult(
        status: '${m['status'] ?? 'error'}',
        where: '${m['where'] ?? ''}',
        error: '${m['error'] ?? ''}',
        name: '${m['name'] ?? ''}',
      );
}

/// §707 итер. 7 — служебный файл от натива: [name] и [bytes], либо
/// [error] (`too_large` — тело [size] байт больше [maxBytes]).
class CcServiceFile {
  const CcServiceFile({
    this.name = '',
    this.bytes,
    this.error = '',
    this.size = 0,
    this.maxBytes = 0,
  });

  final String name;
  final Uint8List? bytes;
  final String error;
  final int size;
  final int maxBytes;

  factory CcServiceFile.fromMap(Map<String, dynamic> m) {
    final b = m['bytes'];
    int n(Object? v) => v is int ? v : 0;
    return CcServiceFile(
      name: '${m['name'] ?? ''}',
      bytes: b is Uint8List
          ? b
          : (b is List ? Uint8List.fromList(b.cast<int>()) : null),
      error: '${m['error'] ?? ''}',
      size: n(m['size']),
      maxBytes: n(m['max_bytes']),
    );
  }
}

/// §613 (ядро SPEC 115) — значения `TailscalePeer.path`. Строки ядра
/// (`command_types_tailscale.go`): строчные, «никогда не слал» — пустая
/// строка; разбор приводит к нижнему регистру (§645).
abstract final class CcTailscalePath {
  static const direct = 'direct';
  static const peerRelay = 'peer_relay';
  static const derp = 'derp';

  /// Узел ни разу не слал устройству.
  static const none = '';
}

/// §581 — владелец устройств сети (`TailscaleUserGroup` ядра).
class CcTailscaleUserGroup {
  const CcTailscaleUserGroup({
    this.userId = 0,
    this.loginName = '',
    this.displayName = '',
    this.peers = const [],
  });

  final int userId;
  final String loginName;
  final String displayName;
  final List<CcTailscalePeer> peers;

  /// Заголовок группы: `DisplayName`, при пустом — `LoginName`.
  String get title => displayName.isNotEmpty ? displayName : loginName;

  factory CcTailscaleUserGroup.fromMap(Map<String, dynamic> m) =>
      CcTailscaleUserGroup(
        userId: CcTailscalePeer._int(m['user_id']),
        loginName: '${m['login_name'] ?? ''}',
        displayName: '${m['display_name'] ?? ''}',
        peers: [
          for (final p in CcChannel._asList(m['peers']))
            if (p is Map) CcTailscalePeer.fromMap(CcChannel._asMap(p)),
        ],
      );
}

/// §581 — ответ проверки устройства (`TailscalePingResult` ядра). Непустой
/// [error] — ответа нет.
class CcTailscalePingResult {
  const CcTailscalePingResult({
    this.latencyMs = 0,
    this.isDirect = false,
    this.endpoint = '',
    this.derpRegionCode = '',
    this.error = '',
  });

  final double latencyMs;
  final bool isDirect;
  final String endpoint;
  final String derpRegionCode;
  final String error;

  factory CcTailscalePingResult.fromMap(Map<String, dynamic> m) =>
      CcTailscalePingResult(
        latencyMs: m['latency_ms'] is num
            ? (m['latency_ms'] as num).toDouble()
            : 0,
        isDirect: m['is_direct'] == true,
        endpoint: '${m['endpoint'] ?? ''}',
        derpRegionCode: '${m['derp_region_code'] ?? ''}',
        error: '${m['error'] ?? ''}',
      );
}
