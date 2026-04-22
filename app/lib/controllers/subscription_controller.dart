import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/subscription_meta.dart';
import '../services/app_log.dart';
import '../services/error_humanize.dart';
import '../services/parse_hints.dart';
import '../services/relative_time.dart';
import '../services/url_mask.dart';
import '../services/builder/build_config.dart';
import '../services/parser/body_decoder.dart';
import '../services/parser/ini_parser.dart';
import '../services/parser/parse_all.dart';
import '../services/parser/uri_parsers.dart';
import '../services/parser/uri_utils.dart';
import '../services/haptic_service.dart';
import '../services/settings_storage.dart';
import '../services/subscription/auto_updater.dart';
import '../services/subscription/http_cache.dart';
import '../services/subscription/input_helpers.dart';
import '../services/subscription/sources.dart';

/// UI-обёртка вокруг `ServerList`. Хранит кэшированный nodeCount и статус.
/// Делегирует мутации полей на wrapped список через `copyWith` + persist
/// через контроллер.
class SubscriptionEntry extends ChangeNotifier {
  ServerList _list;
  int nodeCount;
  String status;

  SubscriptionEntry({
    required ServerList list,
    int? nodeCount,
    this.status = '',
  })  : _list = list,
        nodeCount = nodeCount ??
            (list is SubscriptionServers ? list.lastNodeCount : list.nodes.length);

  ServerList get list => _list;

  String get id => _list.id;
  String get name => _list.name;
  bool get enabled => _list.enabled;
  String get tagPrefix => _list.tagPrefix;
  DetourPolicy get detourPolicy => _list.detourPolicy;
  String get type => _list.type;

  /// URL подписки (пусто для UserServer).
  String get url => _list is SubscriptionServers ? (_list as SubscriptionServers).url : '';

  /// Inline-URI строки (пусто для SubscriptionServers).
  List<String> get connections {
    if (_list is UserServer) {
      final raw = (_list as UserServer).rawBody;
      if (raw.isEmpty) return const [];
      return raw
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  DateTime? get lastUpdated =>
      _list is SubscriptionServers ? (_list as SubscriptionServers).lastUpdated : null;

  SubscriptionMeta? get meta =>
      _list is SubscriptionServers ? (_list as SubscriptionServers).meta : null;

  int get uploadBytes => meta?.uploadBytes ?? 0;
  int get downloadBytes => meta?.downloadBytes ?? 0;
  int get totalBytes => meta?.totalBytes ?? 0;
  int get expireTimestamp => meta?.expireTimestamp ?? 0;
  String get supportUrl => meta?.supportUrl ?? '';
  String get webPageUrl => meta?.webPageUrl ?? '';
  int get updateIntervalHours => _list is SubscriptionServers
      ? (_list as SubscriptionServers).updateIntervalHours
      : 0;

  int get consecutiveFails => _list is SubscriptionServers
      ? (_list as SubscriptionServers).consecutiveFails
      : 0;

  UpdateStatus get lastUpdateStatus => _list is SubscriptionServers
      ? (_list as SubscriptionServers).lastUpdateStatus
      : UpdateStatus.never;

  /// Количество chained-детур узлов (⚙). В `nodeCount` они не включены,
  /// потому что в списке `.nodes` детуры живут как поле `.chained` у
  /// главного узла, не отдельным элементом.
  int get detourCount =>
      _list.nodes.where((n) => n.chained != null).length;

  bool get registerDetourServers => detourPolicy.registerDetourServers;
  bool get registerDetourInAuto => detourPolicy.registerDetourInAuto;
  bool get useDetourServers => detourPolicy.useDetourServers;
  String get overrideDetour => detourPolicy.overrideDetour;

  static String formatAgo(DateTime dt) => _formatAgo(dt);

  String get displayName {
    if (name.isNotEmpty) return name;
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
      return url.length > 40 ? '${url.substring(0, 40)}…' : url;
    }
    if (_list.nodes.isNotEmpty) {
      return _list.nodes.first.label.isNotEmpty
          ? _list.nodes.first.label
          : _list.nodes.first.tag;
    }
    final conns = connections;
    if (conns.isNotEmpty) {
      final c = conns.first;
      if (c.startsWith('{')) {
        final tagMatch = RegExp(r'"tag"\s*:\s*"([^"]+)"').firstMatch(c);
        if (tagMatch != null) return tagMatch.group(1)!;
      }
      return c.length > 40 ? '${c.substring(0, 40)}...' : c;
    }
    return '(empty)';
  }

  String get subtitle {
    final parts = <String>[];
    if (status.isNotEmpty) parts.add(status);
    if (lastUpdated != null) parts.add(_formatAgo(lastUpdated!));
    return parts.join(' · ');
  }

  static String _formatAgo(DateTime dt) =>
      relativeTime(DateTime.now(), dt);

  void _replaceList(ServerList next) {
    _list = next;
    notifyListeners();
  }

  // ─── UI-facing mutable setters (persist via controller.persistSources) ───
  //
  // Каждый setter мутирует обёрнутый ServerList через `copyWith` по типу.
  // UI после каждого set должен вызвать `controller.persistSources()`, чтобы
  // записать на диск. Так же было в v1 ProxySource-паттерне.

  set name(String v) => _replaceList(_copy(name: v));
  set enabled(bool v) => _replaceList(_copy(enabled: v));
  set tagPrefix(String v) => _replaceList(_copy(tagPrefix: v));

  /// Только для SubscriptionServers. Пользовательский override дефолта
  /// `profile-update-interval` (24ч). AutoUpdater читает значение через
  /// `updateIntervalHours` каждый раз при проверке — persist'им через
  /// `controller.persistSources()` на стороне UI.
  set updateIntervalHours(int v) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    final clamped = v < 1 ? 1 : v;
    _replaceList(list.copyWith(updateIntervalHours: clamped));
  }

