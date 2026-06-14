// §119 — VPN mode tab. Выбор как ядро ловит трафик (inbound-трактовка):
//   • VPN       — только tun-inbound (текущее поведение, default).
//   • Proxy     — только локальный mixed-inbound (HTTP+SOCKS), без TUN.
//   • VPN+Proxy — tun + mixed одновременно.
//
// UI для `vpn_mode` storage shape. Builder applyVpnMode() трансформирует это
// в config.inbounds. Смена режима меняет inbounds → требует FULL VPN restart
// (наследуется от config-dirty машинерии: home banner Apply/Restart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../services/settings_storage.dart' show SettingsStorage, VpnModeConfig;
import '../services/subscription/subscription_identity.dart'
    show generateProxyPassword;
import 'lazy_persist_mixin.dart';

class VpnModeTab extends StatefulWidget {
  const VpnModeTab({
    super.key,
    required this.homeController,
    required this.subController,
  });

  final HomeController homeController;
  final SubscriptionController subController;

  @override
  State<VpnModeTab> createState() => _VpnModeTabState();
}

class _VpnModeTabState extends State<VpnModeTab>
    with WidgetsBindingObserver, LazyPersistMixin<VpnModeTab> {
  VpnModeConfig _cfg = const VpnModeConfig.defaults();
  bool _loading = true;
  bool _showPassword = false;

  late final TextEditingController _portCtl;
  late final TextEditingController _userCtl;
  late final TextEditingController _passCtl;
  String _portError = '';

  @override
  SubscriptionController get lazyController => widget.subController;

  @override
  void initState() {
    super.initState();
    _portCtl = TextEditingController();
    _userCtl = TextEditingController();
    _passCtl = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _portCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await SettingsStorage.getVpnMode();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _portCtl.text = cfg.proxyPort.toString();
      _userCtl.text = cfg.proxyUsername;
      _passCtl.text = cfg.proxyPassword;
      _loading = false;
    });
  }

  @override
  Future<void> stageChanges() async {
    await SettingsStorage.setVpnMode(_cfg, flush: false);
  }

  /// Любая мутация: staging + sync configDirty (mixin) + restart-banner если
  /// туннель поднят (смена inbounds → full restart).
  void _commit() {
    markDirty();
    widget.homeController.markConfigChangedNeedRestart();
  }

  void _setMode(String mode) {
    var next = _cfg.copyWith(mode: mode);
    // При переходе на режим с прокси + включённый auth + пустой пароль —
    // генерим (по образцу §118 HWID lazy-gen).
    if (next.hasMixed && next.effectiveAuth && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() => _cfg = next);
    _commit();
  }

  void _setProtocol(String proto) {
    if (proto == _cfg.proxyProtocol) return;
    setState(() => _cfg = _cfg.copyWith(proxyProtocol: proto));
    _commit();
  }

  void _setListen(String listen) {
    var next = _cfg.copyWith(proxyListen: listen);
    // 0.0.0.0 форсит auth on → пустой пароль надо сгенерить.
    if (next.effectiveAuth && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() => _cfg = next);
    _commit();
  }

  void _toggleAuth(bool enable) {
    var next = _cfg.copyWith(proxyAuthEnabled: enable);
    if (enable && next.proxyPassword.isEmpty) {
      final pass = generateProxyPassword();
      next = next.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    }
    setState(() => _cfg = next);
    _commit();
  }

  void _applyPort(String raw) {
    final port = int.tryParse(raw);
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _portError = 'Port must be 1024..65535');
      return;
    }
    if (port == _cfg.proxyPort) {
      setState(() => _portError = '');
      return;
    }
    setState(() {
      _portError = '';
      _cfg = _cfg.copyWith(proxyPort: port);
    });
    _commit();
  }

  void _applyUsername(String raw) {
    final u = raw.trim();
    if (u == _cfg.proxyUsername) return;
    setState(() => _cfg = _cfg.copyWith(proxyUsername: u));
    _commit();
  }

  void _applyPassword(String raw) {
    if (raw == _cfg.proxyPassword) return;
    setState(() => _cfg = _cfg.copyWith(proxyPassword: raw));
    _commit();
  }

  void _regeneratePassword() {
    final pass = generateProxyPassword();
    setState(() {
      _cfg = _cfg.copyWith(proxyPassword: pass);
      _passCtl.text = pass;
    });
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad),
      children: [
        Row(
          children: [
            Text('Mode', style: tt.titleMedium),
            const SizedBox(width: 4),
            Tooltip(
              message:
                  'How the core captures traffic.\n\n'
                  '• VPN — system-wide tunnel (current behaviour).\n'
                  '• Proxy — local HTTP+SOCKS port only, no TUN. Apps must be '
                  'pointed at it manually.\n'
                  '• VPN+Proxy — both at once.\n\n'
                  'Changing the mode requires a full VPN restart.',
              triggerMode: TooltipTriggerMode.tap,
              child: Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'vpn', label: Text('VPN')),
            ButtonSegment(value: 'proxy', label: Text('Proxy')),
            ButtonSegment(value: 'vpn_proxy', label: Text('VPN+Proxy')),
          ],
          selected: {_cfg.mode},
          onSelectionChanged: (s) => _setMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _modeDescription(_cfg.mode),
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),

        if (_cfg.hasMixed) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text('Local proxy', style: tt.titleMedium),
          const SizedBox(height: 12),

          // ─── Protocol ───
          Row(
            children: [
              Text('Protocol', style: tt.bodyMedium),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Mixed — one port accepts both HTTP and SOCKS5.\n'
                    'HTTP — HTTP proxy only (no UDP).\n'
                    'SOCKS5 — SOCKS5 only (supports UDP).',
                triggerMode: TooltipTriggerMode.tap,
                child: Icon(Icons.info_outline,
                    size: 16, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: VpnModeConfig.protoMixed,
                label: Text('Mixed'),
              ),
              ButtonSegment(
                value: VpnModeConfig.protoHttp,
                label: Text('HTTP'),
              ),
              ButtonSegment(
                value: VpnModeConfig.protoSocks,
                label: Text('SOCKS5'),
              ),
            ],
            selected: {_cfg.proxyProtocol},
            onSelectionChanged: (s) => _setProtocol(s.first),
          ),
          const SizedBox(height: 16),

          // ─── Listen address ───
          Text('Listen on', style: tt.bodyMedium),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: '127.0.0.1',
                label: Text('127.0.0.1'),
              ),
              ButtonSegment(
                value: '0.0.0.0',
                label: Text('0.0.0.0 (LAN)'),
              ),
            ],
            selected: {_cfg.proxyListen},
            onSelectionChanged: (s) => _setListen(s.first),
          ),
          const SizedBox(height: 4),
          Text(
            _cfg.isPublicListen
                ? 'Reachable from other devices on the network — auth required.'
                : 'Reachable only from this device.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // ─── Port ───
          TextField(
            controller: _portCtl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Port',
              helperText: 'Range 1024..65535',
              errorText: _portError.isEmpty ? null : _portError,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: _applyPort,
          ),
          const SizedBox(height: 16),

          // ─── Auth toggle ───
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Require authentication'),
            subtitle: Text(
              _cfg.isPublicListen
                  ? 'Required for LAN-exposed proxy (cannot be disabled).'
                  : 'Recommended. Protects the local proxy port.',
            ),
            value: _cfg.effectiveAuth,
            // 0.0.0.0 → залочен on (onChanged null = disabled).
            onChanged: _cfg.isPublicListen ? null : _toggleAuth,
          ),

          if (_cfg.effectiveAuth) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _userCtl,
              decoration: const InputDecoration(
                labelText: 'Username',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: _applyUsername,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtl,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: 'Password',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _showPassword ? 'Hide' : 'Show',
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                    IconButton(
                      tooltip: 'Regenerate',
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: _regeneratePassword,
                    ),
                  ],
                ),
              ),
              onChanged: _applyPassword,
            ),
          ],
        ],
      ],
    );
  }

  String _modeDescription(String mode) {
    switch (mode) {
      case 'proxy':
        return 'Local HTTP+SOCKS proxy only. No system-wide tunnel, no VPN key '
            'icon. Point apps at the proxy manually.';
      case 'vpn_proxy':
        return 'System-wide tunnel AND a local proxy port at the same time.';
      default:
        return 'System-wide tunnel — all traffic goes through the VPN (default).';
    }
  }
}
