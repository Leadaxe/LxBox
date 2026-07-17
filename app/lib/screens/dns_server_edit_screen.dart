import 'dart:async';

import 'package:flutter/material.dart';

import '../services/l10n/l10n.dart';
import '../services/ui_helpers.dart';
import '../widgets/outbound_picker.dart';
import 'dns_server_edit/edit_controller.dart';
import 'dns_server_edit/tabs/json_tab.dart';
import 'dns_server_edit/tabs/params_tab.dart';
import 'dns_settings_screen/resolved_server.dart';

/// §117 задача 4 — полноэкранный редактор DNS-сервера (locked decision №8).
/// Паттерн 1:1 с [CustomRuleEditScreen]: Scaffold-route,
/// `DefaultTabController(2)` (Params / JSON), AppBar с back-guard
/// (`PopScope`+dialog Save/Keep/Discard), Delete (user-only inline, не
/// locked), Reset-to-canonical (↺ для overridden) и Save (dirty-highlight).
///
/// Заменяет фрагментированный UX: боттом-шит `server_editor_sheet` +
/// read-only диалог `dns_body_dialogs.showServerBodyDialog` + инлайн-тюнер
/// на тайле.
class DnsServerEditScreen extends StatefulWidget {
  const DnsServerEditScreen({
    super.key,
    required this.initialRef,
    this.resolved,
    this.templateWrapper,
    this.canonicalDescription = '',
    this.outboundOptions = const [],
    this.dnsServerTags = const [],
    this.existingTags = const {},
  });

  /// Ref-запись стораджа (edit) или дефолтная inline-заготовка (new).
  final Map<String, dynamic> initialRef;

  /// Display-модель (null = new-режим: добавление inline-сервера).
  final ResolvedServer? resolved;

  /// §117-обёртка шаблона для kind=template (JSON-превью).
  final Map<String, dynamic>? templateWrapper;

  /// Каноническое описание template/preset (description-override детект).
  final String canonicalDescription;

  final List<OutboundOption> outboundOptions;
  final List<String> dnsServerTags;

  /// Существующие теги (new-режим): коллизия tag'а → confirm replace.
  final Set<String> existingTags;

  @override
  State<DnsServerEditScreen> createState() => _DnsServerEditScreenState();
}

