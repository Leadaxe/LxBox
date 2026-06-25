import 'dart:async';

import 'package:flutter/material.dart';

import '../models/config_node.dart';
import '../services/traffic_profiler.dart';
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import 'connections_screen.dart';
import 'live_events_tab.dart';
import 'per_app_trace_tab.dart';
import 'stats_screen/overview_models.dart';
import 'stats_screen/overview_tab.dart';

/// §044/§048: enum для start-tab выбора в StatsScreen. Передаётся при
/// `Navigator.push(StatsScreen(initialTab: StatsTab.perApp))`.
enum StatsTab { overview, connections, perApp, live }

/// §122 — Statistics-экран на libbox `CommandClient` (push-стримы), а не
/// Clash HTTP-pull. `CcChannel.instance` даёт status/connections-стримы;
/// `connectScreen()`/`disconnectScreen()` управляют screen-клиентом ядра.
class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    this.configRaw = '',
    this.initialTab = StatsTab.overview,
  });

  final String configRaw;
  final StatsTab initialTab;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  Map<String, OutboundGroup> _groups = {};
  int _totalUp = 0;
  int _totalDown = 0;
  int _totalConns = 0;
  int _memory = 0;
  Map<String, int> _byRule = const {};
  bool _loading = true;

  // §166 — троттл тяжёлого пересчёта connections (byRule/perRule + ruleName в
  // цикле + setState всего дерева). Снапшоты идут на FAST 0.1с = 10/сек → без
  // троттла Stats ВИСЛА (10 полных пересборок/ребилдов в секунду на N conns).
  // 700мс — плавно глазу, но не захлёбывается.
  static const _connRecalc = Duration(milliseconds: 700);
  DateTime? _connRecalcAt;

  final _cc = CcChannel.instance;
  StreamSubscription<CcStatus>? _statusSub;
  StreamSubscription<List<CcConnection>>? _connSub;

  // §091 — структурные запросы к конфигу через ParsedConfig.
  late final ParsedConfig _intro = ParsedConfig.parse(widget.configRaw);

  /// §069 — runtime applied значение `allowBypass()` от последнего
  /// `establish()`. Показывается warning icon в AppBar если true.
  bool _currentSessionAllowBypass = false;
  final _vpn = BoxVpnClient();

  @override
  void initState() {
    super.initState();
    // §122 ПОРЯДОК: сперва подписки (ставят native sink через EventChannel
    // .onListen), ПОТОМ connectScreen() — иначе разовый снапшот может уйти до
    // установки sink. См. home_controller._startCcStreams.
    _statusSub = _cc.status.listen(_onStatus);
    _connSub = _cc.connections.listen(_onConnections);
    // §2.8 — поднимаем screen-клиент ядра на время видимости экрана.
    unawaited(_cc.connectScreen());
    // §164 — Stats открыт → статистика на FAST 0.1с (плавные счётчики).
    // dispose вернёт NORMAL 0.5с (главному экрану 0.1с не нужна).
    unawaited(_cc.setStatusFast(true));
    unawaited(_refreshAllowBypass());
  }

  List<String> _detourChain(String tag) => _intro.detourChain(tag);

  @override
  void dispose() {
    _statusSub?.cancel();
    _connSub?.cancel();
    unawaited(_cc.disconnectScreen());
    // §164 — Stats закрыт → возвращаем status-стрим на NORMAL 0.5с.
    unawaited(_cc.setStatusFast(false));
    super.dispose();
  }

  void _onStatus(CcStatus s) {
    if (!mounted) return;
    // §164 — память обновляем КАЖДЫЙ тик (как totals). Троттл 3с убран — пусть
    // идёт с частотой стрима (FAST 0.1с на Stats), чтобы частота тика была видна
    // визуально (память мельтешит от GC — это и есть индикатор живого стрима).
    setState(() {
      _totalUp = s.uplinkTotal;
      _totalDown = s.downlinkTotal;
      _memory = s.memory;
    });
  }

  void _onConnections(List<CcConnection> conns) {
    // §166/§170 — троттл: тяжёлый пересчёт не чаще _connRecalc. Окно мерим от
    // КОНЦА отработанного пересчёта (метка ставится после setState), НЕ от
    // старта — иначе на медленном железе, где сам пересчёт длится дольше
    // _connRecalc, следующий тик видел бы «окно истекло» сразу и наслаивал
    // пересчёты, не разгребая очередь. Первый снапшот (_loading) — сразу.
    final now = DateTime.now();
    if (!_loading &&
        _connRecalcAt != null &&
        now.difference(_connRecalcAt!) < _connRecalc) {
      return;
    }

    // §069 — bypass warning обновляем на каждом снапшоте (без отдельного таймера).
    unawaited(_refreshAllowBypass());

    _totalConns = conns.length;

    final byRule = <String, int>{};
    final perRule = <String, OutboundGroup>{};
    for (final c in conns) {
      // §165 — имя правила через резолвер (справочник из custom_rules + кэш).
      // Пустой/ненайденный rule → 'final' (резолвер сам). Кэш снимает фриз.
      final rule = ruleName(c.rule);
      byRule[rule] = (byRule[rule] ?? 0) + 1;

      // destination = "host:port" — порт = часть после последнего ':'.
      // host: domain (если есть), иначе host-часть destination (IP-соединения
      // без resolved-домена приходят с пустым domain).
      final destPort = _portOf(c.destination);
      final host = c.domain.isNotEmpty ? c.domain : _hostOf(c.destination);

      final conn = Connection(
        host: host,
        destPort: destPort,
        network: c.network,
        rule: c.rule,
        upload: c.uplink,
        download: c.downlink,
        start: c.createdAt,
      );

      final existing = perRule[rule];
      if (existing != null) {
        existing.upload += c.uplink;
        existing.download += c.downlink;
        existing.connections.add(conn);
      } else {
        perRule[rule] = OutboundGroup(
          name: rule,
          upload: c.uplink,
          download: c.downlink,
          connections: [conn],
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _byRule = byRule;
      _groups = perRule;
      _loading = false;
    });
    // §170 — метка ставится ПОСЛЕ пересчёта: следующее окно _connRecalc
    // отсчитывается от конца этой работы, а не от старта.
    _connRecalcAt = DateTime.now();
  }

  /// Порт из "host:port" — часть после последнего ':' (IPv6-safe: берём хвост).
  static String _portOf(String destination) {
    final i = destination.lastIndexOf(':');
    if (i < 0 || i == destination.length - 1) return '';
    return destination.substring(i + 1);
  }

  /// Host из "host:port" — часть до последнего ':'. Если ':' нет — вся строка.
  static String _hostOf(String destination) {
    final i = destination.lastIndexOf(':');
    return i < 0 ? destination : destination.substring(0, i);
  }

  Future<void> _refreshAllowBypass() async {
    final v = await _vpn.getCurrentSessionAllowBypass();
    if (!mounted) return;
    if (v != _currentSessionAllowBypass) {
      setState(() => _currentSessionAllowBypass = v);
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
                detourChain: _detourChain,
              ),
              const ConnectionsView(),
              const PerAppTraceTab(),
              const LiveEventsTab(),
            ],
          ),
        ),
      ),
    );
  }
}
