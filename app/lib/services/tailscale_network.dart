/// Задача 581 — логика вкладки Network узла Tailscale без Flutter: exit node
/// (записанное против действующего), запись `exit_node` в тело узла, порядок
/// устройств, сводка для Debug API.
library;

import 'dart:convert';

import '../vpn/cc_channel.dart';
import 'l10n/locale_controller.dart';

/// Расхождение записанного `exit_node` тела узла и действующего exit node ядра
/// (таблица раздела 5 спеки 581).
enum ExitNodeMismatch {
  /// Совпадают (оба пусты или указывают на одно устройство).
  none,

  /// В узле выхода нет, на ходу выбран.
  chosenNotSaved,

  /// В узле выход записан, на ходу снят.
  clearedNotSaved,

  /// В узле записан один, на ходу выбран другой.
  otherNotSaved,
}

/// Записанное значение `exit_node` тела узла; пусто и не строка — `null`.
String? recordedExitNode(Map<String, dynamic> body) {
  final v = body['exit_node'];
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

/// Указывает ли записанное [recorded] на устройство [peer]. Ядро принимает в
/// `exit_node` адрес Tailscale или имя устройства (базовое имя, MagicDNS-имя с
/// точкой в конце и без неё; регистр не важен) — `ipn.exitNodeIPOfArg`.
bool exitNodeRefersTo(
  String recorded,
  CcTailscalePeer peer, {
  String magicDnsSuffix = '',
}) {
  final r = recorded.trim().toLowerCase();
  if (r.isEmpty) return false;
  if (peer.ips.any((ip) => ip.toLowerCase() == r)) return true;
  final fqdn = peer.dnsNameClean.toLowerCase();
  if (fqdn.isNotEmpty) {
    if (r == fqdn || r == '$fqdn.') return true;
    final suffix = magicDnsSuffix.toLowerCase().replaceAll(RegExp(r'\.$'), '');
    final base = suffix.isNotEmpty && fqdn.endsWith('.$suffix')
        ? fqdn.substring(0, fqdn.length - suffix.length - 1)
        : fqdn.split('.').first;
    if (r == base) return true;
  }
  return peer.hostName.isNotEmpty && r == peer.hostName.toLowerCase();
}

/// Строка таблицы раздела 5 для пары «записанное / действующее».
ExitNodeMismatch exitNodeMismatch({
  required String? recorded,
  required CcTailscalePeer? active,
  String magicDnsSuffix = '',
}) {
  if (recorded == null && active == null) return ExitNodeMismatch.none;
  if (recorded == null) return ExitNodeMismatch.chosenNotSaved;
  if (active == null) return ExitNodeMismatch.clearedNotSaved;
  return exitNodeRefersTo(recorded, active, magicDnsSuffix: magicDnsSuffix)
      ? ExitNodeMismatch.none
      : ExitNodeMismatch.otherNotSaved;
}

/// Текст у знака предупреждения; для [ExitNodeMismatch.none] — пусто.
String exitNodeWarningText(ExitNodeMismatch m) => switch (m) {
  ExitNodeMismatch.none => '',
  ExitNodeMismatch.chosenNotSaved => getLocalText.s(
    "Not saved. Traffic is not routed through this node until you save the choice.",
  ),
  ExitNodeMismatch.clearedNotSaved => getLocalText.s(
    "Not saved. The node stays in the lists, but has no exit until you save the choice.",
  ),
  ExitNodeMismatch.otherNotSaved => getLocalText.s(
    "Not saved. The choice is lost after restart.",
  ),
};

/// Значение `exit_node` для записи в тело: адрес Tailscale устройства (IPv4
/// первым). Адрес ядро разрешает и при старте, когда список устройств ещё
/// пуст; имя в этот момент не разрешается (`exitNodeIPOfArg`). Адресов нет —
/// MagicDNS-имя, затем имя устройства.
String exitNodeConfigValue(CcTailscalePeer peer) {
  final v4 = peer.ips.where((ip) => !ip.contains(':'));
  if (v4.isNotEmpty) return v4.first;
  if (peer.ips.isNotEmpty) return peer.ips.first;
  if (peer.dnsNameClean.isNotEmpty) return peer.dnsNameClean;
  return peer.hostName;
}

/// Текст источника узла с полем `exit_node` = [value] (`null` — поле
/// убирается). Источник — JSON-объект тела узла; порядок прочих ключей
/// сохраняется, запись — JSON с отступом в два пробела. Не объект —
/// [FormatException].
String withExitNode(String source, String? value) => withBodyFields(source, {
  'exit_node': value == null || value.isEmpty ? null : value,
});

/// §613 — текст источника узла с полями [fields]: значение `null` убирает
/// поле, прочее записывается как есть. Порядок прочих ключей сохраняется,
/// новые идут в конец; запись — JSON с отступом в два пробела. Не объект —
/// [FormatException].
String withBodyFields(String source, Map<String, Object?> fields) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('node source is not a JSON object');
  }
  final body = <String, dynamic>{
    for (final e in decoded.entries) '${e.key}': e.value,
  };
  for (final f in fields.entries) {
    if (f.value == null) {
      body.remove(f.key);
    } else {
      body[f.key] = f.value;
    }
  }
  return const JsonEncoder.withIndent('  ').convert(body);
}

