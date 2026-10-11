import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/dns_ref.dart';
import '../../services/error_format.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/ui_helpers.dart';
import '../../widgets/lx_code_editor.dart';

/// §626 ревизия 2 — полноэкранный редактор inline-правила DNS
/// ([DnsRuleInline]) вместо шторки. Образец — [DnsServerEditScreen]:
/// AppBar с Save, поле имени, JSON-поле на всю оставшуюся высоту, Back с
/// правками — общий диалог Unsaved changes (§219).
///
/// `existing` — правило при правке (null — новое). Результат маршрута —
/// собранное правило (Save) или null (выход без сохранения); insert/replace
/// решает caller.
class UserRuleEditScreen extends StatefulWidget {
  const UserRuleEditScreen({super.key, required this.existing});

  final DnsRuleInline? existing;

  @override
  State<UserRuleEditScreen> createState() => _UserRuleEditScreenState();
}

class _UserRuleEditScreenState extends State<UserRuleEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bodyCtrl;
  late final String _initialName;
  late final String _initialBody;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final body = widget.existing?.rule;
    _initialName = widget.existing?.name ?? '';
    _initialBody = body != null
        ? const JsonEncoder.withIndent('  ').convert(body)
        : '{\n  "rule_set": "geoip-ru",\n  "server": "yandex_doh"\n}';
    _nameCtrl = TextEditingController(text: _initialName)
      ..addListener(_onChanged);
    _bodyCtrl = TextEditingController(text: _initialBody)
      ..addListener(_onChanged);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  bool _wasDirty = false;

  /// Перерисовка только при смене признака правок (подсветка Save).
  void _onChanged() {
    final dirty = _dirty;
    if (dirty != _wasDirty) setState(() => _wasDirty = dirty);
  }

  bool get _dirty =>
      _nameCtrl.text != _initialName || _bodyCtrl.text != _initialBody;

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack(getLocalText.s("Name is required"));
      return;
    }
    Map<String, dynamic> parsed;
    try {
      final obj = jsonDecode(_bodyCtrl.text);
      if (obj is! Map<String, dynamic>) {
        throw const FormatException('Rule body must be a JSON object');
      }
      parsed = obj;
    } catch (e) {
      _snack(getLocalText.s("Invalid JSON: %s", formatUserError(e).render()));
      return;
    }
    Navigator.pop(
      context,
      DnsRuleInline(
        name: name,
        rule: parsed,
        enabled: widget.existing?.enabled ?? true,
      ),
    );
  }

  Future<void> _handleBack() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      _save(); // сам сделает Navigator.pop при успехе
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null — остаёмся на экране
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew
              ? getLocalText.s("Add DNS Rule")
              : getLocalText.s("Edit DNS Rule")),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: Icon(Icons.save,
                  color: _wasDirty ? theme.colorScheme.primary : null),
              onPressed: _save,
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.fromLTRB(
              12, 12, 12, MediaQuery.of(context).padding.bottom + 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Name"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              // §614/§624 — редактор JSON с подсветкой и поиском; подпись —
              // слева в строке кнопок поля (поиск, Format).
              Expanded(
                child: LxTextCodeField(
                  controller: _bodyCtrl,
                  header: Text(
                    getLocalText.s("Rule body (JSON)"),
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                // l10n-exempt: JSON shape example (literal braces)
                'sing-box DNS rule shape: {rule_set, domain, domain_suffix, server, ...}',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Открывает редактор правила; null — выход без сохранения.
Future<DnsRuleInline?> openUserRuleEditor(
  BuildContext context, {
  DnsRuleInline? existing,
}) {
  return Navigator.push<DnsRuleInline>(
    context,
    MaterialPageRoute(builder: (_) => UserRuleEditScreen(existing: existing)),
  );
}