  set registerDetourServers(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(registerDetourServers: v)));
  set registerDetourInAuto(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(registerDetourInAuto: v)));
  set useDetourServers(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(useDetourServers: v)));
  set overrideDetour(String v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(overrideDetour: v)));

  ServerList _copy({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
  }) {
    if (_list is SubscriptionServers) {
      return (_list as SubscriptionServers).copyWith(
        name: name,
        enabled: enabled,
        tagPrefix: tagPrefix,
        detourPolicy: detourPolicy,
      );
    }
    return (_list as UserServer).copyWith(
      name: name,
      enabled: enabled,
      tagPrefix: tagPrefix,
      detourPolicy: detourPolicy,
    );
  }
}

/// Основной контроллер подписок. Владеет `List<ServerList>`, делает
/// fetch/parse через `parseFromSource`, собирает конфиг через `buildConfig`.
class SubscriptionController extends ChangeNotifier {
  List<SubscriptionEntry> _entries = [];
  List<SubscriptionEntry> get entries => _entries;

  /// AutoUpdater устанавливается внешним кодом (HomeScreen) после construction —
  /// конструкторы циклические (AutoUpdater хочет controller, controller хочет
  /// updater для ручного resetFailCount). Optional — контроллер работает и без.
  AutoUpdater? _autoUpdater;
  void bindAutoUpdater(AutoUpdater u) {
    _autoUpdater = u;
  }

  bool _busy = false;
  bool get busy => _busy;

  bool configDirty = false;

  String _lastError = '';
  String get lastError => _lastError;

  /// Debug-only: выставить lastError извне (для Debug API
  /// /action/emulate-error демо). Уведомляет listeners, чтобы UI
  /// отрисовал inline red-текст.
  void setDebugLastError(String msg) {
    _lastError = msg;
    notifyListeners();
  }

  String _progressMessage = '';
  String get progressMessage => _progressMessage;

  String? _lastGeneratedConfig;
  String? get lastGeneratedConfig => _lastGeneratedConfig;

