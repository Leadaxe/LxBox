import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/home_state.dart';
import '../../models/node_spec.dart';
import '../../models/template_vars.dart';
import '../../services/contract/body_sanitizer.dart'
    show carriesPrivateKeyByRegistry;
import '../../services/tag_resolver.dart';
import '../outbound_view_screen.dart';
import '../../services/l10n/locale_controller.dart';
import '../../vpn/cc_channel.dart' show CcEndpointState;

/// Node long-press action helpers.
/// Все принимают `context` явно (раньше использовали `mounted`/`context`
/// напрямую); поведение байт-в-байт идентично.

/// §311 — тега нет в конфиге. После перехода на activeModel (срез ядра) это
/// редкость — список и resolve снова из одного источника; сообщение остаётся
/// диагностическим, но молчать нельзя ни в одном действии (§277/§278).
void _showTagMissing(BuildContext context, String tag) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(getLocalText.s("Not found: %s", tag))),
  );
}

/// §258 — «View details»: экран Overview/JSON. Контроллеры нужны
/// Overview-вкладке для навигации по хопам цепочки (openTagOwner).
void viewOutboundJson(
  BuildContext context,
  String tag,
  HomeState state, {
  required SubscriptionController subController,
  required HomeController homeController,
  bool openDependents = false, // §355 — сразу вкладка Dependents (⚠-тап)
}) {
  // §311 — конфига нет вовсе (ни файла, ни снапшота): молча выходить нельзя
  // (§277/§278) — сообщение то же, причина для юзера одна «данных по тегу нет».
  if (state.configRaw.isEmpty && state.runningConfigRaw == null) {
    _showTagMissing(context, tag);
    return;
  }
  // §311 — activeModel: tag пришёл из списка нод (= из ядра при tunnelUp),
  // значит и искать его надо в срезе ядра, а не в пересобранном файле —
  // иначе в окне «пересборка до рестарта» ловим ложный «Not found».
  final intro = state.activeModel;
  final chain = intro.outboundChain(tag);
  if (chain.isEmpty) {
    _showTagMissing(context, tag);
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
      openDependents: openDependents, // §355
      // §099 — copy-варианты JSON перенесены из контекстного меню сюда.
      onCopy: (mode) => copyNodeJson(context, tag, state, mode),
    ),
  ));
}

void copyNodeJson(
    BuildContext context, String tag, HomeState state, String mode) {
  if (state.configRaw.isEmpty && state.runningConfigRaw == null) {
    _showTagMissing(context, tag); // §311 — не молчим (см. viewOutboundJson)
    return;
  }

  // §311 — activeModel (см. viewOutboundJson).
  final intro = state.activeModel;
  final Map<String, dynamic>? server = intro.rawOf(tag);
  Map<String, dynamic>? detour;
  if (server != null) {
    final detourTag = intro.detourOf(tag);
    if (detourTag != null) detour = intro.rawOf(detourTag);
  }

  // §311 — раньше здесь был немой return: юзер жал «копировать», реакции
  // нет, в буфере оставалось прошлое (анти-паттерн §277/§278).
  if (server == null) {
    _showTagMissing(context, tag);
    return;
  }

  Object toCopy;
  String label;
  switch (mode) {
    case 'detour':
      if (detour == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(getLocalText.s("No detour for this node"))),
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
      // получает prefix. Поищем и там. §404 — цепочка бывает многохоповой,
      // идём по всем звеньям.
      for (var hop = n.chained; hop != null; hop = hop.chained) {
        if (hop.tag == base) return hop;
      }
    }
  }
  return null;
}

/// §466 — подтверждение выдачи ссылки, которая несёт приватный ключ.
/// `true` — юзер согласился; `false` — Cancel или тап мимо диалога.
Future<bool> _confirmPrivateKeyInLink(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Link contains a private key")),
      content: Text(getLocalText.s(
          "Anyone who gets this link can use the key. Copy it only to move "
          "the node to your own device.")),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(getLocalText.s("Cancel")),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(getLocalText.s("Copy anyway")),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<void> copyNodeUri(BuildContext context, String tag,
    SubscriptionController subController) async {
  final node = _findNodeByDisplayTag(tag, subController);
  if (node == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("No source URI for this node"))),
      );
    }
    return;
  }
  // §466 / контракт §24.2 п. 7.16 — ссылка с приватным ключом отдаётся, но с
  // предупреждением (решение владельца; §463 здесь отказывал).
  //
  // Приватный ключ в буфере обмена — другая граница доверия, чем локальное
  // хранение: ссылку пересылают. `toUri()` у нас ОДНОВРЕМЕННО и формат
  // хранения (`rawBody`, инвариант `parseUri(spec.toUri()) ≈ spec`), поэтому
  // молча вырезать ключ из неё нельзя — он потерялся бы при перезагрузке
  // узла. Отказ же ломал перенос своего узла между своими устройствами и был
  // непоследователен: у SSH ключ не отдавался вовсе, у WireGuard уезжал молча.
  if (carriesPrivateKeyByRegistry(node.emit(TemplateVars.empty).map)) {
    if (!context.mounted) return;
    final ok = await _confirmPrivateKeyInLink(context);
    if (!ok) return;
  }
  final uri = node.toUri();
  if (uri.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: uri));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("URI copied"))),
    );
  }
}

/// §557 (ядро SPEC 106) — «Turn off» / «Turn on» WG/AWG-узла на лету: вызов
/// контроллера и snackbar при отказе ядра. Направление — по текущему
/// состоянию узла: выключенный включаем, остальные выключаем.
Future<void> toggleEndpoint(
    BuildContext context, HomeController controller, String tag) async {
  final enable =
      controller.state.endpointStates[tag] == CcEndpointState.disabled;
  final code = await controller.setEndpointEnabled(tag, enable);
  if (code == null || !context.mounted) return;
  final text = switch (code) {
    'not_found' => getLocalText.s("The running config has no node %s.", tag),
    'invalid_argument' =>
      getLocalText.s("Only WireGuard and AmneziaWG nodes can be turned off."),
    'failed_precondition' =>
      getLocalText.s("VPN is not running or is restarting. Try again."),
    'unavailable' => getLocalText.s(
        "The node did not wake up. The next connection through it will retry."),
    _ => enable
        ? getLocalText.s("Could not turn the node on.")
        : getLocalText.s("Could not turn the node off."),
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
