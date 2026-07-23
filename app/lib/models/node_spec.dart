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

  /// §302 — сырая строка подписки ДО применения import-rules (REPLACE).
  /// Проставляется постфактум контроллером на нодах, чьё тело правило
  /// изменило (иначе `null`). Только для UI: значок «были замены» + diff
  /// before/after (`originLine` ↔ `rawUri`). На `emit`/`nodeIdentityHash`
  /// НЕ влияет — как и `warnings`, mutable и не сериализуется (пересоздаётся
  /// на каждый parse; проставляется заново на каждом refresh).
  String? originLine;

  /// §302 — исходный фрагмент подписки, из которого собралась нода, в
  /// «компактном» виде: для JSON-тел это САМ outbound-объект (без dns/
  /// inbounds/routing соседей), для URI-строк — сама строка.
  ///
  /// Нужен, потому что `rawUri` у JSON-нод — синтетическая заглушка
  /// (`xray://<tag>`), а не источник: показать пользователю «как устроено
  /// после парсинга» по ней нельзя. Mutable, не сериализуется, на
  /// `emit`/`nodeIdentityHash` не влияет — как `originLine`.
  String? sourceCompact;

  /// §302 — тот же фрагмент в «расширенном» виде: элемент как пришёл от
  /// провайдера целиком (для Xray-массива — весь элемент с dns/inbounds/
  /// routing). `null`, если расширенный вид не отличается от компактного.
  String? sourceExtended;

  /// §302 — JSON узла после применения import-rules (REPLACE). `null` —
  /// правила узел не меняли. Когда не-null, [emit] отдаёт именно его: узел
  /// уходит в конфиг в изменённом виде, и `nodeIdentityHash` считается от
  /// него же (выключение/роутинг работают с итоговым видом).
  ///
  /// Mutable и не сериализуется — как `originLine`: правила переприменяются
  /// на каждом импорте/регидрации, храниться этому незачем.
  Map<String, dynamic>? patchedJson;

  /// §302 — следы замен для UI («tls.utls.fingerprint: hello… → chrome»).
  List<String> ruleTrail = const [];

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
  ///
  /// §302 — если import-rules пропатчили узел ([patchedJson]), отдаём патч:
  /// узел уходит в конфиг в изменённом виде, и `nodeIdentityHash` считается
  /// от него же. Тип entry (Outbound/Endpoint) сохраняется — билдер
  /// раскладывает по массивам exhaustive-switch'ем.
  SingboxEntry emit(TemplateVars vars) {
    final raw = emitRaw(vars);
    final patch = patchedJson;
    if (patch == null) return raw;
    return switch (raw) {
      Outbound() => Outbound(patch),
      Endpoint() => Endpoint(patch),
    };
  }

  /// Реализация эмита конкретного протокола. Не звать напрямую — снаружи
  /// используется [emit], который учитывает патч import-rules.
  SingboxEntry emitRaw(TemplateVars vars);

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
    this.tls = TlsSpec.disabled,
    this.transport,
    this.packetEncoding = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'vless';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitVless(this, vars);

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
  // §219 — VMess не имеет packet_encoding в sing-box (это VLESS-параметр);
  // поле было write-only copy-paste из VlessSpec, удалено.

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
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'vmess';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitVmess(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitTrojan(this, vars);

  @override
  String toUri() => e.toUriTrojan(this);
}

// ════════════════════════════════════════════════════════════════════════════
// AnyTLS (§269)
// ════════════════════════════════════════════════════════════════════════════
// password + TLS, TCP-based. Мультиплекс/padding — нативно в протоколе, своего
// transport-блока нет (в отличие от Trojan). AnyTLS всегда поверх TLS.
// idle-поля — Go-duration строки ("30s"); пусто = дефолт ядра.

final class AnyTlsSpec extends NodeSpec {
  final String password;
  final TlsSpec tls;
  final String idleSessionCheckInterval;
  final String idleSessionTimeout;
  final int? minIdleSession;

  AnyTlsSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.password,
    this.tls = TlsSpec.disabled,
    this.idleSessionCheckInterval = '',
    this.idleSessionTimeout = '',
    this.minIdleSession,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'anytls';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitAnyTls(this, vars);

