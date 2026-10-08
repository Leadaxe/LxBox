import 'dart:convert';

import '../../controllers/subscription_controller.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/template_vars.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/tag_resolver.dart';
import '../../services/tailscale_network.dart';
import '../../vpn/box_vpn_client.dart';
import '../home/source_lookup.dart';
import 'node_document.dart';

/// §581 — запись источника узла Tailscale, куда Save choice вкладки Network
/// кладёт `exit_node`: свой сервер или член папки. Узел подписки сюда не
/// попадает: его источник — ответ сервера подписки.
class ExitNodeTarget {
  final int entryIndex;

  /// Индекс члена папки; `null` — свой сервер.
  final int? memberIndex;

  /// Текст источника записи: raw члена папки или `rawBody` своего сервера.
  final String raw;

  /// Узел Tailscale этой записи.
  final TailscaleSpec node;

  const ExitNodeTarget({
    required this.entryIndex,
    required this.memberIndex,
    required this.raw,
    required this.node,
  });
}

/// Запись источника по тегу собранного конфига ([ownerOfTag]: префикс
/// записи, суффикс дедупликации). `null` — владелец не найден, это подписка
/// или найденный узел не Tailscale.
ExitNodeTarget? exitNodeTargetForTag(
    String tag, List<SubscriptionEntry> entries) {
  final owner = ownerOfTag(tag, entries);
  if (owner == null) return null;
  final list = entries[owner.entryIndex].list;
  final mi = owner.memberIndex;
  if (list is FolderServers && mi != null) {
    final member = list.members[mi];
    final node = member.node;
    if (node is! TailscaleSpec) return null;
    return ExitNodeTarget(
        entryIndex: owner.entryIndex,
        memberIndex: mi,
        raw: member.raw,
        node: node);
  }
  if (list is UserServer) {
    final candidates = <String>{tag};
    final m = RegExp(r'^(.*)-\d+$').firstMatch(tag);
    if (m != null) candidates.add(m.group(1)!);
    for (final n in list.nodes) {
      if (n is TailscaleSpec &&
          candidates.contains(TagResolver.displayTag(list.tagPrefix, n.tag))) {
        return ExitNodeTarget(
            entryIndex: owner.entryIndex,
            memberIndex: null,
            raw: list.rawBody,
            node: n);
      }
    }
  }
  return null;
}

/// Save choice: `exit_node` = [value] (`null` — поле убирается) в теле узла,
/// дальше путь JSON-ветки Save вкладки Source экрана узла: тег в тело
/// (`prepareNodeDocumentForSave`), проверка ядром (`CheckConfig`), запись
/// (`updateMemberAt` / `updateConnectionAt`). Тег узла не меняется.
/// Возвращает `null` при успехе, иначе текст ошибки для пользователя.
Future<String?> storeExitNodeChoice(SubscriptionController sub,
        ExitNodeTarget target, String? value) =>
    storeTailscaleFields(sub, target, {
      'exit_node': value == null || value.isEmpty ? null : value,
    });

/// §613 — то же для любых полей тела узла Tailscale (переключатели Settings
/// вкладки Network): `null` убирает поле. Путь записи — как у Save choice.
Future<String?> storeTailscaleFields(SubscriptionController sub,
    ExitNodeTarget target, Map<String, Object?> fields) async {
  final raw = target.raw.trim();
  final base = raw.startsWith('{')
      ? raw
      : const JsonEncoder.withIndent('  ')
          .convert(target.node.emit(TemplateVars.empty).map);
  final String text;
  try {
    text = withBodyFields(base, fields);
  } on FormatException catch (e) {
    return getLocalText.s("Invalid JSON: %s", e.message);
  }
  final prep = prepareNodeDocumentForSave(text, target.node.tag);
  if (prep is NodeDocumentRejected) return prep.message;
  final toStore = (prep as NodeDocumentReady).text;
  final payload = checkPayloadFor(toStore);
  if (payload != null) {
    final check = await BoxVpnClient.I.checkConfig(payload);
    // null — мост недоступен: проверять нечем, запись не блокируем.
    if (check != null && !check.ok) {
      return getLocalText.s("The core rejected the node: %s", check.error);
    }
  }
  final mi = target.memberIndex;
  if (mi != null) {
    final err = await sub.updateMemberAt(target.entryIndex, mi, toStore);
    if (err != null) return err.render();
  } else {
    final err = await sub.updateConnectionAt(target.entryIndex, [toStore]);
    if (err != null) return err.render();
  }
  return null;
}