  Future<void> init() async {
    final lists = await SettingsStorage.getServerLists();
    _entries = lists.map((l) => SubscriptionEntry(list: l)).toList();
    // Если app был убит во время fetch'а, status=inProgress остаётся
    // на диске и залочит подписку навсегда (guard в _fetchEntryByRef).
    // Sweep: inProgress → failed. lastUpdateAttempt сохраняем — min-retry
    // 15 мин продолжит работать.
    var swept = false;
    for (var i = 0; i < _entries.length; i++) {
      final l = _entries[i].list;
      if (l is SubscriptionServers &&
          l.lastUpdateStatus == UpdateStatus.inProgress) {
        _entries[i]._replaceList(
            l.copyWith(lastUpdateStatus: UpdateStatus.failed));
        swept = true;
      }
    }
    if (swept) await _persist();
    notifyListeners();
    // Восстанавливаем узлы из кэша тел HTTP-подписок — офлайн доступ.
    // Без этого после перезапуска app узлы пропадали, пока пользователь
    // вручную не нажимал refresh.
    unawaited(_rehydrateFromCache());
  }

  Future<void> _rehydrateFromCache() async {
    for (var i = 0; i < _entries.length; i++) {
      final list = _entries[i].list;
      if (list is! SubscriptionServers) continue;
      if (list.nodes.isNotEmpty) continue;
      final body = await HttpCache.loadBody(list.url);
      if (body == null || body.isEmpty) continue;
      try {
        final decoded = decode(body);
        final nodes = parseAll(decoded);
        if (nodes.isEmpty) continue;
        final next = list.copyWith(nodes: nodes, lastNodeCount: nodes.length);
        _entries[i]._replaceList(next);
        final detours = nodes.where((n) => n.chained != null).length;
        _entries[i].nodeCount = nodes.length;
        _entries[i].status = detours > 0
            ? '${nodes.length} +$detours⚙ nodes (cached)'
            : '${nodes.length} nodes (cached)';
        AppLog.I.info(
            'Re-hydrated ${nodes.length} nodes from cache: ${maskSubscriptionUrl(list.url)}');
      } catch (e) {
        AppLog.I.warning(
            'Re-hydrate failed for ${maskSubscriptionUrl(list.url)}: ${humanizeError(e)}');
      }
    }
    notifyListeners();
  }

  Future<void> addFromInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    _busy = true;
    _lastError = '';
    notifyListeners();
    // Input может быть URL подписки (с токеном), direct-link (vless://user@host),
    // JSON-outbound. Маскируем, если detect'им URL — иначе только kind.
    final inputPreview = isSubscriptionUrl(trimmed)
        ? maskSubscriptionUrl(trimmed)
        : (trimmed.startsWith('{') || trimmed.startsWith('['))
            ? '<JSON outbound>'
            : '<proxy link>';
    AppLog.I.info('addFromInput: $inputPreview');

