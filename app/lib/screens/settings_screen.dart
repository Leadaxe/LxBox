import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/background_mode.dart';
import '../models/parser_config.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
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
  // §084 M14 / §189: Native VPN System toggle (background_mode; §188 —
  // allow_bypass / keep_on_exit переехали в Mode-вкладку) идёт через
  // `SettingsStorage.setNativeBackgroundMode` (§189 — JSON-истина + зеркало в
  // native) + `markConfigChangedNeedRestart` (home banner «Restart VPN»). Это
  // discrete-event toggle, не config-rebuild var.
  final _pendingVars = <String, String>{};
  bool _loading = true;

  BackgroundMode _backgroundMode = BackgroundMode.never;
  bool _vpnLoaded = false;
  // §143 — НЕ native/config-significant: чистая storage-настройка поведения
  // Clash-API клиента при переключении ноды. Без Restart-баннера.
  bool _interruptOnSwitch = false;

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
  /// System settings (background_mode) идут через
  /// `SettingsStorage.setNativeBackgroundMode` (§189) immediate.
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
    // §189 — background_mode читаем из JSON-зеркала native_prefs (истина).
    final bgMode = BackgroundMode.fromNative(
        await SettingsStorage.getNativeBackgroundMode());
    final interruptOnSwitch = await SettingsStorage.getInterruptOnSwitch();
    setState(() {
      _template = template;
      _backgroundMode = bgMode;
      _interruptOnSwitch = interruptOnSwitch;
      _vpnLoaded = true;
      _loading = false;
    });
  }

  // §143 — toggle persist'ится сразу в storage. НЕ config-significant → без
  // `markConfigChangedNeedRestart` (в отличие от соседних native-туглов, §084 M14).
  void _toggleInterruptOnSwitch(bool val) {
    setState(() => _interruptOnSwitch = val);
    unawaited(SettingsStorage.setInterruptOnSwitch(val));
  }

  // §188 — _toggleAllowBypass / _toggleKeepOnExit переехали в vpn_mode_tab.dart.

  Future<void> _applyBackgroundMode(BackgroundMode? mode) async {
    if (mode == null || mode == _backgroundMode) return;
    setState(() => _backgroundMode = mode);
    // §189 — через NativePrefs (JSON-истина + зеркало в native).
    await SettingsStorage.setNativeBackgroundMode(mode.wireValue);
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
              template: template,
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
        // §188 — «Allow VPN bypass» и «Keep VPN on exit» переехали в Mode-вкладку
        // (TUN-зависимы → видны только в vpn / vpn_proxy режимах).
        SwitchListTile(
          title: const Text('Interrupt connections on switch'),
          subtitle: const Text(
              'Drop active connections when you switch nodes, so traffic '
              'moves to the new node immediately'),
          secondary: const Icon(Icons.swap_horiz),
          value: _interruptOnSwitch,
          onChanged: _toggleInterruptOnSwitch,
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