/// Устройства в порядке блока Devices: сначала в сети, затем остальные;
/// внутри — по имени без учёта регистра.
List<CcTailscalePeer> sortDevices(Iterable<CcTailscalePeer> peers) {
  final list = peers.toList();
  list.sort((a, b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    return a.hostName.toLowerCase().compareTo(b.hostName.toLowerCase());
  });
  return list;
}

/// §613 (ядро SPEC 115) — путь до устройства одной строкой по таблице §2
/// руководства ядра: `direct 1.2.3.4:41641`, `peer relay`, `relay fra`.
/// `NONE` (узел ни разу не слал устройству) и ядро без пути — пусто.
String tailscalePathLabel(CcTailscalePeer p) => switch (p.path) {
  CcTailscalePath.direct =>
    p.endpoint.isEmpty
        ? getLocalText.s("direct")
        : getLocalText.s("direct %s", p.endpoint),
  CcTailscalePath.peerRelay => getLocalText.s("peer relay"),
  CcTailscalePath.derp =>
    p.derpRegionCode.isEmpty
        ? getLocalText.s("relay")
        : getLocalText.s("relay %s", p.derpRegionCode),
  _ => '',
};

/// §645 — вид пути до устройства для иконки строки «как подключено»; `null` —
/// пути нет (`NONE`, ядро без пути, неизвестное значение).
enum TailscalePathKind { direct, derp, peerRelay }

TailscalePathKind? tailscalePathKind(CcTailscalePeer p) => switch (p.path) {
  CcTailscalePath.direct => TailscalePathKind.direct,
  CcTailscalePath.derp => TailscalePathKind.derp,
  CcTailscalePath.peerRelay => TailscalePathKind.peerRelay,
  _ => null,
};

/// §645 — короткий возраст `42s` / `5m` / `33h` / `17d` (часы до 48 ч, как в
/// лаунчере); отрицательное — как 0.
String tailscaleAgeLabel(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  if (s < 60) return getLocalText.s("%ss", '$s');
  if (s < 3600) return getLocalText.s("%sm", '${s ~/ 60}');
  if (s < 48 * 3600) return getLocalText.s("%sh", '${s ~/ 3600}');
  return getLocalText.s("%sd", '${s ~/ 86400}');
}

/// §645 — третья строка устройства в Devices («как подключено»), условия по
/// порядку, срабатывает первое:
/// 1. путь `DIRECT` / `DERP` / `PEER_RELAY` — [tailscalePathLabel];
/// 2. пути нет, устройство не в сети и `lastSeen > 0` — `last seen 33h ago`;
/// 3. иначе — ничего.
///
/// Истёкший ключ дописывается через ` · `. Пусто — строки нет. Возраста
/// хендшейка здесь нет (он только у пункта Exit node).
String tailscaleConnectionText(CcTailscalePeer p, int nowUnix) {
  final parts = <String>[];
  final path = tailscalePathKind(p) == null ? '' : tailscalePathLabel(p);
  if (path.isNotEmpty) {
    parts.add(path);
  } else if (!p.online && p.lastSeen > 0) {
    parts.add(
      getLocalText.s(
        "last seen %s ago",
        tailscaleAgeLabel(nowUnix - p.lastSeen),
      ),
    );
  }
  if (p.expired) parts.add(getLocalText.s("key expired"));
  return parts.join(' · ');
}

/// §645 — левая часть второй строки устройства: ОС и роли через ` · `. Слова
/// «в сети» нет — это показывает точка.
String tailscaleDeviceDetails(CcTailscalePeer p) => [
  if (p.os.isNotEmpty) p.os,
  if (p.exitNodeOption) getLocalText.s("exit node"),
  if (p.shareeNode) getLocalText.s("shared"),
].join(' · ');

/// §645 — правая часть второй строки устройства: второй адрес ([second], пусто
/// при адресах ≤ 1) и число скрытых адресов ([more] — адресов сверх двух).
({String second, int more}) tailscaleAddressTail(List<String> ips) => (
  second: ips.length >= 2 ? ips[1] : '',
  more: ips.length > 2 ? ips.length - 2 : 0,
);

/// Устройства, предлагающие себя как exit node (список блока Exit node).
List<CcTailscalePeer> exitNodeOptions(CcTailscaleStatus s) =>
    sortDevices(s.peers.where((p) => p.exitNodeOption));

/// Группировка по владельцам показывается, когда владельцев больше одного.
bool showOwnerGroups(CcTailscaleStatus s) =>
    s.userGroups.where((g) => g.peers.isNotEmpty).length > 1;

/// Раздел 8 — есть ли у узла Tailscale действующий выход. VPN включён и
/// состояние от ядра есть — по `ExitNode` ядра; иначе — по записанному
/// `exit_node` тела (с ним собирается и проба при выключенном VPN).
bool tailscaleHasExit({
  required bool vpnUp,
  required CcTailscaleStatus? status,
  required Map<String, dynamic> body,
}) {
  if (vpnUp && status != null) return status.exitNode != null;
  return recordedExitNode(body) != null;
}

/// Раздел 9 — сводка узла для Debug API: только состояние и число устройств,
/// без имён, адресов, имени сети и ссылки входа.
Map<String, Object> tailscaleDebugSummary(CcTailscaleStatus s) => {
  'backend_state': s.backendState,
  'devices': s.peers.length,
};
