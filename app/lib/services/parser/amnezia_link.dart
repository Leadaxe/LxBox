import 'dart:convert';
import 'dart:io';

import '../../models/node_spec.dart';
import 'body_decoder.dart';
import 'drop_verdict.dart';
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

  // §506 — payload бывает ГОЛЫМ `.conf`: экспорт wg-quick/AWG, завёрнутый в
  // `vpn://` без JSON-обёртки профиля. Тело поддержано полностью (те же
  // AWG3-поля), недостижимо было только через обёртку — проверяем ДО
  // JSON-ветки, потому что признак взаимоисключающий (`[` против `{`).
  final bareIni = _decodeBareIni(t);
  if (bareIni != null) return AmneziaConfig([bareIni]);

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
WireguardSpec? parseAmneziaVpnUri(String link, {XrayDropVerdict? dropped}) {
  final t = link.trim();
  if (!t.startsWith('vpn://')) return null;
  // §110 — cap 512 KiB общий с Go (maxAmneziaLinkLength): профиль с
  // сертификатами штатно больше maxURILength, и общий лимит его терял.

  // §506 — голый `.conf` под обёрткой `vpn://` (см. [decodeAmneziaLink]).
  // Имени у такой ссылки нет: тег даст сам INI (комментарий под `[Peer]`).
  final bareIni = _decodeBareIni(t);
  if (bareIni != null) return parseWireguardIni(bareIni, dropped: dropped);

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

  return parseWireguardIni(ini, nameHint: label, dropped: dropped);
}

/// §570 / контракт 1.1.80 (§77 п.1) — строка `vpn://` ВНУТРИ списка ссылок
/// даёт ТЕ ЖЕ узлы, что тело из одной этой ссылки: все WG/AWG-контейнеры
/// профиля по порядку, origin каждого — самодостаточный `.conf` (`wg_ini`,
/// его ставит [parseWireguardIni]).
///
/// Имя: у контейнера по умолчанию — имя профиля (`description` →
/// `hostName` → имя контейнера), как у прежнего одиночного узла строки,
/// чтобы тег и identity уже сохранённого узла не сменились; у прочих —
/// `<имя профиля> <имя контейнера>` (так их называет лаунчер).
///
/// `null` — ссылка не распаковалась вовсе: вызывающий идёт [parseAmneziaVpnUri]
/// и отбраковывает строку на её позиции.
List<WireguardSpec>? parseAmneziaVpnUriAll(String link,
    {List<XrayDropVerdict>? verdicts}) {
  final t = link.trim();
  if (!t.startsWith('vpn://')) return null;
  final bareIni = _decodeBareIni(t);
  if (bareIni != null) {
    final v = XrayDropVerdict();
    verdicts?.add(v);
    final n = parseWireguardIni(bareIni, dropped: v);
    return n == null ? const [] : [n];
  }
  final root = _decodeAmneziaRoot(t);
  if (root == null) return null;
  final containers = root['containers'];
  if (containers is! List || containers.isEmpty) return null;

  final entries = <({Map c, String ini})>[];
  for (final c in containers) {
    if (c is! Map) continue;
    for (final proto in const ['awg', 'wireguard']) {
      final ini = _extractIni(c[proto]);
      if (ini != null) entries.add((c: c, ini: _substituteDns(ini, root)));
    }
  }
  if (entries.isEmpty) return null;

  final defaultContainer = root['defaultContainer'];
  var chosen = entries.indexWhere((e) =>
      defaultContainer is String && e.c['container'] == defaultContainer);
  if (chosen < 0) chosen = 0;

  final description = root['description'];
  final hostName = root['hostName'];
  final profile = (description is String && description.isNotEmpty)
      ? description
      : (hostName is String && hostName.isNotEmpty)
          ? hostName
          : null;

  final out = <WireguardSpec>[];
  for (var i = 0; i < entries.length; i++) {
    final name = entries[i].c['container'];
    final containerName = name is String && name.isNotEmpty ? name : null;
    final String? label;
    if (i == chosen) {
      label = profile ?? containerName;
    } else if (profile != null && containerName != null) {
      label = '$profile $containerName';
    } else {
      label = profile ?? containerName;
    }
    final v = XrayDropVerdict();
    verdicts?.add(v);
    final n = parseWireguardIni(entries[i].ini, nameHint: label, dropped: v);
    if (n != null) out.add(n);
  }
  return out;
}

/// §506 — payload `vpn://` как ГОЛЫЙ wg-quick/AWG `.conf` (без JSON-обёртки
/// профиля Amnezia). Возвращает текст INI или `null`, если payload не INI.
///
/// Признак — первая НЕ-комментарная и непустая строка начинается с `[`:
/// у профиля Amnezia payload это JSON (`{`), у `.conf` — секция ini
/// (`[Interface]`). Комментарии пропускаем, потому что экспортёры ставят
/// шапку (`# awg-entry-…`) перед первой секцией.
///
/// Форму секций дальше судит [parseWireguardIni] — здесь только распознание
/// РОДА тела, как и у JSON-ветки (`_decodeAmneziaRoot`).
String? _decodeBareIni(String linkTrimmed) {
  final bytes = decodeBase64Safe(linkTrimmed.substring('vpn://'.length));
  if (bytes == null) return null;
  String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    return null;
  }
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty || l.startsWith('#') || l.startsWith(';')) continue;
    return l.startsWith('[') ? text : null;
  }
  return null;
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
/// дописываем строку `MTU = N` в ТЕКСТ INI, а не в разобранные поля: точка
/// конвертации одна (`mapWireguardIni`), и текст же становится `rawSource`
/// узла (§456). Явный `MTU` в `[Interface]` приоритетнее.
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
/// сохраняемого источника узла (`rawSource`).
String _substituteDns(String ini, Map<String, dynamic> root) {
  final values = <String, String>{
    r'$PRIMARY_DNS': _profileString(root['dns1']),
    r'$SECONDARY_DNS': _profileString(root['dns2']),
  };
  final out = <String>[];
  for (final line in ini.split('\n')) {
    final m = RegExp(r'^(\s*DNS\s*=\s*)(.*)$').firstMatch(line);
    if (m == null) {
      out.add(line);
      continue;
    }
    final items = <String>[];
    for (final raw in m.group(2)!.split(',')) {
      var item = raw.trim();
      if (item.isEmpty) continue;
      if (item.startsWith(r'$')) {
        // Контракт 1.1.72 (§68, substitute): плейсхолдер контейнера
        // заменяется значением профиля; неразрешённый снимается.
        item = values[item] ?? '';
        if (item.isEmpty) continue;
      }
      items.add(item);
    }
    // Пустой итог удаляет строку DNS целиком.
    if (items.isNotEmpty) out.add('${m.group(1)}${items.join(', ')}');
  }
  return out.join('\n');
}

String _profileString(Object? v) => v is String ? v.trim() : '';
