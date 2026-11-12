import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics/path_mtu.dart';
import '../services/l10n/locale_controller.dart';
import 'template_var_list.dart';

/// §725 — остров Path MTU на вкладке Diagnostics узла `direct`: наибольший
/// IP-пакет, который доходит до цели без фрагментации, и рекомендация MTU
/// узлам WireGuard / AWG / MASQUE.
///
/// Пробы идут мимо туннеля (ICMP-сокет на физической сети), поэтому остров
/// есть только у direct-узла: через прокси ICMP не ходит. Подключает экран
/// просмотра outbound'а слотом вкладки, сама вкладка о direct не знает.
class PathMtuIsland extends StatefulWidget {
  const PathMtuIsland({super.key, this.prober = const ChannelPathMtuProber()});

  final PathMtuProber prober;

  @override
  State<PathMtuIsland> createState() => _PathMtuIslandState();
}

class _PathMtuIslandState extends State<PathMtuIsland> {
  String _target = kPathMtuDefaultTarget;
  PathMtuNetwork? _network;
  bool _noNetwork = false;
  bool _running = false;
  PathMtuCancel? _cancel;
  final List<PathMtuProbe> _probes = [];
  PathMtuResult? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_loadNetwork());
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  /// MTU интерфейса виден сразу, до запуска.
  Future<void> _loadNetwork() async {
    try {
      final net = await widget.prober.network();
      if (mounted) setState(() => _network = net);
    } on PathMtuNoNetwork {
      if (mounted) setState(() => _noNetwork = true);
    } catch (_) {
      // Канал недоступен — строка интерфейса просто не покажется.
    }
  }

  Future<void> _run() async {
    if (_running) return;
    final cancel = PathMtuCancel();
    setState(() {
      _running = true;
      _cancel = cancel;
      _probes.clear();
      _result = null;
    });
    final result = await findPathMtu(
      widget.prober,
      _target.trim().isEmpty ? kPathMtuDefaultTarget : _target.trim(),
      cancel: cancel,
      onNetwork: (n) {
        if (mounted) {
          setState(() {
            _network = n;
            _noNetwork = false;
          });
        }
      },
      onProbe: (p) {
        if (mounted) setState(() => _probes.add(p));
      },
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
      _cancel = null;
      if (result.status == PathMtuStatus.noNetwork) _noNetwork = true;
    });
  }

  void _stop() => _cancel?.cancel();

  static String _transportLabel(String t) => switch (t) {
        'wifi' => getLocalText.s("Wi-Fi"),
        'cellular' => getLocalText.s("Mobile"),
        'ethernet' => getLocalText.s("Ethernet"),
        _ => getLocalText.s("Other"),
      };

  String? _interfaceLine() {
    if (_noNetwork) return getLocalText.s("No network");
    final n = _network;
    if (n == null) return null;
    final name = n.iface.isEmpty
        ? _transportLabel(n.transport)
        : '${n.iface} (${_transportLabel(n.transport)})';
    final mtu = n.mtu > 0
        ? getLocalText.s("MTU %s", n.mtu)
        : getLocalText.s("MTU unknown");
    return '$name · $mtu';
  }

  static String _probeLine(PathMtuProbe p) {
    final what = switch (p.status) {
      PathMtuProbeStatus.ok => getLocalText.s("ok %s ms", p.rttMs),
      PathMtuProbeStatus.timeout => getLocalText.s("no reply"),
      PathMtuProbeStatus.tooBig =>
        getLocalText.s("does not fit the interface"),
      PathMtuProbeStatus.error => getLocalText.s("error"),
    };
    return '${p.size} · $what';
  }

  /// Заголовок итога и строка под ним.
  (String?, String) _summary(PathMtuResult r) => switch (r.status) {
        PathMtuStatus.ok => (
            getLocalText.s("Path MTU %s", r.pathMtu),
            r.nothingCut
                ? getLocalText.s("Nothing is cut on the way")
                : getLocalText.s("Network drops packets above %s", r.pathMtu),
          ),
        PathMtuStatus.belowFloor => (
            getLocalText.s("Path MTU below %s", r.isIpv6 ? 1280 : 576),
            getLocalText.s("Even a minimum-size packet does not get through"),
          ),
        PathMtuStatus.unreachable => (
            null,
            getLocalText.s("Target does not answer ping"),
          ),
        PathMtuStatus.noNetwork => (null, getLocalText.s("No network")),
        PathMtuStatus.cancelled => (null, getLocalText.s("Stopped")),
        PathMtuStatus.error => (null, r.error),
      };

  String _report(PathMtuResult r) {
    final (head, line) = _summary(r);
    final b = StringBuffer();
    if (head != null) b.writeln(head);
    b.writeln(line);
    b.writeln('${getLocalText.s("Target")}: ${r.target}'
        '${r.ip.isNotEmpty && r.ip != r.target ? ' (${r.ip})' : ''}');
    final iface = _interfaceLine();
    if (iface != null) b.writeln('${getLocalText.s("Interface")}: $iface');
    if (r.hasRecommendation) {
      b.writeln(getLocalText.s("Recommended tunnel MTU"));
      b.writeln('WireGuard / AWG ≤ ${r.wireguardMtu}');
      b.writeln('MASQUE ≤ ${r.masqueMtu}');
    }
    b.writeln(getLocalText.s("Probes (%s)", r.probes.length));
    for (final p in r.probes) {
      b.writeln(_probeLine(p));
    }
    return b.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final iface = _interfaceLine();
    final r = _result;
    final summary = r == null ? null : _summary(r);
    return SettingsIsland(
      key: const ValueKey('path-mtu-island'),
      title: getLocalText.s("Path MTU"),
      description: getLocalText.s(
          "Largest packet that reaches the target unfragmented. Probes bypass the tunnel."),
      children: [
        if (iface != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Text(getLocalText.s("Interface"), style: muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(iface,
                      key: const ValueKey('path-mtu-iface'),
                      style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        VarTextField(
          key: const ValueKey('path-mtu-target'),
          value: _target,
          label: getLocalText.s("Target"),
          tooltip: getLocalText.s("IP address or host name"),
          hintText: kPathMtuDefaultTarget,
          suggestions: [for (final t in kPathMtuTargets) t.$2],
          suggestionLabels: [for (final t in kPathMtuTargets) t.$1],
          onChanged: (v) => setState(() => _target = v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: _running
                ? OutlinedButton.icon(
                    key: const ValueKey('path-mtu-stop'),
                    onPressed: _stop,
                    icon: const Icon(Icons.stop),
                    label: Text(getLocalText.s("Stop")),
                  )
                : FilledButton.icon(
                    key: const ValueKey('path-mtu-run'),
                    onPressed: () => unawaited(_run()),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(getLocalText.s("Run")),
                  ),
          ),
        ),
        if (r != null && summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (summary.$1 != null)
                        Text(
                          summary.$1!,
                          key: const ValueKey('path-mtu-value'),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      Text(
                        summary.$2,
                        style: r.status == PathMtuStatus.ok
                            ? muted
                            : theme.textTheme.bodyMedium
                                ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('path-mtu-copy'),
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: getLocalText.s("Copy"),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _report(r)));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(getLocalText.s("Copied"))));
                  },
                ),
              ],
            ),
          ),
        if (r != null && r.hasRecommendation)
          Padding(
            key: const ValueKey('path-mtu-recommend'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(getLocalText.s("Recommended tunnel MTU"), style: muted),
                const SizedBox(height: 4),
                // l10n-exempt: имена протоколов и числа
                Text('WireGuard / AWG   ≤ ${r.wireguardMtu}'),
                // l10n-exempt: имя протокола и число
                Text('MASQUE   ≤ ${r.masqueMtu}'),
              ],
            ),
          ),
        if (_probes.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('path-mtu-probes'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              expandedAlignment: Alignment.centerLeft,
              title: Text(getLocalText.s("Probes (%s)", _probes.length),
                  style: theme.textTheme.bodyMedium),
              children: [
                for (final p in _probes)
                  Text(_probeLine(p),
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
      ],
    );
  }
}
