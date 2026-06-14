import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../app_log.dart';
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
  static const String base = 'https://api.cloudflareclient.com';
  static const String version = 'v0a2158';
  static const String clientVersionHeader = 'a-7.21-0721';
  static const String userAgent = 'okhttp/3.12.1';

  static Uri reg() => Uri.parse('$base/$version/reg');
  static Uri account(String deviceId) =>
      Uri.parse('$base/$version/reg/$deviceId/account');

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

  /// Регистрирует устройство. Опциональный [licenseKey] — WARP+; если задан,
  /// после /reg делается PATCH account (ошибка PATCH НЕ роняет регистрацию —
  /// возвращается free-аккаунт с warpPlus=false).
  Future<WarpAccount> register({
    String? licenseKey,
    String endpoint = WarpAccount.defaultEndpoint,
    required String nowIso8601,
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

    var account = _parseReg(json, privKey: kp.priv, endpoint: endpoint,
        createdAt: nowIso8601);
    AppLog.I.info('WARP registered: ${account.redacted()}');

    if (licenseKey != null && licenseKey.trim().isNotEmpty) {
      account = await _applyLicenseSafe(account, licenseKey.trim());
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

    final peersRaw = config['peers'];
    String peerPub = '';
    String host = endpoint;
    if (peersRaw is List && peersRaw.isNotEmpty && peersRaw.first is Map) {
      final peer = peersRaw.first as Map;
      peerPub = (peer['public_key'] as String?) ?? '';
      final ep = peer['endpoint'];
      if (ep is Map) {
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
