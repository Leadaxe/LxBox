import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/import_rule.dart'; // §388 — ImportRuleAction для варнинга
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/ui_msg.dart';
import '../services/error_humanize.dart';
import '../services/node_hash.dart';
import '../services/parser/body_decoder.dart';
import '../services/probe/probe_controller.dart';
import '../services/probe/probe_runner.dart';
import '../services/settings_storage.dart';
import '../services/subscription/sources.dart';
import '../services/subscription/subscription_identity.dart'; // §289 — generateUuidV4
import '../widgets/detour_target_picker.dart';
import '../services/url_launcher.dart';
import 'probe_gate_mixin.dart';
import 'subscriptions_screen/entry_context_menu.dart' show showEditSourceDialog;
import 'subscription_detail_screen/detour_mode.dart';
import 'subscription_detail_screen/subscription_detail_format.dart';
import 'subscription_detail_screen/widgets/subscription_meta.dart';
import 'subscription_detail_screen/widgets/subscription_filters_tab.dart';
import 'subscription_detail_screen/widgets/subscription_node_list.dart';
import 'subscription_detail_screen/widgets/subscription_settings_tab.dart';
import 'subscription_detail_screen/widgets/subscription_source_tab.dart';
import '../services/l10n/locale_controller.dart';

class SubscriptionDetailScreen extends StatefulWidget {
  const SubscriptionDetailScreen({
    super.key,
    required this.entry,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  @override
  State<SubscriptionDetailScreen> createState() =>
      _SubscriptionDetailScreenState();
}

class _SubscriptionDetailScreenState extends State<SubscriptionDetailScreen>
    with SingleTickerProviderStateMixin, ProbeGateMixin {
  late final TabController _tabCtrl;
  List<NodeSpec>? _nodes;
  bool _loading = true;
  UiMsg? _error;
  bool _editing = false;
  late TextEditingController _nameCtrl;
  String _rawSource = '';
  Map<String, String> _rawHeaders = const {};
  bool _sourceLoaded = false;
  bool _sourceLoading = false;
  UiMsg? _sourceError;
  bool _showAllHeaders = false;

  /// §302 — Source-вкладка: показывать тело раскодированным из base64.
  /// Многие провайдеры отдают подписку одной base64-простынёй; в таком виде
  /// не видно ни строк-нод, ни того, с чем работают import-rules. Галка
  /// прогоняет тело тем же декодером, что и парсер (`decode`), — вид
  /// совпадает с тем, что видят правила.
  ///
  /// `null` = пользователь галку не трогал → действует дефолт «включено»
  /// (галка вообще показывается только когда тело закодировано, значит
  /// раскрытый вид — то, ради чего её показали). Явный выбор пользователя
  /// перекрывает дефолт и живёт до ухода с экрана.
  bool? _decodeSource;

  // §248 — каналы: секция Channels в detour-пикере + подпись «⚙ <label>»
  // канальной override-цели в Settings-вкладке.
  List<Channel> _channels = const [];

  /// §338 — глобальная галка перекрывает per-subscription «On update»: строку
  /// не рисуем. Читаем в `initState`: App Settings открываются с home, а не
  /// отсюда, поэтому попасть сюда с несвежим значением можно только заново
  /// зайдя на экран — и тогда `initState` отработает снова.
  bool _autoReloadOnChange = false;

  // §283 — per-node disable. Хеш ноды считается лениво и кэшируется по
  // identity. Полный проход хеширования происходит ТОЛЬКО когда есть
  // выключенные отметки — подписка без них не платит ничего.
  final Map<NodeSpec, String> _hashCache = Map.identity();
  Set<NodeSpec> _togglableNodes = Set.identity();
  Set<NodeSpec> _disabledNodes = Set.identity();

  // ─── §339 — Test servers (зеркало папки §236, минус per-list опции) ───
  // Результаты эфемерны; ключ = identity-хеш (§326: переживает refresh —
  // инстансы нод подменяются, идентичность нет).
  final Map<String, ProbeResult> _probe = {};
  Timer? _probeFlushTimer;
  bool _testing = false;
  ProbeRunner? _probeRunner;
  ProbeThresholds _probeThresholds = ProbeThresholds.defaults;

  // §326-кэш ключей текущего состава нод (identity-маркер списка).
  List<NodeSpec?>? _probeKeysFor;
  List<String> _probeKeysCache = const [];
  List<String> _nodeProbeKeys(List<NodeSpec?> nodes) {
    if (!identical(_probeKeysFor, nodes)) {
      _probeKeysFor = nodes;
      _probeKeysCache = ProbeController.probeKeysForNodes(nodes);
    }
    return _probeKeysCache;
  }

  // От какого List<NodeSpec> построены строки/кэш (identity-маркер):
  // refresh подменяет и список, и инстансы → кэш хешей протухает целиком;
  // toggle идёт через copyWith с тем же List → кэш живёт (не хешируем
  // 10k нод заново на каждый toggle).
  List<NodeSpec>? _hashedNodesList;

  String _hashOf(NodeSpec n) => _hashCache[n] ??= nodeIdentityHash(n);

  /// §283 (ревью) — строки, togglable- и disabled-set'ы пересобираются от
  /// ЖИВЫХ инстансов entry.list.nodes одним местом. Иначе refresh мимо
  /// _loadNodes (фоновый AutoUpdater, «Refresh now» из Settings-вкладки,
  /// смена источника) подменял инстансы, identity-set'ы расходились со
  /// строками — и все тогглы исчезали.
  void _rebuildRowsFromEntry() {
    final nodes = widget.entry.list.nodes;
    if (!identical(nodes, _hashedNodesList)) {
      _hashCache.clear();
      _hashedNodesList = nodes;
    }
    final expanded = <NodeSpec>[];
    for (final node in nodes) {
      expanded.add(node);
      if (node.chained != null) expanded.add(node.chained!);
    }
    _nodes = expanded;
    _togglableNodes = widget.entry.list is SubscriptionServers
        ? (Set<NodeSpec>.identity()..addAll(nodes))
        : Set<NodeSpec>.identity();
    _recomputeDisabled();
  }

  /// Derived-set выключенных нод от `disabledHashes` подписки. Дубли по
  /// хешу гаснут синхронно — состояние строки считается отсюда.
  void _recomputeDisabled() {
    final list = widget.entry.list;
    final next = Set<NodeSpec>.identity();
    if (list is SubscriptionServers && list.disabledHashes.isNotEmpty) {
      for (final n in list.nodes) {
        if (list.disabledHashes.containsKey(_hashOf(n))) {
          next.add(n);
          // chained-ребёнок рисуется отдельной строкой — глушим вместе с
          // родителем (он и не эмитится: родитель пропущен целиком).
          if (n.chained != null) next.add(n.chained!);
        }
      }
    }
    _disabledNodes = next;
  }

  void _onEntryChanged() {
    if (!mounted) return;
    setState(_rebuildRowsFromEntry);
  }

  Future<void> _toggleNode(NodeSpec node) async {
    // §219 — index по ссылке (список мог сместиться от reorder).
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller.toggleSubscriptionNode(idx, node);
    // Пересборку строк/set'ов делает listener entry (_onEntryChanged).
  }

  /// §332 — bulk вкл/выкл всех нод подписки (кнопка в SubscriptionMeta).
  Future<void> _toggleAllNodes(bool enable) async {
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller.setAllSubscriptionNodes(idx, enabled: enable);
  }

  /// Headers, которые нам реально нужны — подписочные метаданные.
  /// Остальное (server, date, cookies, content-length, ddos-guard, etc.) —
  /// под раскрывашкой.
  static const _importantHeaders = {
    'profile-title',
    'profile-update-interval',
    'profile-web-page-url',
    'support-url',
    'subscription-userinfo',
    'content-type',
  };

  @override
  void initState() {
    super.initState();
    // §302 — 4-я вкладка «Filters» (import-rules). Порядок Nodes/Settings/
    // Source/Filters сохраняет index Source=2 (слушатель ниже не меняется).
    _tabCtrl = TabController(length: 4, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.name);
    // §283 — entry.list может смениться мимо _loadNodes (см.
    // _rebuildRowsFromEntry); _replaceList нотифицирует entry.
    widget.entry.addListener(_onEntryChanged);
    unawaited(_loadNodes());
    unawaited(_loadChannels());
    unawaited(_loadProbeThresholds()); // §339
    unawaited(_loadAutoReloadOnChange()); // §338
    // При первом заходе на Source — живой GET.
    _tabCtrl.addListener(() {
      if (_tabCtrl.index == 2 && !_sourceLoaded && !_sourceLoading) {
        unawaited(_fetchSourceLive());
      }
    });
  }

  @override
  void dispose() {
    widget.entry.removeListener(_onEntryChanged); // §283
    _probeFlushTimer?.cancel(); // §339/§286
    _probeFlushTimer = null;
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────── §339 — Test servers ───────────────────────

  Future<void> _loadProbeThresholds() async {
    final t = await ProbeController.loadThresholds();
    if (mounted) setState(() => _probeThresholds = t);
  }

  /// §286 — коалесцированный ребилд результатов (как в папке): onResult пишет
  /// в [_probe], setState — не чаще раза в 120мс.
  void _scheduleProbeFlush() {
    if (_probeFlushTimer != null) return;
    _probeFlushTimer = Timer(const Duration(milliseconds: 120), () {
      _probeFlushTimer = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggleProbeTest() async {
    if (_testing) {
      _probeRunner?.cancel();
      _probeFlushTimer?.cancel();
      _probeFlushTimer = null;
      setState(() => _testing = false);
      return;
    }
    if (widget.entry.list.nodes.isEmpty) return;
    // §296-гейт: probe-сессия не поднимается поверх живого туннеля.
    if (await ensureVpnStoppedForProbe()) {
      await _runProbe();
    }
  }

  Future<void> _runProbe() async {
    // §296 — top-level ноды как есть; выключенные (§283) тестируются тоже
    // (probe отвечает «жив ли сервер», не «в конфиге ли он»), группы §322
    // получают вердикт group (§336). Ping-опции — глобальные: per-list
    // override'а у подписки нет.
    final nodes = ProbeController.probeNodesOf(widget.entry.list);
    if (nodes.isEmpty) return;
    final (:url, :timeoutMs) = await ProbeController.resolvePingOptions();
    if (!mounted) return;
    final probeKeys = _nodeProbeKeys(nodes);
    setState(() {
      _testing = true;
      _probe
        ..clear()
        ..addEntries([
          for (final k in probeKeys)
            MapEntry(k, const ProbeResult(ProbeStatus.pending)),
        ]);
    });
    final runner = ProbeRunner();
    _probeRunner = runner;
    final err = await runner.run(
      nodes,
      url: url,
      timeoutMs: timeoutMs,
      onResult: (i, r) {
        if (!mounted) return;
        if (i < probeKeys.length) _probe[probeKeys[i]] = r;
        _scheduleProbeFlush();
      },
    );
    _probeFlushTimer?.cancel();
    _probeFlushTimer = null;
    if (!mounted) return;
    setState(() => _testing = false);
    // §236-гонка — VPN стартовал между гейтом и probeStart: тот же попап.
    if (err == kProbeVpnRunning) {
      if (mounted && await onProbeVpnRaceGate()) await _runProbe();
      return;
    }
    if (err.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  /// Сводка завершённых тестов для контрол-бара (как в папке).
  ({int ok, int dead, int broken}) _probeSummary() {
    var ok = 0, dead = 0, broken = 0;
    for (final r in _probe.values) {
      switch (r.status) {
        case ProbeStatus.ok:
          ok++;
        case ProbeStatus.failed:
          dead++;
        case ProbeStatus.broken:
        case ProbeStatus.invalid:
          broken++;
        case ProbeStatus.pending:
        case ProbeStatus.group: // §336 — не тестируется, не считаем
          break;
      }
    }
    return (ok: ok, dead: dead, broken: broken);
  }

  /// §388 — проекция результатов на позиции top-level нод (граница
  /// «ключ → индекс», паттерн `_probeByIndex` папки §326): bulk-решения
  /// остаются чистыми index-хелперами `ProbeController`, их выход маппится
  /// обратно в `NodeSpec` через [_nodesAtIndexes] для мутатора контроллера.
  Map<int, ProbeResult> _probeByIndex() {
    final nodes = ProbeController.probeNodesOf(widget.entry.list);
    final keys = _nodeProbeKeys(nodes);
    return {
      for (var i = 0; i < keys.length; i++) i: ?_probe[keys[i]],
    };
  }

  List<NodeSpec> _nodesAtIndexes(Set<int> indexes) {
    final nodes = ProbeController.probeNodesOf(widget.entry.list);
    return [
      for (final i in indexes)
        if (i < nodes.length && nodes[i] != null) nodes[i]!,
    ];
  }

  /// §389 — есть хотя бы один ЗАВЕРШЁННЫЙ вердикт теста. Гейт пунктов меню
  /// «Test actions»: разблокируем, как только пришёл первый результат, не
  /// дожидаясь конца прогона (`pending`/`group` вердиктами не считаются —
  /// первый ещё не тестировался, второй не тестируется вовсе, §336).
  bool get _hasProbeVerdict =>
      _probe.values.any((r) => r.status != ProbeStatus.pending &&
          r.status != ProbeStatus.group);

  /// §388 — у подписки есть usable ENABLE-правило фильтров: следующий refresh
  /// снимет ручные отметки §283 (§332 — правило источник истины), поэтому
  /// bulk-действия предупреждают перед простановкой.
  bool get _hasEnableRules {
    final list = widget.entry.list;
    return list is SubscriptionServers &&
        list.activeImportRules
            .any((r) => r.action == ImportRuleAction.enable);
  }

  Future<void> _showProbeError(String err) async {
    if (err.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  /// §388 — выключить недоступные по последнему тесту (параллель
  /// `_disableUnreachable` папки §284; вместо позиционного мутатора — отметки
  /// §283). Без ENABLE-правил действие мгновенное, как в папке.
  Future<void> _disableUnreachable() async {
    final dead = ProbeController.unreachableIndexes(_probeByIndex());
    if (dead.isEmpty) {
      await _showProbeError(
          getLocalText.s("No unreachable or broken servers in last test"));
      return;
    }
    if (_hasEnableRules) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Disable unreachable")),
          content: Text([
            getLocalText.plural(
                "Disable %d servers that failed the test?", dead.length),
            getLocalText.s(
                "Enable rules in Filters will turn these nodes back on at the next update."),
          ].join('\n\n')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(getLocalText.s("Cancel"))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Disable")),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller
        .setSubscriptionNodesEnabled(idx, _nodesAtIndexes(dead), enabled: false);
    // Серые строки/каунтер перестроит listener entry (_onEntryChanged).
  }

  /// §388 — выключить медленнее порога (параллель `_disableSlowerThan` папки).
  Future<void> _disableSlowerThan() async {
    final ctl = TextEditingController(text: '${_probeThresholds.orangeMs}');
    final ms = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Disable slow servers")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Slower than, ms"),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_hasEnableRules) ...[
              const SizedBox(height: 12),
              Text(
                getLocalText.s(
                    "Enable rules in Filters will turn these nodes back on at the next update."),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())),
            child: Text(getLocalText.s("Disable")),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (ms == null || !mounted) return;
    final slow = ProbeController.slowerThan(_probeByIndex(), ms);
    if (slow.isEmpty) {
      await _showProbeError(
          getLocalText.s("No tested servers slower than %d ms", ms));
      return;
    }
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller
        .setSubscriptionNodesEnabled(idx, _nodesAtIndexes(slow), enabled: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(getLocalText.plural(
              "Disabled %1\$d servers > %2\$d ms", slow.length, ms))),
    );
  }

  /// §339 — identity-map «нода → результат» для строк списка. Ключи считаны
  /// от top-level нод (`probeNodesOf`); chained-дети в map не попадают.
  Map<NodeSpec, ProbeResult> _probeByNode() {
    if (_probe.isEmpty) return const {};
    final nodes = ProbeController.probeNodesOf(widget.entry.list);
    final keys = _nodeProbeKeys(nodes);
    return {
      for (var i = 0; i < keys.length; i++)
        if (nodes[i] != null && _probe[keys[i]] != null)
          nodes[i]!: _probe[keys[i]]!,
    };
  }

  /// §339 — полоса теста над списком (паттерн `_buildControlBar` папки):
  /// слева инфо, справа кнопка старт/отмена.
  Widget _buildProbeBar(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final s = _probeSummary();
    final String info;
    if (_testing) {
      info = getLocalText.s("Testing… %d done", s.ok + s.dead);
    } else if (_probe.isNotEmpty) {
      info = [
        getLocalText.s("%d ok", s.ok),
        getLocalText.plural("%d err", s.dead),
        if (s.broken > 0) getLocalText.plural("%d broken", s.broken),
      ].join(' · ');
    } else {
      info = getLocalText.s("Test servers");
    }
    final hasNodes = widget.entry.list.nodes.isNotEmpty;
    // §391 — bulk вкл/выкл всех нод: только подписки с загруженными узлами
    // (у UserServer тогглов нет, без узлов выключать нечего).
    final canToggleAll =
        widget.entry.list is SubscriptionServers && hasNodes;
    // §391 — ВСЕ ноды выключены = переключатель выключен. Раньше иконка
    // выбиралась по будущему действию (`offCount > 0 ? toggle_on : …`) и
    // читалась как состояние — получалась противофаза с тогглами строк:
    // все ноды включены → серый «выключено».
    final allOff = hasNodes && _disabledNodes.length >= _togglableNodes.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Row(
        children: [
          // §391 — переехал сюда из мета-блока (решение юзера): рядом с
          // «Test servers», в одной строке с прочими действиями над списком.
          // Компактный (как прежняя иконка 18px, а не полноразмерный тоггл
          // строки): `Transform.scale` вместо кастомного виджета — Switch
          // остаётся настоящим (фаза, семантика, accessibility целы), сжат
          // только рендер. `shrinkWrap`-таргет убирает 48dp-паддинг Material.
          if (canToggleAll)
            SizedBox(
              width: 40,
              child: Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: !allOff,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => unawaited(_toggleAllNodes(v)),
                ),
              ),
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(info, style: TextStyle(fontSize: 12, color: muted)),
          ),
          GestureDetector(
            onTap: hasNodes ? () => unawaited(_toggleProbeTest()) : null,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                _testing ? Icons.stop_circle_outlined : Icons.speed,
                size: 22,
                color: hasNodes ? null : theme.disabledColor,
              ),
            ),
          ),
          // §388 — bulk-действия по результатам теста (паритет с меню папки;
          // Delete/Sort не переносятся — см. spec).
          // §389 — кнопка на месте ВСЕГДА; без завершённого теста пункты серые
          // и некликабельные (то же и в `_buildControlBar` папки).
          PopupMenuButton<String>(
            tooltip: getLocalText.s("Test actions"),
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'disable_slow') unawaited(_disableSlowerThan());
              if (v == 'disable_dead') unawaited(_disableUnreachable());
            },
            itemBuilder: (menuCtx) {
              final ready = _hasProbeVerdict;
              return [
                PopupMenuItem(
                    value: 'disable_slow',
                    enabled: ready,
                    child: Text(getLocalText.s("Disable slower than…"))),
                PopupMenuItem(
                    value: 'disable_dead',
                    enabled: ready,
                    child: Text(getLocalText.s("Disable unreachable"))),
              ];
            },
          ),
        ],
      ),
    );
  }

  List<MapEntry<String, String>> _filteredHeaders({required bool important}) {
    final entries = _rawHeaders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries
        .where((e) => _importantHeaders.contains(e.key.toLowerCase()) == important)
        .toList();
  }

  Future<void> _fetchSourceLive() async {
    if (widget.entry.url.isEmpty) return;
    setState(() {
      _sourceLoading = true;
      _sourceError = null;
    });
    try {
      // §289 — сырой ответ отражает реальную идентичность фетча (per-sub/глоб.).
      final r = await fetchRaw(
          UrlSource(widget.entry.url, identity: widget.entry.identity));
      if (!mounted) return;
      setState(() {
        _rawSource = r.body;
        _rawHeaders = r.headers;
        _sourceLoaded = true;
        _sourceLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourceError = humanizeError(e);
        _sourceLoading = false;
      });
    }
  }

  Future<void> _loadNodes({bool cacheOnly = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!cacheOnly) {
        // §219 — index по ссылке (список мог сместиться от reorder).
        final idx = widget.controller.entries.indexOf(widget.entry);
        if (idx >= 0) await widget.controller.updateAt(idx);
      }
      // v2: узлы уже распарсены в entry.list.nodes. Детоур-узлы показываем
      // отдельной строкой под родителем.
      _rebuildRowsFromEntry(); // §283 — строки + togglable/disabled set'ы
      // Source-вкладка теперь подтягивается живым GET при переключении туда.
      // Для UserServer (connections) показываем сразу что есть.
      if (widget.entry.connections.isNotEmpty) {
        _rawSource = widget.entry.connections.join('\n');
        _sourceLoaded = true;
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _error = humanizeError(e); _loading = false; });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Delete subscription?")),
        content: Text(getLocalText.s("Remove \"%s\"?", widget.entry.displayName)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(getLocalText.s("Cancel"))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(getLocalText.s("Delete")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // §219 — index по ссылке: список мог переупорядочиться (drag-reorder) пока
    // открыт экран → removeAt снёс бы не ту подписку.
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) {
      if (mounted) Navigator.pop(context);
      return;
    }
    await widget.controller.removeAt(idx);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Copied: %s", url))),
      );
    }
  }

  void _toggleEdit() {
    if (_editing) {
      // Save
      final name = _nameCtrl.text.trim();
      // §219 — index по ссылке (список мог сместиться от reorder).
      final idx = widget.controller.entries.indexOf(widget.entry);
      if (idx >= 0) unawaited(widget.controller.renameAt(idx, name));
    }
    setState(() => _editing = !_editing);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _editing
            ? TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: theme.textTheme.titleLarge,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: getLocalText.s("Display name"),
                ),
                onSubmitted: (_) => _toggleEdit(),
              )
            : Text(
                entry.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: [
          IconButton(
            tooltip: _editing ? getLocalText.s("Save") : getLocalText.s("Rename"),
            icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
            onPressed: _toggleEdit,
          ),
          IconButton(
            tooltip: getLocalText.s("Refresh"),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _loadNodes(cacheOnly: false),
          ),
          IconButton(
            tooltip: getLocalText.s("Delete"),
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          tabs: [
            Tab(text: getLocalText.s("Nodes")),
            Tab(text: getLocalText.s("Settings")),
            Tab(text: getLocalText.s("Source")),
            Tab(text: getLocalText.s("Filters")),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          // Tab 1: Nodes
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading) const LinearProgressIndicator(),
              SubscriptionMeta(
                entry: entry,
                onOpenUrl: _openUrl,
                offCount: _disabledNodes.length, // §283
              ),
              _buildProbeBar(theme), // §339 — Test servers
              const Divider(height: 1),
              Expanded(
                child: SubscriptionNodeList(
                  nodes: _nodes,
                  loading: _loading,
                  error: _error,
                  // §283 — toggle только у top-level нод подписки; chained-
                  // дети управляются родителем, UserServer — без тогглов.
                  // Set'ы — поля, пересобираемые _rebuildRowsFromEntry
                  // синхронно со строками (одни инстансы — нет рассинхрона).
                  togglableNodes: _togglableNodes,
                  disabledNodes: _disabledNodes,
                  onToggleNode:
                      entry.list is SubscriptionServers ? _toggleNode : null,
                  probe: _probeByNode(), // §339
                  probeThresholds: _probeThresholds,
                  // §392 — экран разбора адресует узел display-тегом, когда
                  // диагностика идёт через боевое ядро.
                  tagPrefix: entry.tagPrefix,
                ),
              ),
            ],
          ),
          // Tab 2: Settings
          _buildSettingsTab(theme),
          // Tab 3: Source
          _buildSourceTab(theme),
          // Tab 4: Filters (§302 — import-rules)
          SubscriptionFiltersTab(
            entry: widget.entry,
            controller: widget.controller,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    final hasDetour = (_nodes ?? const []).any((n) => n.chained != null);
    return SubscriptionSettingsTab(
      entry: widget.entry,
      channels: _channels, // §248 — подпись канальной override-цели
      // §252 — разворот цели в цепочку «как пакет пойдёт» для превью.
      detourPathHopsOf: (stored) => detourPathHops(stored,
          controller: widget.controller, channels: _channels),
      hasDetour: hasDetour,
      detourMode: _detourMode,
      onTagPrefixChanged: (val) {
        widget.entry.tagPrefix = val.trim();
        unawaited(widget.controller.persistSources());
      },
      onSetDetourMode: _setDetourMode,
      onRegisterDetourServersChanged: (val) {
        setState(() => widget.entry.registerDetourServers = val);
        unawaited(widget.controller.persistSources());
      },
      onRegisterDetourInAutoChanged: (val) {
        setState(() => widget.entry.registerDetourInAuto = val);
        unawaited(widget.controller.persistSources());
      },
      onShowOverrideDetourPicker: () => _showOverrideDetourPicker(),
      onReplaceDetourChainChanged: (val) {
        setState(() => widget.entry.replaceDetourChain = val);
        unawaited(widget.controller.persistSources());
      },
      onCopyUrl: () async {
        final list = widget.entry.list as SubscriptionServers;
        await Clipboard.setData(ClipboardData(text: list.url));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(getLocalText.s("URL copied")),
              duration: const Duration(seconds: 1)),
        );
      },
      onShowIntervalPicker: _showIntervalPicker,
      onShowOnUpdateActionPicker: _showOnUpdateActionPicker, // §323
      autoReloadOnChange: _autoReloadOnChange, // §338 — перекрытие выбора
      onRefreshNow: _refreshNow,
      onEditSource: _editSource, // §129
      // §289 — per-subscription fetch identity (Default/Custom override).
      onToggleCustomIdentity: (on) {
        setState(() {
          if (on) {
            widget.entry.enableCustomIdentity();
          } else {
            widget.entry.disableCustomIdentity();
          }
        });
        unawaited(widget.controller.persistSources());
      },
      onEditIdentityUserAgent: () => unawaited(_editIdentityUserAgent()),
      onIdentitySendHwidChanged: (v) {
        final id = widget.entry.identity;
        if (id == null) return;
        // §289 — как глобальный _setSendHwid: при первом включении с пустым
        // HWID лениво генерим UUIDv4 (иначе x-hwid не положится — гейт по
        // непустому hwid), device-meta берём как есть из слепка.
        final next = v && id.hwid.isEmpty
            ? id.copyWith(sendHwid: v, hwid: generateUuidV4())
            : id.copyWith(sendHwid: v);
        setState(() => widget.entry.updateIdentity(next));
        unawaited(widget.controller.persistSources());
      },
      onEditIdentityHwid: () => unawaited(_editIdentityField(
            title: 'HWID',
            initial: widget.entry.identity?.hwid ?? '',
            monospace: true,
            apply: (id, v) => id.copyWith(hwid: v.trim()),
          )),
      onRegenerateIdentityHwid: () {
        final id = widget.entry.identity;
        if (id == null) return;
        setState(() =>
            widget.entry.updateIdentity(id.copyWith(hwid: generateUuidV4())));
        unawaited(widget.controller.persistSources());
      },
      onEditIdentityDeviceOs: () => unawaited(_editIdentityField(
            title: 'x-device-os',
            initial: widget.entry.identity?.deviceOs ?? '',
            apply: (id, v) => id.copyWith(deviceOs: v.trim()),
          )),
      onEditIdentityVerOs: () => unawaited(_editIdentityField(
            title: 'x-ver-os',
            initial: widget.entry.identity?.verOs ?? '',
            apply: (id, v) => id.copyWith(verOs: v.trim()),
          )),
      onEditIdentityDeviceModel: () => unawaited(_editIdentityField(
            title: 'x-device-model',
            initial: widget.entry.identity?.deviceModel ?? '',
            apply: (id, v) => id.copyWith(deviceModel: v.trim()),
          )),
    );
  }

  /// §289 — правка UA слепка: пусто = дефолт (брендированный UA), поэтому trim
  /// без hint-подстановки; общий диалог с [_editIdentityField].
  Future<void> _editIdentityUserAgent() => _editIdentityField(
        // §292 — человекочитаемый заголовок диалога (в отличие от HWID/
        // x-device-* — те буквальные имена заголовков, перевод бессмыслен).
        title: getLocalText.s('Custom User-Agent'),
        initial: widget.entry.identity?.userAgent ?? '',
        apply: (id, v) => id.copyWith(userAgent: v.trim()),
      );

  /// §289 — общий edit-диалог одного поля слепка идентичности (зеркало
  /// глобального `_editIdentityText`). Открывает однострочный ввод, применяет
  /// [apply] к текущему слепку и персистит. No-op если Custom не активен.
  Future<void> _editIdentityField({
    required String title,
    required String initial,
    required SubscriptionIdentityOverride Function(
            SubscriptionIdentityOverride id, String value)
        apply,
    bool monospace = false,
  }) async {
    final ctl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: null,
          style: monospace
              ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
              : null,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(getLocalText.s("Save")),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (result == null || !mounted) return;
    final id = widget.entry.identity;
    if (id == null) return;
    setState(() => widget.entry.updateIdentity(apply(id, result)));
    await widget.controller.persistSources();
  }

  /// §129 — сменить источник подписки (online↔file). Переиспользует общий
  /// диалог; index берём по ссылке (мог сместиться от reorder/delete).
  Future<void> _editSource() async {
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await showEditSourceDialog(context, idx, widget.entry, widget.controller);
    if (mounted) setState(() {}); // подхватить смену url/имени
  }

  Future<void> _showIntervalPicker() async {
    final list = widget.entry.list as SubscriptionServers;
    // §129 — -1 = «Don't auto-update» (никогда, игнор серверного интервала);
    //          0 = «Never (respect server)» (сами нет, но сервер может задать).
    final presets = <int>[-1, 0, 1, 3, 6, 12, 24, 48, 72, 168];
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(getLocalText.s("Update interval")),
        children: [
          for (final h in presets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Row(
                children: [
                  if (h == list.updateIntervalHours)
                    const Icon(Icons.check, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(switch (h) {
                    < 0 => getLocalText.s("Don't auto-update"),
                    0 => getLocalText.s("Never (respect server)"),
                    _ => getLocalText.s("%1\$dh (%2\$s)", h, intervalHuman(h)),
                  }),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.updateIntervalHours = chosen;
    });
    await widget.controller.persistSources();
  }

  /// §323 — что делать после успешного АВТО-обновления этой подписки.
  /// Ручной ⟳ («Refresh now») режимом не управляется: там юзер на экране,
  /// видит плашку и применяет сам.
  Future<void> _showOnUpdateActionPicker() async {
    final list = widget.entry.list as SubscriptionServers;
    final chosen = await showDialog<SubscriptionOnUpdateAction>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(getLocalText.s("On update")),
        children: [
          for (final a in SubscriptionOnUpdateAction.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, a),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (a == list.onUpdateAction)
                    const Icon(Icons.check, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(switch (a) {
                          SubscriptionOnUpdateAction.rebuild =>
                            getLocalText.s("Rebuild config"),
                          SubscriptionOnUpdateAction.reload =>
                            getLocalText.s("Rebuild and reload core"),
                          SubscriptionOnUpdateAction.none =>
                            getLocalText.s("Do nothing"),
                        }),
                        Text(
                          switch (a) {
                            SubscriptionOnUpdateAction.rebuild => getLocalText.s(
                                "New nodes go into the config; apply the change yourself"),
                            SubscriptionOnUpdateAction.reload => getLocalText.s(
                                "New nodes apply at once; the connection drops for a few seconds"),
                            SubscriptionOnUpdateAction.none => getLocalText.s(
                                "Nodes update in the list only; the config waits for the next rebuild"),
                          },
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.onUpdateAction = chosen;
    });
    await widget.controller.persistSources();
  }

  Future<void> _refreshNow() async {
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    await widget.controller.updateAt(idx);
    if (!mounted) return;
    setState(() {});
  }

  /// §248 — загрузка каналов (initState + refresh перед пикером).
  Future<void> _loadChannels() async {
    final channels = await SettingsStorage.getChannels();
    if (!mounted) return;
    setState(() => _channels = channels);
  }

  /// §338 — галка «автоперезапуск при смене настроек» (App Settings). Включена
  /// → строка «On update» скрыта: выбор перекрыт глобально.
  Future<void> _loadAutoReloadOnChange() async {
    final v = await SettingsStorage.getAutoReloadOnChange();
    if (!mounted || v == _autoReloadOnChange) return;
    setState(() => _autoReloadOnChange = v);
  }

  Future<void> _showOverrideDetourPicker() async {
    // §239 — единый пикер; для подписки кандидаты = только «свободные»
    // одиночки (члены папок живут под политикой своей папки — чужим нельзя).
    // §248 — свежие каналы (могли измениться, пока экран открыт).
    await _loadChannels();
    if (!mounted) return;
    final chosen = await showDetourTargetPicker(
      context,
      controller: widget.controller,
      channels: _channels,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.overrideDetour = chosen.storeValue;
      // §111: leftover useDetourServers=false (mode был None) молча гасит
      // override в builder'е. Для полного UI идемпотентно.
      if (chosen.storeValue.isNotEmpty) widget.entry.useDetourServers = true;
    });
    unawaited(widget.controller.persistSources());
  }

  /// §302 — тело, раскрытое из base64 (тот же путь, что у парсера: `decode`).
  /// `UriLines` склеиваем обратно построчно — это ровно тот список строк, по
  /// которому работают import-rules. INI/Amnezia/JSON отдаём как текст. Если
  /// декодировать нечего (тело и так plain) — вернём его без изменений, а
  /// галку в UI покажем неактивной через [_sourceIsBase64].
  String get _decodedSource {
    if (_rawSource.isEmpty) return '';
    final d = decode(_rawSource);
    return switch (d) {
      UriLines(lines: final l) => l.join('\n'),
      IniConfig(text: final t) => t,
      AmneziaConfig(iniTexts: final ts) => ts.join('\n\n'),
      JsonConfig() => _rawSource,
      DecodeFailure() => _rawSource,
    };
  }

  /// Тело реально закодировано (raw ≠ decoded) — только тогда галка имеет
  /// смысл. Для plain-подписок она неактивна: раскрывать нечего.
  bool get _sourceIsBase64 =>
      _rawSource.isNotEmpty && _decodedSource.trim() != _rawSource.trim();

  Widget _buildSourceTab(ThemeData theme) {
    final entry = widget.entry;
    final decodable = _sourceIsBase64;
    // Дефолт — раскрытый вид: галка показывается только когда есть что
    // раскрывать, так что показ ⇒ включено. Явный выбор юзера важнее.
    final showDecoded = decodable && (_decodeSource ?? true);
    return SubscriptionSourceTab(
      hasUrl: entry.url.isNotEmpty,
      sourceLoading: _sourceLoading,
      sourceError: _sourceError,
      rawHeaders: _rawHeaders,
      rawSource: showDecoded ? _decodedSource : _rawSource,
      showAllHeaders: _showAllHeaders,
      importantHeaders: _filteredHeaders(important: true),
      moreHeaders: _filteredHeaders(important: false),
      onRefetch: () => unawaited(_fetchSourceLive()),
      onToggleShowAll: () =>
          setState(() => _showAllHeaders = !_showAllHeaders),
      canDecode: decodable,
      decoded: showDecoded,
      onToggleDecode: (v) => setState(() => _decodeSource = v),
    );
  }

  // ─── Detour mode (тернарный radio over {useDetourServers, overrideDetour})
  // Mapping см. в comment у RadioListTile блока в _buildSettingsTab.

  DetourMode get _detourMode {
    if (!widget.entry.useDetourServers) return DetourMode.none;
    if (widget.entry.overrideDetour.isNotEmpty) return DetourMode.override;
    return DetourMode.use;
  }

  void _setDetourMode(DetourMode mode) {
    setState(() {
      switch (mode) {
        case DetourMode.use:
          widget.entry.useDetourServers = true;
          widget.entry.overrideDetour = '';
        case DetourMode.override:
          widget.entry.useDetourServers = true;
          // overrideDetour сохраняем — может уже выбран ранее. Если пусто —
          // открываем picker сразу (юзер хочет Override, надо его сконфигурить).
          if (widget.entry.overrideDetour.isEmpty) {
            unawaited(_showOverrideDetourPicker());
          }
        case DetourMode.none:
          widget.entry.useDetourServers = false;
          widget.entry.overrideDetour = '';
      }
    });
    unawaited(widget.controller.persistSources());
  }
}
