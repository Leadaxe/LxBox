import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/automation/event_emitter.dart';
import '../../../services/settings_storage.dart';
import '../../../services/url_launcher.dart' as ul;
import '../../../vpn/box_vpn_client.dart';
import '../../../services/l10n/locale_controller.dart';

/// §047 Public Intent API — вкладка App Settings → Automation.
///
/// Самодостаточный StatefulWidget: грузит/сохраняет свои настройки сам (через
/// [SettingsStorage]) и синкает в native ([BoxVpnClient]) — не раздувает
/// родительский `_AppSettingsScreenState`.
///
/// Состав:
///   - мастер-toggle «Принимать команды автоматизации» (включает receiver);
///   - список intent-строк команд с кнопкой копирования;
///   - 4 emit-категории (Lifecycle / State / Subscription / Health);
///   - explainer-диалог при первом включении emit-категории;
///   - ссылка на docs.
class AutomationTab extends StatefulWidget {
  const AutomationTab({super.key, required this.padding});

  final EdgeInsets padding;

  @override
  State<AutomationTab> createState() => _AutomationTabState();
}

class _AutomationTabState extends State<AutomationTab> {
  static const _docsUrl =
      'https://github.com/Leadaxe/LxBox/blob/main/docs/AUTOMATION.md';

  /// (action-строка, подпись с extras) для UI-списка команд.
  static const _commands = <(String, String)>[
    ('com.leadaxe.lxbox.START_VPN', ''),
    ('com.leadaxe.lxbox.STOP_VPN', ''),
    ('com.leadaxe.lxbox.TOGGLE_VPN', ''),
    ('com.leadaxe.lxbox.SWITCH_NODE', 'extra: tag'),
    ('com.leadaxe.lxbox.SET_GROUP', 'extra: group'),
    ('com.leadaxe.lxbox.REBUILD_CONFIG', ''),
    ('com.leadaxe.lxbox.REFRESH_SUBS', 'extra: force'),
    ('com.leadaxe.lxbox.RESET_NETWORK', ''),
    ('com.leadaxe.lxbox.URLTEST_GROUP', 'extra: group'),
  ];

