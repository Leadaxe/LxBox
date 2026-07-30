import 'transport_spec.dart';

/// TLS-параметры узла. Singleton для «TLS выключен» — `TlsSpec.disabled`.
///
/// `reality != null` — взаимоисключающе с uTLS fingerprint'ом в sing-box
/// (REALITY уже задаёт fingerprint через `utls`, но разные секции).
class TlsSpec {
  final bool enabled;
  final String? serverName;
  final List<String> alpn;
  final bool insecure;
  final String? fingerprint; // utls: chrome, firefox, safari, etc.
  final RealitySpec? reality;

  /// §320 — Encrypted Client Hello. `null` = ECH не запрошен.
  final EchSpec? ech;

  const TlsSpec({
    required this.enabled,
    this.serverName,
    this.alpn = const [],
    this.insecure = false,
    this.fingerprint,
    this.reality,
    this.ech,
  });

  static const disabled = TlsSpec(enabled: false);

  Map<String, dynamic> toSingbox({TransportSpec? transport}) =>
      _toSingbox(quic: false, transport: transport);

  /// §320 — ALPN, совместимый с [transport] (`h2`/`h3` поверх ws/httpupgrade
  /// ломают апгрейд). Возвращает `(отфильтрованный список, снятые значения)`;
  /// снятые уходят в `IncompatibleAlpnWarning` на стороне эмита узла.
  ///
  /// Фильтр живёт на эмите, а не в парсере: `alpn` хранит то, что было в
  /// ссылке, иначе round-trip (`toUri`) и вкладка Source врали бы.
  static (List<String> kept, List<String> dropped) alpnFor(
      List<String> alpn, TransportSpec? transport) {
    final allowed = transport?.compatibleAlpn;
    if (allowed == null || alpn.isEmpty) return (alpn, const []);
    final kept = <String>[];
    final dropped = <String>[];
    for (final a in alpn) {
      (allowed.contains(a) ? kept : dropped).add(a);
    }
    return (kept, dropped);
  }

  /// §282 — uTLS И REALITY поверх QUIC (hysteria2/tuic) в ядре не работают
  /// вообще: их `STDConfig()` возвращает ошибку («unsupported usage for
  /// uTLS»/«…for reality»), а QUIC-путь фолбэчит именно на `STDConfig()`
  /// (аудит ядра SPECS/027-UTLS_OVER_QUIC). Оба блока на QUIC = мёртвая
  /// нода, и `fp`/reality на hy2/tuic — мусор xray-подписок. Для QUIC-эмита
  /// срезаем `utls` и `reality`; server_name/alpn/insecure цел.
  Map<String, dynamic> toSingboxForQuic() => _toSingbox(quic: true);

  Map<String, dynamic> _toSingbox({
    required bool quic,
    TransportSpec? transport,
  }) {
    if (!enabled) return const {};
    final m = <String, dynamic>{'enabled': true};
    if (serverName != null && serverName!.isNotEmpty) {
      m['server_name'] = serverName;
    }
    // §320 — пустой результат фильтра = ключ не эмитим вовсе (у ядра свой
    // дефолт), а не `[]` — пустой список ядро трактует как «нет ALPN».
    final (keptAlpn, _) = alpnFor(alpn, transport);
    if (keptAlpn.isNotEmpty) m['alpn'] = List<String>.from(keptAlpn);
    if (insecure) m['insecure'] = true;
    if (ech != null) m['ech'] = ech!.toSingbox();
    if (!quic && fingerprint != null && fingerprint!.isNotEmpty) {
      m['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    if (!quic && reality != null) {
      m['reality'] = reality!.toSingbox();
    }
    return m;
  }

  TlsSpec copyWith({
    bool? enabled,
    String? serverName,
    List<String>? alpn,
    bool? insecure,
    String? fingerprint,
    RealitySpec? reality,
    EchSpec? ech,
  }) =>
      TlsSpec(
        enabled: enabled ?? this.enabled,
        serverName: serverName ?? this.serverName,
        alpn: alpn ?? this.alpn,
        insecure: insecure ?? this.insecure,
        fingerprint: fingerprint ?? this.fingerprint,
        reality: reality ?? this.reality,
        ech: ech ?? this.ech,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TlsSpec &&
          enabled == other.enabled &&
          serverName == other.serverName &&
          _listEq(alpn, other.alpn) &&
          insecure == other.insecure &&
          fingerprint == other.fingerprint &&
          reality == other.reality &&
          ech == other.ech);

  @override
  int get hashCode => Object.hash(enabled, serverName, Object.hashAll(alpn),
      insecure, fingerprint, reality, ech);
}

/// §320 — Encrypted Client Hello (клиентская сторона).
///
/// Xray-подписки задают ECH строкой `<query-name>+<resolver-URL>`
/// (`ech=ip.gs+udp://8.8.8.8`). Резолвер отбрасывается на парсинге: в
/// `option.OutboundECHOptions` поля под него нет — ядро тянет ECHConfigList
/// через общий `dnsRouter` (`common/tls/ech.go`).
///
/// `config`/`config_path` не заполняем: при пустых ядро само запрашивает
/// HTTPS-запись DNS для [queryServerName] (а при пустом — для `server_name`),
/// что и есть штатный режим для импортированных узлов.
class EchSpec {
  /// Имя для HTTPS-DNS-запроса. Пусто = ядро спросит `server_name`.
  final String queryServerName;

  const EchSpec({this.queryServerName = ''});

  Map<String, dynamic> toSingbox() => {
        'enabled': true,
        if (queryServerName.isNotEmpty) 'query_server_name': queryServerName,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EchSpec && queryServerName == other.queryServerName);

  @override
  int get hashCode => queryServerName.hashCode;
}

class RealitySpec {
  final String publicKey;
  final String shortId;

  const RealitySpec({required this.publicKey, required this.shortId});

  Map<String, dynamic> toSingbox() => {
        'enabled': true,
        'public_key': publicKey,
        'short_id': shortId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RealitySpec &&
          publicKey == other.publicKey &&
          shortId == other.shortId);

  @override
  int get hashCode => Object.hash(publicKey, shortId);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
