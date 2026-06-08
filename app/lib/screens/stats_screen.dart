import 'dart:async';

import 'package:flutter/material.dart';

import '../models/config_node.dart';
import '../services/clash_api_client.dart';
import '../services/traffic_profiler.dart';
import '../vpn/box_vpn_client.dart';
import 'connections_screen.dart';
import 'live_events_tab.dart';
import 'per_app_trace_tab.dart';
import 'stats_screen/overview_models.dart';
import 'stats_screen/overview_tab.dart';

/// §044/§048: enum для start-tab выбора в StatsScreen. Передаётся при
/// `Navigator.push(StatsScreen(initialTab: StatsTab.perApp))`.
enum StatsTab { overview, connections, perApp, live }

class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    required this.clash,
    this.configRaw = '',
    this.initialTab = StatsTab.overview,
  });

  final ClashApiClient clash;
  final String configRaw;
  final StatsTab initialTab;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> with WidgetsBindingObserver {
  Map<String, OutboundGroup> _groups = {};
  int _totalUp = 0;
  int _totalDown = 0;
  int _totalConns = 0;
  int _memory = 0;
  Map<String, int> _byRule = const {};
  Map<String, AppStat> _byApp = const {};
  bool _loading = true;
  Timer? _timer;
  // §091 — структурные запросы к конфигу через ParsedConfig (был локальный
  // _detourMap + _parseDetourMap + _detourChain дубль; до §091 —
  // ConfigIntrospection).
  late final ParsedConfig _intro = ParsedConfig.parse(widget.configRaw);

  /// §069 — runtime applied значение `allowBypass()` от последнего
  /// `establish()`. Показывается warning icon в AppBar если true.
  bool _currentSessionAllowBypass = false;
  final _vpn = BoxVpnClient();

  static const _refreshInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Battery-friendly: stop'имся когда app уходит в background. 3-секундный
    // polling Clash API не имеет смысла когда юзер даже не видит экран.
    // На resume — immediate refresh + перезапуск таймера.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        _stopTimer();
      case AppLifecycleState.resumed:
        if (_timer == null) {
          unawaited(_refresh());
          _startTimer();
        }
    }
  }

  List<String> _detourChain(String tag) => _intro.detourChain(tag);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAllowBypass() async {
    final v = await _vpn.getCurrentSessionAllowBypass();
    if (!mounted) return;
    if (v != _currentSessionAllowBypass) {
      setState(() => _currentSessionAllowBypass = v);
    }
  }

  Future<void> _refresh() async {
    // §069: piggyback на 3-сек polling — bypass warning виден без отдельного таймера.
    unawaited(_refreshAllowBypass());
    try {
      final data = await widget.clash.fetchConnections();
      final conns = (data['connections'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      _totalUp = (data['uploadTotal'] as num?)?.toInt() ?? 0;
      _totalDown = (data['downloadTotal'] as num?)?.toInt() ?? 0;
      _totalConns = conns.length;

      // Breakdown-агрегации (memory, byRule, byDnsMode, byApp) — парсим
      // тот же response'ом через TrafficSnapshot, чтобы не дублировать логику.
      final snap = TrafficSnapshot.fromConnectionsJson(data);
      _memory = snap.memory;
      _byRule = snap.byRule;
      _byApp = snap.byApp;

      final perChain = <String, OutboundGroup>{};
      for (final c in conns) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        final host = meta['host']?.toString() ?? meta['destinationIP']?.toString() ?? '?';
        final destPort = meta['destinationPort']?.toString() ?? '';
        final network = meta['network']?.toString() ?? '';
        final chains = (c['chains'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
        final chain = chains.isNotEmpty ? chains.first : 'direct';
        final rule = c['rule']?.toString() ?? '';
        final rulePayload = c['rulePayload']?.toString() ?? '';
        final up = (c['upload'] as num?)?.toInt() ?? 0;
        final down = (c['download'] as num?)?.toInt() ?? 0;
        final start = c['start']?.toString() ?? '';

        final process = meta['process']?.toString() ?? meta['processPath']?.toString() ?? '';

        final conn = Connection(
          host: host,
          destPort: destPort,
          network: network,
          chains: chains,
          rule: rule,
          rulePayload: rulePayload,
          upload: up,
          download: down,
          start: start,
          process: process,
        );

        final existing = perChain[chain];
        if (existing != null) {
          existing.upload += up;
          existing.download += down;
          existing.connections.add(conn);
        } else {
          perChain[chain] = OutboundGroup(
            name: chain,
            upload: up,
            download: down,
            connections: [conn],
          );
        }
      }

      if (mounted) {
        setState(() {
          _groups = perChain;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.index,
      child: Builder(
        builder: (innerCtx) => Scaffold(
          appBar: AppBar(
            title: const Text('Statistics'),
            actions: [
              // §069 — warning если bypass реально applied в текущей VPN-сессии
              // (runtime, не persisted). Видимо на всех 4 tabs.
              if (_currentSessionAllowBypass)
                Tooltip(
                  message:
                      'VPN bypass is active in this session.\n\n'
                      'Apps can use bindProcessToNetwork() to skip the tunnel '
                      '(banking apps, WhatsApp, system services). '
                      'Some traffic may not go through VPN.\n\n'
                      'Disable in VPN Settings → System → Allow VPN bypass '
                      'and reload VPN to enforce strict tunnel.',
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 12),
                  waitDuration: const Duration(milliseconds: 100),
                  preferBelow: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(
                      Icons.warning_amber,
                      size: 22,
                      color: Colors.amber.shade700,
                    ),
                  ),
                ),
            ],
            bottom: TabBar(
              // §048: 4 tab'а делят width поровну. «Connections» → «Conns»
              // чтобы влезли без horizontal scroll'а на 360dp экранах.
              tabs: [
                const Tab(icon: Icon(Icons.dashboard_outlined), text: 'Stats'),
                const Tab(icon: Icon(Icons.link), text: 'Conns'),
                Tab(
                  icon: const Icon(Icons.travel_explore),
                  child: AnimatedBuilder(
                    animation: TrafficProfiler.I,
                    builder: (_, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('App'),
                        if (TrafficProfiler.I.isRecording) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.bolt,
                            size: 14,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Tab(
                  icon: const Icon(Icons.podcasts),
                  child: AnimatedBuilder(
                    animation: TrafficProfiler.I,
                    builder: (_, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Live'),
                        if (TrafficProfiler.I.unattributedBannerActive) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.warning_amber,
                            size: 14,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              OverviewTab(
                loading: _loading,
                groups: _groups,
                totalUp: _totalUp,
                totalDown: _totalDown,
                totalConns: _totalConns,
                memory: _memory,
                byRule: _byRule,
                byApp: _byApp,
                detourChain: _detourChain,
              ),
              ConnectionsView(clash: widget.clash),
              PerAppTraceTab(clash: widget.clash),
              const LiveEventsTab(),
            ],
          ),
        ),
      ),
    );
  }
}
