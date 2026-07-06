import 'dart:convert';

import 'package:flutter/material.dart';


/// Read-only dialog с полным JSON body правила. Юзер видит что внутри
/// без необходимости лезть в исходник (особенно для kind=template/rule
/// где body proxy'ится из шаблона/пресета).
///
/// §253: body — Map (одно правило) или List<Map> (пресет с несколькими
/// DNS-правилами); одноэлементный список разворачивается до Map (прежний вид).
void showRuleBodyDialog(
    BuildContext context, String title, String kind, Object? body) {
  final unwrapped = switch (body) {
    List(isEmpty: true) => null, // все правила выпали на expansion'е
    [final only] => only, // одно правило — прежний вид (без [ ] обёртки)
    _ => body,
  };
  final pretty = unwrapped == null
      ? '(content unavailable)'
      : const JsonEncoder.withIndent('  ').convert(unwrapped);
  final sourceLabel = switch (kind) {
    'template' => 'template',
    'preset' => 'preset',
    'srs' => 'srs',
    'rule' => 'routing rule',
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
