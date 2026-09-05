// §046 — Tunnel apps: OS-level split and direct routing inside the VPN.
//
// UI для `tun_apps` storage shape (mode + packages list).
// Builder applyTunPackages(): allow/deny → tun.{include,exclude}_package;
// direct → правило package_name внутри tun (совместимо с Android lockdown).
// Native слой BoxVpnService.openTun пробрасывает include/exclude в
// VpnService.Builder.addAllowedApplication/addDisallowedApplication.
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
import '../services/l10n/locale_controller.dart';

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
  // button — удалены. Staging через LazyPersistMixin (§085 R4 / §107):
  //   - mutations → markDirty() + setState; буфер сразу в _cache (stageChanges)
  //   - dispose / AppLifecycleState.paused → flushToDisk (atomic write)
  //   - markDirty set'ит subController.configDirty = true sync
  //   - home banner показывает «Apply / Restart» глобально
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
      AppInfoCache.ensure(pkg);
    }
  }

  /// §107: staging — `_cfg` в `_cache` на каждую мутацию; дисковый flush —
  /// mixin'ом (flushToDisk) на dispose/paused. `configDirty` уже set'нут в
  /// `markDirty()` синхронно — не трогаем.
  @override
  Future<void> stageChanges() async {
    await SettingsStorage.setTunApps(_cfg, flush: false);
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
        title: Text(getLocalText.s("Clear all apps?")),
        content: Text(
          getLocalText.plural("Remove all %1\$d apps from the list. Mode (%2\$s) is kept.", _cfg.packages.length, _cfg.mode),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _cfg = _cfg.copyWith(packages: const <String>[]));
              markDirty();
            },
            child: Text(getLocalText.s("Clear")),
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
        title: Text(getLocalText.s("Tunnel apps — routing modes")),
        content: SingleChildScrollView(
          child: Text(getLocalText.s("Choose how the listed apps use the VPN.\n\n• Off — all apps use the tunnel and your routing rules.\n• Allow-list — only listed apps enter the tunnel.\n• Deny-list — listed apps bypass the tunnel.\n• Direct (lockdown) — all apps enter the tunnel; listed apps connect directly through LxBox before other routing rules. DNS follows your DNS settings.\n\nAndroid blocks apps outside the tunnel when \"Block connections without VPN\" is enabled. Use Direct (lockdown) to keep selected apps connected while the VPN is running. These apps still see an active VPN; when it stops, Android blocks their connections too.\n\nThis applies to the Android profile running LxBox. Restart the VPN after switching modes.")),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("OK")),
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
            Text(getLocalText.s("Mode"), style: tt.titleMedium),
            const SizedBox(width: 4),
            Tooltip(
              message: getLocalText.s("Allow-list and Deny-list exclude apps from the tunnel. Android lockdown blocks excluded apps. Direct (lockdown) keeps all apps in the tunnel and connects listed apps directly through LxBox."),
              triggerMode: TooltipTriggerMode.tap,
              child: Icon(
                Icons.info_outline,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            PopupMenuButton<String>(
              tooltip: getLocalText.s("More"),
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
                PopupMenuItem(
                  value: 'vpn_system',
                  child: ListTile(
                    leading: const Icon(Icons.tune),
                    title: Text(getLocalText.s("VPN settings (System)")),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'clear',
                  enabled: _cfg.packages.isNotEmpty,
                  child: Text(getLocalText.s("Clear all")),
                ),
                PopupMenuItem(
                    value: 'help', child: Text(getLocalText.s("Help"))),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _cfg.mode,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            DropdownMenuItem(value: 'off', child: Text(getLocalText.s("Off"))),
            DropdownMenuItem(
                value: 'allow', child: Text(getLocalText.s("Allow-list"))),
            DropdownMenuItem(
                value: 'deny', child: Text(getLocalText.s("Deny-list"))),
            DropdownMenuItem(
                value: 'direct', child: Text(getLocalText.s("Direct (lockdown)"))),
          ],
          onChanged: (mode) {
            if (mode != null) _setMode(mode);
          },
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
                getLocalText.s("Apps in this list (%d)", _cfg.packages.length),
                style: tt.titleMedium,
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: _pickApps,
                icon: const Icon(Icons.add, size: 18),
                label: Text(getLocalText.s("Add app")),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_cfg.packages.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                getLocalText.s("No apps yet. Tap \"Add app\" to pick."),
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
    // §109: метка только при ПОДТВЕРЖДЁННОМ native'ом not-found.
    // «Ещё грузится» / «проверка сорвалась (timeout)» → обычный tile без
    // метки (раньше любая неудача красила «uninstalled» до конца сессии).
    final uninstalled = AppInfoCache.isNotFound(pkg);
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
        uninstalled ? getLocalText.s("%s — uninstalled, auto-skipped", pkg) : pkg,
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 20),
        tooltip: getLocalText.s("Remove"),
        onPressed: () => _removeApp(pkg),
      ),
    );
  }

  String _modeDescription(String mode) {
    switch (mode) {
      case 'allow':
        return getLocalText.s("Only selected apps enter the tunnel. Android lockdown blocks all other apps.");
      case 'deny':
        return getLocalText.s("Selected apps bypass the tunnel. Android lockdown blocks these apps; use Direct (lockdown) to keep them connected.");
      case 'direct':
        return getLocalText.s("Selected apps connect directly through LxBox, even with Android lockdown enabled. Other apps follow routing rules. DNS follows your DNS settings. Requires a running VPN.");
      default:
        return getLocalText.s("All apps enter the tunnel and follow your routing rules (default).");
    }
  }
}
