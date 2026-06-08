import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/error_format.dart';

/// §044: универсальный editor для DNS-server entry. Три явных input'а
/// (tag / description / enabled) + body JSON (sing-box body **без**
/// tag/description/enabled — они на ref-level).
///
/// Validation на save:
/// - tag непустой
/// - если `lockedTag: true` — tag не редактируем (read-only input)
/// - body — валидный JSON object; auto-strip tag/description/enabled
///   если случайно оставлены
///
/// `context` is the screen context (used for `ScaffoldMessenger` снаружи sheet'а).
void showServerEditor(
  BuildContext context, {
  required String title,
  required String initialTag,
  required bool lockedTag,
  required String initialDescription,
  required bool initialEnabled,
  required Map<String, dynamic> initialBody,
  required void Function(
    String tag,
    String description,
    bool enabled,
    Map<String, dynamic> body,
  ) onSave,
}) {
  final tagCtrl = TextEditingController(text: initialTag);
  final descCtrl = TextEditingController(text: initialDescription);
  final bodyCtrl = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(initialBody),
  );
  var enabled = initialEnabled;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: tagCtrl,
              readOnly: lockedTag,
              decoration: InputDecoration(
                labelText: 'Tag',
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: lockedTag ? 'Tag locked while editing' : null,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: enabled,
              onChanged: (v) => setSheetState(() => enabled = v),
            ),
            const SizedBox(height: 8),
            const Text('Body (sing-box JSON)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            SizedBox(
              height: 180,
              child: TextField(
                controller: bodyCtrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final tag = tagCtrl.text.trim();
                if (tag.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Tag is required')));
                  return;
                }
                Map<String, dynamic> body;
                try {
                  final parsed = jsonDecode(bodyCtrl.text);
                  if (parsed is! Map<String, dynamic>) {
                    throw const FormatException(
                        'Body must be a JSON object');
                  }
                  body = parsed;
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content:
                          Text('Invalid body JSON: ${formatUserError(e)}')));
                  return;
                }
                // §044: tag/description/enabled — на ref-level. Если юзер
                // случайно оставил их в body — silently strip (warn'ить
                // не будем, тривиально).
                body
                  ..remove('tag')
                  ..remove('description')
                  ..remove('enabled')
                  ..remove('_origin')
                  ..remove('_kind')
                  ..remove('_overrides')
                  ..remove('_preset_label');
                Navigator.pop(ctx);
                onSave(tag, descCtrl.text.trim(), enabled, body);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  ).then((_) {
    tagCtrl.dispose();
    descCtrl.dispose();
    bodyCtrl.dispose();
  });
}
