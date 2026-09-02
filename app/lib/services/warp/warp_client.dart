import 'dart:convert';
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../../models/node_spec.dart' show Awg;
import '../app_log.dart';
import 'masque_account.dart';
import 'masque_keys.dart';
import 'masquerade_params.dart';
import 'warp_account.dart';

/// §025 — клиент регистрации Cloudflare WARP.
///
/// Делает то же, что официальный клиент / `wgcf`: генерит X25519-пару НА
/// УСТРОЙСТВЕ и регистрирует только публичный ключ через
/// `api.cloudflareclient.com`. Приватник не покидает телефон. НЕ ходим на
/// сторонние воркеры-генераторы — они отдают приватник со своего сервера.
class WarpException implements Exception {
  WarpException(this.message);
  final String message;
  @override
  String toString() => 'WarpException: $message';
}

/// Версия пути и заголовок клиента. ВЫНЕСЕНО в одно место намеренно: Cloudflare
/// периодически бампает версию, тогда правка — здесь. Перед релизом сверять с
/// актуальным `wgcf`/`warp-cli`.
class WarpApi {
  static const String base = 'https://api.devices.cloudflare.com';
  static const String version = 'v0a2158';
  static const String clientVersionHeader = 'a-7.21-0721';
  static const String userAgent = 'okhttp/3.12.1';

  static Uri reg() => Uri.parse('$base/$version/reg');
  static Uri account(String deviceId) =>
      Uri.parse('$base/$version/reg/$deviceId/account');

  /// §130 — PATCH `/reg/{id}` для MASQUE-enroll (смена ключа на ECDSA).
  static Uri device(String deviceId) =>
      Uri.parse('$base/$version/reg/$deviceId');

  static Map<String, String> headers({String? bearer}) => {
        'Content-Type': 'application/json',
        'User-Agent': userAgent,
        'CF-Client-Version': clientVersionHeader,
        if (bearer != null) 'Authorization': 'Bearer $bearer',
      };
}

