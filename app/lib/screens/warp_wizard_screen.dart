import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/subscription_controller.dart';
import '../services/warp/warp_account.dart';

/// §025 — Full-screen визард «Get WARP». Открывается из overflow-меню
/// Subscriptions. Один тап «Register» для free; license/endpoint опциональны
/// под «Advanced».
///
/// Поведение: `subController.addWarp(...)` регистрирует устройство в Cloudflare
/// (приватный ключ генерится на телефоне) и добавляет готовый WireGuard-узел.
/// После успеха → [onAdded] (regenerate config + save в parent) → pop.
class WarpWizardScreen extends StatefulWidget {
  const WarpWizardScreen({
    super.key,
    required this.subController,
    required this.onAdded,
  });

  final SubscriptionController subController;
  final Future<void> Function() onAdded;

  @override
  State<WarpWizardScreen> createState() => _WarpWizardScreenState();
}

class _WarpWizardScreenState extends State<WarpWizardScreen> {
  final _license = TextEditingController();
  final _endpoint =
      TextEditingController(text: WarpAccount.defaultEndpoint);

  bool _forceNew = false;
  bool _busy = false;
  WarpAccount? _result;

  @override
  void dispose() {
    _license.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final endpoint = _endpoint.text.trim().isEmpty
          ? WarpAccount.defaultEndpoint
          : _endpoint.text.trim();
      final license = _license.text.trim();

      final account = await widget.subController.addWarp(
        licenseKey: license.isEmpty ? null : license,
        endpoint: endpoint,
        forceNew: _forceNew,
      );

      if (!mounted) return;
      final err = widget.subController.lastError;
      if (account == null || err.isNotEmpty) {
        _showSnack(err.isNotEmpty ? err : 'WARP registration failed');
        return;
      }
      setState(() => _result = account);
      await widget.onAdded();
      if (!mounted) return;
      _showSnack(account.warpPlus ? 'Added WARP+ node' : 'Added WARP node');
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Get WARP'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // §025 — официальный двухтональный логотип-облако Cloudflare
            // (Wikimedia Commons, ~2.8:1). Ширина = доля экрана (≈40%,
            // зажата 120..200 px), чтобы масштабировалось под любой телефон;
            // BoxFit.contain сохраняет пропорции и не обрезает макушку.
            Builder(builder: (context) {
              final w = MediaQuery.of(context).size.width;
              final logoW = (w * 0.40).clamp(120.0, 200.0);
              return Image.asset('assets/icons/cloudflare.png',
                  width: logoW, fit: BoxFit.contain);
            }),
            const SizedBox(height: 16),
            Text(
              'Cloudflare WARP',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Registers a free WireGuard tunnel on Cloudflare. The private key '
              'is generated on this device and never leaves it.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            ExpansionPanelList.radio(
              elevation: 0,
              expandedHeaderPadding: EdgeInsets.zero,
              children: [
                ExpansionPanelRadio(
                  value: 'advanced',
                  canTapOnHeader: true,
                  headerBuilder: (_, _) =>
                      const ListTile(title: Text('Advanced')),
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('WARP+ license key (optional)'),
                        TextField(
                          controller: _license,
                          enabled: !_busy,
                          decoration: _input('Leave empty for free WARP'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'WARP+ adds Argo Smart Routing (lower latency). '
                          'Privacy is the same as free. Leave empty for free WARP.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 12),
                        _label('Endpoint'),
                        TextField(
                          controller: _endpoint,
                          enabled: !_busy,
                          decoration: _input(WarpAccount.defaultEndpoint),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'host:port of the Cloudflare peer. Change only if the '
                          'default is blocked (use a working IP:port).',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _forceNew,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _forceNew = v ?? false),
                          title: const Text('Re-register (force new account)'),
                          subtitle: const Text(
                              'Ignore the cached account and register a fresh one.'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _register,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_busy ? 'Registering…' : 'Register'),
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              _StatusCard(account: _result!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
      );

  InputDecoration _input(String hint) => InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.account});
  final WarpAccount account;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.warpPlus ? 'Registered: WARP+' : 'Registered: WARP',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('Account', account.accountId),
            _row('Device', account.deviceId),
            _row('Address', account.clientV4),
            _row('Endpoint', account.endpoint),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 80, child: Text(k)),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ),
      );
}
