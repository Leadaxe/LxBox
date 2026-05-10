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

/// VPN Settings — два tab'а (§052):
///
/// - **System** — Android-side controls через `VpnService.Builder` API.
///   Сейчас: Allow VPN bypass (§049 F15). Room для будущих Builder-toggle'ов
///   (`setMetered`, `setUnderlyingNetworks`, `setHttpProxy` для VPN — если
///   когда-нибудь будем экспонировать).
/// - **Core** — sing-box core engine vars (template `chapter: core`,
///   фильтрация в `build`). Имя tab'а matches existing project concept:
///   `chapter: 'core'`, `corelog.txt`, `DebugSource.core`. Routing- и
///   DNS-специфичные vars (chapter: routing/dns) живут на своих экранах
///   (Routing, DNS Settings).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  WizardTemplate? _template;
  final _varValues = <String, String>{};
  bool _loading = true;
  Timer? _saveTimer;

  // §049 F15: native-side VPN toggle. Не template-var (storage native через
  // BoxVpnClient), но семантически принадлежит "VPN engine settings" — живёт
  // здесь рядом с template-vars для core chapter'а.
  final _vpn = BoxVpnClient();
  bool _allowBypass = false;
  // §052 Phase 2: переехали из App Settings → Background.
  bool _keepOnExit = false;
  BackgroundMode _backgroundMode = BackgroundMode.never;
  bool _vpnLoaded = false; // gate для onChanged в System tab

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
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

  /// §049 F15: toggle allowBypass. Применяется при следующем openTun.
  Future<void> _toggleAllowBypass(bool enable) async {
    setState(() => _allowBypass = enable);
    await _vpn.setAllowBypass(enable);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved. Reload VPN to apply.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// §052 Phase 2: keep VPN on exit (переехало из App Settings → Background).
  void _toggleKeepOnExit(bool val) {
    setState(() => _keepOnExit = val);
    unawaited(_vpn.setKeepOnExit(val));
  }

  /// §052 Phase 2: tunnel sleep mode (= `BackgroundMode` enum).
  Future<void> _applyBackgroundMode(BackgroundMode? mode) async {
    if (mode == null || mode == _backgroundMode) return;
    setState(() => _backgroundMode = mode);
    await _vpn.setBackgroundMode(mode);
  }

  void _onVarChanged(String name, String value) {
    _varValues[name] = value;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      await SettingsStorage.setVar(name, value);
      await _regenerateConfig();
    });
  }

  Future<void> _regenerateConfig() async {
    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (config == null || !mounted) return;
    final ok = await widget.homeController.saveParsedConfig(config);
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings applied, config regenerated')),
    );
    if (widget.homeController.state.tunnelUp && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restart VPN to apply changes')),
      );
    }
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
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('VPN Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'System'),
              Tab(text: 'Core'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSystemTab(context),
            _buildCoreTab(context, template, editableVars),
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
        // §049 F15 — VPN bypass opt-in. Native-side toggle (not template var):
        // controls `VpnService.Builder.allowBypass()`. Apply'ится при
        // следующем openTun (start или reload VPN).
        SwitchListTile(
          title: const Text('Allow VPN bypass'),
          subtitle: Text(
            _allowBypass
                ? 'Apps may use ConnectivityManager to bypass tun.'
                : 'Strict tunnel — all traffic goes through tun.',
          ),
          secondary: const Icon(Icons.alt_route),
          value: _allowBypass,
          onChanged: (val) => unawaited(_toggleAllowBypass(val)),
        ),
        // §052 Phase 2 — переехало из App Settings → Background.
        SwitchListTile(
          title: const Text('Keep VPN on exit'),
          subtitle: const Text('VPN stays active when app is closed'),
          secondary: const Icon(Icons.exit_to_app),
          value: _keepOnExit,
          onChanged: _vpnLoaded ? _toggleKeepOnExit : null,
        ),
        const Divider(height: 32),
        // §052 Phase 2 — Tunnel sleep mode (BackgroundMode enum), переехало
        // из App Settings → Background.
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