class WarpClient {
  WarpClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 15);

  final http.Client _client;
  final Duration _timeout;

  /// Генерирует X25519-пару. Возвращает (privateBase64, publicBase64) — оба
  /// raw 32 байта в standard base64 (формат, который ждёт Cloudflare и
  /// WireGuard).
  static Future<({String priv, String pub})> genKeypair() async {
    final algo = X25519();
    final pair = await algo.newKeyPair();
    final privBytes = await pair.extractPrivateKeyBytes();
    final pubKey = await pair.extractPublicKey();
    return (
      priv: base64.encode(privBytes),
      pub: base64.encode(pubKey.bytes),
    );
  }

  /// §126/§136 — AmneziaWG preset (без `i1` — он генерится на устройстве).
  ///
  /// Только поля, которые НЕ ломают WG: `s1=s2=0` (handshake без magic-префикса)
  /// + `h1..h4=1,2,3,4` (стандартные WG message-types) → init/response пакеты
  /// бит-в-бит как plain WireGuard, Cloudflare принимает. `jc`+`i1` (junk до
  /// handshake) сбивают DPI-сигнатуру. [jc]/[jmin]/[jmax] — настраиваемые
  /// (§136 Advanced), дефолт 4/40/70. См. [docs/spec/tasks/126], [136].
  static Map<String, Object> amneziaPreset({
    int jc = 4,
    int jmin = 40,
    int jmax = 70,
  }) =>
      <String, Object>{
        'jc': jc,
        'jmin': jmin,
        'jmax': jmax,
        's1': 0,
        's2': 0,
        'h1': 1,
        'h2': 2,
        'h3': 3,
        'h4': 4,
      };

  /// §143 — собирает [Awg] для obfuscate-ветки через masquerade `id/ip/ib`
  /// (ядро 009 само разворачивает в `i1`; LxBox `i1` НЕ генерит).
  ///
  /// - `ip` = протокол ([QuicParams.ip]: quic/dns/stun/sip).
  /// - `id` = домен ([QuicParams.sni], пустой → `www.google.com`); на провод идёт
  ///   только для `dns` (QNAME) / `sip` (host), для quic/stun декоративен.
  /// - `ib` = браузер ([QuicParams.ib]) — только при `ip=quic`.
  ///
  /// **Не пишем `i1`** — `id/ip/ib` взаимоисключающи с явным `i1` (ядро отвергает оба).
  static Awg buildAmneziaAwg(QuicParams params) {
    final sni = params.sni.trim();
    final domain = sni.isEmpty ? 'www.google.com' : sni;
    final ip = params.ip.trim().isEmpty ? 'quic' : params.ip.trim();

    final fields = amneziaPreset(
        jc: params.jc, jmin: params.jmin, jmax: params.jmax)
      ..['ip'] = ip
      ..['id'] = domain;
    if (ip == 'quic') {
      fields['ib'] = params.ib.trim().isEmpty ? 'chrome' : params.ib.trim();
    }
    return Awg(fields);
  }

  /// Регистрирует устройство. Опциональный [licenseKey] — WARP+; если задан,
  /// после /reg делается PATCH account (ошибка PATCH НЕ роняет регистрацию —
  /// возвращается free-аккаунт с warpPlus=false).
  ///
  /// §126/§143 — если [obfuscate] true, в аккаунт кладётся [Awg] из preset +
  /// masquerade `id/ip/ib` из [quicParams] (i1 генерит ядро). Сама регистрация
  /// в Cloudflare не меняется (обфускация — чисто клиентский конфиг).
  ///
  /// §136 — [randomEndpoint] (если задан): когда obfuscate=true И [endpoint]
  /// дефолтный, endpoint заменяется на рандомный `ip:port` из зашитых
  /// Cloudflare-блоков (заблокированный `engage…:2408` обходится без скана).
  Future<WarpAccount> register({
    String? licenseKey,
    String endpoint = WarpAccount.defaultEndpoint,
    required String nowIso8601,
    bool obfuscate = false,
    QuicParams? quicParams,
    String? randomEndpoint,
  }) async {
    final kp = await genKeypair();

    final body = jsonEncode({
      'key': kp.pub,
      'install_id': '',
      'fcm_token': '',
      'tos': nowIso8601,
      'model': 'PC',
      'type': 'Android',
      'locale': 'en_US',
    });

    final http.Response resp;
    try {
      resp = await _client
          .post(WarpApi.reg(), headers: WarpApi.headers(), body: body)
          .timeout(_timeout);
    } catch (e) {
      throw WarpException('network error: $e');
    }

    if (resp.statusCode != 200) {
      throw WarpException(
          'registration failed (HTTP ${resp.statusCode}). API version may '
          'have changed (${WarpApi.version}).');
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw WarpException('bad response: not JSON');
    }

    // §136 — рандомный endpoint при обфускации + дефолтном endpoint. Юзер
    // вписал свой (не дефолт) → уважаем его (§135), рандом не применяем.
    var effectiveEndpoint = endpoint;
    if (obfuscate &&
        endpoint == WarpAccount.defaultEndpoint &&
        randomEndpoint != null &&
        randomEndpoint.isNotEmpty) {
      effectiveEndpoint = randomEndpoint;
      AppLog.I.info('WARP: random endpoint $randomEndpoint');
    }

    var account = _parseReg(json, privKey: kp.priv, endpoint: effectiveEndpoint,
        createdAt: nowIso8601);
    AppLog.I.info('WARP registered: ${account.redacted()}');

    if (licenseKey != null && licenseKey.trim().isNotEmpty) {
      account = await _applyLicenseSafe(account, licenseKey.trim());
    }
    if (obfuscate) {
      account =
          account.copyWith(awg: buildAmneziaAwg(quicParams ?? const QuicParams()));
      AppLog.I.info('WARP: Amnezia obfuscation enabled (ip=${(quicParams ?? const QuicParams()).ip})');
    }
    return account;
  }

  WarpAccount _parseReg(
    Map<String, dynamic> json, {
    required String privKey,
    required String endpoint,
    required String createdAt,
  }) {
    final deviceId = (json['id'] as String?) ?? '';
    final token = (json['token'] as String?) ?? '';
    final account = json['account'];
    final accountId =
        (account is Map ? account['id'] as String? : null) ?? '';

    final config = json['config'];
    if (config is! Map) {
      throw WarpException('bad response: missing config');
    }
    final clientId = (config['client_id'] as String?) ?? '';

    // §135 — кастомный endpoint из Advanced ПРИОРИТЕТНЕЕ ответа Cloudflare.
    // Cloudflare всегда возвращает `peer.endpoint.host` = дефолтный
    // `engage.cloudflareclient.com:2408`; раньше он безусловно затирал ввод
    // юзера → Advanced-поле Endpoint было мёртвым (юзер вписывал
    // `188.114.97.6:988`, в конфиг шёл дефолт). Теперь: юзер явно задал
    // не-дефолтный endpoint → уважаем его, ответ API игнорируем. Оставил
    // дефолт → берём `host` из ответа Cloudflare как fallback.
    final userPickedEndpoint = endpoint != WarpAccount.defaultEndpoint;
    final peersRaw = config['peers'];
    String peerPub = '';
    String host = endpoint;
    if (peersRaw is List && peersRaw.isNotEmpty && peersRaw.first is Map) {
      final peer = peersRaw.first as Map;
      peerPub = (peer['public_key'] as String?) ?? '';
      final ep = peer['endpoint'];
      if (ep is Map && !userPickedEndpoint) {
        final h = (ep['host'] as String?) ?? '';
        if (h.isNotEmpty) host = h;
      }
    }
    if (peerPub.isEmpty) {
      throw WarpException('bad response: missing peer public_key');
    }

    final iface = config['interface'];
    String v4 = '', v6 = '';
    if (iface is Map) {
      final addrs = iface['addresses'];
      if (addrs is Map) {
        v4 = (addrs['v4'] as String?) ?? '';
        v6 = (addrs['v6'] as String?) ?? '';
      }
    }
    if (v4.isEmpty) {
      throw WarpException('bad response: missing interface address');
    }

    return WarpAccount(
      privKey: privKey,
      peerPub: peerPub,
      clientV4: v4,
      clientV6: v6,
      clientId: clientId,
      accountId: accountId,
      deviceId: deviceId,
      token: token,
      endpoint: host,
      createdAt: createdAt,
    );
  }

  /// §130 — регистрирует MASQUE-устройство. ДВА шага (usque/mihomo):
  ///   1. POST /reg с фиктивным WG-ключом → `id` + `token`.
  ///   2. PATCH /reg/{id} (Bearer) с ECDSA-паблик, `key_type=secp256r1`,
  ///      `tunnel_type=masque` → серверный pubkey + interface addresses + endpoint.
  ///
  /// Приватник ECDSA генерится на устройстве ([MasqueKeys]) и не покидает телефон.
  ///
  /// §393 — транспорт (h3/h2) здесь не участвует: регистрация от него не зависит,
  /// он выбирается при сборке узла.
  Future<MasqueAccount> registerMasque({
    required String nowIso8601,
    String? sni,
    String? idleTimeout,
    String? keepAlive,
  }) async {
    final keys = MasqueKeys.generate();

    // Шаг 1 — обычный POST /reg (фиктивный WG-ключ, mimic Android app).
    final regBody = jsonEncode({
      'key': _randomWgKeyB64(),
      'install_id': '',
      'fcm_token': '',
      'tos': nowIso8601,
      'model': 'PC',
      'type': 'Android',
      'locale': 'en_US',
    });

    final http.Response regResp;
    try {
      regResp = await _client
          .post(WarpApi.reg(), headers: WarpApi.headers(), body: regBody)
          .timeout(_timeout);
    } catch (e) {
      throw WarpException('network error: $e');
    }
    if (regResp.statusCode != 200) {
      throw WarpException(
          'MASQUE registration failed (HTTP ${regResp.statusCode}). API '
          'version may have changed (${WarpApi.version}).');
    }
    final Map<String, dynamic> regJson;
    try {
      regJson = jsonDecode(regResp.body) as Map<String, dynamic>;
    } catch (_) {
      throw WarpException('bad response: not JSON');
    }
    final deviceId = (regJson['id'] as String?) ?? '';
    final token = (regJson['token'] as String?) ?? '';
    if (deviceId.isEmpty || token.isEmpty) {
      throw WarpException('bad response: missing id/token for MASQUE enroll');
    }

    // Шаг 2 — PATCH enroll: подменяем ключ на ECDSA, тип на masque.
    final patchBody = jsonEncode({
      'key': keys.publicKeyDer,
      'key_type': 'secp256r1',
      'tunnel_type': 'masque',
    });
    final http.Response patchResp;
    try {
      patchResp = await _client
          .patch(WarpApi.device(deviceId),
              headers: WarpApi.headers(bearer: token), body: patchBody)
          .timeout(_timeout);
    } catch (e) {
      throw WarpException('network error (MASQUE enroll): $e');
    }
    if (patchResp.statusCode != 200) {
      throw WarpException(
          'MASQUE enroll failed (HTTP ${patchResp.statusCode}). This API '
          'version (${WarpApi.version}) may not support MASQUE.');
    }
    final Map<String, dynamic> patchJson;
    try {
      patchJson = jsonDecode(patchResp.body) as Map<String, dynamic>;
    } catch (_) {
      throw WarpException('bad response: MASQUE enroll not JSON');
    }

    final account = _parseMasqueEnroll(
      patchJson,
      privKeyDer: keys.privateKeyDer,
      deviceId: deviceId,
      token: token,
      createdAt: nowIso8601,
      sni: sni ?? '',
      idleTimeout: idleTimeout ?? '',
      keepAlive: keepAlive ?? '',
    );
    AppLog.I.info('MASQUE registered: ${account.redacted()}');
    return account;
  }

  MasqueAccount _parseMasqueEnroll(
    Map<String, dynamic> json, {
    required String privKeyDer,
    required String deviceId,
    required String token,
    required String createdAt,
    required String sni,
    required String idleTimeout,
    required String keepAlive,
  }) {
    final config = json['config'];
    if (config is! Map) {
      throw WarpException('bad response: missing config (MASQUE)');
    }

    // interface addresses (наш ip/ipv6)
    String v4 = '', v6 = '';
    final iface = config['interface'];
    if (iface is Map) {
      final addrs = iface['addresses'];
      if (addrs is Map) {
        v4 = (addrs['v4'] as String?) ?? '';
        v6 = (addrs['v6'] as String?) ?? '';
      }
    }
    if (v4.isEmpty && v6.isEmpty) {
      throw WarpException('bad response: missing interface address (MASQUE)');
    }

    // peers[0]: серверный pubkey + data-plane endpoint
    String serverPub = '';
    String server = MasqueAccount.defaultServer;
    int port = MasqueAccount.defaultPort;
    final peersRaw = config['peers'];
    if (peersRaw is List && peersRaw.isNotEmpty && peersRaw.first is Map) {
      final peer = peersRaw.first as Map;
      serverPub = (peer['public_key'] as String?) ?? '';
      final ep = peer['endpoint'];
      if (ep is Map) {
        final host = _stripEndpointHost((ep['v4'] as String?) ?? '');
        if (host.isNotEmpty) server = host;
        final ports = ep['ports'];
        if (ports is List && ports.isNotEmpty && ports.first is num) {
          port = (ports.first as num).toInt();
        }
      }
    }
    if (serverPub.isEmpty) {
      throw WarpException('bad response: missing server public_key (MASQUE)');
    }

    return MasqueAccount(
      privKeyDer: privKeyDer,
      // CF отдаёт серверный pubkey как PEM → чистый base64(DER) для ядра.
      serverPubDer: MasqueKeys.normalizeServerPubKey(serverPub),
      clientV4: v4,
      clientV6: v6,
      server: server,
      port: port == 0 ? MasqueAccount.defaultPort : port,
      deviceId: deviceId,
      token: token,
      createdAt: createdAt,
      sni: sni,
      idleTimeout: idleTimeout,
      keepAlive: keepAlive,
    );
  }

  /// Снимает `:0`-заглушку с endpoint (`162.159.198.1:0` → `162.159.198.1`).
  static String _stripEndpointHost(String raw) {
    final i = raw.lastIndexOf(':');
    if (i <= 0) return raw;
    return raw.substring(0, i);
  }

  /// 32 случайных байта в base64 — фиктивный WG-pubkey для POST /reg (его роль —
  /// только сымитировать регистрацию Android-клиента; реальный ключ идёт в PATCH).
  static String _randomWgKeyB64() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64.encode(bytes);
  }

  /// PATCH account с license. Безопасный: при любой ошибке возвращает исходный
  /// (free) аккаунт — узел всё равно добавится, просто без WARP+.
  Future<WarpAccount> _applyLicenseSafe(
      WarpAccount acc, String license) async {
    if (acc.deviceId.isEmpty || acc.token.isEmpty) {
      AppLog.I.warning('WARP: cannot apply license — no device id/token');
      return acc.copyWith(license: license);
    }
    try {
      final resp = await _client
          .patch(
            WarpApi.account(acc.deviceId),
            headers: WarpApi.headers(bearer: acc.token),
            body: jsonEncode({'license': license}),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        AppLog.I.warning('WARP: license not applied (HTTP ${resp.statusCode})');
        return acc.copyWith(license: license);
      }
      final json = jsonDecode(resp.body);
      final warpPlus =
          json is Map && (json['warp_plus'] == true ||
              (json['account'] is Map && json['account']['warp_plus'] == true));
      AppLog.I.info('WARP+ license applied: warp_plus=$warpPlus');
      return acc.copyWith(license: license, warpPlus: warpPlus);
    } catch (e) {
      AppLog.I.warning('WARP: license apply failed: $e');
      return acc.copyWith(license: license);
    }
  }

  void close() => _client.close();
}
