// §393 C7 — диалог создания цепочки: тег + имя.
//
// Идиома — `showNewDirectionDialog` (§393 A3). Тег спрашивается ЗДЕСЬ и
// только здесь: после создания он immutable (на него ссылаются фильтры
// Направлений, `route_final` и позиции ДРУГИХ цепочек), и узнать о конфликте
// после создания было бы поздно.
//
// Проверка — тот же [directionTagConflict], что зовёт storage (`_addChain`):
// единственный источник правды. Занятые теги приходят ОБОИХ видов сразу —
// цепочек и Направлений: одинаковый тег дал бы два outbound'а с одним именем,
// и ядро отвергло бы конфиг целиком.

import 'package:flutter/material.dart';

import '../../models/direction.dart';
import '../../models/source_chain.dart';
import '../../services/l10n/locale_controller.dart';

class NewChainRequest {
  const NewChainRequest({required this.tag, required this.label});

  final String tag;
  final String label;
}

/// Открывает диалог создания. null — пользователь отменил.
///
/// [usedTags] — теги существующих цепочек И Направлений.
Future<NewChainRequest?> showNewChainDialog(
  BuildContext context, {
  required List<String> usedTags,
}) =>
    showDialog<NewChainRequest>(
      context: context,
      builder: (ctx) => _NewChainDialog(usedTags: usedTags),
    );

class _NewChainDialog extends StatefulWidget {
  const _NewChainDialog({required this.usedTags});

  final List<String> usedTags;

  @override
  State<_NewChainDialog> createState() => _NewChainDialogState();
}

class _NewChainDialogState extends State<_NewChainDialog> {
  late final TextEditingController _tagCtrl;
  late final TextEditingController _labelCtrl;

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController(text: nextChainTag(widget.usedTags))
      ..addListener(_onChange);
    _labelCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  void _onChange() => setState(() {});

  String? _tagError() {
    final code = directionTagConflict(_tagCtrl.text, widget.usedTags);
    return switch (code) {
      null => null,
      'empty' => getLocalText.s("Tag cannot be empty"),
      'reserved' => getLocalText.s("This tag is reserved by the config"),
      'duplicate' => getLocalText.s(
          "This tag is already taken by another chain or direction"),
      _ => getLocalText.s("This tag collides with an auto twin (<tag>-auto)"),
    };
  }

  @override
  Widget build(BuildContext context) {
    final error = _tagError();
    return AlertDialog(
      title: Text(getLocalText.s("New hop chain")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              getLocalText.s(
                  "A chain is a route through several hops in a row. It joins the pool as a node, so directions can pick it like any server."),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: _tagCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: getLocalText.s("Tag"),
              helperText: getLocalText.s("System id, cannot be changed later"),
              helperMaxLines: 2,
              errorText: error,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _labelCtrl,
            decoration: InputDecoration(
              labelText: getLocalText.s("Title"),
              hintText: getLocalText.s("optional — defaults to the tag"),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: error != null
              ? null
              : () => Navigator.pop(
                    context,
                    NewChainRequest(
                      tag: _tagCtrl.text.trim(),
                      label: _labelCtrl.text.trim(),
                    ),
                  ),
          child: Text(getLocalText.s("Create")),
        ),
      ],
    );
  }
}
