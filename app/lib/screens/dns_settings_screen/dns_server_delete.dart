import 'package:flutter/material.dart';

import '../../services/l10n/locale_controller.dart';
import '../../services/ui_helpers.dart';
import 'resolved_server.dart';

/// §680 — удаление сервера из списка доступно: не залочен ссылкой (пресет,
/// правило, список) и не preset-ref (живёт с пресетом). Template и override
/// (inline поверх template) удаляются целиком.
bool canDeleteDnsServer(ResolvedServer s) =>
    !s.locked && s.kind != ServerKind.preset;

/// §680 — подтверждение удаления DNS-сервера. Шаблонный (и override поверх
/// шаблона) уходит из списка, вернуть можно из каталога; свой inline —
/// прежний текст про необратимость.
Future<bool?> confirmDeleteDnsServer(
  BuildContext context,
  ResolvedServer s,
) {
  final fromCatalog =
      s.kind == ServerKind.template || s.overrides == ServerKind.template;
  if (!fromCatalog) {
    return showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete DNS server?"),
      message: getLocalText.s("Remove \"%s\" permanently?", s.tag),
    );
  }
  return showDeleteConfirmDialog(
    context,
    title: getLocalText.s("Delete server?"),
    message: getLocalText.s(
        "Remove \"%s\" from the list?\nYou can add it back from the catalog.",
        s.description.isNotEmpty ? s.description : s.tag),
  );
}
