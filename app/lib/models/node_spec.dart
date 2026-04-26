import 'emit_context.dart';
import 'node_entries.dart';
import 'node_spec_emit.dart' as e;
import 'node_warning.dart';
import 'singbox_entry.dart';
import 'template_vars.dart';
import 'tls_spec.dart';
import 'transport_spec.dart';

/// Sealed-иерархия типизированных узлов (§2 спеки 026).
///
/// Полиморфный `emit(vars)` выбирает Outbound vs Endpoint (WireGuard) —
/// никаких рантайм-проверок `type == 'wireguard'` в builder'е. `toUri()`
/// возвращает канонический URI (round-trip инвариант §4).
///
/// **Отступ от §5 спеки:** все 9 вариантов в одном файле вместо девяти
/// (принцип YAGNI, проще читать и мержить). Если конкретный UI потребует
/// импорт одного variant'а — разнесём через `part` позже.
///
/// **Mutable `warnings`:** единственное mutable поле в spec'е (§2.4, решение
/// §11 #9). Парсер заполняет при конструировании; `emit` дописывает при
/// fallback'ах. Не сериализуется — пересоздаётся на каждом parse/emit.
sealed class NodeSpec {
  final String id;
  final String tag;
  final String label;
  final String server;
  final int port;
  final String rawUri;
  final NodeSpec? chained;
  final List<NodeWarning> warnings;

  NodeSpec({
    required this.id,
    required this.tag,
    required this.label,
    required this.server,
    required this.port,
    required this.rawUri,
    this.chained,
    List<NodeWarning>? warnings,
  }) : warnings = warnings ?? <NodeWarning>[];

  /// Чистая функция spec → sing-box entry. Не применяет prefix, не знает
  /// про подписку или детур-политику. Используется round-trip тестами,
  /// "view JSON" в UI, и внутри `getEntries`.
  SingboxEntry emit(TemplateVars vars);

  /// Канонический URI. Инвариант: `parseUri(spec.toUri()) ≈ spec`.
  String toUri();

  /// Тип протокола — для UI иконок и дебага.
  String get protocol;

  /// Превращает один сервер в список sing-box entries, которые надо
  /// положить в конфиг.
  ///
  /// - `raw[0]` — сам сервер (Outbound или Endpoint — для WireGuard).
  /// - `raw[1..]` — его chained-детур цепочка (если есть).
  ///
  /// `skipDetour=true` — вернёт только `[self]`; ServerList передаёт это
  /// когда по своей политике всё равно выкинет детур (override или
  /// `!useDetourServers`).
  ///
  /// Узел **не знает** ничего про `ServerList`, `tagPrefix`, политику.
  /// Тэг у entry — базовый (из `this.tag`), без префикса. Префикс и
  /// глобальную уникальность вешает ServerList через `EmitContext`.
  NodeEntries getEntries(EmitContext? ctx, {bool skipDetour = false}) {
    final vars = ctx?.vars ?? TemplateVars.empty;
    final self = emit(vars);
    if (skipDetour || chained == null) {
      return NodeEntries(main: self);
    }
    final childEntries = chained!.getEntries(ctx, skipDetour: skipDetour);
    final detours = <SingboxEntry>[childEntries.main, ...childEntries.detours];
    return NodeEntries(main: self, detours: detours);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeSpec &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          tag == other.tag);

  @override
  int get hashCode => Object.hash(runtimeType, id, tag);

  @override
  String toString() => '$runtimeType($tag @ $server:$port)';
}


// ════════════════════════════════════════════════════════════════════════════
// VLESS
// ════════════════════════════════════════════════════════════════════════════

final class VlessSpec extends NodeSpec {
  final String uuid;
  final String flow;
  final String encryption;
  final TlsSpec tls;
  final TransportSpec? transport;
  final String packetEncoding;

  VlessSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.uuid,
    this.flow = '',
    this.encryption = 'none',
    this.tls = TlsSpec.disabled,
    this.transport,
    this.packetEncoding = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'vless';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitVless(this, vars);

  @override
  String toUri() => e.toUriVless(this);
}

// ════════════════════════════════════════════════════════════════════════════
// VMess
// ════════════════════════════════════════════════════════════════════════════

final class VmessSpec extends NodeSpec {
  final String uuid;
  final int alterId;
  final String security; // cipher: auto, aes-128-gcm, chacha20-poly1305, none
  final TlsSpec tls;
  final TransportSpec? transport;
  final String packetEncoding;

  VmessSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.uuid,
    this.alterId = 0,
    this.security = 'auto',
    this.tls = TlsSpec.disabled,
    this.transport,
    this.packetEncoding = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'vmess';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitVmess(this, vars);

  @override
  String toUri() => e.toUriVmess(this);
}

// ════════════════════════════════════════════════════════════════════════════
// Trojan
// ════════════════════════════════════════════════════════════════════════════

final class TrojanSpec extends NodeSpec {
  final String password;
  final TlsSpec tls;
  final TransportSpec? transport;

  TrojanSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.password,
    this.tls = TlsSpec.disabled,
    this.transport,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'trojan';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitTrojan(this, vars);

  @override
  String toUri() => e.toUriTrojan(this);
}

