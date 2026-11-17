part of '../cc_channel.dart';

/// §3.1 — статус от `writeStatus`. `uplink`/`downlink` — байтовая дельта за
/// интервал (B/s при interval=1s); `*Total` — накопленный объём.
class CcStatus {
  const CcStatus({
    this.uplink = 0,
    this.downlink = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
    this.memory = 0,
    this.memoryRuntime = 0,
    this.goroutines = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
  });

  final int uplink;
  final int downlink;
  final int uplinkTotal;
  final int downlinkTotal;
  final int memory;

  /// §705 (ядро lx.29, SPEC 148) — память Go-рантайма ядра в байтах: то, с
  /// чем ядро сравнивает порог Memory limit. [memory] — RSS всего процесса.
  /// 0 — старое ядро без поля.
  final int memoryRuntime;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;

  /// §3.1 — НЕ сумма in+out вслепую (могут двоить); для бейджа активных
  /// предпочтительнее длина connections-снапшота. Здесь — справочно.
  int get connectionsTotal => connectionsIn + connectionsOut;

  factory CcStatus.fromMap(Map<String, dynamic> m) => CcStatus(
    uplink: _int(m['uplink']),
    downlink: _int(m['downlink']),
    uplinkTotal: _int(m['uplinkTotal']),
    downlinkTotal: _int(m['downlinkTotal']),
    memory: _int(m['memory']),
    memoryRuntime: _int(m['memoryRuntime']),
    goroutines: _int(m['goroutines']),
    connectionsIn: _int(m['connectionsIn']),
    connectionsOut: _int(m['connectionsOut']),
  );
}

/// §2.4 — плоский узел из `writeOutbounds` (outbound ИЛИ endpoint).
class CcOutbound {
  const CcOutbound({
    required this.tag,
    required this.type,
    required this.urlTestDelay,
    required this.urlTestTime,
    this.endpointState = '',
    this.idleSinceSeconds = 0,
  });

  final String tag;
  final String type;

  /// Задержка в мс. 0 = не тестирован / не ответил — различать по `urlTestTime`.
  final int urlTestDelay;

  /// Unix-время последнего теста (0 = не тестирован).
  final int urlTestTime;

  /// §535 (ядро SPEC 097) — состояние WG/AWG-endpoint'а:
  /// `never_built` / `building` / `up` / `asleep` / `torn_down` / `down`.
  ///
  /// Пусто у всего остального И на любом пути, кроме `getOutbounds()`: поток
  /// `writeOutbounds` и дерево групп поле не несут (ядро заполняет его только
  /// в ответе `GetOutbounds`). Пусто = «состояние неизвестно», не ошибка.
  final String endpointState;

  /// §535 — секунд с последнего дайла через endpoint (0 вне `getOutbounds()`).
  final int idleSinceSeconds;

  factory CcOutbound.fromMap(Map<String, dynamic> m) => CcOutbound(
    tag: m['tag']?.toString() ?? '',
    type: m['type']?.toString() ?? '',
    urlTestDelay: _int(m['urlTestDelay']),
    urlTestTime: _int(m['urlTestTime']),
    // no-throw: старое ядро/поток без ключей → '' и 0 (состояние неизвестно).
    endpointState: m['endpointState']?.toString() ?? '',
    idleSinceSeconds: _int(m['idleSinceSeconds']),
  );
}

/// §535 — состояния WG/AWG-endpoint'а из `CcOutbound.endpointState`
/// (ядро SPEC 097). Строки ядра, не переводятся и в UI не показываются.
abstract final class CcEndpointState {
  /// Ленивый endpoint, дайлов ещё не было.
  static const neverBuilt = 'never_built';

  /// Идёт сборка (включая ожидание бюджета).
  static const building = 'building';

  /// Устройство собрано и бодрствует.
  static const up = 'up';

  /// Устройство собрано, уведено в Down.
  static const asleep = 'asleep';

