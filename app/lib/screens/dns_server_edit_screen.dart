import 'dart:async';

import 'package:flutter/material.dart';

import '../models/dns_ref.dart';
import '../services/ui_helpers.dart';
import '../widgets/outbound_picker.dart';
import 'dns_server_edit/edit_controller.dart';
// §312 — опция пикера членов группы нужна caller'у (dns_settings_screen).
export 'dns_server_edit/edit_controller.dart' show DnsMemberOption;
// §435 — опция пикера endpoint у сервера tailscale (тот же caller).
export '../services/dns/tailscale_endpoint_options.dart' show TailscaleEndpointOption;
import '../services/dns/tailscale_endpoint_options.dart' show TailscaleEndpointOption;
import 'dns_server_edit/tabs/json_tab.dart';
import 'dns_server_edit/tabs/params_tab.dart';
import 'dns_settings_screen/dns_server_copy.dart' show dnsCopyTag;
import 'dns_settings_screen/dns_server_delete.dart';
import 'dns_settings_screen/resolved_server.dart';
import '../services/l10n/locale_controller.dart';

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
    this.dnsMemberOptions = const [],
    this.tailscaleEndpoints = const [],
    this.existingTags = const {},
  });

  /// Ref-запись (edit) или дефолтная inline-заготовка (new).
  final DnsServerRef initialRef;

  /// Display-модель (null = new-режим: добавление inline-сервера).
  final ResolvedServer? resolved;

  /// §117-обёртка шаблона для kind=template (JSON-превью).
  final Map<String, dynamic>? templateWrapper;

  /// Каноническое описание template/preset (description-override детект).
  final String canonicalDescription;

  final List<OutboundOption> outboundOptions;
  final List<String> dnsServerTags;

  /// §312 — опции пикера членов DNS-группы (все серверы кроме self и
  /// fakeip/hosts; disabled помечаются).
  final List<DnsMemberOption> dnsMemberOptions;

  /// §435 — узлы Tailscale для пикера `endpoint` сервера `tailscale`.
  final List<TailscaleEndpointOption> tailscaleEndpoints;

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
      dnsMemberOptions: widget.dnsMemberOptions,
      tailscaleEndpoints: widget.tailscaleEndpoints,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ─── Save / delete / reset / back ────────────────────────────────────

  Future<void> _save() async {
    // §682 — у шаблонной/пресетной записи сменённый тег = inline-копия;
    // оригинал и ссылки на него не трогаются.
    if (_ctrl.savesAsCopy) {
      final tag = _ctrl.tagCtrl.text.trim();
      if (tag.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Tag is required"))),
        );
        return;
      }
      if (widget.existingTags.contains(tag)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Tag \"%s\" is already in use", tag))),
        );
        return;
      }
      Navigator.pop(context, DnsServerEditResult.copy(_ctrl.copySnapshot(tag)));
      return;
    }
    if (_ctrl.kind == ServerKind.inline) {
      final tag = _ctrl.tagCtrl.text.trim();
      if (tag.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Tag is required"))),
        );
        return;
      }
      if (_ctrl.jsonError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(getLocalText.s("Fix body JSON first: %s", '${_ctrl.jsonError}'))),
        );
        return;
      }
      // §117 задача 4b: для форменных режимов (UDP/DoT/DoH) адрес обязателен.
      // §312: КРОМЕ группы — у неё вместо адреса участники (`isGroup`).
      // §435: и КРОМЕ tailscale — у него вместо адреса endpoint.
      if (_ctrl.serverMode != null &&
          !_ctrl.isGroup &&
          !_ctrl.isTailscale &&
          _ctrl.addressCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Server address is required"))),
        );
        return;
      }
      // §435: у tailscale обязателен endpoint — без него сервер мёртв
      // (санитайзер сборки выбросит его с warning), хранить нечего.
      if (_ctrl.isTailscale && _ctrl.tailscaleEndpoint.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Tailscale node is required"))),
        );
        return;
      }
      // §117 задача 4b: rename existing — коллизия запрещена (replace-
      // семантики у rename нет, ссылки каскадно поедут на save).
      if (!_ctrl.isNew &&
          tag != (widget.resolved?.tag ?? '') &&
          widget.existingTags.contains(tag)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Tag \"%s\" is already in use", tag))),
        );
        return;
      }
      // New-режим: коллизия с существующим tag'ом → явный confirm replace
      // (раньше боттом-шит заменял молча).
      if (_ctrl.isNew && widget.existingTags.contains(tag)) {
        final replace = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(getLocalText.s("Tag \"%s\" exists", tag)),
            content: Text(getLocalText.s("Replace the existing server with this one?")),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(getLocalText.s("Cancel")),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(getLocalText.s("Replace")),
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

  /// §682 — Duplicate: копия текущего состояния формы уходит caller'у,
  /// тот открывает её в редакторе нового сервера; до Save ничего не пишется.
  void _duplicate() {
    final resolved = widget.resolved;
    if (resolved == null) return;
    final tag = dnsCopyTag(
        resolved.tag, {...widget.existingTags, resolved.tag});
    final desc = _ctrl.descCtrl.text.trim();
    Navigator.pop(
      context,
      DnsServerEditResult.duplicate(_ctrl.copySnapshot(tag,
          description: getLocalText.s(
              "%s (copy)", desc.isNotEmpty ? desc : resolved.tag))),
    );
  }

  Future<void> _delete() async {
    final resolved = widget.resolved;
    if (resolved == null) return;
    // §219 / §680 — текст зависит от вида: шаблонный возвращается из каталога.
    final confirmed = await confirmDeleteDnsServer(context, resolved);
    if (confirmed == true && mounted) {
      Navigator.pop(context, DnsServerEditResult.deleted());
    }
  }

  /// §043/§117: reset inline-override обратно к canonical (template/preset) —
  /// ref схлопывается в template/preset-ref с тем же `enabled` и тегом.
  Future<void> _resetToCanonical() async {
    final overrides = _ctrl.overrides;
    final resolved = widget.resolved;
    // overrides — вид canonical'а: template или preset.
    if (overrides == null || overrides == ServerKind.inline || resolved == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Reset to default?")),
        content: Text(getLocalText.s("Discard the override and restore the %1\$s definition of \"%2\$s\"?", overrides.name, resolved.tag)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Reset")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.pop(
      context,
      DnsServerEditResult.saved(overrides == ServerKind.preset
          ? DnsServerPreset(
              enabled: _ctrl.enabled,
              tag: resolved.tag,
              presetId: resolved.presetId)
          : DnsServerTemplate(enabled: _ctrl.enabled, tag: resolved.tag)),
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
    // §680 — inline и template (override — как template), если не залочен;
    // preset-ref живёт с пресетом.
    final resolved = widget.resolved;
    final canDelete = resolved != null && canDeleteDnsServer(resolved);
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
                  ? getLocalText.s("Add DNS Server")
                  : getLocalText.s("Edit DNS Server")),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _handleBack,
              ),
              actions: [
                if (canReset)
                  IconButton(
                    tooltip: getLocalText.s("Reset to default"),
                    icon: const Icon(Icons.restart_alt),
                    onPressed: _resetToCanonical,
                  ),
                if (canDelete)
                  IconButton(
                    tooltip: getLocalText.s("Delete server"),
                    icon: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    onPressed: _delete,
                  ),
                _SaveIconButton(controller: _ctrl, onPressed: _save),
                if (_ctrl.canCopy)
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'duplicate') _duplicate();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        value: 'duplicate',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.copy_all, size: 20),
                          title: Text(getLocalText.s("Duplicate")),
                        ),
                      ),
                    ],
                  ),
              ],
              bottom: TabBar(
                tabs: [
                  Tab(text: getLocalText.s("Params")),
                  Tab(text: getLocalText.s("JSON")),
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
          tooltip: controller.savesAsCopy
              ? getLocalText.s("Save as copy")
              : getLocalText.s("Save"),
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
  const DnsServerEditResult._(
      {this.saved, this.wasDeleted = false, this.copy, this.duplicate});

  /// Новый/обновлённый ref. Для reset-to-canonical — схлопнутый ref.
  final DnsServerRef? saved;
  final bool wasDeleted;

  /// §682 — «Save as copy»: inline-копия дописывается в список, оригинал
  /// остаётся как был.
  final DnsServerInline? copy;

  /// §682 — Duplicate: заготовка, которую caller открывает в редакторе
  /// нового сервера (в список пишется только по Save).
  final DnsServerInline? duplicate;

  factory DnsServerEditResult.saved(DnsServerRef ref) =>
      DnsServerEditResult._(saved: ref);
  factory DnsServerEditResult.copy(DnsServerInline ref) =>
      DnsServerEditResult._(copy: ref);
  factory DnsServerEditResult.duplicate(DnsServerInline ref) =>
      DnsServerEditResult._(duplicate: ref);
  factory DnsServerEditResult.deleted() =>
      const DnsServerEditResult._(wasDeleted: true);
}

/// §117 задача 4 — opener (паттерн `openCustomRuleEditor`). null = back без
/// изменений.
Future<DnsServerEditResult?> openDnsServerEditor(
  BuildContext context, {
  required DnsServerRef initialRef,
  ResolvedServer? resolved,
  Map<String, dynamic>? templateWrapper,
  String canonicalDescription = '',
  List<OutboundOption> outboundOptions = const [],
  List<String> dnsServerTags = const [],
  List<DnsMemberOption> dnsMemberOptions = const [],
  List<TailscaleEndpointOption> tailscaleEndpoints = const [],
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
        dnsMemberOptions: dnsMemberOptions,
        tailscaleEndpoints: tailscaleEndpoints,
        existingTags: existingTags,
      ),
    ),
  );
}
