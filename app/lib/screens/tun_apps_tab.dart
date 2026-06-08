// §046 — Tunnel apps tab. OS-level split-tunneling control.
//
// UI для `tun_apps` storage shape (mode + packages list).
// Builder applyTunPackages() трансформирует это в config.tun.{include,exclude}_package.
// Native слой BoxVpnService.kt:557-560 далее пробрасывает в VpnService.Builder.
//
// Изменения требуют **full VPN restart** (не light reload) — addAllowedApplication
// applies только на builder.establish(). Banner показывается при tunnel up.

import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../services/app_info_cache.dart';
import '../services/settings_storage.dart' show SettingsStorage, TunAppsConfig;
import 'app_picker_screen.dart';
import 'lazy_persist_mixin.dart';
import 'settings_screen.dart';

class TunAppsTab extends StatefulWidget {
  const TunAppsTab({
    super.key,
    required this.homeController,
    required this.subController,
  });

  final HomeController homeController;
  final SubscriptionController subController;

  @override
  State<TunAppsTab> createState() => _TunAppsTabState();
}

class _TunAppsTabState extends State<TunAppsTab>
    with WidgetsBindingObserver, LazyPersistMixin<TunAppsTab> {
  TunAppsConfig _cfg = const TunAppsConfig(mode: 'off', packages: <String>[]);
  // §076: `_appliedCfg` / `_isModified` / `_listEq` / local restart banner +
  // button — удалены. Lazy write-on-exit через LazyPersistMixin (§085 R4):
  //   - mutations → markDirty() + setState (in-memory)
  //   - dispose / AppLifecycleState.paused → persistChanges (atomic write)
  //   - markDirty set'ит subController.configDirty = true sync
  //   - home banner показывает «Apply / Restart» глобально
  //
  // packages для которых мы вызвали `AppInfoCache.ensure(pkg)`.
  final Set<String> _ensured = <String>{};
  bool _loading = true;

  @override
  SubscriptionController get lazyController => widget.subController;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cfg = await SettingsStorage.getTunApps();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _loading = false;
    });
    for (final pkg in cfg.packages) {
      _ensured.add(pkg);
      AppInfoCache.ensure(pkg);
    }
  }

  /// §076/§085 R4: atomic disk flush (вызывается mixin'ом на dispose/paused).
  /// `setTunApps` идёт через §072 atomic write. `configDirty` уже set'нут в
  /// `markDirty()` синхронно — не трогаем.
  @override
  Future<void> persistChanges() async {
    await SettingsStorage.setTunApps(_cfg);
  }

  void _setMode(String mode) {
    setState(() {
      _cfg = _cfg.copyWith(mode: mode);
    });
    markDirty();
  }

  Future<void> _pickApps() async {
    final result = await Navigator.push<AppPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(selected: _cfg.packages.toSet()),
      ),
    );
    if (result == null || !mounted) return;
    final newPackages = List<String>.from(result.packages)..sort();
    setState(() {
      _cfg = _cfg.copyWith(packages: newPackages);
    });
    for (final pkg in newPackages) {
      _ensured.add(pkg);
      AppInfoCache.ensure(pkg);
    }
    markDirty();
  }

  void _removeApp(String pkg) {
    setState(() {
      _cfg = _cfg.copyWith(
        packages: _cfg.packages.where((p) => p != pkg).toList(),
      );
    });
    markDirty();
  }

  void _clearAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all apps?'),
        content: Text(
          'Remove all ${_cfg.packages.length} apps from the list. '
          'Mode (${_cfg.mode}) is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _cfg = _cfg.copyWith(packages: const <String>[]));
              markDirty();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _openVpnSettingsSystem() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          subController: widget.subController,
          homeController: widget.homeController,
          initialTab: 0, // 0 = System (VpnService toggles); per-app split
                          // — это System-level фича, не Core sing-box.
        ),
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tunnel apps — OS-level split'),
        content: const SingleChildScrollView(
          child: Text(
            'This is OS-level split-tunneling. It controls which apps see the '
            'VPN tunnel at all — packets from excluded apps go directly via '
            'cellular/wifi without entering sing-box.\n\n'
            '• Off — every app uses the VPN (default)\n'
            '• Allow-list — ONLY listed apps go through VPN; everything else '
            'bypasses\n'
            '• Deny-list — listed apps bypass VPN; everything else goes '
            'through\n\n'
            'Note: apps in the Allow-list still go through your normal routing '
            'rules. Apps that bypass the tunnel are not visible to sing-box at '
            'all — your custom rules with package_name will not match them.\n\n'
            'Changes require a full VPN restart to apply (Android creates the '
            'tun interface only at start).',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // Подписка на icon-cache updates: re-render когда AppInfo подгружаются.
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // §076: tunnelUp / showRestartBanner — удалены. Home banner показывает
    // «Apply / Restart» глобально через configDirty + configChangedNeedRestart.
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad),
      children: [
        // ─── Header: Mode + tooltip + overflow ───
        Row(
          children: [
            Text('Mode', style: tt.titleMedium),
            const SizedBox(width: 4),
            Tooltip(
              message:
                  'OS-level split-tunneling. Apps in Allow-list go through tun '
                  '— routing rules apply normally. Apps outside Allow-list (or '
                  'in Deny-list) bypass VPN entirely; sing-box doesn\'t see '
                  'them, custom rules with package_name won\'t match.',
              triggerMode: TooltipTriggerMode.tap,
              child: Icon(
                Icons.info_outline,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'vpn_system':
                    _openVpnSettingsSystem();
                  case 'clear':
                    _clearAll();
                  case 'help':
                    _showHelp();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'vpn_system',
                  child: ListTile(
                    leading: Icon(Icons.tune),
                    title: Text('VPN settings (System)'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'clear',
                  enabled: _cfg.packages.isNotEmpty,
                  child: const Text('Clear all'),
                ),
                const PopupMenuItem(value: 'help', child: Text('Help')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'off', label: Text('Off')),
            ButtonSegment(value: 'allow', label: Text('Allow-list')),
            ButtonSegment(value: 'deny', label: Text('Deny-list')),
          ],
          selected: {_cfg.mode},
          onSelectionChanged: (s) => _setMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _modeDescription(_cfg.mode),
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),

        // §076: локальный «Restart needed» banner удалён.
        // Home banner единый source-of-truth для «Apply / Restart».


        if (!_cfg.isOff) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                'Apps in this list (${_cfg.packages.length})',
                style: tt.titleMedium,
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: _pickApps,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add app'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_cfg.packages.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No apps yet. Tap "Add app" to pick.',
                textAlign: TextAlign.center,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            )
          else
            ..._sortedPackages().map(_buildAppTile),
        ],
      ],
    );
  }

  List<String> _sortedPackages() {
    final list = List<String>.from(_cfg.packages);
    list.sort((a, b) {
      final na = AppInfoCache.of(a)?.appName ?? a;
      final nb = AppInfoCache.of(b)?.appName ?? b;
      return na.toLowerCase().compareTo(nb.toLowerCase());
    });
    return list;
  }

  Widget _buildAppTile(String pkg) {
    final info = AppInfoCache.of(pkg);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // Native пыталась найти, не нашла → uninstalled.
    final uninstalled = info == null && _ensured.contains(pkg);
    final displayName = info?.appName ?? pkg;

    Widget leading;
    final icon = info?.icon;
    if (icon != null) {
      leading = Opacity(
        opacity: uninstalled ? 0.4 : 1.0,
        child: Image.memory(icon, width: 36, height: 36),
      );
    } else {
      leading = CircleAvatar(
        radius: 18,
        backgroundColor: cs.surfaceContainerHighest,
        child: Icon(
          uninstalled ? Icons.help_outline : Icons.android,
          size: 20,
          color: cs.onSurfaceVariant,
        ),
      );
    }

    return ListTile(
      leading: leading,
      title: Text(
        displayName,
        style: TextStyle(
          color: uninstalled ? cs.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text(
        uninstalled ? '$pkg — uninstalled, auto-skipped' : pkg,
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 20),
        tooltip: 'Remove',
        onPressed: () => _removeApp(pkg),
      ),
    );
  }

  String _modeDescription(String mode) {
    switch (mode) {
      case 'allow':
        return 'Only selected apps go through VPN. Others bypass via cellular/wifi.';
      case 'deny':
        return 'Selected apps bypass VPN. Others go through.';
      default:
        return 'All apps go through VPN (default).';
    }
  }
}
