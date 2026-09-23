import 'auto_select.dart';
import 'emit_context.dart';
import 'node_entries.dart';
import 'node_sections.dart';
import 'node_spec_emit.dart' as e;
import 'node_warning.dart';
import 'singbox_entry.dart';
import 'tcp_keep_alive_spec.dart';
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
/// §307 — глубокая копия JSON-значения (Map/List рекурсивно, листья как есть:
/// в JSON они иммутабельны). Нужна, чтобы `emit` отдавал сохранённый
/// [NodeSpec.patchedJson] без разделяемого состояния с потребителем.
Object? deepCopyJson(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final e in value.entries) e.key as String: deepCopyJson(e.value),
    };
  }
  if (value is List) return [for (final v in value) deepCopyJson(v)];
  return value;
}

sealed class NodeSpec {
  final String id;
  final String tag;
  final String label;
  final String server;
  final int port;

  /// §454 — источник узла: из чего он разобран. URI-строка байт в байт,
  /// объект outbound'а (sing-box / Xray) в pretty-JSON, INI-текст у WG из
  /// `.conf` (§456; тег — поле записи, не текста).
  /// Им узел предъявляет себя, когда нужен собственный текст: переезд в
  /// папку (`raw` члена), вкладка Source. Пусто только у узлов, собранных
  /// приложением без текста (группы §208).
  /// Не сериализуется: хранение держит текст контейнера (`origin.raw`).
  final String rawSource;
  final NodeSpec? chained;
  final List<NodeWarning> warnings;

  /// §453 — TCP keep-alive dial-поля sing-box. В ядре это `DialerOptions`,
  /// общая для всех outbound'ов с TCP-дозвоном, а не свойство протокола —
  /// потому база, а не копия в каждом `*Spec`. `null` = не задано, эмит
  /// ничего не пишет. Прокидывают только 9 носителей (у QUIC/UDP-типов
  /// keep-alive TCP-сокета не к чему применить, см. §1 спеки 453).
  final TcpKeepAliveSpec? tcpKeepAlive;

  /// §302 — источник узла в «расширенном» виде: элемент как пришёл от
  /// провайдера целиком (для Xray-массива / sing-box-конфига — с dns/inbounds/
  /// routing соседями). `null`, если не отличается от [rawSource]. Mutable,
  /// не сериализуется, на `emit` и идентичность не влияет.
  String? sourceExtended;

  /// §302 — JSON узла после применения import-rules (REPLACE). `null` —
  /// правила узел не меняли. Когда не-null, [emit] отдаёт его КОПИЮ: узел
  /// уходит в конфиг в изменённом виде. На идентичность узла патч не влияет
  /// (§400: идентичность — тег, а тег патч не трогает).
  ///
  /// §307 — именно копию: билдер мутирует map результата `emit` на месте
  /// (префикс в `tag`, политика `detour`), и когда `emit` отдавал патч по
  /// ссылке, эти мутации впечатывались сюда — префикс накапливался в теге
  /// на каждом старте VPN. Патч — сохранённое состояние узла; писать в него
  /// может только применение правил.
  ///
  /// Mutable и не сериализуется — как `sourceExtended`: правила переприменяются
  /// на каждом импорте/регидрации, храниться этому незачем.
  Map<String, dynamic>? patchedJson;

  /// §302 — следы замен для UI («tls.utls.fingerprint: hello… → chrome»).
  /// Непустой ⇔ [patchedJson] != null; на нём значок «modified» и диалог
  /// «View replacements» в списке нод.
  List<String> ruleTrail = const [];

  /// §435 — связка узла, извлечённая парсером из целого sing-box-конфига с
  /// одним узлом (NODE_SECTIONS.md §6) или прочитанная из документа с
  /// `sections`. Mutable и не сериализуется, как `sourceExtended`: хозяин
  /// секций — контейнер (`UserServer.sections` / `FolderMember.sections`),
  /// контроллер переносит её туда при добавлении узла и только тогда.
  NodeSections? importedSections;

  /// §435 — узел без адреса: группа §322 или Tailscale (tsnet сам входит в
  /// tailnet). Инвариант `isAddressless ⇔ server.isEmpty && port == 0`.
  /// Гейт для подписей `server:port`, пробы и операций, требующих адреса.
  bool get isAddressless => false;

  NodeSpec({
    required this.id,
    required this.tag,
    required this.label,
    required this.server,
    required this.port,
    required this.rawSource,
    this.chained,
    this.tcpKeepAlive,
    List<NodeWarning>? warnings,
  }) : warnings = warnings ?? <NodeWarning>[];

  /// Чистая функция spec → sing-box entry. Не применяет prefix, не знает
  /// про подписку или детур-политику. Используется round-trip тестами,
  /// "view JSON" в UI, и внутри `getEntries`.
  ///
  /// §302 — если import-rules пропатчили узел ([patchedJson]), отдаём патч:
  /// узел уходит в конфиг в изменённом виде. Тип entry (Outbound/Endpoint)
  /// сохраняется — билдер
  /// раскладывает по массивам exhaustive-switch'ем.
  ///
  /// §307 — патч отдаётся ГЛУБОКОЙ копией (симметрия с `emitRaw`, который
  /// строит свежие map на каждый вызов): результат `emit` одноразовый,
  /// потребитель волен мутировать его как угодно, сохранённый патч не
  /// пострадает. Отдача по ссылке накапливала префикс билдера в теге.
  SingboxEntry emit(TemplateVars vars) {
    final raw = emitRaw(vars);
    final patch = patchedJson;
    if (patch == null) return raw;
    final copy = deepCopyJson(patch) as Map<String, dynamic>;
    return switch (raw) {
      Outbound() => Outbound(copy),
      Endpoint() => Endpoint(copy),
    };
  }

