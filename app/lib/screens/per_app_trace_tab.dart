// §044 — Per-app trace tab. Третий tab в `StatsScreen`. Показывает
// recording state, target picker, sub-tabs Live / Domains / IPs / Connections,
// overflow menu (verbose toggle / wipe / share / help), in-tab banner для
// verbose-active state.
//
// Дизайн-решения:
// - **4 sub-tab'а**: Live (streaming) / Domains (по domain'у) / IPs (по IP)
//   / Connections (per-conn timeline). Domains и IPs дают симметричные
//   точки входа: «куда app ходит» и «какие IP» — оба полезны для разных
//   диагностических кейсов (IP-аудит, hostless conn'ы без SNI).
// - **Inline expand на Connections** + jump-to-Domains даёт двухуровневый
//   drill-down: timeline → конкретный conn → детальный domain breakdown,
//   без потери контекста внутри tab'а.
// - **Search-by-IP в Domains tab**: cross-domain CDN-аудит (один IP =
//   много доменов) + удобный «обратный lookup» когда есть подозрительный
//   IP из внешнего источника.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/app_info.dart';
import '../services/app_info_cache.dart';
import '../services/clash_api_client.dart';
import '../services/traffic_profiler.dart';

class PerAppTraceTab extends StatefulWidget {
  const PerAppTraceTab({super.key, required this.clash});

  final ClashApiClient clash;

  @override
  State<PerAppTraceTab> createState() => _PerAppTraceTabState();
}