  bool _loaded = false;
  bool _receiveEnabled = false;
  bool _emitLifecycle = false;
  bool _emitState = false;
  bool _emitSubs = false;
  bool _emitHealth = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final receive = await SettingsStorage.getAutomationReceiveEnabled();
    final lifecycle = await SettingsStorage.getAutomationEmitLifecycle();
    final state = await SettingsStorage.getAutomationEmitState();
    final subs = await SettingsStorage.getAutomationEmitSubs();
    final health = await SettingsStorage.getAutomationEmitHealth();
    if (!mounted) return;
    setState(() {
      _receiveEnabled = receive;
      _emitLifecycle = lifecycle;
      _emitState = state;
      _emitSubs = subs;
      _emitHealth = health;
      _loaded = true;
    });
  }

  // ─── Master toggle ──────────────────────────────────────────────────────────

  Future<void> _onReceiveChanged(bool value) async {
    if (value) {
      final ok = await _confirmEnableReceiver();
      if (ok != true) return;
    }
    setState(() => _receiveEnabled = value);
    await SettingsStorage.setAutomationReceiveEnabled(value);
    await BoxVpnClient.I.setAutomationEnabled(value);
  }

  Future<bool?> _confirmEnableReceiver() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Enable command receiver?")),
        content: Text(getLocalText.s("Any app on this device will be able to control the VPN via broadcast commands while this is on. Only turn it on if you use Tasker / Macrodroid and understand the implications.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(getLocalText.s("Enable")),
          ),
        ],
      ),
    );
  }

  // ─── Emit categories ─────────────────────────────────────────────────────────

  Future<void> _onEmitChanged(
    bool value,
    Future<void> Function(bool) persist,
    void Function(bool) apply,
  ) async {
    if (value && !await SettingsStorage.getAutomationExplainerShown()) {
      final ok = await _showEmitExplainer();
      if (ok != true) return;
      await SettingsStorage.setAutomationExplainerShown(true);
    }
    setState(() => apply(value));
    await persist(value);
    await AutomationEventEmitter.I.reload();
  }

  Future<bool?> _showEmitExplainer() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Emitting events outward")),
        content: Text(getLocalText.s("Enabling this category lets other apps receive L×Box events.\n\nEvents do NOT contain subscription / config secrets — only labels (node tags, group names, status).")),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(getLocalText.s("Continue")),
          ),
        ],
      ),
    );
  }

  // ─── Clipboard ───────────────────────────────────────────────────────────────

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(getLocalText.s("%s copied", label)),
          duration: const Duration(seconds: 1)),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(
      fontSize: 12,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      padding: widget.padding,
      children: [
        Text(getLocalText.s("Automation API"),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          getLocalText.s("Control L×Box from Tasker / Macrodroid / Llama and other automation apps via Android broadcast intents."),
          style: muted,
        ),
        const Divider(height: 28),

        // ─── Master ───
        Text(getLocalText.s("Command receiver"),
            style: theme.textTheme.titleSmall),
        SwitchListTile(
          title: Text(getLocalText.s("Accept automation commands")),
          subtitle: Text(getLocalText.s("Start / Stop / Toggle / Switch / Refresh / … (default OFF)")),
          secondary: const Icon(Icons.settings_remote),
          value: _receiveEnabled,
          onChanged: _loaded ? _onReceiveChanged : null,
        ),

        const Divider(height: 28),

        // ─── Commands ───
        Text(getLocalText.s("Commands (intent actions)"),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          getLocalText.s("Paste into the \"Send Intent\" of your automation app. Target: Broadcast Receiver."),
          style: muted,
        ),
        const SizedBox(height: 4),
        for (final (action, extra) in _commands)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              action,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            subtitle: extra.isEmpty ? null : Text(extra, style: muted),
            trailing: IconButton(
              tooltip: getLocalText.s("Copy"),
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () =>
                  _copy(action, getLocalText.s("Command")),
            ),
          ),

        const Divider(height: 28),

        // ─── Emit categories ───
        Text(getLocalText.s("Outbound events (emit)"),
            style: theme.textTheme.titleSmall),
        SwitchListTile(
          title: Text(getLocalText.s("Lifecycle")),
          subtitle: const Text(
            // l10n-exempt: broadcast event names (wire values)
            'VPN_CONNECTED · DISCONNECTED · ERROR · REVOKED · '
            'UPDATE_AVAILABLE · PERMISSION_NEEDED',
          ),
          value: _emitLifecycle,
          onChanged: _loaded
              ? (v) => _onEmitChanged(v,
                  SettingsStorage.setAutomationEmitLifecycle,
                  (x) => _emitLifecycle = x)
              : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("State")),
          // l10n-exempt: broadcast event names (wire values)
          subtitle: const Text('ACTIVE_NODE_CHANGED · ACTIVE_GROUP_CHANGED'),
          value: _emitState,
          onChanged: _loaded
              ? (v) => _onEmitChanged(v,
                  SettingsStorage.setAutomationEmitState, (x) => _emitState = x)
              : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Subscription")),
          // l10n-exempt: broadcast event names (wire values)
          subtitle: const Text('SUB_REFRESHED · SUB_REFRESH_FAILED'),
          value: _emitSubs,
          onChanged: _loaded
              ? (v) => _onEmitChanged(v,
                  SettingsStorage.setAutomationEmitSubs, (x) => _emitSubs = x)
              : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Health")),
          subtitle: const Text(
            // l10n-exempt: broadcast event names (wire values)
            'HEARTBEAT_FAILED · LATENCY_DEGRADED',
          ),
          value: _emitHealth,
          onChanged: _loaded
              ? (v) => _onEmitChanged(v,
                  SettingsStorage.setAutomationEmitHealth,
                  (x) => _emitHealth = x)
              : null,
        ),

        const Divider(height: 28),
        OutlinedButton.icon(
          onPressed: () => ul.UrlLauncher.open(_docsUrl),
          icon: const Icon(Icons.menu_book_outlined, size: 18),
          label: Text(getLocalText.s("Documentation and Tasker recipes")),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
