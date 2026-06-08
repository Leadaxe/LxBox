import 'dart:convert';

import 'package:flutter/material.dart';

import 'resolved_server.dart';

/// Read-only dialog с полным JSON DNS-сервера.
/// §044: read-only dialog показывает body синтезированного sing-box shape'а
/// (без UI-аннотаций — их физически нет в `ResolvedServer.body`).
///
/// Extracted from `DnsSettingsScreen._showServerBodyDialog` (§089 split).
void showServerBodyDialog(BuildContext context, ResolvedServer server) {
  final pretty = const JsonEncoder.withIndent('  ').convert(server.body);
  final title = server.description.isNotEmpty ? server.description : server.tag;
  final sourceLabel = switch (server.kind) {
    ServerKind.template => 'Template',
    ServerKind.preset =>
      server.presetLabel != null && server.presetLabel!.isNotEmpty
          ? 'Preset · ${server.presetLabel}'
          : 'Preset',
    ServerKind.inline =>
      server.isOverridden ? 'Overridden' : 'User',
  };
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(fontSize: 15)),
          Text(sourceLabel,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ],
      ),
      content: SingleChildScrollView(
        child: SelectableText(
          pretty,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Read-only dialog с полным JSON body правила. Юзер видит что внутри
/// без необходимости лезть в исходник (особенно для kind=template/rule
/// где body proxy'ится из шаблона/пресета).
///
/// Extracted from `DnsSettingsScreen._showRuleBodyDialog` (§089 split).
void showRuleBodyDialog(
    BuildContext context, String title, String kind, Map<String, dynamic>? body) {
  final pretty = body == null
      ? '(content unavailable)'
      : const JsonEncoder.withIndent('  ').convert(body);
  final sourceLabel = switch (kind) {
    'template' => 'from template',
    'preset' => 'from preset',
    'srs' => 'srs',
    _ => 'user rule',
  };
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(fontSize: 15)),
          Text(sourceLabel,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ],
      ),
      content: SingleChildScrollView(
        child: SelectableText(
          pretty,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
