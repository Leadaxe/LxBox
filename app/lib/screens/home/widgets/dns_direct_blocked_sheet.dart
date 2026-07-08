import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../services/settings_storage.dart';

/// §259 — разовый нижний баннер «DNS problems detected».
///
/// Показывается ОДИН раз при вердикте детектора (переход dnsDirectBlocked
/// false→true в home_screen._onControllerChange; флаг сразу потребляется через
/// consumeDnsDirectBlocked, поэтому баннер не переподнимается).
///
/// UX (согласовано):
///   • компактный баннер снизу: «⚠ DNS problems detected» + [Hide];
///   • тап по баннеру → выезжает лист снизу вверх с деталями + двумя
///     действиями (Route DNS through VPN / Use operator's DNS);
///   • через 5 сек без действий ИЛИ тап [Hide] → исчезает совсем (разовый,
///     в эту сессию больше не появится).
const Duration _kAutoHide = Duration(seconds: 5);

/// Показать компактный баннер снизу. Возвращает future, завершающийся при
/// закрытии (auto-hide / Hide / переход в лист и его закрытие).
Future<void> showDnsDirectBlockedBanner(
  BuildContext context, {
  required HomeController controller,
  required SubscriptionController subController,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Барьер прозрачный и не блокирует — это лёгкий баннер, не модалка.
    barrierColor: Colors.transparent,
    builder: (ctx) => _DnsCompactBanner(
      controller: controller,
      subController: subController,
    ),
  );
}

/// Компактный баннер: авто-скрытие 5с, кнопка Hide, тап → детальный лист.
class _DnsCompactBanner extends StatefulWidget {
  const _DnsCompactBanner({
    required this.controller,
    required this.subController,
  });

  final HomeController controller;
  final SubscriptionController subController;

  @override
  State<_DnsCompactBanner> createState() => _DnsCompactBannerState();
}

class _DnsCompactBannerState extends State<_DnsCompactBanner> {
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    _autoHide = Timer(_kAutoHide, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    super.dispose();
  }

  Future<void> _expand() async {
    _autoHide?.cancel();
    final nav = Navigator.of(context);
    nav.pop(); // закрыть компактный
    // Открыть детальный лист (выезжает снизу вверх).
    await showModalBottomSheet<void>(
      context: nav.context,
      isScrollControlled: true,
      builder: (ctx) => _DnsDetailSheet(
        controller: widget.controller,
        subController: widget.subController,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: InkWell(
        onTap: _expand,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, color: cs.error, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'DNS problems detected on this network',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Hide'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Детальный лист: пояснение + два действия + Not now.
class _DnsDetailSheet extends StatelessWidget {
  const _DnsDetailSheet({
    required this.controller,
    required this.subController,
  });

  final HomeController controller;
  final SubscriptionController subController;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.dns_outlined, color: cs.error, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'DNS server not reachable',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Your operator seems to block direct DNS queries on this '
              'network. Choose how to resolve names:',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _routeDnsThroughVpn(context),
              child: const Text('Route DNS through VPN'),
            ),
            const SizedBox(height: 4),
            Text(
              'Recommended. Queries go inside the tunnel — private, and works '
              'past the operator\'s block.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _useOperatorDns(context),
              child: const Text('Use operator\'s DNS'),
            ),
            const SizedBox(height: 4),
            Text(
              'Works everywhere, but your operator sees every domain you visit.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }

  /// Действие 1: завернуть DNS в VPN — `varValues['outbound']` = первый
  /// доступный vpn-канал у enabled template-серверов. Поднимает configDirty →
  /// штатный баннер «Settings changed → rebuild».
  Future<void> _routeDnsThroughVpn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      final channels = await SettingsStorage.getChannels();
      final vpnTag = channels
          .firstWhere(
            (c) => c.enabled || c.isRequired,
            orElse: () => throw StateError('no vpn channel available'),
          )
          .tag;

      final servers = await SettingsStorage.getDnsServers();
      var changed = false;
      final updated = <Map<String, dynamic>>[];
      for (final srv in servers) {
        final copy = Map<String, dynamic>.from(srv);
        if (copy['kind'] == 'template' &&
            copy['enabled'] != false &&
            (copy['tag'] == 'google_udp' || copy['tag'] == 'cloudflare_udp')) {
          final vv = <String, dynamic>{
            ...?(copy['varValues'] as Map?)?.cast<String, dynamic>(),
          };
          if (vv['outbound'] != vpnTag) {
            vv['outbound'] = vpnTag;
            copy['varValues'] = vv;
            changed = true;
          }
        }
        updated.add(copy);
      }
      if (changed) {
        await SettingsStorage.saveDnsServers(updated, flush: false);
        await SettingsStorage.flushToDisk();
        subController.configDirty = true;
      }
      messenger.showSnackBar(SnackBar(
        content: Text(changed
            ? 'DNS routed through VPN — rebuild config to apply'
            : 'DNS already routed through VPN'),
      ));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not update DNS: $e')));
    }
  }

  /// Действие 2: системный DNS оператора — `dns_final` → `local_dns_resolver`
  /// (config-var → авто-dirty).
  Future<void> _useOperatorDns(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      await SettingsStorage.setVar('dns_final', 'local_dns_resolver',
          flush: false);
      await SettingsStorage.flushToDisk();
      subController.configDirty = true;
      messenger.showSnackBar(const SnackBar(
        content: Text('Using operator DNS — rebuild config to apply'),
      ));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not update DNS: $e')));
    }
  }
}
