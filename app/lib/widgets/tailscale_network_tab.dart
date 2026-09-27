import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tunnel_status.dart';
import '../services/l10n/locale_controller.dart';
import '../services/tailscale_network.dart';
import '../services/url_launcher.dart';
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';

/// Задача 581 — вызовы ядра вкладки Network. Отдельно от [CcChannel], чтобы
/// тесты подставляли свои.
class TailscaleNetworkActions {
  const TailscaleNetworkActions();

  Future<String?> setExitNode(String tag, String stableId) =>
      CcChannel.instance.setTailscaleExitNode(tag, stableId);

  Future<String?> logout(String tag) => CcChannel.instance.tailscaleLogout(tag);

  Future<void> startPing(String tag, String ip) =>
      CcChannel.instance.startTailscalePing(tag, ip);

  Future<void> stopPing() => CcChannel.instance.stopTailscalePing();

  Stream<CcTailscalePingResult> get pings => CcChannel.instance.tailscalePing;
}

/// Задача 581 — вкладка Network узла Tailscale (экраны `node_settings_screen`
/// и `node_inspect_screen`): состояние узла, свой узел, exit node, устройства
/// сети.
///
/// [liveTag] — тег узла в работающем конфиге. [body] — тело узла (источник
/// записанного `exit_node`). [onSaveExitNode] — запись выбора в тело узла
/// (`null` убирает поле); `null` — кнопки Save choice нет (узел подписки).
class TailscaleNetworkTab extends StatefulWidget {
  const TailscaleNetworkTab({
    super.key,
    required this.liveTag,
    required this.body,
    this.onSaveExitNode,
    this.statusSource,
    this.vpnUp,
    this.actions = const TailscaleNetworkActions(),
  });

  final String liveTag;
  final Map<String, dynamic> body;
  final Future<void> Function(String? value)? onSaveExitNode;

  /// Тесты: поток состояния вместо [CcChannel.tailscaleStatus] (подписка ядра
  /// тогда не поднимается).
  @visibleForTesting
  final Stream<List<CcTailscaleStatus>>? statusSource;

  /// Тесты: VPN включён / выключен без обращения к сервису.
  @visibleForTesting
  final bool? vpnUp;

  final TailscaleNetworkActions actions;

  @override
  State<TailscaleNetworkTab> createState() => _TailscaleNetworkTabState();
}

class _TailscaleNetworkTabState extends State<TailscaleNetworkTab> {
  bool _vpnUp = false;
  bool _hasData = false;
  CcTailscaleStatus? _status;
  StreamSubscription<List<CcTailscaleStatus>>? _sub;
  StreamSubscription<TunnelStatusEvent>? _vpnSub;
  bool _acquired = false;

