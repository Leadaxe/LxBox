/// §686 п. 9 — узел WireGuard / AmneziaWG в виде `.conf` (вкладка INI экрана
/// узла и Edit INI).
///
/// Текст собирается обратным ходом таблицы переноса секции `conf` реестра
/// ([emitIniViaSection]) — той же, что разбирает `.conf` ([parseWireguardIni])
/// и, через общие имена параметров, ссылку. Частный генератор WARP
/// (`warp_account.dart`) здесь не участвует.
library;

import '../parser/engine/ini_emitter.dart';
import '../parser/engine/section_loader.dart';

export '../parser/engine/ini_emitter.dart' show IniEmitResult;

/// `.conf` из тела узла [body] (то, что показывает вкладка JSON). `null` —
/// секция `conf` не загружена.
IniEmitResult? wireguardIniOf(Map<String, dynamic> body) {
  final section = MapperSections.I.sectionFor('conf', 'wireguard');
  if (section == null) return null;
  return emitIniViaSection(section, body);
}

/// Имя файла `.conf` от тега узла: всё, что не буква, цифра, `-`, `_`, `.`,
/// — `_`; пустой тег — `wireguard`.
String wireguardIniFileName(String tag) {
  final base = tag
      .trim()
      .replaceAll(RegExp(r'[^\p{L}\p{N}._-]+', unicode: true), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return '${base.isEmpty ? 'wireguard' : base}.conf';
}
