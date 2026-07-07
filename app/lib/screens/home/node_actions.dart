import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/home_state.dart';
import '../../models/node_spec.dart';
import '../../services/tag_resolver.dart';
import '../outbound_view_screen.dart';

/// Node long-press action helpers.
/// Все принимают `context` явно (раньше использовали `mounted`/`context`
/// напрямую); поведение байт-в-байт идентично.

/// §258 — «View details»: экран Overview/JSON. Контроллеры нужны
/// Overview-вкладке для навигации по хопам цепочки (openTagOwner).
void viewOutboundJson(
  BuildContext context,
  String tag,
  HomeState state, {
  required SubscriptionController subController,
  required HomeController homeController,
}) {
  if (state.configRaw.isEmpty) return;
  // §091 — уже распарсенная модель из state (без ре-парса на каждый tap).
  final intro = state.configModel;
  final chain = intro.outboundChain(tag);
  if (chain.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Not found: $tag')),
    );
    return;
  }

  final payload = chain.length == 1 ? chain.first : chain;
  final json = const JsonEncoder.withIndent('  ').convert(payload);
  final detourCount = chain.length - 1; // [self, d1, …] → кол-во detour'ов
  Navigator.push(context, MaterialPageRoute(
    builder: (_) => OutboundViewScreen(
      tag: tag,
      kind: intro.kindOf(tag),
      json: json,
      detourCount: detourCount,
      config: intro,
      subController: subController,
      homeController: homeController,
      // §099 — copy-варианты JSON перенесены из контекстного меню сюда.
      onCopy: (mode) => copyNodeJson(context, tag, state, mode),
    ),
  ));
}

void copyNodeJson(
    BuildContext context, String tag, HomeState state, String mode) {
  if (state.configRaw.isEmpty) return;

  // §091 — уже распарсенная модель из state (без ре-парса на каждый tap).
  final intro = state.configModel;
  final Map<String, dynamic>? server = intro.rawOf(tag);
  Map<String, dynamic>? detour;
  if (server != null) {
    final detourTag = intro.detourOf(tag);
    if (detourTag != null) detour = intro.rawOf(detourTag);
  }

  if (server == null) return;

  Object toCopy;
  String label;
  switch (mode) {
    case 'detour':
      if (detour == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No detour for this node')),
          );
        }
        return;
      }
      toCopy = Map<String, dynamic>.from(detour)..remove('detour');
      label = 'Detour copied';
    case 'both':
      // §099 — server + ВСЯ цепочка detour'ов (не только первый hop), каждый
      // без своего detour-указателя (standalone outbounds для вставки).
      final chain = intro.outboundChain(tag); // [self, d1, d2, …]
      final n = chain.length - 1;
      if (n <= 0) {
        toCopy = Map<String, dynamic>.from(server)..remove('detour');
        label = 'Server copied';
      } else {
        toCopy = [
          for (final m in chain) Map<String, dynamic>.from(m)..remove('detour'),
        ];
        label = 'Server + $n detour${n > 1 ? "s" : ""} copied';
      }
    default: // 'server'
      toCopy = Map<String, dynamic>.from(server)..remove('detour');
      label = 'Server copied';
  }

  final json = const JsonEncoder.withIndent('  ').convert(toCopy);
  Clipboard.setData(ClipboardData(text: json));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label)));
  }
}

/// Lookup исходного `NodeSpec` по display-тэгу (с префиксом подписки).
/// Возвращает `null` если не нашли (control-узлы direct/auto, чужой
/// конфиг, или collision-suffix от `allocateTag`). Используется для
/// "Copy URI" в long-press меню.
NodeSpec? _findNodeByDisplayTag(
    String displayTag, SubscriptionController subController) {
  for (final e in subController.entries) {
    final base = TagResolver.stripPrefix(displayTag, e.tagPrefix);
    for (final n in e.list.nodes) {
      if (n.tag == base) return n;
      // Detour-нода живёт под главным как `chained` — в config она тоже
      // получает prefix. Поищем и там.
      final ch = n.chained;
      if (ch != null && ch.tag == base) return ch;
    }
  }
  return null;
}

void copyNodeUri(
    BuildContext context, String tag, SubscriptionController subController) {
  final node = _findNodeByDisplayTag(tag, subController);
  if (node == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No source URI for this node')),
      );
    }
    return;
  }
  final uri = node.toUri();
  if (uri.isEmpty) return;
  Clipboard.setData(ClipboardData(text: uri));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URI copied')),
    );
  }
}