  // Раздел «Риски»: не чаще раза в секунду.
  static const _minRedraw = Duration(seconds: 1);
  DateTime _lastRedraw = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _redrawTimer;
  List<CcTailscaleStatus>? _pending;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final forced = widget.vpnUp;
    if (forced != null) {
      _vpnUp = forced;
    } else {
      unawaited(
        BoxVpnClient.I.getVpnStatus().then((s) {
          if (mounted) setState(() => _vpnUp = s.isUp);
        }),
      );
      _vpnSub = BoxVpnClient.I.onStatusChanged.listen((e) {
        if (mounted) setState(() => _vpnUp = e.status.isUp);
      });
    }
    final source = widget.statusSource;
    if (source != null) {
      _sub = source.listen(_onStatus);
    } else {
      // §122 — слушатель до старта подписки.
      _sub = CcChannel.instance.tailscaleStatus.listen(_onStatus);
      _acquired = true;
      unawaited(CcChannel.instance.acquireTailscaleStatus());
    }
  }

  @override
  void dispose() {
    _redrawTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_vpnSub?.cancel());
    if (_acquired) unawaited(CcChannel.instance.releaseTailscaleStatus());
    super.dispose();
  }

  void _onStatus(List<CcTailscaleStatus> list) {
    _pending = list;
    final wait = _minRedraw - DateTime.now().difference(_lastRedraw);
    if (!_hasData || wait <= Duration.zero) {
      _applyPending();
      return;
    }
    _redrawTimer ??= Timer(wait, () {
      _redrawTimer = null;
      _applyPending();
    });
  }

  void _applyPending() {
    final list = _pending;
    if (list == null || !mounted) return;
    _pending = null;
    _lastRedraw = DateTime.now();
    setState(() {
      _hasData = true;
      _status = list.where((s) => s.tag == widget.liveTag).firstOrNull;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _snack(getLocalText.s("Copied"));
  }

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
    final devices = sortDevices(s.peers);
    final grouped = showOwnerGroups(s);
    final children = <Widget>[
      _statusBlock(context, s),
      if (s.self != null) _thisDeviceBlock(context, s.self!),
      _exitNodeBlock(context, s),
      _header(context, getLocalText.s("Devices")),
      if (devices.isEmpty)
        ListTile(dense: true, title: Text(getLocalText.s("No devices"))),
    ];
    // Устройства — ленивой частью списка (сети из сотен устройств).
    final rows = <Object>[];
    if (grouped) {
      for (final g in s.userGroups) {
        if (g.peers.isEmpty) continue;
        rows.add(g.title);
        rows.addAll(sortDevices(g.peers));
      }
    } else {
      rows.addAll(devices);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: children.length + rows.length,
      itemBuilder: (ctx, i) {
        if (i < children.length) return children[i];
        final r = rows[i - children.length];
        if (r is String) return _groupTitle(ctx, r);
        return _deviceRow(ctx, s, r as CcTailscalePeer);
      },
    );
  }

  Widget _centerText(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _groupTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  // ── Status ──

  Widget _statusBlock(BuildContext context, CcTailscaleStatus s) {
    final needsLogin = s.backendState == 'NeedsLogin';
    final running = s.backendState == 'Running';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("Status")),
        ListTile(
          dense: true,
          title: Text(tailscaleStateLabel(s)),
          subtitle: s.networkName.isEmpty ? null : Text(s.networkName),
          trailing: s.keyAuth
              ? Chip(label: Text(getLocalText.s("signed in with a key")))
              : null,
        ),
        if ((needsLogin && s.authUrl.isNotEmpty) || running)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                if (needsLogin && s.authUrl.isNotEmpty)
                  FilledButton(
                    onPressed: () => unawaited(UrlLauncher.open(s.authUrl)),
                    child: Text(getLocalText.s("Sign in")),
                  ),
                if (running)
                  OutlinedButton(
                    onPressed: _busy ? null : () => unawaited(_logout(s)),
                    child: Text(getLocalText.s("Log out")),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _logout(CcTailscaleStatus s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Log out?")),
        content: Text(
          s.keyAuth
              ? getLocalText.s(
                  "The node leaves the network. The node has a sign-in key, so it signs in again on the next start.",
                )
              : getLocalText.s(
                  "The node leaves the network. To join again, sign in from this tab.",
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Log out")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final err = await widget.actions.logout(widget.liveTag);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _snack(getLocalText.s("Failed: %s", err));
  }

  // ── This device ──

  Widget _thisDeviceBlock(BuildContext context, CcTailscalePeer self) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("This device")),
        _copyTile(getLocalText.s("Name"), self.hostName),
        _copyTile(getLocalText.s("MagicDNS name"), self.dnsNameClean),
        for (final ip in self.ips) _copyTile(getLocalText.s("Address"), ip),
        if (self.keyExpiry > 0)
          ListTile(
            dense: true,
            title: Text(getLocalText.s("Key expiry")),
            subtitle: Text(_date(self.keyExpiry)),
          ),
      ],
    );
  }

  Widget _copyTile(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(value),
      onTap: () => unawaited(_copy(value)),
    );
  }

  static String _date(int unixSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // ── Exit node ──

  Widget _exitNodeBlock(BuildContext context, CcTailscaleStatus s) {
    final options = exitNodeOptions(s);
    final active = s.exitNode;
    final recorded = recordedExitNode(widget.body);
    final mismatch = exitNodeMismatch(
      recorded: recorded,
      active: active,
      magicDnsSuffix: s.magicDnsSuffix,
    );
    final activeId = active?.stableId ?? '';
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _header(context, getLocalText.s("Exit node"))),
            if (mismatch != ExitNodeMismatch.none)
              Padding(
                padding: const EdgeInsets.only(right: 16, top: 12),
                child: Icon(
                  Icons.warning_amber_rounded,
                  key: const ValueKey('exit-node-warning'),
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        RadioGroup<String>(
          groupValue: activeId,
          onChanged: (v) {
            if (v != null && !_busy) unawaited(_choose(v));
          },
          child: Column(
            children: [
              RadioListTile<String>(
                dense: true,
                value: '',
                title: Text(getLocalText.s("None")),
              ),
              for (final p in options)
                RadioListTile<String>(
                  dense: true,
                  value: p.stableId,
                  title: Text(p.hostName),
                  subtitle: p.online ? null : Text(getLocalText.s("offline")),
                ),
            ],
          ),
        ),
        if (mismatch != ExitNodeMismatch.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              exitNodeWarningText(mismatch),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (mismatch != ExitNodeMismatch.none && widget.onSaveExitNode != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: FilledButton(
              onPressed: _busy ? null : () => unawaited(_save(active)),
              child: Text(getLocalText.s("Save choice")),
            ),
          ),
      ],
    );
  }

  Future<void> _choose(String stableId) async {
    setState(() => _busy = true);
    final err = await widget.actions.setExitNode(widget.liveTag, stableId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _snack(getLocalText.s("Failed: %s", err));
  }

  Future<void> _save(CcTailscalePeer? active) async {
    final save = widget.onSaveExitNode;
    if (save == null) return;
    setState(() => _busy = true);
    try {
      await save(active == null ? null : exitNodeConfigValue(active));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Devices ──

  Widget _deviceRow(
    BuildContext context,
    CcTailscaleStatus s,
    CcTailscalePeer p,
  ) {
    final theme = Theme.of(context);
    final marks = <String>[
      if (p.online)
        getLocalText.s("online")
      else if (p.lastSeen > 0)
        getLocalText.s("last seen %s", _date(p.lastSeen)),
      if (p.os.isNotEmpty) p.os,
      if (p.expired) getLocalText.s("key expired"),
      if (p.shareeNode) getLocalText.s("shared"),
      if (p.exitNodeOption) getLocalText.s("exit node"),
    ];
    final second = [p.dnsNameClean, p.firstIp].where((v) => v.isNotEmpty);
    return ListTile(
      dense: true,
      title: Text(p.hostName),
      subtitle: Text(
        [
          second.join(' · '),
          marks.join(' · '),
        ].where((v) => v.isNotEmpty).join('\n'),
        style: theme.textTheme.bodySmall,
      ),
      leading: Icon(
        Icons.circle,
        size: 10,
        color: p.online ? Colors.green : theme.disabledColor,
      ),
      onTap: () => unawaited(_deviceMenu(p)),
    );
  }

  Future<void> _deviceMenu(CcTailscalePeer p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(getLocalText.s("Copy name")),
              onTap: () => Navigator.pop(ctx, 'name'),
            ),
            if (p.firstIp.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_all),
                title: Text(getLocalText.s("Copy address")),
                onTap: () => Navigator.pop(ctx, 'address'),
              ),
            if (p.firstIp.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.network_ping),
                title: Text(getLocalText.s("Ping")),
                onTap: () => Navigator.pop(ctx, 'ping'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'name':
        await _copy(p.dnsNameClean.isNotEmpty ? p.dnsNameClean : p.hostName);
      case 'address':
        await _copy(p.firstIp);
      case 'ping':
        await showModalBottomSheet<void>(
          context: context,
          builder: (_) => TailscalePingSheet(
            tag: widget.liveTag,
            peer: p,
            actions: widget.actions,
          ),
        );
    }
  }
}

/// Подпись состояния узла — значения таблицы раздела 3 спеки 579; прочие
/// состояния — текстом ядра.
String tailscaleStateLabel(CcTailscaleStatus s) => switch (s.backendState) {
  'Running' => getLocalText.s("running"),
  'NeedsLogin' => getLocalText.s("sign-in needed"),
  'Stopped' => getLocalText.s("stopped"),
  _ =>
    s.stateText.isNotEmpty
        ? s
              .stateText // l10n-exempt: core state text as is
        : s.backendState, // l10n-exempt: core state as is
};

/// Задача 581 раздел 7 — проверка устройства: до закрытия листа или пяти
/// ответов.
class TailscalePingSheet extends StatefulWidget {
  const TailscalePingSheet({
    super.key,
    required this.tag,
    required this.peer,
    this.actions = const TailscaleNetworkActions(),
  });

  final String tag;
  final CcTailscalePeer peer;
  final TailscaleNetworkActions actions;

  static const maxReplies = 5;

  @override
  State<TailscalePingSheet> createState() => _TailscalePingSheetState();
}

class _TailscalePingSheetState extends State<TailscalePingSheet> {
  final _results = <CcTailscalePingResult>[];
  StreamSubscription<CcTailscalePingResult>? _sub;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.actions.pings.listen((r) {
      if (!mounted || _stopped) return;
      setState(() => _results.add(r));
      if (_results.length >= TailscalePingSheet.maxReplies) _stop();
    });
    unawaited(widget.actions.startPing(widget.tag, widget.peer.firstIp));
  }

  void _stop() {
    if (_stopped) return;
    _stopped = true;
    unawaited(widget.actions.stopPing());
  }

  @override
  void dispose() {
    _stop();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peer.hostName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_results.isEmpty && !_stopped) const LinearProgressIndicator(),
            for (final r in _results)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(_line(r), style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }

  static String _line(CcTailscalePingResult r) {
    if (r.error.isNotEmpty) return getLocalText.s("No reply: %s", r.error);
    final ms = r.latencyMs.toStringAsFixed(r.latencyMs < 10 ? 1 : 0);
    if (r.isDirect) {
      return r.endpoint.isEmpty
          ? getLocalText.s("%s ms, direct", ms)
          : getLocalText.s("%s ms, direct, %s", ms, r.endpoint);
    }
    return r.derpRegionCode.isEmpty
        ? getLocalText.s("%s ms, relay", ms)
        : getLocalText.s("%s ms, relay %s", ms, r.derpRegionCode);
  }
}
