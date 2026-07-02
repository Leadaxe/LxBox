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
  // §143/§219 — НЕ native/config-significant: чистая storage-настройка
  // поведения CommandClient при переключении ноды (selectOutbound +
  // closeConnection). Без Restart-баннера.
  bool _interruptOnSwitch = false;
  String _idleSuspend = ''; // §215 — route.lx_idle_suspend threshold ("" = off)

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
    final idleSuspend = await SettingsStorage.getIdleSuspend(); // §215
    setState(() {
      _template = template;
      _backgroundMode = bgMode;
      _interruptOnSwitch = interruptOnSwitch;
      _idleSuspend = idleSuspend;
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

  /// §215 — idle-suspend threshold (route.lx_idle_suspend, kernel SPEC 020).
  /// Выбор списком (RadioGroup) — применяется сразу, config-significant.
  Future<void> _applyIdleSuspend(String value) async {
    if (value == _idleSuspend) return;
    setState(() => _idleSuspend = value);
    await SettingsStorage.saveIdleSuspend(value);
    widget.subController.configDirty = true;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Applies on next connect.'),
        duration: Duration(seconds: 3),
      ),
    );
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
        const TemplateSectionHeader(
          title: 'Optimization',
          description:
              'Memory and battery tuning for WireGuard tunnels and VPN lifecycle',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Suspend idle tunnels',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 2),
              Text(
                'Put unreachable WireGuard tunnels to sleep after they sit '
                'idle, freeing memory and saving battery. They wake instantly '
                'on use. Only affects tunnels not on the active route.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: DropdownButtonFormField<String>(
            initialValue: _idleSuspend,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem<String>(value: '', child: Text('Off')),
              DropdownMenuItem<String>(value: '30s', child: Text('30 seconds')),
              DropdownMenuItem<String>(value: '2m', child: Text('2 minutes')),
              DropdownMenuItem<String>(value: '5m', child: Text('5 minutes')),
            ],
            onChanged: (String? v) {
              if (!_vpnLoaded || v == null) return;
              unawaited(_applyIdleSuspend(v));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tunnel sleep mode',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 2),
              Text(
                'When to pause the tunnel to save battery. Takes effect on '
                'next VPN connect.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
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