class _PerAppTraceTabState extends State<PerAppTraceTab>
    with SingleTickerProviderStateMixin {
  String? _pendingTarget; // выбран но ещё не started
  bool _verbose = false;
  bool _verboseActiveInSession = false;
  Timer? _ticker; // для refresh «Recording 02:34» каждую секунду

  late TabController _subTabs;

  /// Целевой домен для авто-фокуса в Domains tab'е после нажатия
  /// «View in Domains →» на Connections row. После того как _DomainsView
  /// применил focus (заполнил search + expand'нул row), parent сбрасывает
  /// в null через [_consumeFocusDomain].
  String? _focusDomain;

  @override
  void initState() {
    super.initState();
    _subTabs = TabController(length: 4, vsync: this);
    TrafficProfiler.I.addListener(_onProfilerChanged);
    // Runtime fetcher уже забинден в HomeScreen.initState — не дублируем
    // (closure там читает свежий clashClient на каждом poll'е).
    _onProfilerChanged();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TrafficProfiler.I.isRecording) setState(() {});
    });
  }

  void _onProfilerChanged() {
    if (!mounted) return;
    setState(() {
      final s = TrafficProfiler.I.active;
      if (s != null) {
        _verboseActiveInSession = s.wasVerbose;
        _pendingTarget = s.targetPackage;
      }
    });
  }

  @override
  void dispose() {
    TrafficProfiler.I.removeListener(_onProfilerChanged);
    _ticker?.cancel();
    _subTabs.dispose();
    super.dispose();
  }

  /// Триггерится из «View in Domains →» в Connections row. Переключает
  /// sub-tab на Domains (index 1) и устанавливает [_focusDomain]; внутри
  /// `_DomainsView` это auto-fill'ит search и expand'ит соответствующую
  /// строку. После применения focus consumer'ится через [_consumeFocusDomain].
  void _navigateToDomain(String domain) {
    setState(() => _focusDomain = domain);
    _subTabs.animateTo(1);
  }

  void _consumeFocusDomain() {
    if (_focusDomain != null) {
      setState(() => _focusDomain = null);
    }
  }

  Future<void> _pickApp() async {
    final pkg = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _SingleAppPickerScreen()),
    );
    if (pkg == null || !mounted) return;
    setState(() => _pendingTarget = pkg);
  }

  Future<void> _toggleRecording() async {
    final profiler = TrafficProfiler.I;
    if (profiler.isRecording) {
      await profiler.stop();
    } else {
      final target = _pendingTarget;
      if (target == null) return;
      await profiler.start(target, verbose: _verbose);
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _toggleVerbose(bool value) async {
    setState(() => _verbose = value);
    // Если сейчас active session — изменить уже nothing нельзя без reload,
    // показываем snackbar.
    if (TrafficProfiler.I.isRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Verbose toggle takes effect on next session — stop and restart.'),
        ),
      );
    }
  }

  Future<void> _shareSession(Session s) async {
    final json = const JsonEncoder.withIndent('  ').convert(_sessionToJson(s));
    await Share.share(json, subject: 'LxBox session ${s.targetPackage}');
  }

  Future<void> _copySession(Session s) async {
    final json = const JsonEncoder.withIndent('  ').convert(_sessionToJson(s));
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Session JSON copied to clipboard')),
    );
  }

  void _wipeAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all sessions?'),
        content: const Text('Saved trace sessions will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              TrafficProfiler.I.clearAll();
              Navigator.pop(ctx);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiler = TrafficProfiler.I;
    final session = profiler.active;
    return Column(
      children: [
        if (_verboseActiveInSession && session != null)
          _verboseBanner(context),
        _header(context, session),
        if (session != null) _statsRow(context, session),
        const SizedBox(height: 4),
        TabBar(
          controller: _subTabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Live'),
            Tab(text: 'Domains'),
            Tab(text: 'IPs'),
            Tab(text: 'Connections'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _subTabs,
            children: [
              _LiveView(
                session: session,
                onViewInDomains: _navigateToDomain,
              ),
              _DomainsView(
                session: session,
                focusDomain: _focusDomain,
                onFocusConsumed: _consumeFocusDomain,
                onViewInDomains: _navigateToDomain,
              ),
              _IpsView(
                session: session,
                onViewInDomains: _navigateToDomain,
              ),
              _ConnectionsView(
                session: session,
                onViewInDomains: _navigateToDomain,
              ),
            ],
          ),
        ),
        if (session == null && profiler.completed.isNotEmpty)
          _savedSessions(context),
      ],
    );
  }

  Widget _header(BuildContext context, Session? active) {
    final cs = Theme.of(context).colorScheme;
    final target = active?.targetPackage ?? _pendingTarget;
    final canRecord = target != null;
    final isRecording = active != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: isRecording ? null : _pickApp,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                  color: cs.surface,
                ),
                child: Row(
                  children: [
                    Icon(Icons.android, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        target ?? 'Pick an app to trace…',
                        style: TextStyle(
                          fontSize: 14,
                          color: target == null ? cs.onSurfaceVariant : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!isRecording)
                      Icon(Icons.arrow_drop_down,
                          color: cs.onSurfaceVariant, size: 20),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canRecord ? _toggleRecording : null,
            icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record,
                size: 18),
            label: Text(isRecording ? 'STOP' : 'START'),
            style: FilledButton.styleFrom(
              backgroundColor:
                  isRecording ? cs.error : cs.primary,
              foregroundColor: isRecording ? cs.onError : cs.onPrimary,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'verbose-on':
                  await _toggleVerbose(true);
                case 'verbose-off':
                  await _toggleVerbose(false);
                case 'share':
                  if (active != null) await _shareSession(active);
                case 'copy':
                  if (active != null) await _copySession(active);
                case 'wipe':
                  _wipeAll();
                case 'help':
                  _showHelp();
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: _verbose ? 'verbose-off' : 'verbose-on',
                checked: _verbose,
                child: const Text('Verbose core logs (debug)'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'copy',
                enabled: active != null,
                child: const ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('Copy session JSON'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'share',
                enabled: active != null,
                child: const ListTile(
                  leading: Icon(Icons.share),
                  title: Text('Share session'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'wipe',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Clear all sessions'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  leading: Icon(Icons.help_outline),
                  title: Text('Help'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statsRow(BuildContext context, Session s) {
    final cs = Theme.of(context).colorScheme;
    final dur = (s.finishedAt ?? DateTime.now()).difference(s.startedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: cs.error),
          const SizedBox(width: 6),
          Text(
            s.finishedAt == null ? 'Recording' : 'Stopped',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Text(_fmtDur(dur),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(width: 16),
          Text('${s.byDomain.length} doms · ${s.byIp.length} ips · ${s.events.length} ev',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          if (s.eventsDropped > 0) ...[
            const SizedBox(width: 8),
            Text('· ${s.eventsDropped} dropped',
                style: TextStyle(fontSize: 12, color: cs.error)),
          ],
        ],
      ),
    );
  }

  Widget _verboseBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: cs.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Verbose core logs active — battery/CPU impact while session runs',
              style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _savedSessions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sessions = TrafficProfiler.I.completed.toList().reversed.toList();
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Saved sessions (last ${sessions.length})',
                style: Theme.of(context).textTheme.labelMedium),
          ),
          ...sessions.map((s) => ListTile(
                dense: true,
                title: Text(s.targetPackage,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${_fmtDur(s.finishedAt!.difference(s.startedAt))} · '
                  '${s.byDomain.length} doms · ${s.byIp.length} ips',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.share, size: 18),
                      tooltip: 'Share',
                      onPressed: () => _shareSession(s),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete',
                      onPressed: () {
                        TrafficProfiler.I.delete(s.id);
                      },
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Per-app trace'),
        content: const SingleChildScrollView(
          child: Text(
            'Pick an app and tap START to record its DNS resolves, '
            'connections, and routing chain.\n\n'
            '• Live — newest events first (DNS + TCP/UDP)\n'
            '• Domains — aggregated unique domains, with CNAME chain & IPs. '
            'Search by domain or IP.\n'
            '• IPs — aggregated unique destination IPs (ports, conns, bytes, '
            'outbound)\n'
            '• Connections — per-connection timeline. Tap a row to inline-expand '
            '(CNAME, all IPs, issues); button [View in Domains →] jumps to '
            'aggregated breakdown.\n\n'
            'Verbose mode (debug-level core logs) gives more detail '
            'but increases CPU/battery use until you disable it. '
            'Toggling verbose takes effect on the next session.\n\n'
            'Sessions are kept in memory only — last 5 are saved across '
            'recordings, but ALL are wiped if the app is force-stopped.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  static String _fmtDur(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes % 60}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    }
    return '${d.inSeconds}s';
  }
}

Map<String, Object?> _sessionToJson(Session s) => {
      ...s.toMetaJson(),
      'events': s.events.map((e) => e.toJson()).toList(),
      'by_domain': s.byDomain.values.map((d) => d.toJson()).toList(),
      'by_ip': s.byIp.values.map((i) => i.toJson()).toList(),
    };

// ─── Sub-views ──────────────────────────────────────────────────────────

class _LiveView extends StatelessWidget {
  const _LiveView({required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const _Empty(text: 'Start recording to see events.');
    if (s.events.isEmpty) {
      return const _Empty(text: 'Waiting for events…');
    }
    final reversed = s.events.reversed.toList();
    return ListView.builder(
      itemCount: reversed.length,
      itemBuilder: (_, i) => _eventTile(context, reversed[i]),
    );
  }

  Widget _eventTile(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    Color kindColor;
    String kindLabel;
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        kindColor = cs.tertiary;
        kindLabel = 'DNS';
      case TrafficEventKind.dnsFail:
        kindColor = cs.error;
        kindLabel = 'DNS×';
      case TrafficEventKind.tcpOpen:
        kindColor = cs.primary;
        kindLabel = 'TCP';
      case TrafficEventKind.tcpClose:
        kindColor = cs.outline;
        kindLabel = 'TCP·';
      case TrafficEventKind.udpOpen:
        kindColor = cs.secondary;
        kindLabel = 'UDP';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ts,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: kindColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(kindLabel,
                    style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: kindColor)),
              ),
              const SizedBox(width: 8),
              Expanded(child: _eventSummaryWidget(context, e)),
              if (e.issues.isNotEmpty)
                Tooltip(
                  message:
                      e.issues.map((a) => a.description).join('\n'),
                  child: Icon(Icons.warning_amber,
                      size: 14, color: cs.error),
                ),
            ],
          ),
          if (e.cnameChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '↳ CNAME ${e.cnameChain.join(" → ")}',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.outboundChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '↳ via ${e.outboundChain.join(" → ")}',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.processInferred)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '〽 inferred from prior DNS',
                style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// Rich event-summary с inline-кликабельным IP chip'ом для Live tab'а.
  /// Layout: domain/host text + (если есть IP в event'е) ↗-icon → переход
  /// на Domains tab с автоподстановкой этого IP в search.
  Widget _eventSummaryWidget(BuildContext context, TrafficEvent e) {
    const style = TextStyle(fontSize: 12);
    final ip = e.ip;
    final port = e.port;
    final domain = e.domain;

    String head;
    bool showIpChip = false;
    bool hostlessIpInline = false;

    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        head = '${domain ?? "?"} →';
        showIpChip = ip != null;
      case TrafficEventKind.dnsFail:
        return const Text('DNS exchange failed',
            style: style, overflow: TextOverflow.ellipsis);
      case TrafficEventKind.tcpOpen:
      case TrafficEventKind.udpOpen:
        if (domain != null && domain.isNotEmpty) {
          head = '$domain:${port ?? "?"}';
        } else {
          head = '[';
          hostlessIpInline = true;
        }
      case TrafficEventKind.tcpClose:
        final bytes =
            '↑${_fmtBytes(e.upBytes ?? 0)} ↓${_fmtBytes(e.downBytes ?? 0)}';
        if (domain != null && domain.isNotEmpty) {
          head = '$domain:${port ?? "?"} closed · $bytes';
        } else {
          head = '[';
          hostlessIpInline = true;
        }
        return Row(
          children: [
            Flexible(child: Text(head, style: style, overflow: TextOverflow.ellipsis)),
            if (hostlessIpInline) ...[
              _ipChip(context, ip ?? '?', onViewInDomains),
              Text(']:${port ?? "?"} closed · $bytes',
                  style: style, overflow: TextOverflow.ellipsis),
            ],
          ],
        );
    }

    if (hostlessIpInline) {
      return Row(
        children: [
          Text(head, style: style),
          _ipChip(context, ip ?? '?', onViewInDomains),
          Flexible(
            child: Text(']:${port ?? "?"}',
                style: style, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }
    return Row(
      children: [
        Flexible(child: Text(head, style: style, overflow: TextOverflow.ellipsis)),
        if (showIpChip) ...[
          const SizedBox(width: 4),
          _ipChip(context, ip!, onViewInDomains),
        ],
      ],
    );
  }

  // ignore: unused_element
  static String _legacyEventSummary(TrafficEvent e) {
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        return '${e.domain ?? "?"} → ${e.ip ?? "?"}';
      case TrafficEventKind.dnsFail:
        return 'DNS exchange failed';
      case TrafficEventKind.tcpOpen:
      case TrafficEventKind.udpOpen:
        final hp = '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"}';
        return hp;
      case TrafficEventKind.tcpClose:
        final hp = '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"}';
        final bytes = '↑${_fmtBytes(e.upBytes ?? 0)} ↓${_fmtBytes(e.downBytes ?? 0)}';
        return '$hp closed · $bytes';
    }
  }
}

/// Domains tab — aggregated unique domains with CNAME chain & IPs.
///
/// Stateful, потому что:
/// - Search field (matches domain || ip || cname target) — folded роль
///   ушедшей IPs tab'ы. Юзер вбивает IP → видит все домены, что резолвились
///   на него (cross-domain CDN-аудит).
/// - Auto-expand при focus-навигации из Connections («View in Domains →»)
///   через `widget.focusDomain` + `widget.onFocusConsumed`.
class _DomainsView extends StatefulWidget {
  const _DomainsView({
    required this.session,
    required this.onViewInDomains,
    this.focusDomain,
    this.onFocusConsumed,
  });
  final Session? session;
  final ValueChanged<String> onViewInDomains;
  final String? focusDomain;
  final VoidCallback? onFocusConsumed;

  @override
  State<_DomainsView> createState() => _DomainsViewState();
}

class _DomainsViewState extends State<_DomainsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  // Domain'ы которые юзер «expand'нул» (в т.ч. через focus-jump). PageStorageKey
  // не используем потому что ExpansionTile state живёт внутри tile'а — нам надо
  // программно открывать.
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _applyFocusIfAny(initial: true);
  }

  @override
  void didUpdateWidget(_DomainsView old) {
    super.didUpdateWidget(old);
    if (widget.focusDomain != null &&
        widget.focusDomain != old.focusDomain) {
      _applyFocusIfAny();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _applyFocusIfAny({bool initial = false}) {
    final focus = widget.focusDomain;
    if (focus == null) return;
    _searchCtrl.text = focus;
    _search = focus;
    _expanded.add(focus);
    if (!initial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onFocusConsumed?.call();
        if (mounted) setState(() {});
      });
    } else {
      // initState path — onFocusConsumed зовём после первого build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onFocusConsumed?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    if (s == null) {
      return const _Empty(text: 'Start recording to see domains.');
    }
    final all = s.byDomain.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    final filtered = _search.isEmpty
        ? all
        : all.where((d) => _matchesSearch(d, _search)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search domain or IP…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? const _Empty(text: 'No domains yet.')
              : (filtered.isEmpty
                  ? const _Empty(text: 'No matches.')
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _row(context, filtered[i]),
                    )),
        ),
      ],
    );
  }

  static bool _matchesSearch(DomainStats d, String q) {
    final lq = q.toLowerCase();
    if (d.domain.toLowerCase().contains(lq)) return true;
    if (d.ips.any((ip) => ip.contains(q))) return true;
    if (d.cnameTargets.any((c) => c.toLowerCase().contains(lq))) return true;
    return false;
  }

  Widget _row(BuildContext context, DomainStats d) {
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      // PageStorageKey стабильно идентифицирует tile в списке — иначе
      // expand-state теряется при rebuild'ах от ChangeNotifier'а.
      key: PageStorageKey<String>('domain:${d.domain}'),
      initiallyExpanded: _expanded.contains(d.domain),
      onExpansionChanged: (open) {
        if (open) {
          _expanded.add(d.domain);
        } else {
          _expanded.remove(d.domain);
        }
      },
      title: Text(d.domain,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: Row(
        children: [
          Text('${d.connections} conns',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          Text('↑${_fmtBytes(d.upBytes)} ↓${_fmtBytes(d.downBytes)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if (d.issues.isNotEmpty) ...[
            const SizedBox(width: 6),
            Icon(Icons.warning_amber, size: 12, color: cs.error),
          ],
        ],
      ),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
      children: [
        if (d.cnameTargets.isNotEmpty)
          _kv(cs, 'CNAME', d.cnameTargets.join(' → ')),
        if (d.ips.isNotEmpty) _kvIps(context, cs, 'IPs', d.ips),
        if (d.outbounds.isNotEmpty)
          _kv(cs, 'Outbound', d.outbounds.join(' / ')),
        if (d.firstSeen != null)
          _kv(cs, 'First', _fmtTime(d.firstSeen!)),
        if (d.lastSeen != null) _kv(cs, 'Last', _fmtTime(d.lastSeen!)),
        for (final a in d.issues)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(Icons.warning_amber, size: 12, color: cs.error),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(a.description,
                      style: TextStyle(fontSize: 11, color: cs.error)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// IP-вариант [_kv]: вместо строки рендерит [_ipChipList] — каждый IP
  /// со своей ↗-иконкой перехода на Domains tab. В Domains tab
  /// `onViewInDomains` обновит search-фильтр на этот IP, что эквивалентно
  /// «refocus»: видны все домены резолвящиеся на него (cross-domain CDN).
  Widget _kvIps(BuildContext context, ColorScheme cs, String k,
          Iterable<String> ips) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: _ipChipList(context, ips, widget.onViewInDomains),
            ),
          ],
        ),
      );

  Widget _kv(ColorScheme cs, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 70,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant))),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}

/// IPs tab — aggregated unique destination IPs. Симметричен Domains tab'у:
/// «куда app ходит по IP». Полезен для:
/// - hostless conn'ов (без SNI sniffing) — здесь они нормально aggregated
/// - подозрительных IP из внешнего источника (threat-feed, логи провайдера)
/// - топ-IP-by-traffic glance view
///
/// На каждой строке — иконка `open_in_new`, симметричная Connections row:
/// тап → переход на Domains tab с автоподстановкой IP в search (увидеть
/// все domain'ы которые резолвились на этот IP — cross-domain CDN-аудит).
class _IpsView extends StatelessWidget {
  const _IpsView({required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const _Empty(text: 'Start recording to see IPs.');
    final ips = s.byIp.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    if (ips.isEmpty) return const _Empty(text: 'No IPs yet.');
    return ListView.builder(
      itemCount: ips.length,
      itemBuilder: (_, i) {
        final ip = ips[i];
        return ListTile(
          dense: true,
          title: Align(
            alignment: Alignment.centerLeft,
            child: _ipChip(context, ip.ip, onViewInDomains),
          ),
          subtitle: Text(
            'ports ${ip.ports.join(", ")} · ${ip.connections} conns · '
            '↑${_fmtBytes(ip.upBytes)} ↓${_fmtBytes(ip.downBytes)}'
            '${ip.outbounds.isEmpty ? "" : " · ${ip.outbounds.join(" / ")}"}',
            style: const TextStyle(fontSize: 11),
          ),
        );
      },
    );
  }
}

/// Connections timeline. Tap row → inline-expand (CNAME + all IPs +
/// issues + кнопка `[View in Domains →]` если у event'а есть domain).
class _ConnectionsView extends StatelessWidget {
  const _ConnectionsView({required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) {
      return const _Empty(text: 'Start recording to see connections.');
    }
    final conns = s.events
        .where((e) =>
            e.kind == TrafficEventKind.tcpOpen ||
            e.kind == TrafficEventKind.tcpClose ||
            e.kind == TrafficEventKind.udpOpen)
        .toList()
        .reversed
        .toList();
    if (conns.isEmpty) {
      return const _Empty(text: 'No connections yet.');
    }
    return ListView.builder(
      itemCount: conns.length,
      itemBuilder: (_, i) => _ConnTile(
        // Stable key: ts + domain/ip — events append-only, ts уникальный
        // на event level (микросекундная DateTime.now).
        key: ValueKey<String>(
            '${conns[i].ts.microsecondsSinceEpoch}:${conns[i].kind.name}'),
        event: conns[i],
        session: s,
        onViewInDomains: onViewInDomains,
      ),
    );
  }
}

class _ConnTile extends StatefulWidget {
  const _ConnTile({
    super.key,
    required this.event,
    required this.session,
    required this.onViewInDomains,
  });
  final TrafficEvent event;
  final Session session;
  final ValueChanged<String> onViewInDomains;

  @override
  State<_ConnTile> createState() => _ConnTileState();
}

class _ConnTileState extends State<_ConnTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    final closed = e.kind == TrafficEventKind.tcpClose;

    // Hostless conn: domain отсутствует → показываем `[<ip>]:port`.
    final displayHostPort = e.domain != null && e.domain!.isNotEmpty
        ? '${e.domain}:${e.port ?? "?"}'
        : '[${e.ip ?? "?"}]:${e.port ?? "?"}';

    final domain = e.domain;
    final domainStats =
        (domain != null && domain.isNotEmpty) ? widget.session.byDomain[domain] : null;

    // Click-target — только верхняя часть (header). Раскрытая secция
    // _expandedDetails вне InkWell'а: тап по [View in Domains] кнопке или
    // по тексту CNAME/IPs не схлопывает row.
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ts,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  displayHostPort,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: closed ? cs.onSurfaceVariant : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${_fmtBytes(e.upBytes ?? 0)} ↓${_fmtBytes(e.downBytes ?? 0)}',
                style:
                    TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              if (e.issues.isNotEmpty) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message:
                      e.issues.map((a) => a.description).join('\n'),
                  child:
                      Icon(Icons.warning_amber, size: 14, color: cs.error),
                ),
              ],
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: cs.onSurfaceVariant),
            ],
          ),
          if (e.outboundChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Text('via ${e.outboundChain.join(" → ")}',
                  style:
                      TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ),
          if (e.duration != null)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Text('duration ${e.duration!.inMilliseconds}ms',
                  style:
                      TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: header,
        ),
        if (_expanded) _expandedDetails(context, e, domainStats),
      ],
    );
  }

  Widget _expandedDetails(
      BuildContext context, TrafficEvent e, DomainStats? d) {
    final cs = Theme.of(context).colorScheme;
    final cnameTargets = d?.cnameTargets.toList() ?? const <String>[];
    final domainIps = d?.ips.toList() ?? const <String>[];
    final issues = e.issues.isNotEmpty
        ? e.issues
        : (d?.issues ?? const <ConnectionIssue>[]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cnameTargets.isNotEmpty)
            _miniKv(cs, 'CNAME', cnameTargets.join(' → ')),
          if (domainIps.isNotEmpty)
            _miniKvIps(context, cs, 'All IPs', domainIps)
          else if (e.ip != null)
            _miniKvIps(context, cs, 'IP', [e.ip!]),
          if (e.rule != null && e.rule!.isNotEmpty)
            _miniKv(cs,
                'Rule',
                e.rulePayload != null && e.rulePayload!.isNotEmpty
                    ? '${e.rule} (${e.rulePayload})'
                    : e.rule!),
          if (e.processInferred)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('〽 process inferred from prior DNS',
                  style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: cs.onSurfaceVariant)),
            ),
          for (final a in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 12, color: cs.error),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(a.description,
                        style: TextStyle(fontSize: 11, color: cs.error)),
                  ),
                ],
              ),
            ),
          if (e.domain != null && e.domain!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => widget.onViewInDomains(e.domain!),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('View in Domains',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniKv(ColorScheme cs, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  /// IP-вариант [_miniKv]: вместо строки рендерит [_ipChipList] с
  /// ↗-иконкой перехода на Domains tab.
  Widget _miniKvIps(BuildContext context, ColorScheme cs, String k,
          Iterable<String> ips) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: _ipChipList(context, ips, widget.onViewInDomains),
            ),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
}

/// `IP ↗` chip — текст IP'а + clickable иконка перехода на Domains tab
/// с автоподстановкой этого IP в search. Используется во всех вкладках
/// где рендерится IP (Live / Domains expanded / IPs / Connections expanded)
/// для symметрии.
Widget _ipChip(BuildContext context, String ip, ValueChanged<String>? onTap) {
  final cs = Theme.of(context).colorScheme;
  final content = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(ip,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
      if (onTap != null) ...[
        const SizedBox(width: 3),
        Icon(Icons.open_in_new, size: 12, color: cs.primary),
      ],
    ],
  );
  if (onTap == null) return content;
  return InkWell(
    onTap: () => onTap(ip),
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: content,
    ),
  );
}

