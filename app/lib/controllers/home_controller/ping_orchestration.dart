part of '../home_controller.dart';

/// Ping / URLTest оркестрация (§040 resolve-chain, §070 cache-gen,
/// §078 explicit order). Вынесено `part`'ом из `home_controller.dart` — та же
/// библиотека и тот же `HomeController`, поведение (concurrency, epoch-cancel,
/// _emit timing, per-group url/timeout snapshot) идентично. Общие с контроллером
/// поля/хелперы объявлены абстрактно; реализацию даёт `HomeController`.
mixin _PingMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController / другими частями ---
  HomeState get _state;
  ClashApiClient? get _clash;
  Timer? get _autoPingTimer;
  set _autoPingTimer(Timer? value);
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);
  Future<void> reloadProxies();

  /// Single-node URLTest через clash `/proxies/<tag>/delay`. Симметричен
  /// `runGroupUrltest(groupTag)` для group'ы. Использует per-group resolved
  /// url/timeout (§040) — контекст ноды = `state.selectedGroup`.
  Future<void> runNodeUrltest(String nodeTag) async {
    final clash = _clash;
    if (clash == null) return;
    final pingBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '…';
    _emit(_state.copyWith(pingBusy: pingBusy));
    final group = _state.selectedGroup;
    final url = pingUrlFor(group);
    final timeoutMs = pingTimeoutFor(group);
    try {
      final ms = await clash.delay(nodeTag, timeoutMs: timeoutMs, url: url);
      final nextDelay = Map<String, int>.from(_state.lastDelay)..[nodeTag] = ms;
      final nextBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '';
      _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
      _addDebug(DebugSource.app, 'URLTest $nodeTag → $url: ${ms}ms');
    } catch (e) {
      final nextDelay = Map<String, int>.from(_state.lastDelay)..[nodeTag] = -1;
      final nextBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '';
      final msg = _formatProbeError(nodeTag, url, e);
      _emit(_state.copyWith(
          lastDelay: nextDelay, pingBusy: nextBusy, lastError: msg));
      _addDebug(DebugSource.app, msg);
    }
  }

  /// Человекочитаемое сообщение для UI banner / debug log на ошибку
  /// ping/URLTest операции. Формат: `<target> → <host> — <reason>`.
  /// Reason формируется через [formatUserError] — общий §041 helper.
  ///
  ///   "direct-out → ya.ru — timeout 5.8s"
  ///   "vpn-2 → ya.ru — HTTP 503"
  ///   "direct-out → ya.ru — connection refused"
  static String _formatProbeError(String target, String url, Object e) {
    return '${_routeLabel(target, url)} — ${formatUserError(e)}';
  }

  /// `direct-out → ya.ru` если URL валиден, иначе только `direct-out`.
  static String _routeLabel(String target, String url) {
    if (url.isEmpty) return target;
    try {
      final host = Uri.parse(url).host;
      if (host.isNotEmpty) return '$target → $host';
    } catch (_) {}
    return target;
  }

  bool _massPingRunning = false;
  bool get massPingRunning => _massPingRunning;
  int _massPingEpoch = 0;

  // §040: ping/test settings now persisted в SettingsStorage `ping_options`.
  // Resolve chain: per-group override → global storage → template default.
  // _templatePing* кешируются на старте через [reloadPingOptions].
  Map<String, dynamic> _pingOptions = const {};
  String _templatePingUrl = '';
  int _templatePingTimeoutMs = 10000;

  /// Глобальный URL (storage > template fallback). Backward-compat getter —
  /// не setter'ом, мутации только через [SettingsStorage.setGlobalPingUrl] +
  /// [reloadPingOptions].
  String get pingUrl {
    final saved = _pingOptions['url'];
    if (saved is String && saved.isNotEmpty) return saved;
    return _templatePingUrl;
  }

  /// Глобальный timeout ms (storage > template fallback).
  int get pingTimeout {
    final saved = _pingOptions['timeout_ms'];
    if (saved is num && saved > 0) return saved.toInt();
    return _templatePingTimeoutMs;
  }

  /// Resolved URL для конкретной группы: override этой группы > global > template.
  /// `groupTag` пустой/null → equivalent to global [pingUrl].
  String pingUrlFor(String? groupTag) {
    if (groupTag != null && groupTag.isNotEmpty) {
      final groups = _pingOptions['groups'];
      if (groups is Map<String, dynamic>) {
        final override = groups[groupTag];
        if (override is Map<String, dynamic>) {
          final url = override['url'];
          if (url is String && url.isNotEmpty) return url;
        }
      }
    }
    return pingUrl;
  }

  /// Resolved timeout (ms) для группы. См. [pingUrlFor].
  int pingTimeoutFor(String? groupTag) {
    if (groupTag != null && groupTag.isNotEmpty) {
      final groups = _pingOptions['groups'];
      if (groups is Map<String, dynamic>) {
        final override = groups[groupTag];
        if (override is Map<String, dynamic>) {
          final t = override['timeout_ms'];
          if (t is num && t > 0) return t.toInt();
        }
      }
    }
    return pingTimeout;
  }

  /// Перечитывает `ping_options` из SettingsStorage + template defaults.
  /// Зовётся из [init] и из UI dialog'а после save (а также из Debug API
  /// после CRUD). Не уведомляет listeners — values используются on-demand.
  Future<void> reloadPingOptions() async {
    try {
      final tpl = await TemplateLoader.load();
      final tplOpts = tpl.pingOptions;
      final tplUrl = tplOpts['url'];
      final tplTimeout = tplOpts['timeout_ms'];
      _templatePingUrl = (tplUrl is String) ? tplUrl : '';
      _templatePingTimeoutMs =
          (tplTimeout is num && tplTimeout > 0) ? tplTimeout.toInt() : 10000;
    } catch (e) {
      _addDebug(DebugSource.app, 'Template load (ping options): $e');
    }
    _pingOptions = await SettingsStorage.getPingOptions();
  }

  static const _pingConcurrency = 10;

  /// Запланировать автопинг через 5 сек после connect, если включено в
  /// App Settings (`auto_ping_on_start`, default true). Пингуем только
  /// активную группу (`runMassUrltest` использует `_state.nodes` — ноды
  /// выбранного selector'а). Отменяется при disconnect.
  static const _autoPingDelay = Duration(seconds: 5);
  Future<void> _scheduleAutoPing() async {
    _autoPingTimer?.cancel();
    final enabled =
        await SettingsStorage.getVar('auto_ping_on_start', 'true');
    if (enabled != 'true') return;
    _autoPingTimer = Timer(_autoPingDelay, () {
      if (!_state.tunnelUp || _state.nodes.isEmpty) return;
      unawaited(runMassUrltest());
    });
  }

  /// Форсит sing-box URLTest на группе (`/group/<tag>/delay`) с per-group
  /// resolved url/timeout (§040). После теста sing-box обновит `now` у
  /// URLTest-группы; мы пулим свежий proxies чтобы UI увидел выбор.
  Future<void> runGroupUrltest(String groupTag) async {
    final clash = _clash;
    if (clash == null || !_state.tunnelUp) return;
    final url = pingUrlFor(groupTag);
    try {
      await clash.groupDelay(groupTag,
          timeoutMs: pingTimeoutFor(groupTag), url: url);
      _addDebug(DebugSource.app, 'Group URLTest done: $groupTag → $url');
      await reloadProxies();
      // §070: bump cache gen — re-sort после group URLtest (latency мог
      // существенно измениться).
      _emit(_state.copyWith(pingBatchGen: _state.pingBatchGen + 1));
    } catch (e) {
      final msg = _formatProbeError(groupTag, url, e);
      _addDebug(DebugSource.app, msg);
      _emit(_state.copyWith(lastError: msg));
    }
  }

  /// Mass URLTest на всех нодах активной группы — параллельные `clash.delay`
  /// с concurrency cap (`_pingConcurrency`). Не путать с [runGroupUrltest]
  /// (там единый clash `/group/<tag>/delay`). Использует per-group resolved
  /// url/timeout (§040). Повторный вызов во время running — cancel.
  ///
  /// §078: [order] — optional explicit порядок тэгов для пинга. Если не
  /// передан, iterates `_state.nodes` (raw config-order, backward-compat).
  /// UI обычно передаёт `displayList` из home_screen → ping идёт в порядке
  /// отображения (sort + manual + pinned + filter уже применены caller'ом),
  /// что юзер ожидает визуально.
  Future<void> runMassUrltest({List<String>? order}) async {
    final clash = _clash;
    if (clash == null) return;

    if (_massPingRunning) {
      cancelMassPing();
      return;
    }

    final nodes = List<String>.from(order ?? _state.nodes);
    if (nodes.isEmpty) return;

    _massPingRunning = true;
    _massPingEpoch++;
    final epoch = _massPingEpoch;

    final busyMap = {for (final tag in nodes) tag: '…'};
    _emit(_state.copyWith(lastDelay: <String, int>{}, pingBusy: busyMap));
    _addDebug(DebugSource.app, 'Mass ping started (${nodes.length} nodes, concurrency=$_pingConcurrency)');

    // Parallel ping with limited concurrency
    var index = 0;
    // §040: для всех нод текущей mass-ping сессии используем per-group
    // resolved url/timeout — снимок на старте сессии, чтобы все ноды
    // получили одинаковый test endpoint (юзер не сменит group в середине).
    final massPingGroup = _state.selectedGroup;
    final massPingUrl = pingUrlFor(massPingGroup);
    final massPingTimeout = pingTimeoutFor(massPingGroup);

    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= nodes.length) break;
        if (!_massPingRunning || _massPingEpoch != epoch || !_state.tunnelUp) break;
        final tag = nodes[i];
        try {
          final ms = await clash.delay(tag, timeoutMs: massPingTimeout, url: massPingUrl);
          if (_massPingEpoch != epoch) break;
          final nextDelay = Map<String, int>.from(_state.lastDelay)..[tag] = ms;
          final nextBusy = Map<String, String>.from(_state.pingBusy)..[tag] = '';
          _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
        } catch (_) {
          if (_massPingEpoch != epoch) break;
          final nextDelay = Map<String, int>.from(_state.lastDelay)..[tag] = -1;
          final nextBusy = Map<String, String>.from(_state.pingBusy)..[tag] = '';
          _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
        }
      }
    }

    final workers = List.generate(
      _pingConcurrency.clamp(1, nodes.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    if (_massPingEpoch == epoch) {
      _massPingRunning = false;
      _addDebug(DebugSource.app, 'Mass ping finished');
      // §070: bump cache gen — single re-sort после batch.
      // (notifyListeners выполнится внутри _emit.)
      _emit(_state.copyWith(pingBatchGen: _state.pingBatchGen + 1));

      // Форсим URLTest на всех urltest-группах (auto и т.п.) —
      // без этого sing-box держит `now` пустым до первого interval-тика
      // (дефолт 5m). Использует pingUrl/pingTimeout из mass-ping'а.
      unawaited(_runAllUrltestGroups(epoch));
    }
  }

  Future<void> _runAllUrltestGroups(int epoch) async {
    final pmap = _state.proxiesJson['proxies'];
    if (pmap is! Map<String, dynamic>) return;
    for (final entry in pmap.entries) {
      // Bug 2 fix: проверяем epoch на каждой итерации — если юзер нажал
      // cancel пока крутятся urltest-группы, прерываемся (auto-группа была
      // основным источником "ping продолжается" после Stop).
      if (_massPingEpoch != epoch) return;
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      final type = v['type']?.toString().toLowerCase() ?? '';
      if (!type.contains('urltest')) continue;
      await runGroupUrltest(entry.key);
    }
  }

  void cancelMassPing() {
    if (!_massPingRunning) return;
    _massPingRunning = false;
    _massPingEpoch++;
    // Прерываем in-flight delay/groupDelay HTTP-запросы — клиент закрывается,
    // workers получают exception и завершаются (и пути для direct/auto где
    // sing-box reusing connection pool не оставляются висеть). Без этого
    // mass ping продолжал реально пинговать пока все timeout'ы не истекут.
    _clash?.cancelDelays();
    // Очищаем все pingBusy — workers которые ждут in-flight clash.delay
    // ответ break'нутся по epoch-mismatch БЕЗ финального cleanup'а своих
    // тегов (см. runMassUrltest worker). Без этой очистки у нод которые не
    // успели ответить остаётся "…" indicator до следующего ping'а.
    _emit(_state.copyWith(pingBusy: const {}));
    _addDebug(DebugSource.app, 'Mass ping cancelled');
  }
}
