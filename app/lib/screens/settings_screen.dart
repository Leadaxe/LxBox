import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/background_mode.dart';
import '../models/parser_config.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../vpn/box_vpn_client.dart';
import '../widgets/template_var_list.dart';
import 'vpn_mode_tab.dart';

/// VPN Settings — System (`VpnService.Builder` toggles) + Core (sing-box
/// engine vars, `chapter: 'core'`). Routing/DNS vars живут на своих экранах.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
    this.initialTab = 0,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  /// 0 = System, 1 = Core, 2 = Mode (§119). Used by deep-links.
  final int initialTab;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  WizardTemplate? _template;
  final _varValues = <String, String>{};
  // §076: template var changes pending для write-on-exit. Накапливается
  // {var_name → value} в `_onVarChanged` (роль `_markDirty` других lazy-
  // экранов; сигнатура отличается — здесь per-var, не boolean-флаг),
  // flush'ится в `_persist` (dispose + lifecycle.paused).
  //
  // §084 M14: Native VPN System toggles (allow_bypass / keep_on_exit /
  // background_mode) идут **другим** путём — НЕ через `_pendingVars`/
  // `_persist`/`configDirty`, а через `_vpn.setX()` (immediate native write)
  // + `homeController.markConfigChangedNeedRestart()` (home banner «Restart
  // VPN»). Это discrete-event toggles, не config-rebuild vars.
  final _pendingVars = <String, String>{};
  bool _loading = true;

  final _vpn = BoxVpnClient();
  bool _allowBypass = false;
  bool _keepOnExit = false;
  BackgroundMode _backgroundMode = BackgroundMode.never;
  bool _vpnLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // §076 write-on-exit: Navigator.pop → flush pending vars.
    if (_pendingVars.isNotEmpty) unawaited(_persist());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _pendingVars.isNotEmpty) {
      unawaited(_persist());
    }
  }

  /// §107: дисковый flush staged vars — мутации уже в `_cache` (см.
  /// `_onVarChanged`), осталось одно атомарное `flushToDisk()`. Native
  /// System settings (allow_bypass etc.) идут отдельно через `_vpn.setX`
  /// immediate.
  Future<void> _persist() async {
    if (_pendingVars.isEmpty) return;
    _pendingVars.clear();
    await SettingsStorage.flushToDisk();
    // configDirty уже true (set in _onVarChanged sync). Не трогаем.
  }

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final storedVars = await SettingsStorage.getAllVars();
    for (final v in template.vars) {
      _varValues[v.name] = storedVars[v.name] ?? v.defaultValue;
    }
    final allowBypass = await _vpn.getAllowBypass();
    final keep = await _vpn.getKeepOnExit();
    final bgMode = await _vpn.getBackgroundMode();
    setState(() {
      _template = template;
      _allowBypass = allowBypass;
      _keepOnExit = keep;
      _backgroundMode = bgMode;
      _vpnLoaded = true;
      _loading = false;
    });
  }

  Future<void> _toggleAllowBypass(bool enable) async {
    setState(() => _allowBypass = enable);
    await _vpn.setAllowBypass(enable);
    if (!mounted) return;
    // §076: home banner показывает «Restart VPN» если tunnelUp. Локальный
    // snackbar удалён — единый source-of-truth.
    widget.homeController.markConfigChangedNeedRestart();
  }

  void _toggleKeepOnExit(bool val) {
    setState(() => _keepOnExit = val);
    unawaited(_vpn.setKeepOnExit(val));
    widget.homeController.markConfigChangedNeedRestart();
  }

  Future<void> _applyBackgroundMode(BackgroundMode? mode) async {
    if (mode == null || mode == _backgroundMode) return;
    setState(() => _backgroundMode = mode);
    await _vpn.setBackgroundMode(mode);
    widget.homeController.markConfigChangedNeedRestart();
  }

  /// §076/§107: template var change. Staged-запись в `_cache` сразу + sync
  /// mark configDirty; дисковая запись — одним flush'ем в `_persist`
  /// (dispose / lifecycle.paused).
  void _onVarChanged(String name, String value) {
    _varValues[name] = value;
    _pendingVars[name] = value;
    unawaited(SettingsStorage.setVar(name, value, flush: false));
    widget.subController.configDirty = true; // sync race-safe
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('VPN Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;
    final editableVars = template
        .varsFor('core')
        .where((v) => v.isEditable)
        .toList();

    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('VPN Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'System'),
              Tab(text: 'Core'),
              Tab(text: 'Mode'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSystemTab(context),
            _buildCoreTab(context, template, editableVars),
            VpnModeTab(
              homeController: widget.homeController,
              subController: widget.subController,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemTab(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        SwitchListTile(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Flexible(child: Text('Allow VPN bypass')),
              const SizedBox(width: 6),
              Tooltip(
                message:
                    'Allows apps to bypass the VPN tunnel via '
                    'ConnectivityManager.bindProcessToNetwork(). '
                    'Useful for banking apps, captive portal detection, '
                    'or system services that refuse VPN connections.\n\n'
                    'Off = strict tunnel (all traffic forced through VPN).\n'
                    'Takes effect on next VPN connect.',
                preferBelow: false,
                triggerMode: TooltipTriggerMode.tap,
                showDuration: const Duration(seconds: 12),
                waitDuration: const Duration(milliseconds: 100),
                child: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          subtitle: Text(
            _allowBypass
                ? 'Apps may use ConnectivityManager to bypass tun.'
                : 'Strict tunnel — all traffic goes through tun.',
          ),
          secondary: const Icon(Icons.alt_route),
          value: _allowBypass,
          onChanged: (val) => unawaited(_toggleAllowBypass(val)),
        ),
        SwitchListTile(
          title: const Text('Keep VPN on exit'),
          subtitle: const Text('VPN stays active when app is closed'),
          secondary: const Icon(Icons.exit_to_app),
          value: _keepOnExit,
          onChanged: _vpnLoaded ? _toggleKeepOnExit : null,
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.bedtime_outlined, size: 20),
              const SizedBox(width: 12),
              Text('Tunnel sleep mode',
                  style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(48, 0, 16, 4),
          child: Text(
            'When to pause the tunnel to save battery. Takes effect on '
            'next VPN connect.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        RadioGroup<BackgroundMode>(
          groupValue: _backgroundMode,
          onChanged: (BackgroundMode? m) {
            if (!_vpnLoaded) return;
            unawaited(_applyBackgroundMode(m));
          },
          child: const Column(
            children: [
              RadioListTile<BackgroundMode>(
                value: BackgroundMode.never,
                title: Text('Never sleep (recommended)'),
                subtitle: Text(
                    'Tunnel is always active. Best reliability — pushes '
                    'and long-lived sockets survive. Higher battery use.'),
              ),
              RadioListTile<BackgroundMode>(
                value: BackgroundMode.lazy,
                title: Text('Lazy sleep'),
                subtitle: Text(
                    'Pause only in deep Doze (screen off for a long '
                    'time + no motion). Balanced.'),
              ),
              RadioListTile<BackgroundMode>(
                value: BackgroundMode.always,
                title: Text('Aggressive battery saving'),
                subtitle: Text(
                    'Pause tunnel whenever screen turns off. Max '
                    'battery savings, but pushes, incoming calls and '
                    'background sync stop until unlock.'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoreTab(
    BuildContext context,
    WizardTemplate template,
    List<WizardVar> editableVars,
  ) {
    if (editableVars.isEmpty) {
      return const Center(child: Text('No configurable variables'));
    }
    final sectionDescriptions = {
      for (final s in template.sectionsFor('core')) s.title: s.description,
    };
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        TemplateVarListView(
          vars: editableVars,
          initialValues: _varValues,
          sectionDescriptions: sectionDescriptions,
          onChanged: _onVarChanged,
        ),
      ],
    );
  }
}
