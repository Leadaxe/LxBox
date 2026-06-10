import 'dart:convert';
import 'dart:io';

import 'body_decoder.dart';
import 'uri_utils.dart';

/// §110 — декод Amnezia `vpn://`-ссылки в WG/AWG INI-тексты.
///
/// Формат (amnezia-client `ExportController` / `config-decoder`):
/// `vpn://` + base64url (без padding) от `qCompress(JSON, 8)`, где qCompress =
/// 4 байта big-endian длины + zlib-поток. Несжатый payload (голый
/// base64-JSON) тоже валиден — importController Amnezia пробует оба варианта.
///
/// Из JSON берём `containers[]` → под-объекты `awg`/`wireguard` →
/// `last_config.config` (готовый INI). Остальные протоколы Amnezia
/// (openvpn/xray/…) скипаются. Не throws.
DecodedBody decodeAmneziaLink(String link) {
  final t = link.trim();
  if (!t.startsWith('vpn://')) {
    return const DecodeFailure('not a vpn:// link');
  }
  if (t.length > maxURILength) {
    return const DecodeFailure('vpn://: link too long');
  }

  final bytes = decodeBase64Safe(t.substring('vpn://'.length));
  if (bytes == null) return const DecodeFailure('vpn://: invalid base64');

  final json = _inflate(bytes);
  if (json == null) {
    return const DecodeFailure('vpn://: payload is neither qCompress nor JSON');
  }

  Object root;
  try {
    root = jsonDecode(json);
  } catch (_) {
    return const DecodeFailure('vpn://: payload is not valid JSON');
  }
  if (root is! Map<String, dynamic>) {
    return const DecodeFailure('vpn://: root is not an object');
  }

  final containers = root['containers'];
  if (containers is! List || containers.isEmpty) {
    return const DecodeFailure('vpn://: no containers[]');
  }

  final inis = <String>[];
  for (final c in containers) {
    if (c is! Map) continue;
    for (final proto in const ['awg', 'wireguard']) {
      final ini = _extractIni(c[proto]);
      if (ini != null) inis.add(_substituteDns(ini, root));
    }
  }
  if (inis.isEmpty) {
    return const DecodeFailure('vpn://: no WireGuard/AmneziaWG containers');
  }
  return AmneziaConfig(inis);
}

/// Анти-bomb cap на claimed uncompressed size из qCompress-заголовка.
const int _maxInflated = 4 << 20; // 4 MiB

/// qCompress-payload → UTF-8 JSON. Fallback: payload уже несжатый JSON.
String? _inflate(List<int> bytes) {
  if (bytes.length > 4) {
    final claimed = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    if (claimed <= _maxInflated) {
      try {
        return utf8.decode(zlib.decode(bytes.sublist(4)));
      } catch (_) {
        // Не zlib — пробуем как несжатый payload ниже.
      }
    }
  }
  try {
    final s = utf8.decode(bytes);
    return s.trimLeft().startsWith('{') ? s : null;
  } catch (_) {
    return null;
  }
}

/// Под-объект протокола (`awg`/`wireguard`) → INI из `last_config.config`.
/// `last_config` в экспортах — JSON-строка; защитно принимаем и Map.
String? _extractIni(Object? protoObj) {
  if (protoObj is! Map) return null;
  Object? lastConfig = protoObj['last_config'];
  if (lastConfig is String) {
    try {
      lastConfig = jsonDecode(lastConfig);
    } catch (_) {
      return null;
    }
  }
  if (lastConfig is! Map) return null;
  final ini = lastConfig['config'];
  if (ini is! String) return null;
  if (!ini.contains('[Interface]') || !ini.contains('[Peer]')) return null;
  return ini;
}

/// `$PRIMARY_DNS`/`$SECONDARY_DNS` ← корневые `dns1`/`dns2`. Парсу не
/// мешают и без подстановки (INI-парсер DNS игнорирует) — это fidelity
/// сохраняемого rawIni.
String _substituteDns(String ini, Map<String, dynamic> root) {
  var out = ini;
  final dns1 = root['dns1'];
  final dns2 = root['dns2'];
  if (dns1 is String && dns1.isNotEmpty) {
    out = out.replaceAll(r'$PRIMARY_DNS', dns1);
  }
  if (dns2 is String && dns2.isNotEmpty) {
    out = out.replaceAll(r'$SECONDARY_DNS', dns2);
  }
  return out;
}