    try {
      if (isSubscriptionUrl(trimmed)) {
        final list = SubscriptionServers(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: trimmed,
        );
        _entries.add(SubscriptionEntry(list: list));
        await _persist();
        await _fetchEntry(_entries.length - 1);
      } else if (isWireGuardConfig(trimmed)) {
        final spec = parseWireguardIni(trimmed);
        if (spec == null) {
          _lastError = 'Invalid WireGuard config';
          return;
        }
        _entries.add(SubscriptionEntry(
          list: UserServer(
            id: newUuidV4(),
            name: '',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.paste,
            createdAt: DateTime.now(),
            rawBody: spec.rawUri,
            nodes: [spec],
          ),
          nodeCount: 1,
        ));
        await _persist();
      } else if (isDirectLink(trimmed)) {
        final spec = parseUri(trimmed);
        if (spec == null) {
          _lastError = 'Could not parse direct link';
          return;
        }
        _entries.add(SubscriptionEntry(
          list: UserServer(
            id: newUuidV4(),
            name: '',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            origin: UserSource.paste,
            createdAt: DateTime.now(),
            rawBody: trimmed,
            nodes: [spec],
          ),
          nodeCount: 1,
        ));
        await _persist();
      } else if (_isJsonOutbound(trimmed)) {
        await _addJsonOutbounds(trimmed);
      } else {
        _lastError = 'Input is not a subscription URL, proxy link, or outbound JSON';
      }
    } catch (e) {
      _lastError = humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  bool _isJsonOutbound(String text) {
    if (!text.startsWith('{') && !text.startsWith('[')) return false;
    if (!text.contains('"type"')) return false;
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) {
        return parsed.containsKey('type');
      }
      if (parsed is List && parsed.isNotEmpty) {
        return parsed.first is Map<String, dynamic> &&
            (parsed.first as Map).containsKey('type');
      }
    } catch (_) {}
    return false;
  }

  Future<void> _addJsonOutbounds(String text) async {
    final parsed = jsonDecode(text);
    final outbounds = <Map<String, dynamic>>[];
    if (parsed is Map<String, dynamic>) {
      outbounds.add(parsed);
    } else if (parsed is List) {
      outbounds.addAll(parsed.whereType<Map<String, dynamic>>());
    }
    if (outbounds.isEmpty) {
      _lastError = 'No valid outbounds in JSON';
      return;
    }

    // Each JSON outbound → own UserServer entry (v1 behavior parity).
    for (final ob in outbounds) {
      final decoded = decode(jsonEncode(ob));
      final nodes = parseAll(decoded);
      if (nodes.isEmpty) continue;
      _entries.add(SubscriptionEntry(
        list: UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: jsonEncode(ob),
          nodes: nodes,
        ),
        nodeCount: nodes.length,
      ));
    }
    await _persist();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _entries.removeAt(index);
    await _persist();
    notifyListeners();
  }

  Future<void> renameAt(int index, String name) async {
    if (index < 0 || index >= _entries.length) return;
    _entries[index]._replaceList(_renameList(_entries[index].list, name));
    await _persist();
    notifyListeners();
  }

  Future<void> updateAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    // Сбрасываем session fail-count для этой подписки — ручной refresh =
    // осознанное действие юзера, замороженная подписка должна разморозиться.
    if (list is SubscriptionServers) {
      _autoUpdater?.resetFailCount(list.url);
    }
    await _fetchEntry(index, trigger: UpdateTrigger.manual);
  }

  /// Публичный refresh для AutoUpdater. Помечает попытку
  /// (`lastUpdateAttempt` + `lastUpdateStatus`) и персистит, чтобы триггер #1
  /// (app start) после рестарта мог принять решение.
  Future<void> refreshEntry(SubscriptionEntry entry,
      {UpdateTrigger? trigger}) async {
    await _fetchEntryByRef(entry, trigger: trigger);
  }

  Future<void> toggleAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _entries[index]._replaceList(
        _toggleEnabled(_entries[index].list, !_entries[index].enabled));
    await _persist();
    notifyListeners();
  }

  Future<void> moveEntry(int from, int to) async {
    if (from < 0 || from >= _entries.length) return;
    if (to < 0 || to >= _entries.length) return;
    final entry = _entries.removeAt(from);
    _entries.insert(to, entry);
    await _persist();
    notifyListeners();
  }

  /// Замена `entry.list` на новый ServerList (для экранов, меняющих политику
  /// или tagPrefix). Сам ServerList immutable; вызывающий строит новый через
  /// `copyWith` на subscription/user-обёртке.
  Future<void> replaceList(int index, ServerList next) async {
    if (index < 0 || index >= _entries.length) return;
    _entries[index]._replaceList(next);
    await _persist();
    notifyListeners();
  }

  Future<String?> updateAllAndGenerate() async {
    _busy = true;
    _lastError = '';
    _progressMessage = 'Updating subscriptions...';
    notifyListeners();

    try {
      for (var i = 0; i < _entries.length; i++) {
        if (!_entries[i].enabled) continue;
        if (_entries[i].list is SubscriptionServers &&
            (_entries[i].list as SubscriptionServers).url.isNotEmpty) {
          await _fetchEntry(i);
        }
      }
      _progressMessage = 'Generating config...';
      notifyListeners();

      final config = await _generate();
      _lastGeneratedConfig = config;
      _progressMessage = '';
      configDirty = false;
      await SettingsStorage.setLastGlobalUpdate(DateTime.now());
      return config;
    } catch (e) {
      _lastError = humanizeError(e);
      return null;
    } finally {
      _busy = false;
      _progressMessage = '';
      notifyListeners();
    }
  }

  Future<String?> generateConfig() async {
    _busy = true;
    _lastError = '';
    notifyListeners();
    try {
      final config = await _generate();
      _lastGeneratedConfig = config;
      configDirty = false;
      return config;
    } catch (e) {
      _lastError = humanizeError(e);
      return null;
    } finally {
      _busy = false;
      _progressMessage = '';
      notifyListeners();
    }
  }

  Future<String> _generate() async {
    AppLog.I.info('Generating config...');
    _progressMessage = 'Building config...';
    notifyListeners();

    final settings = BuildSettings(
      userVars: await SettingsStorage.getAllVars(),
      enabledGroups: await SettingsStorage.getEnabledGroups(),
      excludedNodes: await SettingsStorage.getExcludedNodes(),
      customRules: await SettingsStorage.getCustomRules(),
      routeFinal: await SettingsStorage.getRouteFinal(),
    );

    final lists = _entries.map((e) => e.list).toList();
    final result = await buildConfig(lists: lists, settings: settings);

    // Записываем обратно то, что buildConfig сгенерил (clash_api/secret на
    // первом запуске). GUI не обязано знать про этот механизм — достаточно
    // пройти по `generatedVars` и сохранить.
    for (final e in result.generatedVars.entries) {
      await SettingsStorage.setVar(e.key, e.value);
    }

    final outs = (result.config['outbounds'] as List?)?.length ?? 0;
    final eps = (result.config['endpoints'] as List?)?.length ?? 0;
    AppLog.I.info('Config built: $outs outbounds + $eps endpoints, ${lists.length} lists');
    if (result.validation.hasFatal) {
      for (final issue in result.validation.fatal) {
        AppLog.I.error('Validation: ${issue.message}');
      }
    }
    for (final w in result.emitWarnings) {
      AppLog.I.warning(w);
    }
    return result.configJson;
  }

  Future<void> _fetchEntry(int index, {UpdateTrigger? trigger}) async {
    if (index < 0 || index >= _entries.length) return;
    await _fetchEntryByRef(_entries[index], trigger: trigger);
  }

  /// Fetch по ссылке на entry, а не индексу. Защищает от race conditions:
  /// если между добавлением entry и `await _persist` подмешался ещё один
  /// `addFreeList` / `addFromInput`, индекс уже сместился, но ссылка валидна.
  ///
  /// Записывает `lastUpdateAttempt` (всегда) и `lastUpdateStatus` (ok|failed)
  /// в `SubscriptionServers` и сразу персистит — чтобы AutoUpdater после
  /// рестарта app не пытался обновить ту же подписку через 5 секунд.
  Future<void> _fetchEntryByRef(SubscriptionEntry entry,
      {UpdateTrigger? trigger}) async {
    final list = entry.list;
    if (list is! SubscriptionServers) return;

    // Дедупликация: если предыдущий fetch этой же подписки ещё идёт
    // (ручной refresh нажали 2 раза подряд, или manual + триггер совпали),
    // не стартуем второй HTTP. Guard снимается по успеху/фейлу в том же
    // вызове (status→ok|failed). Crash-safe: init() sweep чистит зависший
    // inProgress.
    if (list.lastUpdateStatus == UpdateStatus.inProgress) {
      AppLog.I.debug(
          'Fetch skipped — already inProgress: ${maskSubscriptionUrl(list.url)}');
      return;
    }

    // Масированный URL (T2-3): char-truncation раньше мог оставить токен
    // в логе (провайдеры вроде `https://host/sub/<token>` укладываются в 60
    // символов). `maskSubscriptionUrl` рубит на host.
    final shortUrl = maskSubscriptionUrl(list.url);
    final triggerName = trigger?.name ?? 'manual';
    AppLog.I.info('Fetching subscription [$triggerName]: $shortUrl');
    final attemptAt = DateTime.now();
    try {
      entry.status = 'Fetching...';
      // Помечаем попытку до начала fetch'а, чтобы при крэше app
      // (или kill процесса) AutoUpdater всё равно увидел, что мы пробовали.
      entry._replaceList(list.copyWith(
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.inProgress,
      ));
      await _persist();
      notifyListeners();

      final result = await parseFromSource(UrlSource(list.url));
      // Кешируем сырое тело и заголовки на диск для офлайн-реактивации после
      // перезапуска (см. `_rehydrateFromCache`) и для Source-вкладки (fallback).
      unawaited(HttpCache.save(list.url, result.rawBody, result.headers));
      AppLog.I.info(
          'Fetched ${result.nodes.length} nodes from $shortUrl'
          '${result.meta?.profileTitle == null ? "" : " (title: ${result.meta!.profileTitle})"}');
      final warnNodes = result.nodes.where((n) => n.warnings.isNotEmpty).length;
      if (warnNodes > 0) {
        AppLog.I.warning('$warnNodes nodes with warnings (XHTTP fallback etc.)');
      }
      // Parse hint (night T3-3): 0 узлов при успешном HTTP → вероятно
      // body не распознан. Диагностируем и логируем подсказку, чтобы юзер
      // знал что делать (HTML / Clash YAML / error page / full config).
      if (result.nodes.isEmpty) {
        final hint = diagnoseEmptyParse(result.rawBody);
        if (hint != null) AppLog.I.warning('Parse hint: $hint');
      }
      entry.nodeCount = result.nodes.length;
      final detours = result.nodes.where((n) => n.chained != null).length;
      if (result.nodes.isEmpty) {
        final hint = diagnoseEmptyParse(result.rawBody);
        entry.status = hint != null ? '0 nodes — $hint' : '0 nodes';
      } else {
        entry.status = detours > 0
            ? '${result.nodes.length} +$detours⚙ nodes'
            : '${result.nodes.length} nodes';
      }

      final current = entry.list as SubscriptionServers;
      final nextName = current.name.isEmpty && result.meta?.profileTitle != null
          ? result.meta!.profileTitle!
          : current.name;

      final next = current.copyWith(
        name: nextName,
        meta: result.meta,
        lastUpdated: DateTime.now(),
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: result.nodes.length,
        consecutiveFails: 0,
        updateIntervalHours: result.meta?.updateIntervalHours ??
            current.updateIntervalHours,
        nodes: result.nodes,
      );
      entry._replaceList(next);
      await _persist();
      // Haptic только на user-инициированные fetch'и — auto/periodic тихие.
      if (trigger == UpdateTrigger.manual) HapticService.I.onFetchSuccess();
    } catch (e) {
      AppLog.I.error('Fetch failed for $shortUrl: $e');
      entry.status = entry.nodeCount > 0
          ? '${entry.nodeCount} nodes (update failed)'
          : 'Error: $e';
      // Записываем factual fail-статус: nodes/lastUpdated сохраняем
      // (последнее успешное состояние), но lastUpdateAttempt + status=failed
      // обновляем — чтобы AutoUpdater видел fail и считал в `_failCounts`.
      final current = entry.list;
      if (current is SubscriptionServers) {
        entry._replaceList(current.copyWith(
          lastUpdateAttempt: attemptAt,
          lastUpdateStatus: UpdateStatus.failed,
          consecutiveFails: current.consecutiveFails + 1,
        ));
        await _persist();
      }
      if (trigger == UpdateTrigger.manual) HapticService.I.onFetchError();
    }
    notifyListeners();
  }

  Future<void> persistSources() async {
    configDirty = true;
    await _persist();
  }

  /// Обновляет inline-узлы `UserServer` из нового списка URI/JSON строк.
  Future<void> updateConnectionAt(int index, List<String> connections) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! UserServer) return;

    final nodes = <NodeSpec>[];
    for (final c in connections) {
      final decoded = decode(c);
      nodes.addAll(parseAll(decoded));
    }
    final next = list.copyWith(
      rawBody: connections.join('\n'),
      nodes: nodes,
    );
    _entries[index]._replaceList(next);
    _entries[index].nodeCount = nodes.length;
    _entries[index].status = 'JSON outbound';
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    if (!_busy) configDirty = true;
    await SettingsStorage.saveServerLists(_entries.map((e) => e.list).toList());
  }

  ServerList _renameList(ServerList l, String name) {
    if (l is SubscriptionServers) return l.copyWith(name: name);
    if (l is UserServer) return l.copyWith(name: name);
    return l;
  }

  ServerList _toggleEnabled(ServerList l, bool enabled) {
    if (l is SubscriptionServers) return l.copyWith(enabled: enabled);
    if (l is UserServer) return l.copyWith(enabled: enabled);
    return l;
  }
}