/// Wrap из [_ipChip] для рендера множества IP'ов (Domains/Connections
/// expanded views).
Widget _ipChipList(
    BuildContext context, Iterable<String> ips, ValueChanged<String>? onTap) {
  return Wrap(
    spacing: 4,
    runSpacing: 2,
    children: [for (final ip in ips) _ipChip(context, ip, onTap)],
  );
}

String _fmtBytes(int b) {
  if (b < 1024) return '${b}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
}

String _fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

// ─── Single-app picker ──────────────────────────────────────────────────

class _SingleAppPickerScreen extends StatefulWidget {
  const _SingleAppPickerScreen();

  @override
  State<_SingleAppPickerScreen> createState() => _SingleAppPickerScreenState();
}

class _SingleAppPickerScreenState extends State<_SingleAppPickerScreen> {
  List<AppInfo> _apps = [];
  bool _loading = true;
  bool _showSystem = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 50), _load);
  }

  Future<void> _load() async {
    try {
      final apps = await AppInfoCache.loadAllApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<AppInfo> get _filtered {
    var list = _apps.where((a) => _showSystem || !a.isSystem).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((a) =>
              a.appName.toLowerCase().contains(q) ||
              a.packageName.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick app to trace'),
        actions: [
          IconButton(
            tooltip: 'Show system apps',
            icon: Icon(
              _showSystem ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () => setState(() => _showSystem = !_showSystem),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by name or package',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final a = _filtered[i];
                      AppInfoCache.ensure(a.packageName);
                      return AnimatedBuilder(
                        animation: AppInfoCache.revision,
                        builder: (_, _) {
                          final info = AppInfoCache.of(a.packageName);
                          Widget leading;
                          if (info?.icon != null) {
                            leading = ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(info!.icon!,
                                  width: 32, height: 32, gaplessPlayback: true),
                            );
                          } else {
                            leading = SizedBox(
                              width: 32,
                              height: 32,
                              child: CircleAvatar(
                                backgroundColor: cs.surfaceContainerHighest,
                                child: Text(
                                  a.appName.isEmpty
                                      ? '?'
                                      : a.appName.characters.first
                                          .toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface),
                                ),
                              ),
                            );
                          }
                          return ListTile(
                            leading: leading,
                            title: Text(a.appName,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(a.packageName,
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace')),
                            onTap: () =>
                                Navigator.pop(context, a.packageName),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

