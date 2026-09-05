import 'dart:convert';
import 'dart:io';

import '../../models/node_spec.dart';
import 'body_decoder.dart';
import 'ini_parser.dart';
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
  if (t.length > maxAmneziaLinkLength) {
    return const DecodeFailure('vpn://: link too long');
  }

  final root = _decodeAmneziaRoot(t);
  if (root == null) {
    return const DecodeFailure('vpn://: payload is neither qCompress nor JSON');
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

/// §103 §9.B12 — `vpn://` строкой ВНУТРИ построчного URI-списка подписки
/// (не как тело целиком — тот путь идёт через [decodeAmneziaLink] из
/// body_decoder). Go принимает такую строку в обход MaxURILength через
/// ParseNode; Dart parseUri() раньше не имел ветки vpn — строка молча
/// терялась (разрыв, целевое: Dart добавляет).
///
/// В отличие от body-пути (все контейнеры → нода на контейнер), одиночная
/// URI-строка даёт РОВНО ОДНУ ноду — зеркалим Go
/// (node_parser_amnezia.go: рекурсивный поиск, defaultContainer предпочтён,
/// импортируется первый найденный контейнер). Label: `description` →
/// `hostName` → имя контейнера (Go-порядок; отличается от body-пути, где
/// Dart берёт nameHint файла — здесь такого контекста нет).
WireguardSpec? parseAmneziaVpnUri(String link) {
  final t = link.trim();
  if (!t.startsWith('vpn://')) return null;
  // §110 — cap 512 KiB общий с Go (maxAmneziaLinkLength): профиль с
  // сертификатами штатно больше maxURILength, и общий лимит его терял.

  final root = _decodeAmneziaRoot(t);
  if (root == null) return null;

  final containers = root['containers'];
  if (containers is! List || containers.isEmpty) return null;

  final defaultContainer = root['defaultContainer'];
  final preferredName = defaultContainer is String ? defaultContainer : null;

  // Предпочитаем контейнер с именем == defaultContainer (если он несёт
  // валидный WG/AWG INI); иначе — первый контейнер с валидным INI.
  Map? chosen;
  String? chosenIni;
  Map? firstWithIni;
  String? firstWithIniText;
  for (final c in containers) {
    if (c is! Map) continue;
    String? ini;
    for (final proto in const ['awg', 'wireguard']) {
      ini = _extractIni(c[proto]);
      if (ini != null) break;
    }
    if (ini == null) continue;
    firstWithIni ??= c;
    firstWithIniText ??= ini;
    final name = c['container'];
    if (preferredName != null && name == preferredName) {
      chosen = c;
      chosenIni = ini;
      break;
    }
  }
  chosen ??= firstWithIni;
  chosenIni ??= firstWithIniText;
  if (chosen == null || chosenIni == null) return null;

  final ini = _substituteDns(chosenIni, root);

  // Go label: description → hostName → имя контейнера.
  final description = root['description'];
  final hostName = root['hostName'];
  final containerName = chosen['container'];
  final label = (description is String && description.isNotEmpty)
      ? description
      : (hostName is String && hostName.isNotEmpty)
          ? hostName
          : (containerName is String && containerName.isNotEmpty)
              ? containerName
              : null;

  return parseWireguardIni(ini, nameHint: label);
}

/// base64 (любой из 4 вариантов) → qCompress-инфлейт/несжатый JSON → decode
/// в Map. `null` при любой ошибке на любом шаге — общий decode-конвейер для
/// [decodeAmneziaLink] и [parseAmneziaVpnUri].
Map<String, dynamic>? _decodeAmneziaRoot(String linkTrimmed) {
  final bytes = decodeBase64Safe(linkTrimmed.substring('vpn://'.length));
  if (bytes == null) return null;

  final json = _inflate(bytes);
  if (json == null) return null;

  Object root;
  try {
    root = jsonDecode(json);
  } catch (_) {
    return null;
  }
  if (root is! Map<String, dynamic>) return null;
  return root;
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
  return _withLastConfigMtu(ini, lastConfig['mtu']);
}

/// §421 — экспорт AWG3 кладёт MTU не в `[Interface]`, а рядом в
/// `last_config.mtu` (строкой `"1376"`). Если в `[Interface]` нет `MTU`,
/// дописываем строку `MTU = N` в INI (текст, не params — одна точка
/// конвертации, `_iniToUri`). Явный `MTU` в `[Interface]` приоритетнее.
/// Эталон Go `amneziaPrepareConf`/`amneziaMTUValue`.
String _withLastConfigMtu(String ini, Object? mtuRaw) {
  int? mtu;
  if (mtuRaw is num) {
    mtu = mtuRaw.toInt();
  } else if (mtuRaw is String) {
    mtu = int.tryParse(mtuRaw.trim());
  }
  if (mtu == null || mtu <= 0) return ini;
  final lines = ini.split(RegExp(r'\r?\n'));
  var section = '';
  var ifaceIdx = -1;
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.startsWith('[')) {
      section = t.toLowerCase();
      if (section == '[interface]' && ifaceIdx < 0) ifaceIdx = i;
      continue;
    }
    if (section != '[interface]') continue;
    final eq = t.indexOf('=');
    if (eq > 0 && t.substring(0, eq).trim().toLowerCase() == 'mtu') return ini;
  }
  if (ifaceIdx < 0) return ini;
  lines.insert(ifaceIdx + 1, 'MTU = $mtu');
  return lines.join('\n');
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
