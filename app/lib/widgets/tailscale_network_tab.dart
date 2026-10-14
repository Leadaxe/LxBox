import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tunnel_status.dart';
import '../services/l10n/locale_controller.dart';
import '../services/tailscale_network.dart';
import '../services/url_launcher.dart';
import '../services/wg_peer_status.dart' show wgAgeLabel;
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import 'app_bottom_sheet.dart';
import 'safe_bottom.dart';

/// Задача 581 — вызовы ядра вкладки Network. Отдельно от [CcChannel], чтобы
/// тесты подставляли свои.
class TailscaleNetworkActions {
  const TailscaleNetworkActions();

  Future<String?> setExitNode(String tag, String stableId) =>
      CcChannel.instance.setTailscaleExitNode(tag, stableId);

  Future<String?> logout(String tag) => CcChannel.instance.tailscaleLogout(tag);

  /// §645 — одиночный статус endpoint'а для опроса вкладки.
  Future<CcTailscaleStatusPoll> getStatus(String tag) =>
      CcChannel.instance.getTailscaleStatus(tag);

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
    this.onSaveFields,
    this.statusSource,
    this.vpnUp,
    this.actions = const TailscaleNetworkActions(),
  });

  final String liveTag;
  final Map<String, dynamic> body;
  final Future<void> Function(String? value)? onSaveExitNode;

  /// §613 — запись полей тела узла (значение `null` убирает поле) тем же
  /// путём, что Save choice; `null` — блока Settings нет (узел подписки).
  final Future<void> Function(Map<String, Object?> fields)? onSaveFields;

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