  /// Устройство освобождено (разборка по idle_teardown или бюджетом).
  static const tornDown = 'torn_down';

  /// Ещё не стартовал или закрыт.
  static const down = 'down';

  /// §557 (SPEC 106) — выключен вручную: дайлы отвергаются, ничто его не
  /// будит до включения. Не «соберётся при дайле», поэтому не [isNotBuilt].
  static const disabled = 'disabled';

  /// Узел не поднят: ядро соберёт его при первом дайле (0,5–1 с).
  /// Это состояние, а не сбой, — UI не показывает тут таймаут.
  static bool isNotBuilt(String s) => s == neverBuilt || s == tornDown;
}

/// §613 — коды отказа `getWireGuardStatus` ([PlatformException.code]).
abstract final class CcStatusError {
  /// Тега нет в работающем конфиге.
  static const notFound = 'not_found';

  /// Узел не WG/AWG.
  static const invalidArgument = 'invalid_argument';

  /// Сервис или узел не запущен.
  static const failedPrecondition = 'failed_precondition';

  static const unavailable = 'unavailable';

  /// Ядро без `with_lx_command` или старше lx.12: статуса пиров нет.
  static const unimplemented = 'unimplemented';

  /// Прочее: нет клиента, транспорт.
  static const error = 'error';
}

/// §613 (ядро SPEC 114) — ответ `GetWireGuardStatus`: состояние узла
/// (строки [CcEndpointState]), простой и пиры в порядке конфига.
class CcWireGuardStatus {
  const CcWireGuardStatus({
    this.endpointState = '',
    this.idleSinceSeconds = 0,
    this.peers = const [],
  });

  final String endpointState;
  final int idleSinceSeconds;
  final List<CcWireGuardPeer> peers;

  factory CcWireGuardStatus.fromMap(Map<String, dynamic> m) =>
      CcWireGuardStatus(
        endpointState: '${m['endpoint_state'] ?? ''}',
        idleSinceSeconds: CcTailscalePeer._int(m['idle_since_seconds']),
        peers: [
          for (final p in CcChannel._asList(m['peers']))
            if (p is Map) CcWireGuardPeer.fromMap(CcChannel._asMap(p)),
        ],
      );
}

/// §613 — пир WG/AWG-узла (`PeerStatus` ядра). `lastHandshakeUnix` —
/// Unix-секунды, 0 — в текущей сессии хендшейка не было; `rx`/`tx` —
/// накопленные байты устройства, обнуляются при пересборке; `session*` — с
/// начала сессии (ядро SPEC 145, lx.27): обнуляются ещё и при включении или
/// пробуждении узла.
class CcWireGuardPeer {
  const CcWireGuardPeer({
    required this.publicKey,
    this.endpoint = '',
    this.lastHandshakeUnix = 0,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.sessionRxBytes = 0,
    this.sessionTxBytes = 0,
  });

  final String publicKey;
  final String endpoint;
  final int lastHandshakeUnix;
  final int rxBytes;
  final int txBytes;
  final int sessionRxBytes;
  final int sessionTxBytes;

  /// Ключ сокращённо, как в логе ядра: символы 0–3 и 39–42 base64.
  String get shortKey => publicKey.length < 43
      ? publicKey
      : '${publicKey.substring(0, 4)}…${publicKey.substring(39, 43)}';

  factory CcWireGuardPeer.fromMap(Map<String, dynamic> m) => CcWireGuardPeer(
        publicKey: '${m['public_key'] ?? ''}',
        endpoint: '${m['endpoint'] ?? ''}',
        lastHandshakeUnix: CcTailscalePeer._int(m['last_handshake_unix']),
        rxBytes: CcTailscalePeer._int(m['rx_bytes']),
        txBytes: CcTailscalePeer._int(m['tx_bytes']),
        sessionRxBytes: CcTailscalePeer._int(m['session_rx_bytes']),
        sessionTxBytes: CcTailscalePeer._int(m['session_tx_bytes']),
      );
}