// ════════════════════════════════════════════════════════════════════════════
// Shadowsocks
// ════════════════════════════════════════════════════════════════════════════

final class ShadowsocksSpec extends NodeSpec {
  final String method;
  final String password;
  final String plugin;
  final String pluginOpts;

  ShadowsocksSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.method,
    required this.password,
    this.plugin = '',
    this.pluginOpts = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'shadowsocks';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitShadowsocks(this, vars);

  @override
  String toUri() => e.toUriShadowsocks(this);
}

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

final class Hysteria2Spec extends NodeSpec {
  final String password;
  final String obfs; // '' | 'salamander'
  final String obfsPassword;
  final TlsSpec tls;
  final int? upMbps;
  final int? downMbps;

  Hysteria2Spec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.password,
    this.obfs = '',
    this.obfsPassword = '',
    this.tls = TlsSpec.disabled,
    this.upMbps,
    this.downMbps,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'hysteria2';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitHysteria2(this, vars);

  @override
  String toUri() => e.toUriHysteria2(this);
}

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy
// ════════════════════════════════════════════════════════════════════════════

/// NaïveProxy outbound. Cronet (Chrome network stack) внутри libbox даёт
/// настоящий Chrome TLS-fingerprint, поэтому в этом outbound'е sing-box
/// **не** принимает кастомные `alpn`/`utls`/`fingerprint`/`reality` —
/// только `enabled`, `server_name`, `certificate(_path)`, `ech`.
///
/// Build-tag в libbox — `with_naive_outbound`. Уже включён в основной
/// `libbox.aar` от `singbox-android/libbox` (см. spec 037 §2).
final class NaiveSpec extends NodeSpec {
  final String username; // может быть пустым
  final String password; // может быть пустым (anonymous)
  final TlsSpec tls;
  final Map<String, String> extraHeaders;

  NaiveSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    this.username = '',
    this.password = '',
    this.tls = TlsSpec.disabled,
    this.extraHeaders = const {},
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'naive';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitNaive(this, vars);

  @override
  String toUri() => e.toUriNaive(this);
}

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5 (new in v2)
// ════════════════════════════════════════════════════════════════════════════

final class TuicSpec extends NodeSpec {
  final String uuid;
  final String password;
  final String congestionControl; // bbr | cubic | new_reno
  final String udpRelayMode; // native | quic
  final bool zeroRtt;
  final TlsSpec tls;

  TuicSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.uuid,
    required this.password,
    this.congestionControl = 'cubic',
    this.udpRelayMode = 'native',
    this.zeroRtt = false,
    this.tls = TlsSpec.disabled,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'tuic';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitTuic(this, vars);

  @override
  String toUri() => e.toUriTuic(this);
}

// ════════════════════════════════════════════════════════════════════════════
// SSH
// ════════════════════════════════════════════════════════════════════════════

final class SshSpec extends NodeSpec {
  final String user;
  final String password;
  final String privateKey;
  final String privateKeyPassphrase;
  final List<String> hostKey;
  final List<String> hostKeyAlgorithms;

  SshSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.user,
    this.password = '',
    this.privateKey = '',
    this.privateKeyPassphrase = '',
    this.hostKey = const [],
    this.hostKeyAlgorithms = const [],
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'ssh';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitSsh(this, vars);

  @override
  String toUri() => e.toUriSsh(this);
}

// ════════════════════════════════════════════════════════════════════════════
// SOCKS (5)
// ════════════════════════════════════════════════════════════════════════════

final class SocksSpec extends NodeSpec {
  final String version; // '5' | '4' | '4a'
  final String username;
  final String password;

  SocksSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    this.version = '5',
    this.username = '',
    this.password = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'socks';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitSocks(this, vars);

  @override
  String toUri() => e.toUriSocks(this);
}

// ════════════════════════════════════════════════════════════════════════════
// WireGuard — emit'ится в Endpoint, не в Outbound.
// ════════════════════════════════════════════════════════════════════════════

class WireguardPeer {
  final String publicKey;
  final String preSharedKey;
  final String endpointHost;
  final int endpointPort;
  final List<String> allowedIps;
  final int? persistentKeepalive;

  const WireguardPeer({
    required this.publicKey,
    this.preSharedKey = '',
    required this.endpointHost,
    required this.endpointPort,
    this.allowedIps = const ['0.0.0.0/0', '::/0'],
    this.persistentKeepalive,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WireguardPeer &&
          publicKey == other.publicKey &&
          preSharedKey == other.preSharedKey &&
          endpointHost == other.endpointHost &&
          endpointPort == other.endpointPort);

  @override
  int get hashCode =>
      Object.hash(publicKey, preSharedKey, endpointHost, endpointPort);
}

final class WireguardSpec extends NodeSpec {
  final String privateKey;
  final List<String> localAddresses; // CIDR список
  final List<WireguardPeer> peers;
  final int? mtu;
  final String? rawIni; // если парсили из INI, сохраняем оригинал

  WireguardSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.privateKey,
    required this.localAddresses,
    required this.peers,
    this.mtu,
    this.rawIni,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'wireguard';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitWireguard(this, vars);

  @override
  String toUri() => e.toUriWireguard(this);
}