  /// Реализация эмита конкретного протокола. Не звать напрямую — снаружи
  /// используется [emit], который учитывает патч import-rules.
  SingboxEntry emitRaw(TemplateVars vars);

  /// Канонический URI. Инвариант: `parseUri(spec.toUri()) ≈ spec`.
  String toUri();

  /// Тип протокола — для UI иконок и дебага.
  String get protocol;

  /// §466 — [toUri] этого узла несёт приватный ключ владельца.
  ///
  /// Признак для экрана, а не для эмиттера: `toUri()` у нас одновременно и
  /// форма хранения (инвариант `parseUri(spec.toUri()) ≈ spec`), вырезать из
  /// неё ключ нельзя — он потерялся бы при перезагрузке узла. Но ссылку
  /// пересылают, и это другая граница доверия, чем локальное хранение:
  /// «Copy URI» у такого узла спрашивает подтверждение (§466 заменил отказ
  /// §463).
  ///
  /// Пароли, UUID и PSK признаком НЕ считаются: это секрет доступа к конкретному
  /// прокси, а не ключ, которым владелец опознаётся где-то ещё.
  bool get linkCarriesPrivateKey => false;

  /// §322 — узел-группа (пул автовыбора), а не соединение. У такого нет
  /// адреса: `server`/`port` пусты, пинг берётся у выбранного члена. Гейт для
  /// операций, требующих `server:port`, и для тех, что раздают ссылку наружу
  /// (copy / QR / move): ссылки у группы нет, её члены — узлы своего
  /// контейнера, и в чужом она осмысленной не станет.
  ///
  /// Инвариант: `isGroup ⇔ server.isEmpty && port == 0` (проверяется тестом).
  bool get isGroup => false;

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

  /// §335 — постквантовый слой шифрования VLESS (ядро: SPEC 032). Спек-строка
  /// вида `mlkem768x25519plus.МЕТОД.RTT[.ПАДДИНГ].КЛЮЧ`; живёт внутри VLESS,
  /// независимо от TLS (узлы с ним ходят с `security=none`). Переносится как
  /// есть — валидирует ядро.
  final String encryption;

  VlessSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    required this.uuid,
    this.flow = '',
    this.tls = TlsSpec.disabled,
    this.transport,
    this.packetEncoding = '',
    this.encryption = '',
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'vless';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitVless(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    required this.uuid,
    this.alterId = 0,
    this.security = 'auto',
    this.tls = TlsSpec.disabled,
    this.transport,
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'vmess';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitVmess(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    required this.password,
    this.tls = TlsSpec.disabled,
    this.transport,
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'trojan';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitTrojan(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    required this.password,
    this.tls = TlsSpec.disabled,
    this.idleSessionCheckInterval = '',
    this.idleSessionTimeout = '',
    this.minIdleSession,
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'anytls';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitAnyTls(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    required this.method,
    required this.password,
    this.plugin = '',
    this.pluginOpts = '',
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'shadowsocks';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitShadowsocks(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
}

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

final class Hysteria2Spec extends NodeSpec {
  final String password;

  /// §358 — `'' | 'salamander' | 'gecko'` ([kHysteria2ObfsTypes]). Значение
  /// нормализуют парсеры: тип вне словаря ядра или без пароля роняет ВЕСЬ
  /// конфиг (`Hysteria2Obfs.MarshalJSON` → «unknown obfs type», outbound.go
  /// → «missing obfs password»), поэтому в спеку он не попадает.
  final String obfs;
  final String obfsPassword;

  /// §358 — параметры `gecko` (`Hysteria2ObfsGecko`). Эмитятся только при
  /// `obfs == 'gecko'`; при salamander хранятся, но в JSON не идут.
  final int? obfsMinPacketSize;
  final int? obfsMaxPacketSize;
  final TlsSpec tls;
  final int? upMbps;
  final int? downMbps;

  /// §103 §9.B2 — Hysteria2 multi-port / port hopping: диапазоны/списки
  /// портов из `mport=`/`ports=` (query) и/или из authority
  /// (`host:443,20000-30000`), слитые в sing-box `server_ports`
  /// (`["low:high", ...]`, одиночный порт → `"N:N"`). `null`/пусто —
  /// не задано, ключ не эмитится (Go: hysteria2_ports.go).
  final List<String>? serverPorts;

  Hysteria2Spec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    required this.password,
    this.obfs = '',
    this.obfsPassword = '',
    this.obfsMinPacketSize,
    this.obfsMaxPacketSize,
    this.tls = TlsSpec.disabled,
    this.upMbps,
    this.downMbps,
    this.serverPorts,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'hysteria2';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitHysteria2(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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

  /// §103 §9.B1 — `naive+quic://` вместо `naive+https://`: транспорт QUIC
  /// вместо HTTP/2. Go запоминает это как `quic:true` в outbound + фиксирует
  /// `quic_congestion_control:"bbr"` (единственная опция, других нет).
  /// `false` — HTTP/2 (дефолт, ключ `quic` не эмитится вовсе).
  final bool quic;

  NaiveSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    this.username = '',
    this.password = '',
    this.tls = TlsSpec.disabled,
    this.extraHeaders = const {},
    this.quic = false,
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'naive';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitNaive(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
}

// ════════════════════════════════════════════════════════════════════════════
// TUIC v5 (new in v2)
// ════════════════════════════════════════════════════════════════════════════

final class TuicSpec extends NodeSpec {
  final String uuid;
  final String password;
  // §103 D-016(в) — null = не было явно задано (URI/JSON) → не эмитим,
  // ядро подставит свой дефолт (cubic/native, option/tuic.go omitempty).
  // Непустая строка — значение пришло явно, эмитим как есть (в т.ч. если
  // оно совпадает с дефолтом ядра: явный cubic ≠ отсутствие поля для UI/
  // round-trip, но на identity-хеш не влияет — ядро трактует оба одинаково).
  final String? congestionControl; // bbr | cubic | new_reno
  final String? udpRelayMode; // native | quic
  final bool zeroRtt;
  final TlsSpec tls;

  /// §103 D-024 — QUIC heartbeat, sing-box duration-строка (напр. "10s").
  /// null = не задан явно → не эмитим, ядро подставит свой дефолт.
  /// Нормализация голого числа в секунды — на разборе
  /// ([normalizeSingboxDuration], зеркало Go normalizeTuicHeartbeat).
  final String? heartbeat;

  TuicSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    required this.uuid,
    required this.password,
    this.congestionControl,
    this.udpRelayMode,
    this.zeroRtt = false,
    this.tls = TlsSpec.disabled,
    this.heartbeat,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'tuic';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitTuic(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    required this.user,
    this.password = '',
    this.privateKey = '',
    this.privateKeyPassphrase = '',
    this.hostKey = const [],
    this.hostKeyAlgorithms = const [],
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'ssh';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitSsh(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);

  /// §466 — `toUriSsh` пишет `private_key` в query только когда ключ непустой;
  /// узел с одним паролем ключа в ссылке не несёт.
  @override
  bool get linkCarriesPrivateKey => privateKey.isNotEmpty;
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
    required super.rawSource,
    this.version = '5',
    this.username = '',
    this.password = '',
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'socks';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitSocks(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
    required super.rawSource,
    this.username = '',
    this.password = '',
    this.path = '',
    this.headers = const {},
    this.tls = TlsSpec.disabled,
    super.chained,
    super.tcpKeepAlive,
    super.warnings,
  });

  @override
  String get protocol => 'http';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitHttp(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);
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
  /// `String` (i1–i5, а также h1–h4-диапазоны `"N-M"` — §112) |
  /// §421 AWG 3.x: [awg3RangeKeys] → `int` (`N`) | `String` (`"N-M"`),
  /// [awg3BoolKeys] → `bool` (только `true`; выключенное = ключа нет),
  /// [headerKey] → `String` (base64 32 байт). Ключи map — JSON-ключи ядра
  /// (корень endpoint `wireguard`).
  final Map<String, Object> fields;

  static const numKeys = <String>{
    'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4',
  };
  // §143 — masquerade id/ip/ib (WireSock-style sugar над i1, ядро 009 само
  // генерит i1). Строки, как i*. Взаимоисключающи с явным i1 (ядро отвергает оба).
  static const strKeys = <String>{
    'i1', 'i2', 'i3', 'i4', 'i5', 'id', 'ip', 'ib',
  };

  // ── §421 — AmneziaWG 3.0/3.1 (SPEC 123 лаунчера, эталон awg3.go) ──────
  // URI/.conf-параметр = JSON-ключ без подчёркиваний в нижнем регистре
  // (`content_padding_addition` ↔ `contentpaddingaddition`), как `jc`/`h1`
  // у AWG2. Эмиттер и парсер ходят парой — схема без emit-ветки молча
  // урезается на round-trip.

  /// Тайминги/паддинг 3.0: `N` → `int`, `N-M` → `String` (ядро перевыбирает
  /// значение из диапазона при каждом взводе таймера).
  static const awg3RangeKeys = <String>{
    'content_padding_addition',
    'rekey_after_time',
    'rekey_timeout',
    'reject_after_time',
    'keepalive_timeout',
    'max_handshake_attempts',
  };

  /// Булевы 3.1: `on`/`true`/`1` → `true`; `off`/пусто → ключа нет
  /// (никогда `false` — лишний ключ менял бы identity-хеш узла).
  static const awg3BoolKeys = <String>{'random_trailers', 'disable_cookies'};

  /// Единственное серверное значение AWG3: ключ защиты заголовка (base64
  /// 32 байт, `awg genkey`), дословно. Валидируется на узел, не на поле
  /// (`awg3NodeError` в uri_utils): без верного ключа хендшейк невозможен,
  /// а ядро отвергает конфиг целиком.
  static const headerKey = 'header_protection_key';

  /// Минимум s1–s4 при заданном [headerKey]: nonce шифра заголовка берётся
  /// из первых 12 байт паддинга.
  static const awg3MinPadding = 12;

  /// Ширина диапазона h1–h4, с которой приёмник сервера начинает путать
  /// data-пакеты с хендшейком при `random_trailers` (docs-lx §2.10).
  static const awg3WideHeaderRange = 65536;

  /// Все AWG3 JSON-ключи корня endpoint (маркер уровня 3.x).
  static const awg3JsonKeys = <String>{
    headerKey, ...awg3RangeKeys, ...awg3BoolKeys,
  };

  /// JSON-ключ → URI/.conf-параметр.
  static String awg3Param(String jsonKey) => jsonKey.replaceAll('_', '');

  /// URI/.conf-параметр → JSON-ключ.
  static final Map<String, String> awg3ParamToJson = {
    for (final k in awg3JsonKeys) awg3Param(k): k,
  };

  static final _uintRe = RegExp(r'^\d+$');
  static const _uint32Max = 0xFFFFFFFF;

  /// Go `strconv.ParseUint(s, 10, 32)`: только цифры, без знака, ≤ 2³²−1.
  static int? _parseUint32(String s) {
    if (!_uintRe.hasMatch(s)) return null;
    final n = int.tryParse(s);
    return (n == null || n > _uint32Max) ? null : n;
  }

  /// Значение AWG3-тайминга: `N` → `int`, `N-M` (N ≤ M, оба uint32) →
  /// нормализованная `String` `"N-M"`, иначе `null`. Границы НЕ свопаются
  /// (в отличие от h1–h4, [_parseHeader]): тайминги клиентские, ядро живёт
  /// на дефолтах, а перевёрнутый диапазон — опечатка, которую человек должен
  /// увидеть (SPEC 123 §2). Эталон Go `parseAWG3Range`.
  static Object? parseAwg3Range(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    final n = _parseUint32(v);
    if (n != null) return n;
    final dash = v.indexOf('-');
    if (dash < 0) return null;
    final lo = _parseUint32(v.substring(0, dash).trim());
    final hi = _parseUint32(v.substring(dash + 1).trim());
    if (lo == null || hi == null || hi < lo) return null;
    return '$lo-$hi';
  }

  /// Булево AWG3: `true` — включено; `false` — выключено/пусто (ключ не
  /// пишется); `null` — мусор (поле снимается с `awg3_field_invalid`).
  /// Эталон Go `parseAWG3Bool`.
  static bool? parseAwg3Bool(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'on':
      case 'true':
      case '1':
        return true;
      case '':
      case 'off':
      case 'false':
      case '0':
        return false;
      default:
        return null;
    }
  }

  /// Маркер AWG3 в query (до сборки узла — им решается политика MTU):
  /// любой непустой AWG3-параметр (даже невалидный) или диапазонный
  /// `keepalive` (`25-35`). Эталон Go `hasAWG3Params`.
  static bool hasAwg3Params(Map<String, String> q) {
    for (final p in awg3ParamToJson.keys) {
      if ((q[p] ?? '').trim().isNotEmpty) return true;
    }
    return (q['keepalive'] ?? '').contains('-');
  }

  /// Маркер AWG3 в endpoint-JSON: любой AWG3-ключ корня с non-null
  /// значением или строковый диапазон `persistent_keepalive_interval` у
  /// любого пира. Эталон Go `HasAWG3Fields`.
  static bool hasAwg3Json(Map<String, dynamic> m) {
    if (awg3JsonKeys.any((k) => m[k] != null)) return true;
    final peers = m['peers'];
    if (peers is List) {
      for (final p in peers) {
        if (p is Map) {
          final ka = p['persistent_keepalive_interval'];
          if (ka is String && ka.contains('-')) return true;
        }
      }
    }
    return false;
  }

  /// Есть ли в полях хоть один AWG3-ключ.
  bool get hasAwg3 => awg3JsonKeys.any(fields.containsKey);

  /// Задан ли ключ защиты заголовка (непустая строка).
  bool get hasHeaderKey =>
      (fields[headerKey] is String) && (fields[headerKey] as String).isNotEmpty;

  /// `random_trailers` вместе с ШИРОКИМ диапазоном h1–h4 (≥ 65536): ничего
  /// не снимается, только info-код `awg3_random_trailers_wide_headers`.
  /// Эталон Go `awg3RandomTrailersWithWideHeaders`.
  bool get randomTrailersWithWideHeaders {
    if (fields['random_trailers'] != true) return false;
    for (final k in headerKeys) {
      final v = fields[k];
      if (v is! String) continue;
      final dash = v.indexOf('-');
      if (dash < 0) continue;
      final lo = int.tryParse(v.substring(0, dash));
      final hi = int.tryParse(v.substring(dash + 1));
      if (lo == null || hi == null) continue;
      if (hi >= lo && hi - lo >= awg3WideHeaderRange) return true;
    }
    return false;
  }

  /// Первое из s1–s4, что меньше [awg3MinPadding] (отсутствие = 0), когда
  /// задан [headerKey]; `null` — всё в порядке или ключа нет.
  String? get paddingTooShortField {
    if (!hasHeaderKey) return null;
    for (final k in const ['s1', 's2', 's3', 's4']) {
      final v = fields[k];
      final n = v is int ? v : 0;
      if (n < awg3MinPadding) return k;
    }
    return null;
  }

  /// §112 — magic headers: с AWG 2.0 значение бывает диапазоном `N-M`
  /// (ranged headers). Подмножество [numKeys] — consumers, проверяющие
  /// наличие ключа (ini_parser, securityLabel), не меняются.
  static const headerKeys = <String>{'h1', 'h2', 'h3', 'h4'};

  /// `N` или `N-M`. Глубже (uint32, start ≤ end, непересечение) не
  /// валидируем: ядро даёт явную ошибку старта, а молчаливый drop
  /// здесь = тихо сломанный handshake (исходный баг §112).
  static final _headerRe = RegExp(r'^\d+(-\d+)?$');

  /// h1–h4: `"5"` → `int 5` (type-fidelity §097), `"N-M"` → `String`
  /// нормализованная к возрастающему порядку (D-031: `300-200` → `200-300`,
  /// эталон Go `parseAWGHeaderRange` — граница диапазона не «другое
  /// значение», а та же пара, без нормализации одна нода даёт два хеша),
  /// мусор → null (поле пропускается, как `jc=abc`).
  static Object? _parseHeader(String v) {
    if (!_headerRe.hasMatch(v)) return null;
    final n = int.tryParse(v);
    if (n != null) return n;
    final parts = v.split('-');
    final lo = int.parse(parts[0]);
    final hi = int.parse(parts[1]);
    return lo <= hi ? v : '$hi-$lo';
  }

  bool get isEmpty => fields.isEmpty;


  /// §463 / контракт §24.6 — `jmin` без `jmax` снимается
  /// (`requires: [{path: jmax, code: awg_header_invalid}]` в
  /// `registry/protocols/wireguard.json`).
  ///
  /// Отсутствующий `jmax` ядро читает как 0 и валит ВЕСЬ конфиг
  /// («amneziawg: jmin (50) must be <= jmax (0)», проверено на
  /// 1.14.0-lx.39) — вердикт B. Раньше одинокий `jmin` доезжал до тела:
  /// `jc=abc` отбрасывался молча, а `jmin=50` оставался и ронял всё.
  ///
  /// Обратная пара (`jmax` без `jmin`) безопасна: `jmin` по умолчанию 0,
  /// и `0 <= jmax` выполняется — реестр её и не требует.
  ///
  /// [dropped] — пути снятых полей для `warnings[]` узла.
  static void applyJunkSizeRequires(Map<String, Object> f,
      {List<String>? dropped}) {
    if (f.containsKey('jmin') && !f.containsKey('jmax')) {
      f.remove('jmin');
      dropped?.add('jmin');
    }
  }

  /// Из endpoint-JSON (корень). Числа: `num`→`int`; h1–h4 также `String`
  /// `"N"`/`"N-M"` (§112, контракт ядра lx.6); `i*`: непустые `String`.
  static Awg? fromJson(Map<String, dynamic> m) {
    final f = <String, Object>{};
    // §472 шаг 7 — ПОРЯДОК: сначала AWG 3.x, потом
    // числовые AWG2 и строковые `i*`. Порядок вставки в `fields` становится
    // порядком ключей в теле узла (`writeInto` — это `addAll`), а тело
    // сравнивается БАЙТ В БАЙТ golden-эталонами (`avd_v0.config.json`).
    // Пока ссылка шла своим парсером, обе воронки жили порознь и разный
    // порядок был не виден; на конвейере ссылка идёт через
    // `parseSingboxEntry`, то есть через ЭТОТ разбор, и расхождение стало бы
    // сдвигом эталона на ровном месте. Значения и identity от порядка не
    // зависят (`legacyNodeIdentityHash` сортирует ключи), но эталон — да.
    // §421 — AWG3: тайминги числом или строкой-диапазоном, булевы только
    // `true`, ключ защиты — непустая строка (валидация — awg3NodeError).
    final hk = m[headerKey];
    if (hk is String && hk.trim().isNotEmpty) f[headerKey] = hk.trim();
    for (final k in awg3RangeKeys) {
      final v = m[k];
      if (v is num) {
        final n = v.toInt();
        if (n >= 0 && n <= _uint32Max) f[k] = n;
      } else if (v is String) {
        final r = parseAwg3Range(v);
        if (r != null) f[k] = r;
      }
    }
    for (final k in awg3BoolKeys) {
      if (m[k] == true) f[k] = true;
    }
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
    // §463 — то же правило `requires`, что и на URI-пути: одинокий `jmin`
    // роняет весь конфиг независимо от того, откуда тело пришло.
    applyJunkSizeRequires(f);
    return f.isEmpty ? null : Awg(f);
  }

  /// В endpoint-map (корень). `int`→JSON number, `String`→JSON string
  /// (h-диапазоны эмитятся строкой — ровно контракт ядра lx.6, §112),
  /// `bool` → `true` (§421; `false` в полях не бывает).
  void writeInto(Map<String, dynamic> m) => m.addAll(fields);

}

class WireguardPeer {
  final String publicKey;
  final String preSharedKey;
  final String endpointHost;
  final int endpointPort;
  final List<String> allowedIps;

  /// `int` секунд, либо §421 AWG3-диапазон `"N-M"` (`String`) — ядро
  /// перевыбирает интервал при каждом взводе таймера. Эмитится как есть.
  final Object? persistentKeepalive;

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

  /// §097 Phase 1 — AmneziaWG2 obfuscation params (null = обычный WG).
  final Awg? awg;

  WireguardSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    required this.privateKey,
    required this.localAddresses,
    required this.peers,
    this.mtu,
    this.awg,
    super.chained,
    super.warnings,
  });

  @override
  String get protocol => 'wireguard';

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitWireguard(this, vars);

  @override
  String toUri() => e.uriViaEngineRequired(this);

  /// §466 — приватный ключ интерфейса уходит в userinfo ссылки. AWG (`awg`
  /// != null) — тот же класс, тот же эмиттер, потому отдельной ветки нет.
  @override
  bool get linkCarriesPrivateKey => privateKey.isNotEmpty;
}

/// §130 — MASQUE (CONNECT-IP over HTTP/3/HTTP-2) для Cloudflare WARP.
///
/// В отличие от [WireguardSpec] эмитится как **Outbound** (не Endpoint) —
/// ядро sing-box-lx (SPEC 021) регистрирует `type:masque` через
/// `outbound.Register`. Ключи — ECDSA P-256 в DER-base64 (см. [MasqueKeys]):
/// [privateKeyDer] = наш приватник (SEC1), [publicKeyDer] = серверный pubkey
/// (PKIX, для pinning). `vhttp` — это версия HTTP (`h3`/`h2`), не L4-сеть и не
/// [TransportSpec] других протоколов (там `transport` — это ws/grpc/httpupgrade).
final class MasqueSpec extends NodeSpec {
  /// base64(SEC1 DER) нашего ECDSA-приватника. СЕКРЕТ.
  final String privateKeyDer;

  /// base64(PKIX DER) серверного ECDSA-pubkey (pinning).
  final String publicKeyDer;

  /// Локальные адреса туннеля (CIDR): [v4, v6]. Хотя бы один обязателен.
  final List<String> localAddresses;

  /// `cloudflare` (дефолт) | `standard`.
  final String profile;

  /// Версия HTTP: `h3` (QUIC, дефолт) | `h2` | `auto` (h3 с откатом на h2,
  /// контракт 0.11.1, ядро >= lx.27). §393 — в конфиге ядра ключ `vhttp`;
  /// старое имя `network` не принимается (контракт 0.8.0, D-078).
  ///
  /// Имя поля НЕ `transport`: у остальных протоколов так называется
  /// [TransportSpec] (ws/grpc/httpupgrade) — совсем другая сущность.
  final String vhttp;

  /// TLS SNI (`tls.server_name` в конфиге). Пусто = дефолт ядра, с lx.25-rc.4
  /// это `www.cloudflare.com` (было `consumer-masque.cloudflareclient.com`).
  /// Пустой SNI — НЕ то же самое, что [disableSni]: пустой подменяется дефолтом
  /// профиля, а `disable_sni` убирает расширение из ClientHello совсем.
  final String sni;

  /// §393 — `tls.disable_sni`: ClientHello без SNI. UI не выставляет, задаётся
  /// через URI/JSON-импорт и редактор конфига.
  final bool disableSni;

  final int? mtu;

  /// idle-suspend туннеля (Go-duration, напр. `5m`). Пусто = дефолт ядра (5m);
  /// отрицательное (`-1s`) = выключить. См. [§128](../128%20idle-suspend/).
  final String idleTimeout;

  /// QUIC keepalive-период (Go-duration, напр. `30s`). Пусто = дефолт (30s);
  /// отрицательное = выключить. Только для `vhttp=h3`.
  final String keepAlive;

  MasqueSpec({
    required super.id,
    required super.tag,
    required super.label,
    required super.server,
    required super.port,
    required super.rawSource,
    required this.privateKeyDer,
    required this.publicKeyDer,
    required this.localAddresses,
    this.profile = 'cloudflare',
    this.vhttp = 'h3',
    this.sni = '',
    this.disableSni = false,
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
  String toUri() => e.uriViaEngineRequired(this);

  /// §466 — `toUriMasque` кладёт [privateKeyDer] (SEC1 DER нашего ECDSA) в
  /// userinfo ссылки.
  @override
  bool get linkCarriesPrivateKey => privateKeyDer.isNotEmpty;
}

// ════════════════════════════════════════════════════════════════════════════
// Узел автовыбора (§322)
// ════════════════════════════════════════════════════════════════════════════

/// Пул серверов, внутри которого ядро само выбирает выход (`urltest`).
///
/// В отличие от остальных вариантов [NodeSpec] это **не соединение**, а
/// правило выбора среди уже существующих узлов — у него нет ни `server`, ни
/// `port` (оба пустые, см. [isGroup]). Тот же водораздел, что у DNS-группы в
/// §319: у группы нет адреса и транспорта.
///
/// Инвариант (§322 §2): узел **не покидает свой контейнер** — он ссылается на
/// членов той же подписки/папки. Границу обеспечивает сам билдер: резолв
/// состава идёт по узлам текущего контейнера и дальше не смотрит. Отдельного
/// поля-владельца нет — оно дублировало бы эту границу и могло с ней разойтись.
final class AutoSelectSpec extends NodeSpec {
  /// Как набирается пул (§322 §3.1).
  final AutoSelectMembership membership;

  /// Параметры urltest, смапленные из Xray-стратегии (§322 §4).
  final AutoSelectParams params;

  /// §322 — regexp, которым из имени члена пула добывается значок для строки
  /// списка (по умолчанию — первый флаг-эмодзи, [kDefaultPoolBadge]).
  /// **UI-only:** в конфиг не уходит, ядру неизвестен. Пусто = значки не
  /// показываем.
  final String poolBadge;

  /// §321 P6 — теги провайдера → идентичности. Нужна, чтобы `include` из
  /// `selector` (написанный на ЧУЖИХ тегах) находил наши узлы после дедупа.
  /// Производное от тела подписки, как `sourceExtended` (§302).
  final Map<String, String> tagSynonyms;

  AutoSelectSpec({
    required super.id,
    required super.tag,
    required super.label,
    this.membership = const RuleMembers(),
    this.params = const AutoSelectParams(),
    this.tagSynonyms = const {},
    this.poolBadge = kDefaultPoolBadge,
    super.warnings,
    // §454 — у группы из sing-box-конфига источник — её объект; у групп,
    // собранных приложением (§208, папки), источника нет.
    super.rawSource = '',
  }) : super(server: '', port: 0);

  @override
  String get protocol => 'urltest';

  @override
  bool get isGroup => true;

  @override
  bool get isAddressless => true;

  /// Эмиссия у этого узла особая: состав пула известен только билдеру (теги
  /// членов присваиваются `allocateTag` уже после `getEntries`), поэтому
  /// собственный `emitRaw` отдаёт заготовку БЕЗ `outbounds` — билдер
  /// дописывает их сам (см. `auto_select_build.dart`).
  @override
  SingboxEntry emitRaw(TemplateVars vars) => Outbound({
        'tag': tag,
        'type': 'urltest',
        'outbounds': <String>[],
        ...params.toJson(),
      });

  /// URI-формы у группы нет: в папке она хранится записью `kind: auto`
  /// (§439, кодек `codec/auto_group_record.dart`), в подписке производна от
  /// тела. Пустая строка — «ссылки нет».
  @override
  String toUri() => '';

  /// Значение группы — то, что хранит запись `kind: auto`: тег, подпись,
  /// членство, параметры, значки. `id` (рантайм) и [tagSynonyms] (производное
  /// от тела подписки) в значение не входят.
  bool sameGroupAs(AutoSelectSpec other) =>
      tag == other.tag &&
      label == other.label &&
      membership == other.membership &&
      params == other.params &&
      poolBadge == other.poolBadge;

  AutoSelectSpec copyWith({
    String? tag,
    String? label,
    AutoSelectMembership? membership,
    AutoSelectParams? params,
    Map<String, String>? tagSynonyms,
    String? poolBadge,
  }) =>
      AutoSelectSpec(
        id: id,
        tag: tag ?? this.tag,
        label: label ?? this.label,
        membership: membership ?? this.membership,
        params: params ?? this.params,
        tagSynonyms: tagSynonyms ?? this.tagSynonyms,
        poolBadge: poolBadge ?? this.poolBadge,
        warnings: warnings,
        rawSource: rawSource,
      );
}

// ════════════════════════════════════════════════════════════════════════════
// Tailscale (§435, контракт ## 13) — endpoint без адреса
// ════════════════════════════════════════════════════════════════════════════

/// Узел Tailscale (`type: tailscale`, sing-box ≥ 1.12 endpoint): tsnet в
/// user-space сам входит в tailnet по `auth_key`, адреса на верхнем уровне у
/// него нет. URI-формы у схемы нет — узел приходит из sing-box JSON или из
/// мастера «Add server → Tailscale».
///
/// Тело хранится **как есть** ([body]): контракт его не типизирует, а
/// типизация потеряла бы незнакомое молча (`auth_key`, `control_url`,
/// `hostname`, `ephemeral`, `accept_routes`, `exit_node`,
/// `exit_node_allow_lan_access`, `advertise_routes`, `state_directory`,
/// dial-поля …). Без `type`/`tag`/`detour`: тип и тег — метаданные, detour —
/// через [chained], как у всех.
final class TailscaleSpec extends NodeSpec {
  final Map<String, dynamic> body;

  TailscaleSpec({
    required super.id,
    required super.tag,
    required super.label,
    Map<String, dynamic> body = const {},
    super.rawSource = '',
    super.chained,
    super.warnings,
  })  : body = _stripMeta(body),
        super(server: '', port: 0);

  static Map<String, dynamic> _stripMeta(Map<String, dynamic> raw) {
    final copy = deepCopyJson(raw) as Map<String, dynamic>;
    copy
      ..remove('type')
      ..remove('tag')
      ..remove('detour');
    return copy;
  }

  @override
  String get protocol => 'tailscale';

  @override
  bool get isAddressless => true;

  /// Непустой `exit_node` — узел выпускает в интернет и годится в
  /// Направления; без него он только даёт доступ в tailnet (NODE_SECTIONS.md
  /// §6): в пул Направлений не идёт, но законен как `detour` и `outbound`.
  bool get hasExitNode {
    final v = body['exit_node'];
    return v is String && v.trim().isNotEmpty;
  }

  @override
  SingboxEntry emitRaw(TemplateVars vars) => e.emitTailscale(this, vars);

  /// Канонический текст узла — JSON endpoint'а с `tag` (URI-формы нет).
  /// `decode()` разбирает его обратно как `singboxOutbound`, поэтому
  /// `rawBody`/`raw` члена папки, переименование и эмодзи работают без
  /// отдельных веток.
  @override
  String toUri() => e.toUriTailscale(this);

  TailscaleSpec copyWith({
    String? tag,
    String? label,
    Map<String, dynamic>? body,
    NodeSpec? chained,
  }) =>
      TailscaleSpec(
        id: id,
        tag: tag ?? this.tag,
        label: label ?? this.label,
        body: body ?? this.body,
        rawSource: rawSource,
        chained: chained ?? this.chained,
        warnings: warnings,
      );
}

/// §368 — пересборка узла с detour-звеном.
///
/// `NodeSpec` иммутабелен и общего `copyWith` в базе нет, поэтому ветвим по
/// типу. Обобщение приватного `_withChain` из §321 (там были только VLESS и
/// Trojan — единственные, у кого Xray-`dialerProxy` встречается на практике):
/// в sing-box `detour` живёт на любом outbound'е, и звеном может стать любой
/// тип, кроме группы.
///
/// Группа цепочку не несёт (`AutoSelectSpec` без `chained`) — возвращаем как
/// есть; вызывающий такую ссылку отсеивает раньше, с warning'ом (§4 P5).
NodeSpec withChained(NodeSpec spec, NodeSpec chained) => switch (spec) {
      TailscaleSpec s => s.copyWith(chained: chained),
      VlessSpec s => VlessSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          uuid: s.uuid,
          flow: s.flow,
          tls: s.tls,
          transport: s.transport,
          packetEncoding: s.packetEncoding,
          encryption: s.encryption,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      VmessSpec s => VmessSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          uuid: s.uuid,
          alterId: s.alterId,
          security: s.security,
          tls: s.tls,
          transport: s.transport,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      TrojanSpec s => TrojanSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          password: s.password,
          tls: s.tls,
          transport: s.transport,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      AnyTlsSpec s => AnyTlsSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          password: s.password,
          tls: s.tls,
          idleSessionCheckInterval: s.idleSessionCheckInterval,
          idleSessionTimeout: s.idleSessionTimeout,
          minIdleSession: s.minIdleSession,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      ShadowsocksSpec s => ShadowsocksSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          method: s.method,
          password: s.password,
          plugin: s.plugin,
          pluginOpts: s.pluginOpts,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      Hysteria2Spec s => Hysteria2Spec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          password: s.password,
          obfs: s.obfs,
          obfsPassword: s.obfsPassword,
          obfsMinPacketSize: s.obfsMinPacketSize,
          obfsMaxPacketSize: s.obfsMaxPacketSize,
          tls: s.tls,
          upMbps: s.upMbps,
          downMbps: s.downMbps,
          chained: chained,
          warnings: s.warnings,
        ),
      NaiveSpec s => NaiveSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          username: s.username,
          password: s.password,
          tls: s.tls,
          extraHeaders: s.extraHeaders,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      TuicSpec s => TuicSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          uuid: s.uuid,
          password: s.password,
          congestionControl: s.congestionControl,
          udpRelayMode: s.udpRelayMode,
          zeroRtt: s.zeroRtt,
          tls: s.tls,
          heartbeat: s.heartbeat,
          chained: chained,
          warnings: s.warnings,
        ),
      SshSpec s => SshSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          user: s.user,
          password: s.password,
          privateKey: s.privateKey,
          privateKeyPassphrase: s.privateKeyPassphrase,
          hostKey: s.hostKey,
          hostKeyAlgorithms: s.hostKeyAlgorithms,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      SocksSpec s => SocksSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          version: s.version,
          username: s.username,
          password: s.password,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      HttpSpec s => HttpSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          username: s.username,
          password: s.password,
          path: s.path,
          headers: s.headers,
          tls: s.tls,
          chained: chained,
          tcpKeepAlive: s.tcpKeepAlive,
          warnings: s.warnings,
        ),
      WireguardSpec s => WireguardSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          privateKey: s.privateKey,
          localAddresses: s.localAddresses,
          peers: s.peers,
          mtu: s.mtu,
          awg: s.awg,
          chained: chained,
          warnings: s.warnings,
        ),
      MasqueSpec s => MasqueSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawSource: s.rawSource,
          privateKeyDer: s.privateKeyDer,
          publicKeyDer: s.publicKeyDer,
          localAddresses: s.localAddresses,
          profile: s.profile,
          vhttp: s.vhttp,
          sni: s.sni,
          disableSni: s.disableSni,
          mtu: s.mtu,
          idleTimeout: s.idleTimeout,
          keepAlive: s.keepAlive,
          chained: chained,
          warnings: s.warnings,
        ),
      AutoSelectSpec s => s,
    };