class _DnsServerEditScreenState extends State<DnsServerEditScreen> {
  late final DnsServerEditController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = DnsServerEditController(
      initialRef: widget.initialRef,
      resolved: widget.resolved,
      templateWrapper: widget.templateWrapper,
      canonicalDescription: widget.canonicalDescription,
      outboundOptions: widget.outboundOptions,
      dnsServerTags: widget.dnsServerTags,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ─── Save / delete / reset / back ────────────────────────────────────

  Future<void> _save() async {
    if (_ctrl.kind == ServerKind.inline) {
      final tag = _ctrl.tagCtrl.text.trim();
      if (tag.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.dnsEditTagRequired)),
        );
        return;
      }
      if (_ctrl.jsonError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(context.l.dnsEditFixJsonFirst('${_ctrl.jsonError}'))),
        );
        return;
      }
      // §117 задача 4b: для форменных режимов (UDP/DoT/DoH) адрес обязателен.
      if (_ctrl.serverMode != null &&
          _ctrl.addressCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.dnsEditAddressRequired)),
        );
        return;
      }
      // §117 задача 4b: rename existing — коллизия запрещена (replace-
      // семантики у rename нет, ссылки каскадно поедут на save).
      if (!_ctrl.isNew &&
          tag != (widget.resolved?.tag ?? '') &&
          widget.existingTags.contains(tag)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l.dnsEditTagInUse(tag))),
        );
        return;
      }
      // New-режим: коллизия с существующим tag'ом → явный confirm replace
      // (раньше боттом-шит заменял молча).
      if (_ctrl.isNew && widget.existingTags.contains(tag)) {
        final replace = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(ctx.l.dnsEditTagExistsTitle(tag)),
            content: Text(ctx.l.dnsEditReplaceBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ctx.l.commonReplace),
              ),
            ],
          ),
        );
        if (replace != true || !mounted) return;
      }
    }
    if (!mounted) return;
    Navigator.pop(context, DnsServerEditResult.saved(_ctrl.snapshot()));
  }

  Future<void> _delete() async {
    final tag = widget.resolved?.tag ?? '';
    final confirmed = await showDeleteConfirmDialog(
      context,
      title: context.l.dnsEditDeleteTitle,
      message: context.l.ruleEditDeleteBody(tag),
    ); // §219
    if (confirmed == true && mounted) {
      Navigator.pop(context, DnsServerEditResult.deleted());
    }
  }

  /// §043/§117: reset inline-override обратно к canonical (template/preset) —
  /// ref схлопывается в `{enabled, kind: <canonical>, tag}`.
  Future<void> _resetToCanonical() async {
    final overrides = _ctrl.overrides;
    final resolved = widget.resolved;
    if (overrides == null || resolved == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l.dnsEditResetTitle),
        content: Text(ctx.l.dnsEditResetBody(overrides.name, resolved.tag)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.dnsEditResetButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.pop(
      context,
      DnsServerEditResult.saved({
        'enabled': _ctrl.enabled,
        'kind': overrides.name,
        'tag': resolved.tag,
      }),
    );
  }

  Future<void> _handleBack() async {
    if (!_ctrl.isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      unawaited(_save()); // сам сделает Navigator.pop при успехе
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null — остаёмся на экране
  }

  // ─── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final canDelete = !_ctrl.isNew && _ctrl.isUserOnly && !_ctrl.locked;
    final canReset = !_ctrl.isNew && _ctrl.overrides != null;

    return DnsServerEditScope(
      notifier: _ctrl,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          unawaited(_handleBack());
        },
        child: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: Text(_ctrl.isNew
                  ? context.l.dnsEditAddTitle
                  : context.l.dnsEditEditTitle),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _handleBack,
              ),
              actions: [
                if (canReset)
                  IconButton(
                    tooltip: context.l.dnsEditResetTooltip,
                    icon: const Icon(Icons.restart_alt),
                    onPressed: _resetToCanonical,
                  ),
                if (canDelete)
                  IconButton(
                    tooltip: context.l.dnsEditDeleteServerTooltip,
                    icon: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    onPressed: _delete,
                  ),
                _SaveIconButton(controller: _ctrl, onPressed: _save),
              ],
              bottom: TabBar(
                tabs: [
                  Tab(text: context.l.ruleEditTabParams),
                  Tab(text: context.l.dnsEditTabJson),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                DnsServerParamsTab(onSave: _save),
                const DnsServerJsonTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Save-icon в AppBar: подсвечивается primary при `isDirty()` (как у
/// rule-редактора — rebuild ограничен этой кнопкой).
class _SaveIconButton extends StatelessWidget {
  const _SaveIconButton({required this.controller, required this.onPressed});

  final DnsServerEditController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (ctx, _) {
        final dirty = controller.isDirty();
        return IconButton(
          tooltip: ctx.l.commonSave,
          icon: Icon(Icons.save,
              color: dirty ? Theme.of(ctx).colorScheme.primary : null),
          onPressed: onPressed,
        );
      },
    );
  }
}

/// Результат редактора — сохранённая ref-запись либо удаление.
class DnsServerEditResult {
  const DnsServerEditResult._({this.saved, this.wasDeleted = false});

  /// Новый/обновлённый ref `{enabled, kind, tag, description?, body?,
  /// varValues?}`. Для reset-to-canonical — схлопнутый ref.
  final Map<String, dynamic>? saved;
  final bool wasDeleted;

  factory DnsServerEditResult.saved(Map<String, dynamic> ref) =>
      DnsServerEditResult._(saved: ref);
  factory DnsServerEditResult.deleted() =>
      const DnsServerEditResult._(wasDeleted: true);
}

/// §117 задача 4 — opener (паттерн `openCustomRuleEditor`). null = back без
/// изменений.
Future<DnsServerEditResult?> openDnsServerEditor(
  BuildContext context, {
  required Map<String, dynamic> initialRef,
  ResolvedServer? resolved,
  Map<String, dynamic>? templateWrapper,
  String canonicalDescription = '',
  List<OutboundOption> outboundOptions = const [],
  List<String> dnsServerTags = const [],
  Set<String> existingTags = const {},
}) {
  return Navigator.push<DnsServerEditResult>(
    context,
    MaterialPageRoute(
      builder: (_) => DnsServerEditScreen(
        initialRef: initialRef,
        resolved: resolved,
        templateWrapper: templateWrapper,
        canonicalDescription: canonicalDescription,
        outboundOptions: outboundOptions,
        dnsServerTags: dnsServerTags,
        existingTags: existingTags,
      ),
    ),
  );
}
