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
String withExitNode(String source, String? value) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('node source is not a JSON object');
  }
  final body = <String, dynamic>{
    for (final e in decoded.entries) '${e.key}': e.value,
  };
  if (value == null || value.isEmpty) {
    body.remove('exit_node');
  } else {
    body['exit_node'] = value;
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
