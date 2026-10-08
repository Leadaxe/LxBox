import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/format_utils.dart' show formatBytes;
import '../services/l10n/locale_controller.dart';
import '../services/wg_peer_status.dart';
import '../vpn/cc_channel.dart';
import 'app_bottom_sheet.dart';

/// §613 (ядро SPEC 114) — секция Peers окна WG/AWG-узла: пиры из
/// `GetWireGuardStatus`, вердикт по руководству ядра.
///
/// Опрос раз в [kWgStatusPollInterval], пока секция на экране, VPN поднят и
/// приложение на переднем плане; уход в фон и dispose останавливают опрос.
/// Вызов только читает статус — спящий узел не будится, пробы нет.
/// `unimplemented` (ядро без `with_lx_command`), `not_found` и
/// `invalid_argument` прекращают опрос, секции нет, ошибки в UI нет.
class WgPeersSection extends StatefulWidget {
  const WgPeersSection({
    super.key,
    required this.tag,
    required this.tunnelUp,
    this.body,
    this.fetch,
  });

  /// Тег узла в работающем конфиге.
  final String tag;

  final bool tunnelUp;

  /// Тело узла: `reject_after_time` AWG-узла задаёт порог «на связи».
  final Map<String, dynamic>? body;

  /// Тесты: свой источник статуса вместо [CcChannel.getWireGuardStatus].
  @visibleForTesting
  final Future<CcWireGuardStatus> Function(String tag)? fetch;

  @override
  State<WgPeersSection> createState() => _WgPeersSectionState();
}

class _WgPeersSectionState extends State<WgPeersSection> {
  CcWireGuardStatus? _status;
  final _tracker = WgRxTracker();
  Map<String, bool> _rxGrew = const {};
  Timer? _timer;
  bool _inFlight = false;

  /// Ядро ответило отказом, который опросом не лечится.
  bool _stopped = false;
  bool _foreground = true;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      _foreground = s == AppLifecycleState.resumed;
      _sync();
    });
    _sync();
  }

  @override
  void didUpdateWidget(WgPeersSection old) {
    super.didUpdateWidget(old);
    if (old.tag != widget.tag) {
      _stopped = false;
      _status = null;
    }
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  bool get _shouldPoll => widget.tunnelUp && _foreground && !_stopped;

  void _sync() {
    if (!_shouldPoll) {
      _timer?.cancel();
      _timer = null;
      // build и так не рисует секцию без туннеля; при новом подъёме
      // старый снимок показываться не должен.
      if (!widget.tunnelUp) _status = null;
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(kWgStatusPollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _poll() async {
    if (_inFlight || !_shouldPoll) return;
    _inFlight = true;
    try {
      final fetch = widget.fetch ?? CcChannel.instance.getWireGuardStatus;
      final st = await fetch(widget.tag);
      if (!mounted) return;
      final grew = <String, bool>{
        for (final p in st.peers)
          p.publicKey: _tracker.grew(p.publicKey, p.rxBytes),
      };
      setState(() {
        _status = st;
        _rxGrew = grew;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      final fatal = e.code == CcStatusError.unimplemented ||
          e.code == CcStatusError.notFound ||
          e.code == CcStatusError.invalidArgument;
      if (fatal) {
        _stopped = true;
        _timer?.cancel();
        _timer = null;
      }
      setState(() => _status = null);
    } on MissingPluginException {
      _stopped = true;
      _timer?.cancel();
      _timer = null;
    } finally {
      _inFlight = false;
    }
  }

  static int _nowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  Widget build(BuildContext context) {
    final st = _status;
    if (!widget.tunnelUp ||
        st == null ||
        !wgPeersSectionVisible(st.endpointState)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final now = _nowUnix();
    final rejectAfter = wgRejectAfterSeconds(widget.body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            getLocalText.s("Peers"),
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
        if (st.peers.isEmpty)
          Text(wgEmptyPeersLabel(st.endpointState),
              style: theme.textTheme.bodySmall),
        for (final p in st.peers)
          _peerRow(
            context,
            p,
            wgPeerVerdict(
              endpointState: st.endpointState,
              peer: p,
              rxGrew: _rxGrew[p.publicKey] ?? false,
              nowUnix: now,
              rejectAfterSeconds: rejectAfter,
            ),
            now,
          ),
      ],
    );
  }

  Widget _peerRow(
    BuildContext context,
    CcWireGuardPeer p,
    WgPeerVerdict v,
    int now,
  ) {
    final theme = Theme.of(context);
    final color = switch (v.kind) {
      WgPeerVerdictKind.connected => Colors.green,
      WgPeerVerdictKind.noSession => Colors.orange,
      _ => theme.disabledColor,
    };
    final endpoint = p.endpoint.isEmpty ? '—' : p.endpoint;
    final age = wgHandshakeAgeLabel(p.lastHandshakeUnix, now);
    final traffic = '↓ ${formatBytes(p.rxBytes, spaced: true)}  '
        '↑ ${formatBytes(p.txBytes, spaced: true)}';
    final verdict = wgPeerVerdictLabel(v);
    final line = [p.shortKey, endpoint, age, traffic, verdict].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.circle, size: 10, color: color),
      minLeadingWidth: 10,
      title: Text(p.shortKey, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(
        [
          '$endpoint · $age',
          traffic,
          verdict,
        ].join('\n'),
        style: theme.textTheme.bodySmall,
      ),
      onLongPress: () => unawaited(_peerMenu(p, line)),
      trailing: IconButton(
        icon: const Icon(Icons.more_horiz),
        tooltip: getLocalText.s("More"),
        onPressed: () => unawaited(_peerMenu(p, line)),
      ),
    );
  }

  Future<void> _peerMenu(CcWireGuardPeer p, String line) async {
    final action = await showAppBottomSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.endpoint.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(getLocalText.s("Copy endpoint")),
              onTap: () => Navigator.pop(ctx, 'endpoint'),
            ),
          ListTile(
            leading: const Icon(Icons.key),
            title: Text(getLocalText.s("Copy public key")),
            onTap: () => Navigator.pop(ctx, 'key'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_all),
            title: Text(getLocalText.s("Copy row")),
            onTap: () => Navigator.pop(ctx, 'line'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    final text = switch (action) {
      'endpoint' => p.endpoint,
      'key' => p.publicKey,
      _ => line,
    };
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Copied"))));
  }
}