class _TailscaleNetworkTabState extends State<TailscaleNetworkTab>
    with WidgetsBindingObserver {
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

  /// Последняя запись узла из потока или опроса; `null` — узла нет в
  /// работающем конфиге. [_hasPending] — запись ждёт перерисовки.
  CcTailscaleStatus? _pending;
  bool _hasPending = false;

  bool _busy = false;

  // §645 — опрос `GetTailscaleStatus` раз в 3 с, пока вкладка на экране и
  // VPN включён. Ядро без метода — опрос снят до закрытия вкладки.
  static const _pollInterval = Duration(seconds: 3);
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _pollUnsupported = false;
  bool _onScreen = true;
  bool _appResumed = true;

  /// Устройства (`stableId`), у которых раскрыты адреса сверх двух.
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final life = WidgetsBinding.instance.lifecycleState;
    _appResumed = life == null || life == AppLifecycleState.resumed;
    final forced = widget.vpnUp;
    if (forced != null) {
      _vpnUp = forced;
    } else {
      unawaited(
        BoxVpnClient.I.getVpnStatus().then((s) {
          if (!mounted) return;
          setState(() => _vpnUp = s.isUp);
          _syncPolling();
        }),
      );
      _vpnSub = BoxVpnClient.I.onStatusChanged.listen((e) {
        if (!mounted) return;
        setState(() => _vpnUp = e.status.isUp);
        _syncPolling();
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Маршрут перекрыт другим или вкладка за кадром — тикеры выключены.
    _onScreen = TickerMode.valuesOf(context).enabled;
    _syncPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _redrawTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_vpnSub?.cancel());
    if (_acquired) unawaited(CcChannel.instance.releaseTailscaleStatus());
    super.dispose();
  }

  /// §645 — опрос идёт, пока вкладка на экране, приложение на переднем плане,
  /// VPN включён и ядро знает метод. Запуск — первый вызов сразу.
  void _syncPolling() {
    final want =
        mounted && _onScreen && _appResumed && _vpnUp && !_pollUnsupported;
    if (!want) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_pollTick()));
    unawaited(_pollTick());
  }

  /// Вызов ещё не вернулся — тик пропускается.
  Future<void> _pollTick() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final r = await widget.actions.getStatus(widget.liveTag);
      if (!mounted) return;
      if (r.unsupported) {
        _pollUnsupported = true;
        _syncPolling();
        return;
      }
      final s = r.status;
      // Пропуск тика: тег не найден, endpoint не запущен, опрос снят.
      if (s == null || s.tag != widget.liveTag || _pollTimer == null) return;
      _offer(s);
    } finally {
      _pollInFlight = false;
    }
  }

  void _onStatus(List<CcTailscaleStatus> list) =>
      _offer(list.where((s) => s.tag == widget.liveTag).firstOrNull);

  /// Запись из потока или опроса: на экране — пришедшая последней.
  void _offer(CcTailscaleStatus? s) {
    _pending = s;
    _hasPending = true;
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
    if (!_hasPending || !mounted) return;
    final s = _pending;
    _pending = null;
    _hasPending = false;
    _lastRedraw = DateTime.now();
    setState(() {
      _hasData = true;
      _status = s;
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
    // Выход остаётся и в Devices: меню строки (пинг, копирование) есть только
    // там, у пункта Exit node его нет.
    final devices = sortDevices(s.peers);
    final grouped = showOwnerGroups(s);
    final children = <Widget>[
      if (s.health.isNotEmpty) _healthBlock(context, s.health),
      _statusBlock(context, s),
      if (s.self != null) _thisDeviceBlock(context, s.self!),
      _exitNodeBlock(context, s),
      if (widget.onSaveFields != null) _settingsBlock(context),
      _devicesHeader(context, devices),
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
      padding: const EdgeInsets.only(bottom: 24).withSafeBottom(context),
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
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  /// §645 — `Devices` и вторичным цветом `· 2 online / 6` (всего — устройства
  /// списка).
  Widget _devicesHeader(BuildContext context, List<CcTailscalePeer> devices) {
    final theme = Theme.of(context);
    final online = devices.where((p) => p.online).length;
    final counts = getLocalText.s(
      "%s online / %s",
      '$online',
      '${devices.length}',
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: getLocalText.s("Devices")),
            if (devices.isNotEmpty)
              TextSpan(
                text: ' · $counts',
                style: TextStyle(
                  fontWeight: FontWeight.normal,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        key: const ValueKey('tailscale-devices-header'),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _groupTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
        if (self.ips.isNotEmpty) _addressTile(self.ips),
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

  /// §645 — один заголовок Address, адреса столбиком в порядке ядра; тап по
  /// строке копирует этот адрес.
  Widget _addressTile(List<String> ips) => ListTile(
    dense: true,
    title: Text(getLocalText.s("Address")),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final ip in ips)
          InkWell(
            onTap: () => unawaited(_copy(ip)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(ip),
            ),
          ),
      ],
    ),
  );

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
                  subtitle: _exitSubtitle(p, active),
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

  /// §613 — строка пути устройства: путь и возраст хендшейка (`0` — без
  /// возраста). `NONE` — пусто, строка не рисуется.
  static String _pathLine(CcTailscalePeer p) {
    final path = tailscalePathLabel(p);
    if (path.isEmpty) return '';
    if (p.lastHandshake <= 0) return path;
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - p.lastHandshake;
    return '$path · ${getLocalText.s("handshake %s", wgAgeLabel(age))}';
  }

  /// §613 — подпись пункта Exit node: у действующего выхода — путь до него
  /// (§645 — с иконкой пути).
  Widget? _exitSubtitle(CcTailscalePeer p, CcTailscalePeer? active) {
    final offline = p.online ? '' : getLocalText.s("offline");
    final path = active != null && active.stableId == p.stableId
        ? _pathLine(active)
        : '';
    if (offline.isEmpty && path.isEmpty) return null;
    return Text.rich(
      TextSpan(
        children: [
          if (offline.isNotEmpty)
            TextSpan(text: path.isEmpty ? offline : '$offline · '),
          if (path.isNotEmpty) ..._pathSpans(tailscalePathKind(active!), path),
        ],
      ),
    );
  }

  /// §645 — иконка пути (цветная только она) и текст подписи.
  static List<InlineSpan> _pathSpans(TailscalePathKind? kind, String text) {
    final look = tailscalePathIcon(kind);
    return [
      if (look != null)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(look.icon, size: 15, color: look.color),
          ),
        ),
      TextSpan(text: text),
    ];
  }

  // ── Settings ──

  /// §613 — `advertise_exit_node` тела узла. Ядро не совмещает его с
  /// `exit_node` (реестр: `field_conflict`) — при записанном выходе его можно
  /// только снять. `exit_node_allow_lan_access` в UI нет (§646): ядро на
  /// Android его не применяет, локальную сеть ведёт пресет «Private IPs».
  Widget _settingsBlock(BuildContext context) {
    final body = widget.body;
    final hasExit = recordedExitNode(body) != null;
    final advertise = body['advertise_exit_node'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("Settings")),
        SwitchListTile(
          key: const ValueKey('tailscale-advertise-exit'),
          dense: true,
          title: Text(getLocalText.s("Advertise this device as exit node")),
          subtitle: hasExit && !advertise
              ? Text(
                  getLocalText.s("Not available while an exit node is used."),
                )
              : null,
          value: advertise,
          onChanged: _busy || (hasExit && !advertise)
              ? null
              : (v) => unawaited(_saveField('advertise_exit_node', v)),
        ),
      ],
    );
  }

  /// Выключенное значение — поле убирается (по умолчанию `false`).
  Future<void> _saveField(String key, bool value) async {
    final save = widget.onSaveFields;
    if (save == null) return;
    setState(() => _busy = true);
    try {
      await save({key: value ? true : null});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Health ──

  /// §613 (ядро SPEC 115) — предупреждения бэкенда, по строке на запись.
  /// Текст ядра, не переводится.
  Widget _healthBlock(BuildContext context, List<String> health) {
    final theme = Theme.of(context);
    const color = Colors.orange;
    return Container(
      key: const ValueKey('tailscale-health'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in health)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(h, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Devices ──

  /// §645 — строка устройства:
  /// 1. точка в сети / нет, имя; справа первый адрес;
  /// 2. ОС и роли; справа второй адрес и `+N` (раскрывает остальные адреса);
  /// 3. как подключено ([tailscaleConnectionText]) с иконкой пути.
  ///
  /// Не влезает по ширине — обрезается левая часть, адрес справа целый.
  Widget _deviceRow(
    BuildContext context,
    CcTailscaleStatus s,
    CcTailscalePeer p,
  ) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final tail = tailscaleAddressTail(p.ips);
    final expanded = tail.more > 0 && _expanded.contains(p.stableId);
    final details = tailscaleDeviceDetails(p);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final connection = tailscaleConnectionText(p, now);
    final rowKey = p.stableId.isEmpty ? p.hostName : p.stableId;
    return ListTile(
      key: ValueKey('tailscale-device-$rowKey'),
      dense: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              p.hostName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (p.firstIp.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(p.firstIp, style: small),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (details.isNotEmpty || tail.second.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
                if (tail.second.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _secondAddress(p, tail, expanded, small),
                ],
              ],
            ),
          if (expanded)
            for (final ip in p.ips.skip(2))
              Align(
                alignment: Alignment.centerRight,
                child: Text(ip, style: small),
              ),
          if (connection.isNotEmpty)
            Text.rich(
              TextSpan(children: _pathSpans(tailscalePathKind(p), connection)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small,
            ),
        ],
      ),
      leading: Icon(
        Icons.circle,
        size: 10,
        color: p.online ? Colors.green : theme.disabledColor,
      ),
      onTap: () => unawaited(_deviceMenu(p)),
    );
  }

  /// Второй адрес; при адресах сверх двух — `+N` и стрелка, тап раскрывает и
  /// сворачивает остальные адреса.
  Widget _secondAddress(
    CcTailscalePeer p,
    ({String second, int more}) tail,
    bool expanded,
    TextStyle? style,
  ) {
    final address = Text(tail.second, style: style);
    if (tail.more == 0) return address;
    return InkWell(
      key: ValueKey('tailscale-more-${p.stableId}'),
      onTap: () => setState(() {
        if (!_expanded.remove(p.stableId)) _expanded.add(p.stableId);
      }),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          address,
          const SizedBox(width: 4),
          Text('+${tail.more}', style: style), // l10n-exempt: count
          Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16),
        ],
      ),
    );
  }

  /// Меню устройства: имя, MagicDNS-имя, по пункту на адрес, проверка по
  /// первому адресу.
  Future<void> _deviceMenu(CcTailscalePeer p) async {
    final single = p.ips.length == 1;
    final action = await showAppBottomSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(getLocalText.s("Copy name")),
            onTap: () => Navigator.pop(ctx, 'name'),
          ),
          if (p.dnsNameClean.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(getLocalText.s("Copy MagicDNS name")),
              onTap: () => Navigator.pop(ctx, 'dns'),
            ),
          for (final ip in p.ips)
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: Text(
                single
                    ? getLocalText.s("Copy address")
                    : getLocalText.s("Copy %s", ip),
              ),
              onTap: () => Navigator.pop(ctx, 'ip:$ip'),
            ),
          if (p.firstIp.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.network_ping),
              title: Text(getLocalText.s("Ping")),
              onTap: () => Navigator.pop(ctx, 'ping'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action.startsWith('ip:')) {
      await _copy(action.substring(3));
      return;
    }
    switch (action) {
      case 'name':
        await _copy(p.hostName);
      case 'dns':
        await _copy(p.dnsNameClean);
      case 'ping':
        await showAppBottomSheet<void>(
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

/// §645 — иконка и цвет пути до устройства: напрямую — молния цвета точки
/// «в сети», через DERP и через пира-ретранслятора — оранжевые; пути нет —
/// без иконки.
({IconData icon, Color color})? tailscalePathIcon(
  TailscalePathKind? kind,
) => switch (kind) {
  TailscalePathKind.direct => (icon: Icons.bolt, color: Colors.green),
  TailscalePathKind.derp => (icon: Icons.cloud_outlined, color: Colors.orange),
  TailscalePathKind.peerRelay => (icon: Icons.device_hub, color: Colors.orange),
  null => null,
};

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
