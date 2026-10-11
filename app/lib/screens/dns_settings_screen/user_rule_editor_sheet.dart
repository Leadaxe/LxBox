import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/dns_ref.dart';
import '../../services/error_format.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/lx_code_editor.dart';
import '../../widgets/unsaved_changes_sheet.dart';

/// Bottom-sheet editor for an inline user DNS rule ([DnsRuleInline]).
///
/// `existing` — текущее правило при edit (null при add). `onSave` получает уже
/// собранное правило (caller решает insert vs replace). `context` —
/// screen context (для `ScaffoldMessenger` снаружи sheet'а).
///
/// §626 — с несохранёнными правками любой выход (Back, тап по фону,
/// смахивание вниз) спрашивает общий диалог Unsaved changes (§219).
void showUserRuleEditor(
  BuildContext context, {
  required bool isNew,
  required DnsRuleInline? existing,
  required void Function(DnsRuleInline entry) onSave,
}) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    // §626 — смахивание ведёт [UnsavedChangesSheet].
    enableDrag: false,
    builder: (ctx) => _UserRuleEditor(
      screenContext: context,
      isNew: isNew,
      existing: existing,
      onSave: onSave,
    ),
  );
}

class _UserRuleEditor extends StatefulWidget {
  const _UserRuleEditor({
    required this.screenContext,
    required this.isNew,
    required this.existing,
    required this.onSave,
  });

  final BuildContext screenContext;
  final bool isNew;
  final DnsRuleInline? existing;
  final void Function(DnsRuleInline entry) onSave;

  @override
  State<_UserRuleEditor> createState() => _UserRuleEditorState();
}

class _UserRuleEditorState extends State<_UserRuleEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bodyCtrl;
  late final String _initialName;
  late final String _initialBody;

  @override
  void initState() {
    super.initState();
    final body = widget.existing?.rule;
    _initialName = widget.existing?.name ?? '';
    _initialBody = body != null
        ? const JsonEncoder.withIndent('  ').convert(body)
        : '{\n  "rule_set": "geoip-ru",\n  "server": "yandex_doh"\n}';
    _nameCtrl = TextEditingController(text: _initialName);
    _bodyCtrl = TextEditingController(text: _initialBody);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _nameCtrl.text != _initialName || _bodyCtrl.text != _initialBody;

  void _snack(String text) {
    ScaffoldMessenger.of(
      widget.screenContext,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Save шторки и диалога: true — правило отдано в `onSave`, шторка закрыта.
  bool _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack(getLocalText.s("Name is required"));
      return false;
    }
    Map<String, dynamic>? parsed;
    try {
      final obj = jsonDecode(_bodyCtrl.text);
      if (obj is! Map<String, dynamic>) {
        throw const FormatException('Rule body must be a JSON object');
      }
      parsed = obj;
    } catch (e) {
      _snack(getLocalText.s("Invalid JSON: %s", formatUserError(e).render()));
      return false;
    }
    Navigator.pop(context);
    widget.onSave(
      DnsRuleInline(
        name: name,
        rule: parsed,
        enabled: widget.existing?.enabled ?? true,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesSheet(
      isDirty: () => _dirty,
      onSave: () async => _save(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isNew
                  ? getLocalText.s("Add DNS Rule")
                  : getLocalText.s("Edit DNS Rule"),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("Name"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            // §614 — редактор JSON с подсветкой, высота прежняя.
            LxTextCodeField(
              controller: _bodyCtrl,
              height: 180,
              label: getLocalText.s("Rule body (JSON)"),
            ),
            const SizedBox(height: 8),
            const Text(
              // l10n-exempt: JSON shape example (literal braces)
              'sing-box DNS rule shape: {rule_set, domain, domain_suffix, server, ...}',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _save, child: Text(getLocalText.s("Save"))),
          ],
        ),
      ),
    );
  }
}
