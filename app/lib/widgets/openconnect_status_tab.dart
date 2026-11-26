import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/l10n/locale_controller.dart';
import '../services/openconnect_auth.dart' show OpenConnectRowKind, openConnectRowState;
import '../services/openconnect_status_feed.dart';
import '../vpn/cc_openconnect.dart';
import 'safe_bottom.dart';

/// §764 — строка вкладки: название и значение.
typedef OpenConnectStatusRow = ({String label, String value});

/// §764 — время подключения: в тот же день `HH:mm`, иначе
/// `yyyy-MM-dd HH:mm`, местное время. [unixSeconds] `0` — пусто.
String openConnectSinceLabel(int unixSeconds, {DateTime? now}) {
  if (unixSeconds <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == n.year && d.month == n.month && d.day == n.day) return hm;
  return '${d.year}-${two(d.month)}-${two(d.day)} $hm';
}

/// §764 — адрес без длины префикса хоста (`/32` у IPv4, `/128` у IPv6);
/// прочие префиксы — как пришли.
String openConnectAddressLabel(String prefix) {
  final p = prefix.trim();
  if (p.endsWith('/32') && !p.contains(':')) {
    return p.substring(0, p.length - 3);
  }
  if (p.endsWith('/128') && p.contains(':')) {
    return p.substring(0, p.length - 4);
  }
  return p;
}

/// §764 — строки вкладки по состоянию endpoint'а. Пустые значения
/// пропущены; строки туннеля — только при `connected` (в прочих
/// состояниях карта `tunnel` неполная).
List<OpenConnectStatusRow> openConnectStatusRows(
  CcOpenConnectStatus s, {
  DateTime? now,
}) {
  final rows = <OpenConnectStatusRow>[];
  void add(String label, String value) {
    final v = value.trim();
    if (v.isNotEmpty) rows.add((label: label, value: v));
  }

  final stateLabel = getLocalText.s("State");
  final row = openConnectRowState(s);
  if (row.kind == OpenConnectRowKind.waiting) {
    add(stateLabel, getLocalText.s("Waiting for sign-in"));
    add(getLocalText.s("Status"), s.stateText);
    return rows;
  }
  if (row.kind == OpenConnectRowKind.error) {
    add(stateLabel, getLocalText.s("Error"));
    add(getLocalText.s("Error"), row.text);
    return rows;
  }
  switch (s.state) {
    case CcOpenConnectState.connected:
      final t = s.tunnel ?? const CcOpenConnectTunnel();
      final since = openConnectSinceLabel(t.connectedSince, now: now);
      add(
        stateLabel,
        since.isEmpty
            ? getLocalText.s("Connected")
            : getLocalText.s("Connected · since %s", since),
      );
      add(
        getLocalText.s("Gateway"),
        [t.server, t.flavor].where((e) => e.trim().isNotEmpty).join(' · '),
      );
      add(getLocalText.s("Transport"), t.transport);
      add(
        getLocalText.s("Address"),
        [...t.ipv4, ...t.ipv6]
            .map(openConnectAddressLabel)
            .where((e) => e.isNotEmpty)
            .join(' · '),
      );
      add(getLocalText.s("DNS"), t.dns.join(', '));
      if (t.mtu > 0) add(getLocalText.s("MTU"), '${t.mtu}');
    case CcOpenConnectState.connecting:
      add(stateLabel, getLocalText.s("Connecting…"));
    default:
      add(stateLabel, s.stateText.trim().isNotEmpty ? s.stateText : s.state);
  }
  return rows;
}

/// §764 — вкладка Network узла OpenConnect: состояние подключения к шлюзу
/// по потоку ядра `SubscribeOpenConnectStatus` (подписку держит натив).
class OpenConnectStatusTab extends StatefulWidget {
  const OpenConnectStatusTab({
    super.key,
    required this.liveTag,
    this.statusSource,
    this.vpnUp,
  });

  /// Тег узла в работающем конфиге.
  final String liveTag;

  /// Тесты: поток снапшотов вместо [OpenConnectStatusFeed.statuses] (снапшот
  /// при открытии тогда не запрашивается).
  @visibleForTesting
  final Stream<CcOpenConnectSnapshot>? statusSource;

  /// Тесты: VPN включён / выключен без обращения к сервису.
  @visibleForTesting
  final bool? vpnUp;

  @override
  State<OpenConnectStatusTab> createState() => _OpenConnectStatusTabState();
}

class _OpenConnectStatusTabState extends State<OpenConnectStatusTab> {
  bool _vpnUp = false;
  bool _hasData = false;
  CcOpenConnectStatus? _status;
  StreamSubscription<CcOpenConnectSnapshot>? _sub;
  StreamSubscription<bool>? _vpnSub;

  @override
  void initState() {
    super.initState();
    final forced = widget.vpnUp;
    if (forced != null) {
      _vpnUp = forced;
    } else {
      unawaited(
        OpenConnectStatusFeed.vpnUp().then((up) {
          if (!mounted) return;
          setState(() => _vpnUp = up);
          if (up) unawaited(_fetch());
        }),
      );
      _vpnSub = OpenConnectStatusFeed.vpnUpChanges.listen((up) {
        if (!mounted) return;
        final wasUp = _vpnUp;
        setState(() {
          _vpnUp = up;
          if (!up) {
            _hasData = false;
            _status = null;
          }
        });
        if (up && !wasUp) unawaited(_fetch());
      });
    }
    final source = widget.statusSource;
    if (source != null) {
      _sub = source.listen(_onSnapshot);
    } else {
      // Слушатель до снапшота: обновление между ними не теряется.
      _sub = OpenConnectStatusFeed.statuses.listen(_onSnapshot);
    }
  }

  /// Текущий снапшот: поток шлёт только изменения.
  Future<void> _fetch() async {
    final snap = await OpenConnectStatusFeed.snapshot();
    if (!mounted) return;
    if (snap == null) {
      setState(() => _hasData = true);
      return;
    }
    _onSnapshot(snap);
  }

  void _onSnapshot(CcOpenConnectSnapshot snap) {
    if (!mounted) return;
    setState(() {
      _hasData = true;
      _status = snap.endpoints[widget.liveTag];
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_vpnSub?.cancel());
    super.dispose();
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(getLocalText.s("Copied"))));
  }

  Widget _centerText(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_vpnUp) {
      return _centerText(getLocalText.s("Start VPN to see the network."));
    }
    if (!_hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _status;
    if (s == null) {
      return _centerText(
        getLocalText.s("The node is not in the running config."),
      );
    }
    final rows = openConnectStatusRows(s);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24).withSafeBottom(context),
      children: [
        for (final r in rows)
          ListTile(
            dense: true,
            title: Text(r.label),
            subtitle: Text(r.value),
            onTap: () => unawaited(_copy(r.value)),
          ),
      ],
    );
  }
}
