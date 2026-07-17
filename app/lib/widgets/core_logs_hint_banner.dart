import 'dart:async';

import 'package:flutter/material.dart';
import '../services/l10n/l10n.dart';

import '../screens/app_settings_screen.dart';
import '../vpn/box_vpn_client.dart';

/// Banner showing «DNS / router events off» when «Forward sing-box logs»
/// (Diagnostics → §043) is disabled. Used in tabs that depend on core logs
/// for full event attribution (Live tab, Per-app trace tab):
///
///   - Без core logs нет `dns: exchanged` / `dns: cached` events → DNS
///     resolves пропадают.
///   - Нет `router: found package name: ...` → process attribution
///     ухудшается до Clash /connections poll'а только.
///
/// Hit-zones split:
///  • Левая (i + «DNS / router events off») → tap = tooltip с
///    объяснением.
///  • Правая («turn on Forward sing-box logs» + chevron) → tap =
///    deep-link в App Settings → Diagnostics с auto-scroll и подсветкой
///    нужного toggle'а.
///
/// State auto-managed: подписывается на `AppLifecycleState.resumed`,
/// re-fetches `getCoreLogsEnabled()` чтобы поймать toggle juзера и
/// исчезнуть. Self-hides когда core logs forwarding включён.
class CoreLogsHintBanner extends StatefulWidget {
  const CoreLogsHintBanner({super.key});

  @override
  State<CoreLogsHintBanner> createState() => _CoreLogsHintBannerState();
}

class _CoreLogsHintBannerState extends State<CoreLogsHintBanner>
    with WidgetsBindingObserver {
  final BoxVpnClient _vpn = BoxVpnClient();
  bool? _enabled; // null до первого load — banner скрыт

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final on = await _vpn.getCoreLogsEnabled();
    if (mounted && on != _enabled) {
      setState(() => _enabled = on);
    }
  }

  void _openDiagnostics() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AppSettingsScreen(
          initialTab: 2, // §118 — Diagnostics сдвинут на 2 (вставлен Subscriptions)
          highlightCoreLogs: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled != false) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final textStyle = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      child: Row(
        children: [
          Tooltip(
            message:
                'Sing-box internal logs (router decisions, DNS resolves) are '
                "not forwarded here. Enable 'Forward sing-box logs' in "
                'Diagnostics — after that DNS events and precise app '
                'attribution will appear.',
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 6),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(context.l.debugDnsEventsOff, style: textStyle),
                ],
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: _openDiagnostics,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l.debugForwardLogsHint,
                        style: textStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 16, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