  @override
  String toUri() => e.toUriAnyTls(this);
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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitShadowsocks(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitHysteria2(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitNaive(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitTuic(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitSsh(this, vars);

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
  SingboxEntry emitRaw(TemplateVars vars) => e.emitSocks(this, vars);

  @override
  String toUri() => e.toUriSocks(this);
}

// ════════════════════════════════════════════════════════════════════════════
// HTTP(S) CONNECT proxy — see task 222.
// ════════════════════════════════════════════════════════════════════════════

final class HttpSpec extends NodeSpec {
  final String username;
  final String password;
  final String path;
  final Map<String, String> headers;
  final TlsSpec tls; // enabled → HTTPS-прокси (CONNECT over TLS)

  HttpSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    this.username = '',
    this.password = '',
    this.path = '',
    this.headers = const {},
    this.tls = TlsSpec.disabled,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'http';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitHttp(this, vars);

  @override
  String toUri() => e.toUriHttp(this);
}

// ════════════════════════════════════════════════════════════════════════════
// WireGuard — emit'ится в Endpoint, не в Outbound.
// ════════════════════════════════════════════════════════════════════════════

/// §097 Phase 1 — AmneziaWG 2.0 obfuscation params (по образцу singbox-launcher
/// SPEC 073). **Endpoint-level** (корень endpoint, не peer), **config-only** (не
/// негоциируются — mismatch client/server рвёт соединение). Числовые
/// (`jc`/`jmin`/`jmax`/`s1`–`s4`/`h1`–`h4`) — uint32 → JSON **number**; `i1`–`i5`
/// — CPS-строки (тег-формат `<b 0xHEX>`/`<r N>`/…, **регистр сохраняется**).
///
/// Хранит ровно заданные поля (`fields`: key→`int` для числовых, key→`String`
/// для `i*`). Пусто → `WireguardSpec.awg == null` (обычный WG, backward-compat).
class Awg {
  const Awg(this.fields);

  /// key → `int` (числовые jc/jmin/jmax/s1–s4 и одиночные h1–h4) |
  /// `String` (i1–i5, а также h1–h4-диапазоны `"N-M"` — §112).
  final Map<String, Object> fields;

  static const numKeys = <String>{
    'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4',
  };
  // §143 — masquerade id/ip/ib (WireSock-style sugar над i1, ядро 009 само
  // генерит i1). Строки, как i*. Взаимоисключающи с явным i1 (ядро отвергает оба).
  static const strKeys = <String>{
    'i1', 'i2', 'i3', 'i4', 'i5', 'id', 'ip', 'ib',
  };

  /// §112 — magic headers: с AWG 2.0 значение бывает диапазоном `N-M`
  /// (ranged headers). Подмножество [numKeys] — consumers, проверяющие
  /// наличие ключа (ini_parser, securityLabel), не меняются.
  static const headerKeys = <String>{'h1', 'h2', 'h3', 'h4'};

  /// `N` или `N-M`. Глубже (uint32, start ≤ end, непересечение) не
  /// валидируем: ядро даёт явную ошибку старта, а молчаливый drop
  /// здесь = тихо сломанный handshake (исходный баг §112).
  static final _headerRe = RegExp(r'^\d+(-\d+)?$');

  /// h1–h4: `"5"` → `int 5` (type-fidelity §097), `"N-M"` → `String`,
  /// мусор → null (поле пропускается, как `jc=abc`).
  static Object? _parseHeader(String v) {
    if (!_headerRe.hasMatch(v)) return null;
    return int.tryParse(v) ?? v;
  }

  bool get isEmpty => fields.isEmpty;

  /// Из URI query (строки). Числа → `int.tryParse` (битое → пропуск поля, не
  /// валим парс — forward-compat, как mtu/keepalive). h1–h4 дополнительно
  /// принимают диапазон `N-M` (§112). `i*` пустые пропускаем.
  static Awg? fromQuery(Map<String, String> q) {
    final f = <String, Object>{};
    for (final k in numKeys) {
      final v = q[k];
      if (v == null) continue;
      if (headerKeys.contains(k)) {
        final h = _parseHeader(v.trim());
        if (h != null) f[k] = h;
        continue;
      }
      final n = int.tryParse(v.trim());
      if (n != null) f[k] = n;
    }
    for (final k in strKeys) {
      final v = q[k];
      if (v != null && v.isNotEmpty) f[k] = v; // регистр НЕ трогаем
    }
    return f.isEmpty ? null : Awg(f);
  }

  /// Из endpoint-JSON (корень). Числа: `num`→`int`; h1–h4 также `String`
  /// `"N"`/`"N-M"` (§112, контракт ядра lx.6); `i*`: непустые `String`.
  static Awg? fromJson(Map<String, dynamic> m) {
    final f = <String, Object>{};
    for (final k in numKeys) {
      final v = m[k];
      if (v is num) {
        f[k] = v.toInt();
      } else if (v is String && headerKeys.contains(k)) {
        final h = _parseHeader(v.trim());
        if (h != null) f[k] = h;
      }
    }
    for (final k in strKeys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) f[k] = v;
    }
    return f.isEmpty ? null : Awg(f);
  }

  /// В endpoint-map (корень). `int`→JSON number, `String`→JSON string
  /// (h-диапазоны эмитятся строкой — ровно контракт ядра lx.6, §112).
  void writeInto(Map<String, dynamic> m) => m.addAll(fields);

  /// В URI query (числа → строка, `i*` как есть; encode делает `buildQuery`).
  void writeQuery(Map<String, String> q) =>
      fields.forEach((k, v) => q[k] = v.toString());
}

class WireguardPeer {
  final String publicKey;
  final String preSharedKey;
  final String endpointHost;
  final int endpointPort;
  final List<String> allowedIps;
  final int? persistentKeepalive;

  /// §025 — Cloudflare WARP `client_id` (3 байта). В sing-box 1.12+ эмитится
  /// per-peer как `reserved: [b0, b1, b2]`. Без него WARP-handshake проходит,
  /// но трафик не идёт. `null` для обычных WG-пиров.
  final List<int>? reserved;

  const WireguardPeer({
    required this.publicKey,
    this.preSharedKey = '',
    required this.endpointHost,
    required this.endpointPort,
    this.allowedIps = const ['0.0.0.0/0', '::/0'],
    this.persistentKeepalive,
    this.reserved,
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

  /// §097 Phase 1 — AmneziaWG2 obfuscation params (null = обычный WG).
  final Awg? awg;

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
    this.awg,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'wireguard';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitWireguard(this, vars);

  @override
  String toUri() => e.toUriWireguard(this);
}

/// §130 — MASQUE (CONNECT-IP over HTTP/3/HTTP-2) для Cloudflare WARP.
///
/// В отличие от [WireguardSpec] эмитится как **Outbound** (не Endpoint) —
/// ядро sing-box-lx (SPEC 021) регистрирует `type:masque` через
/// `outbound.Register`. Ключи — ECDSA P-256 в DER-base64 (см. [MasqueKeys]):
/// [privateKeyDer] = наш приватник (SEC1), [publicKeyDer] = серверный pubkey
/// (PKIX, для pinning). `network` — это ТРАНСПОРТ (`h3`/`h2`), не L4.
final class MasqueSpec extends NodeSpec {
  /// base64(SEC1 DER) нашего ECDSA-приватника. СЕКРЕТ.
  final String privateKeyDer;

  /// base64(PKIX DER) серверного ECDSA-pubkey (pinning).
  final String publicKeyDer;

  /// Локальные адреса туннеля (CIDR): [v4, v6]. Хотя бы один обязателен.
  final List<String> localAddresses;

  /// `cloudflare` (дефолт) | `standard`.
  final String profile;

  /// Транспорт: `h3` (QUIC, дефолт) | `h2` (HTTP/2).
  final String network;

  /// TLS SNI; пусто = дефолт ядра (`consumer-masque.cloudflareclient.com`).
  final String sni;

  final int? mtu;

  /// idle-suspend туннеля (Go-duration, напр. `5m`). Пусто = дефолт ядра (5m);
  /// отрицательное (`-1s`) = выключить. См. [§128](../128%20idle-suspend/).
  final String idleTimeout;

  /// QUIC keepalive-период (Go-duration, напр. `30s`). Пусто = дефолт (30s);
  /// отрицательное = выключить. Только для `network=h3`.
  final String keepAlive;

  MasqueSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawUri,
    required this.privateKeyDer,
    required this.publicKeyDer,
    required this.localAddresses,
    this.profile = 'cloudflare',
    this.network = 'h3',
    this.sni = '',
    this.mtu,
    this.idleTimeout = '',
    this.keepAlive = '',
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'masque';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitMasque(this, vars);

  @override
  String toUri() => e.toUriMasque(this);
}
