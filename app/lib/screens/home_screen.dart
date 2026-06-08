import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/consts.dart';
import '../services/tag_resolver.dart';
import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../models/home_state.dart';
import '../models/node_spec.dart';
import '../services/backup_service.dart';
import '../services/clash_api_client.dart';
import '../services/config_introspection.dart';
import '../services/error_format.dart';
import '../services/version_info.dart';
import '../widgets/node_row.dart';
import '../widgets/node_view_item.dart';
import 'home/node_filter.dart';
import 'home/filter_widgets.dart';
import 'home/widgets/traffic_bar.dart';
import 'home/widgets/status_chip.dart';
import 'home/widgets/progress_banner.dart';
import 'home/widgets/nodes_header.dart';
import 'home/widgets/home_drawer.dart';
import 'home/widgets/add_server_cta.dart';
import 'home/home_menus.dart';
import 'home/subscription_lookup.dart';
import 'home/node_filter_view_model.dart';
import '../widgets/wifi_permission_dialog.dart';
import 'outbound_view_screen.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/debug_registry.dart';
import '../services/haptic_service.dart';
import '../services/nav/home_return_observer.dart';
import '../services/template_loader.dart';
import '../services/settings_storage.dart';
import '../services/traffic_profiler.dart';
import '../services/subscription/auto_updater.dart';
import '../services/update_checker.dart';
import '../services/url_launcher.dart' as ul;
import '../vpn/box_vpn_client.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final HomeController _controller;
  late final SubscriptionController _subController;
  late final AutoUpdater _autoUpdater;
  late final AnimationController _connectingAnim;
  final BoxVpnClient _vpn = BoxVpnClient();
  bool _autoRebuild = true;

  // §085 R3 — весь node-filter state (§048 regex/protocols/subscriptions/
  // ping + show-detour/show-non-matching + §083 per-channel memory)
  // инкапсулирован в `NodeFilterViewModel`. home_screen подписывается на
  // него и rebuild'ит (`setState`) на каждый `notifyListeners`.
  late final NodeFilterViewModel _filter;

  // §070 — UI-cache для frozen sort при `state.resortOnManualPing == false`.
  // См. spec'у — manual single ping не двигает порядок, batch / group switch /
  // config rebuild сбрасывает через `state.pingBatchGen` bump.
  List<String>? _cachedSorted;
  ({NodeSortMode mode, int gen, int nodesLen, bool pinD, bool pinA})?
      _cachedSortKey;
  /// Derived UI flag. §076 banner gate:
  /// (а) `_subController.configDirty` — ВСЕГДА показываем banner (независимо
  ///     от tunnel state). Юзер видит pending changes даже когда VPN down,
  ///     может Apply из banner.
  /// (б) `state.configChangedNeedRestart && tunnelUp` — saved config обновлён
  ///     во время работы tunnel, running config устарел, нужен restart.
  bool get _needsRestart {
    final state = _controller.state;
    return _subController.configDirty ||
        (state.tunnelUp && state.configChangedNeedRestart);
  }
  Timer? _errorTimer;

  /// Для side-effect'ов на transition tunnel (SnackBar при → revoked,
  /// управление `_connectingAnim`, авто-dismiss timer для lastError).
  /// Обновляются в `_onControllerChange` после каждого notifyListeners.
  /// Ключевое: side-effects **НЕ** в `build` (анти-паттерн Flutter) —
  /// вся мутация state/timers/animations идёт через этот listener.
  TunnelStatus _prevTunnel = TunnelStatus.disconnected;
  String _prevError = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Порядок: subController first → AutoUpdater видит entries,
    // HomeController holds AutoUpdater для VPN-transitions callback.
    _subController = SubscriptionController();
    _autoUpdater = AutoUpdater(_subController);
    _subController.bindAutoUpdater(_autoUpdater);
    _controller = HomeController(autoUpdater: _autoUpdater);
    // §085 R3 — filter view-model: rebuild на любое изменение фильтров.
    _filter = NodeFilterViewModel()..addListener(_onFilterChanged);
    _connectingAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    // §031 Debug API: публикуем контроллеры в реестр и, если пользователь
    // включал Debug API раньше, поднимаем сервер на старте.
    DebugRegistry.I.home = _controller;
    DebugRegistry.I.sub = _subController;
    DebugRegistry.I.autoUpdater = _autoUpdater;
    // §044: profiler нужен runtime data-source `/connections`. Биндим один
    // раз тут (singleton-controller singleton-fetcher), чтобы и Debug API
    // /profiler/start (без открытого UI), и StatsScreen.PerAppTraceTab
    // оба видели актуальный fetcher. Closure читает свежий clashClient
    // на каждом poll'е — переподключение Clash API не требует rebind.
    TrafficProfiler.I.bindRuntime(connections: () async {
      final c = _controller.clashClient;
      if (c == null) return const <String, dynamic>{'connections': []};
      return c.fetchConnections();
    });
    unawaited(applyDebugApiSettings());
    unawaited(_controller.init());
    unawaited(_initSubsAndAutoUpdate());
    unawaited(_loadAutoRebuild());
    unawaited(_loadHapticPref());
    // Track tunnel transitions для side-effect'ов (SnackBar при revoke,
    // animation для connecting, auto-dismiss timer для lastError).
    // AnimatedBuilder уже rebuildит UI на notifyListeners; listener здесь
    // нужен только для эффектов вне build-фазы.
    _prevTunnel = _controller.state.tunnel;
    _prevError = _controller.state.lastError;
    _controller.addListener(_onControllerChange);
    // §076: global home-return observer триггерит auto-rebuild когда
    // юзер возвращается на home с любого settings screen'а.
    homeReturnObserver.setHandler(_onReturnToHome);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowNotificationPermissionDialog());
      unawaited(_maybeShowBatteryOptimizationDialog());
    });
    // Update check (§036): hydrate cached "last known version" сразу,
    // network fetch — через 5 сек чтобы не мешать запуску VPN. Throttled
    // 24h в самом UpdateChecker. Listener подхватывает результат и
    // показывает SnackBar если есть newer + не dismissed.
    UpdateChecker.I.latest.addListener(_onLatestUpdateChanged);
    unawaited(UpdateChecker.I.hydrate(localVersion: VersionInfo.I.version));
    Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      unawaited(
        UpdateChecker.I.maybeCheck(localVersion: VersionInfo.I.version),
      );
    });
  }

  /// Reactive handler — UpdateChecker.latest изменился (hydrate / fetch).
  /// Показываем SnackBar если есть newer + не dismissed для этой версии.
  /// Вынесен в отдельный async-flow чтобы не блокировать notifier callback.
  bool _updateSnackbarShown = false;
  void _onLatestUpdateChanged() {
    final info = UpdateChecker.I.latest.value;
    if (info == null) {
      _updateSnackbarShown = false;
      return;
    }
    if (_updateSnackbarShown) return;
    unawaited(_maybeShowUpdateSnackbar(info));
  }

  Future<void> _maybeShowUpdateSnackbar(UpdateInfo info) async {
    final dismissed = await SettingsStorage.getDismissedUpdateVersion();
    if (dismissed == info.tag) return;
    if (!mounted) return;
    _updateSnackbarShown = true;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        content: Text(
          'L×Box ${info.tag} available '
          '(you have v${VersionInfo.I.version})',
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: () async {
            await ul.UrlLauncher.open(info.htmlUrl);
          },
        ),
      ),
    );
  }

  /// Показывает диалог-попап при старте, если приложение не в battery
  /// optimization whitelist'е. Без whitelist'а Android агрессивно throttle'ит
  /// foreground service + tunnel засыпает в Doze → интернет «отваливается»
  /// до следующего открытия приложения.
  ///
  /// Без cooldown: показываем при **каждом** запуске пока юзер не даст
  /// permission. Как только `isIgnoringBatteryOptimizations()=true` — dialog
  /// никогда больше не появится.

  /// On Android 13+ (API 33+) `POST_NOTIFICATIONS` is a runtime permission.
  /// Without it, the foreground-service notification used by VPN may not
  /// be shown — the user has no visual indicator that VPN is active.
  /// We show an explainer once on first launch (or after revocation),
  /// then trigger the system permission dialog.
  static const _notifPromptKey = 'notif_perm_prompted_v1';

  Future<void> _maybeShowNotificationPermissionDialog() async {
    final granted = await ul.UrlLauncher.checkNotificationPermission();
    if (granted) return;
    final asked = await SettingsStorage.getVar(_notifPromptKey, '0');
    if (asked == '1') return;
    await SettingsStorage.setVar(_notifPromptKey, '1');
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Allow notifications'),
        content: const Text(
          'L×Box runs as a foreground service while VPN is active. '
          'A persistent notification is required by Android — it lets you '
          'see at a glance that VPN is on, and prevents the system from '
          'killing the tunnel in the background.\n\n'
          'No promotional or alert notifications will be sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ul.UrlLauncher.requestNotificationPermission();
    }
  }

  Future<void> _maybeShowBatteryOptimizationDialog() async {
    final ok = await _vpn.isIgnoringBatteryOptimizations();
    if (ok) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Allow background activity'),
        content: const Text(
          'Android restricts background activity to save battery. '
          'Without an exception, the VPN tunnel may be killed when the '
          'screen turns off — your connection drops until you reopen L×Box.\n\n'
          'Open system settings and choose "Unrestricted" / "Not optimized".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _vpn.openBatteryOptimizationSettings();
              // OEM (ColorOS/MIUI/MagicOS) имеет proprietary battery toggles
              // поверх AOSP — наш REQUEST_IGNORE_BATTERY_OPTIMIZATIONS их не
              // контролирует. Followup показывается всегда (независимо от
              // того что юзер выбрал в AOSP dialog) — OEM toggles важнее
              // на проблемных device'ах.
              if (mounted) await _showOemBatteryFollowupDialog();
            },
            child: const Text('Allow'),
          ),
        ],
      ),
    );
  }

  /// Standard AOSP REQUEST_IGNORE_BATTERY_OPTIMIZATIONS добавляет app в
  /// AOSP whitelist, но на OEM (ColorOS/OxygenOS на OnePlus/OPPO/Realme,
  /// MIUI на Xiaomi, MagicOS на Honor) есть **отдельные** proprietary
  /// toggle'ы поверх AOSP («Background activity», «Stop when idle»),
  /// которые AOSP intent НЕ контролирует. Open App Info чтобы юзер
  /// тапнул их вручную.
  Future<void> _showOemBatteryFollowupDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Disable battery restrictions'),
        content: const Text(
          'To keep the VPN running in background, also disable battery '
          'restrictions for L×Box. The settings screen will open — find '
          'and toggle:\n\n'
          '• "Battery usage" → "Don\'t optimize" or "Allow background '
          'activity"\n\n'
          '• On OnePlus / OPPO / Realme also:\n'
          '  "Stop activity when idle" → OFF',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _vpn.openAppDetailsSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _onControllerChange() {
    final state = _controller.state;
    final now = state.tunnel;
    final nowError = state.lastError;

    // Animation control — вне build. Раньше было в _buildStatusChip, что
    // нарушало «build чистый» (multiple rebuilds в секунду на hot path'е
    // heartbeat'а / ping'а → лишние .repeat/.stop/.reset вызовы).
    final isConnecting = now == TunnelStatus.connecting;
    if (isConnecting && !_connectingAnim.isAnimating) {
      _connectingAnim.repeat();
    } else if (!isConnecting && _connectingAnim.isAnimating) {
      _connectingAnim.stop();
      _connectingAnim.reset();
    }

    // Revoke → SnackBar.
    if (_prevTunnel != TunnelStatus.revoked &&
        now == TunnelStatus.revoked) {
      _showRevokedSnackBar();
    }

    // §050 — structured alert prefix `alert:permission_location:<perm>` →
    // show AlertDialog with "Open Settings" button instead of plain error.
    // Background: ACCESS_BACKGROUND_LOCATION on API 30+ can only be granted
    // through Settings (not via runtime permission dialog), so we explain
    // and offer button.
    if (nowError != _prevError &&
        nowError.contains('alert:permission_location:') &&
        !_permissionDialogShowing) {
      _permissionDialogShowing = true;
      // Strip the "Stopped: " prefix that HomeController prepends.
      final permName = nowError
          .replaceFirst(RegExp(r'^Stopped:\s*'), '')
          .replaceFirst('alert:permission_location:', '')
          .trim();
      // Clear immediately so toast/snackbar для same error не показывается.
      _controller.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showLocationPermissionDialog(permName);
      });
    } else if (nowError != _prevError) {
      // Auto-dismiss timer для lastError. Раньше жил в Builder внутри build —
      // логика завязана на прохождение build, хрупко при агрессивных
      // rebuild'ах. Теперь явный transition detection: ошибка изменилась —
      // перезапускаем 15с таймер; ошибка очистилась — cancel.
      _errorTimer?.cancel();
      _errorTimer = null;
      if (nowError.isNotEmpty) {
        _errorTimer = Timer(const Duration(seconds: 15), () {
          if (mounted) _controller.clearError();
        });
      }
    }

    // §083 — per-channel match-filter memory. Канал сменился → save старого
    // + restore нового. ViewModel сам guard'ит no-op и notify'ит только при
    // реальной смене (→ _onFilterChanged → setState).
    _filter.syncChannel(state.selectedGroup);

    _prevTunnel = now;
    _prevError = nowError;
  }

  bool _permissionDialogShowing = false;

  Future<void> _showLocationPermissionDialog(String permName) async {
    if (!mounted) return;
    // permName из BoxService alert prefix — может быть comma-separated:
    // "android.permission.ACCESS_BACKGROUND_LOCATION,android.permission.NEARBY_WIFI_DEVICES".
    final missing = permName.split(',').map((p) => p.trim()).toList();
    await WifiPermissionDialog.show(context, missing: missing);
    _permissionDialogShowing = false;
  }

  void _showRevokedSnackBar() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('VPN taken by another app'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Start',
            onPressed: () => unawaited(_controller.start()),
          ),
        ),
      );
  }

  /// init подписок + затем `start()` AutoUpdater'а (триггер #1 appStart
  /// и заведение periodic-таймера на 1 час). Порядок важен — AutoUpdater
  /// итерирует `entries`, они должны быть загружены с диска.
  ///
  /// Bootstrap-config после init:
  ///   - если в storage есть subs но native ещё не имеет загруженного config'а
  ///     (`state.configRaw.isEmpty`) — auto-bootstrap (исходный сценарий).
  ///   - §076: если `subController.configDirty == true` (восстановлен из
  ///     mtime compare в `init`, означает kill mid-edit оставил settings
  ///     новее saved config) — также bootstrap. Тихое согласование.
  ///
  /// Закрывает класс «UI пустой после backup-import + restart» / «storage
  /// был мутирован через Debug API» / «kill во время editing → старый config».
  Future<void> _initSubsAndAutoUpdate() async {
    await _subController.init();
    _autoUpdater.start();

    // Wait one frame: HomeController.init() is also unawaited above; даём
    // ему успеть прочитать существующий config (если был). После этого
    // решаем: bootstrap нужен только если config реально пустой ИЛИ dirty.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    final needBootstrap = _subController.entries.isNotEmpty &&
        (_controller.state.configRaw.isEmpty || _subController.configDirty);
    if (needBootstrap) {
      final config = await _subController.generateConfig();
      if (config != null && mounted) {
        await _controller.saveParsedConfig(config);
        // §076: rebuild успешен → флаг гаснет (in-memory; mtime теперь
        // tied — saved config обновлён, settings file не изменился).
        _subController.configDirty = false;
        setState(() {});
      }
    }
  }

  Future<void> _loadHapticPref() async {
    await HapticService.I.loadFromPrefs();
  }

  Future<void> _loadAutoRebuild() async {
    final val = await SettingsStorage.getVar('auto_rebuild', 'true');
    _autoRebuild = val == 'true';
  }

  // §085 R3 — filter event handlers + per-channel memory переехали в
  // `NodeFilterViewModel` (`_filter`). Здесь остаются только lookup-замыкания
  // (`_protocolOfTag` / `_subscriptionsOfTag` / `_isControlTag`), которые
  // зависят от `state`/`_subController`, а не от filter-state.

  /// Lookup protocol for tag — учитывает urltest group fallback (см. §048
  /// «Protocol detection»). Возвращает null если cache miss и urltest нет.
  String? _protocolOfTag(String tag, HomeState state) {
    final cache = state.configCache;
    final urltestNow = ClashApiClient.urltestNow(state.proxiesJson, tag);
    return cache.protoByTag[tag] ??
        (urltestNow != null ? cache.protoByTag[urltestNow] : null);
  }

  /// §077 — Lookup subscription id'ов по display-тэгу. Тонкая обёртка
  /// над pure helper'ом `subscriptionsOfTag` (см. `home/subscription_lookup.dart`).
  /// Алгоритм + edge cases описаны в спеке §077 и docstring'е helper'а.
  Set<String> _subscriptionsOfTag(String tag) =>
      subscriptionsOfTag(tag, _subController.entries);

  /// §078 — True если outbound с этим tag'ом — control (selector / urltest
  /// / direct / block / dns), не payload-нода. Source-of-truth =
  /// `state.proxiesJson` (Clash API знает типы outbound'ов лучше нас).
  ///
  /// Caller использует чтобы (a) короткозамкнуть filter passing — control
  /// ноды **всегда** matching независимо от фильтров, (b) исключить из
  /// 'Custom' chip detection — empty `subscriptionsOf` у control'ов не
  /// должен триггерить 'Custom' chip когда у юзера нет UserServer'ов.
  static const _controlProxyTypes = <String>{
    'selector', 'urltest', 'direct', 'block', 'dns',
  };

  bool _isControlTag(String tag, HomeState state) {
    final pmap = state.proxiesJson['proxies'];
    if (pmap is! Map<String, dynamic>) return false;
    final entry = pmap[tag];
    if (entry is! Map<String, dynamic>) return false;
    final type = (entry['type'] as String?)?.toLowerCase() ?? '';
    return _controlProxyTypes.contains(type);
  }

  /// §085 R3 — единый `NodeFilter` из view-model + state-зависимых lookup'ов.
  /// Используется и `_computeDisplayList`, и `_buildNodeList` (был дубль §078).
  NodeFilter _buildNodeFilter(HomeState state) => NodeFilter(
        regex: _filter.activeRegex,
        regexInvert: _filter.regexInvert,
        protocols: _filter.enabledProtocols,
        subscriptions: _filter.enabledSubscriptions,
        maxPingMs: _filter.activeMaxPingMs,
        protocolOf: (t) => _protocolOfTag(t, state),
        subscriptionsOf: _subscriptionsOfTag,
        pingOf: (t) => state.lastDelay[t],
      );

  /// §085 R3 — pool (detour show/hide) → split на matching/non-matching.
  /// Control-узлы (direct/auto/…) короткозамкнуты в matching (§078).
  /// Возвращает `(matching, nonMatching)`.
  (List<String>, List<String>) _splitNodes(
      List<String> sortedNodes, HomeState state) {
    final pool = _filter.showDetour
        ? sortedNodes
        : sortedNodes.where((t) => !TagResolver.isDetourMarker(t)).toList();
    final filter = _buildNodeFilter(state);
    final matching = <String>[];
    final nonMatching = <String>[];
    for (final tag in pool) {
      if (_isControlTag(tag, state) || filter.passes(tag)) {
        matching.add(tag);
      } else {
        nonMatching.add(tag);
      }
    }
    return (matching, nonMatching);
  }

  /// §078 — текущий displayList снаружи `_buildNodeList` (для ping button →
  /// `runMassUrltest(order:)` в порядке отображения).
  List<String> _computeDisplayList(HomeState state) {
    final (matching, nonMatching) = _splitNodes(_viewSortedNodes(state), state);
    return _filter.showNonMatching
        ? [...matching, ...nonMatching]
        : matching;
  }

  /// §070 — true если хоть одна sort-опция отклонена от default (для
  /// yellow dot indicator).
  /// §070 — frozen sort при `resortOnManualPing == false`. Cache hit ↔
  /// (sortMode, pingBatchGen, nodes.length, pinDirect, pinAuto) совпадают
  /// с предыдущим вызовом + все cached tags ещё в pool. Manual single ping
  /// → новый state, та же key → cache hit → строка не прыгает.
  List<String> _viewSortedNodes(HomeState s) {
    if (s.resortOnManualPing) {
      _cachedSortKey = null;
      _cachedSorted = null;
      return s.sortedNodes;
    }
    final key = (
      mode: s.sortMode,
      gen: s.pingBatchGen,
      nodesLen: s.nodes.length,
      pinD: s.pinDirect,
      pinA: s.pinAuto,
    );
    if (key == _cachedSortKey && _cachedSorted != null) {
      // sanity: все cached tags ещё в pool (защита от ноды удалённой из
      // подписки между bump'ами).
      if (_cachedSorted!.every(s.nodes.contains)) return _cachedSorted!;
    }
    _cachedSortKey = key;
    _cachedSorted = List<String>.unmodifiable(s.sortedNodes);
    return _cachedSorted!;
  }

  @override
  void dispose() {
    // Порядок: сначала отменяем side-effects (timer, listener),
    // потом сами владельцы (autoUpdater имеет ref на subController,
    // controller имеет ref на autoUpdater — dispose в обратном порядке
    // созданию).
    _errorTimer?.cancel();
    _errorTimer = null;
    _filter.removeListener(_onFilterChanged);
    _filter.dispose();
    _controller.removeListener(_onControllerChange);
    UpdateChecker.I.latest.removeListener(_onLatestUpdateChanged);
    WidgetsBinding.instance.removeObserver(this);
    homeReturnObserver.clearHandler();
    _autoUpdater.dispose();
    // Ownership contract: HomeScreen владеет controller'ами + анимацией.
    // Раньше dispose пропускался — на проде ОС гасит процесс, но в
    // тестах / hot reload / будущем смене root widget'а получали бы
    // утечку _statusSub, heartbeat timer, transient timer, ChangeNotifier
    // listeners.
    _controller.dispose();
    _subController.dispose();
    _connectingAnim.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
    }
  }

  /// §085 R3 — rebuild при изменении фильтров (NodeFilterViewModel notify).
  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _subController]),
      builder: (context, _) {
        // Debug API `POST /action/preview-empty-state?on=true` имитирует
        // empty-state без потери данных: для UI configRaw/nodes выглядят
        // пустыми, реальный _controller.state не трогается.
        final realState = _controller.state;
        final state = _controller.previewEmpty
            ? realState.copyWith(configRaw: '', nodes: const [])
            : realState;
        final startActive = !state.tunnelUp;
        final startEnabled = !state.busy && !state.tunnelUp && state.configRaw.isNotEmpty;
        final stopEnabled = !state.busy && state.tunnelUp;
        return Scaffold(
          appBar: AppBar(title: const Text('L×Box')),
          drawer: HomeDrawer(
            controller: _controller,
            subController: _subController,
            autoUpdater: _autoUpdater,
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Empty state (no config) → guide + CTA берёт на себя весь
              // экран; controls/header не рисуем, чтобы disabled-кнопка
                // не путала первого пользователя.
              if (state.configRaw.isNotEmpty) ...[
                _buildControls(context, state, startActive, startEnabled, stopEnabled),
                if (state.tunnelUp)
                  TrafficBar(state: state, controller: _controller),
                if (_subController.busy && _subController.progressMessage.isNotEmpty)
                  ProgressBanner(message: _subController.progressMessage),
                const SizedBox(height: 12),
                NodesHeader(
                  controller: _controller,
                  subController: _subController,
                  filter: _filter,
                  onSortLongPress: () => showSortOptionsMenu(context, _controller),
                ),
                const SizedBox(height: 4),
              ],
              _buildNodeList(context, state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(
    BuildContext context,
    HomeState state,
    bool startActive,
    bool startEnabled,
    bool stopEnabled,
  ) {
    final isRevoked = state.tunnel == TunnelStatus.revoked;
    final isConnecting = state.tunnel == TunnelStatus.connecting;
    final isStopping = state.tunnel == TunnelStatus.stopping;
    final canToggle = !state.busy && !isConnecting && !isStopping;
    final toggleEnabled = canToggle && (state.tunnelUp || state.configRaw.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: toggleEnabled
                    ? () {
                        HapticService.I.onConnectTap();
                        if (state.tunnelUp) {
                          _confirmStop(state);
                        } else {
                          unawaited(_startWithAutoRefresh());
                        }
                      }
                    : null,
                icon: Icon(
                  state.tunnelUp ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 20,
                ),
                label: Text(state.tunnelUp ? 'Stop' : 'Start'),
              ),
              const SizedBox(width: 8),
              StatusChip(
                state: state,
                isRevoked: isRevoked,
                isConnecting: isConnecting,
                connectingAnim: _connectingAnim,
              ),
              const SizedBox(width: 8),
              _buildReloadButton(context, state),
            ],
          ),
          if (_subController.configDirty && !_subController.busy) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => unawaited(_rebuildAndClearDirty()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.build_circle_outlined, size: 16, color: Theme.of(context).colorScheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Settings changed — tap to rebuild config',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          // §076: показываем «Restart» banner ТОЛЬКО когда rebuild уже
          // сделан (configDirty=false) но running config устарел. Если
          // configDirty=true — выше показывается «Apply» banner, юзер
          // сначала тапнет его → rebuild → configDirty=false → configChangedNeedRestart=true
          // → этот banner появится автоматически. Никаких stacked'ов.
          if (state.tunnelUp &&
              state.configChangedNeedRestart &&
              !_subController.configDirty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              // Не гасим `_needsRestart` на тап — если юзер отменит Stop-диалог,
              // banner должен остаться. Гаснет только реальным tunnel up↔down.
              onTap: () => _confirmStop(_controller.state),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Config changed — restart VPN to apply',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onTertiaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (state.lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Pure render — auto-dismiss timer завведён в _onControllerChange
            // при изменении state.lastError (вне build-фазы).
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.lastError,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _errorTimer?.cancel();
                    _errorTimer = null;
                    _controller.clearError();
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Text('Channel', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      isDense: true,
                      value: state.groups.contains(state.selectedGroup)
                          ? state.selectedGroup
                          : null,
                      hint: const Text('Select channel'),
                      items: state.groups
                          .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                          .toList(),
                      onChanged: (!state.tunnelUp || state.busy || state.groups.isEmpty)
                          ? null
                          : (value) async {
                              _controller.setSelectedGroup(value);
                              await _controller.applyGroup(value);
                            },
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                    ? null
                    : () {
                        if (_controller.massPingRunning) {
                          _controller.cancelMassPing();
                        } else {
                          // §078 — пингуем в порядке отображения. Фильтр и
                          // sort учитываются: ping всё что **видно**, в том
                          // порядке как видно. Control-outbounds тоже в
                          // списке (clash.delay для них вернёт error или
                          // реальный latency для direct-out).
                          unawaited(_controller.runMassUrltest(
                              order: _computeDisplayList(state)));
                        }
                      },
                onLongPress: _showPingSettings,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    _controller.massPingRunning ? Icons.stop_circle_outlined : Icons.speed,
                    color: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                        ? Theme.of(context).disabledColor
                        : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Кнопка справа от status chip. Short tap = умный default (reconnect /
  /// rebuild+start / rebuild+reconnect в зависимости от состояния), long
  /// press = меню с 3 явными действиями. Иконка refresh читается как
  /// «переподключиться», что и является default-поведением.
  Widget _buildReloadButton(BuildContext context, HomeState state) {
    final cs = Theme.of(context).colorScheme;
    final dirty = _subController.configDirty || _needsRestart;
    final enabled = !state.busy && !_subController.busy;
    final fg = dirty ? cs.onPrimaryContainer : null;
    final bg = dirty ? cs.primaryContainer : Colors.transparent;
    // Без Tooltip: на mobile он сам хватает long-press (его default trigger)
    // и наш `onLongPress` на InkWell никогда не срабатывает. Label доступен
    // через Semantics для accessibility.
    return Semantics(
      button: true,
      label: _defaultReloadLabel(state, dirty),
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        // Builder нужен чтобы `findRenderObject` в _showReloadMenu нашёл саму
        // кнопку, а не родительский Row/Column (иначе меню всплывёт с краю).
        child: Builder(builder: (inkCtx) => InkWell(
          onTap: enabled ? () => _runDefaultReload(state) : null,
          onLongPress: enabled ? () => _showReloadMenu(inkCtx, state) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.refresh, size: 20, color: fg),
          ),
        )),
      ),
    );
  }

  String _defaultReloadLabel(HomeState state, bool dirty) {
    if (!state.tunnelUp) return 'Rebuild config + connect';
    // §030: default tap теперь делает in-place reload (легче чем reconnect).
    // Long-press menu всё ещё даёт явный 'Reconnect' для full restart.
    return dirty ? 'Rebuild config + reconnect' : 'Reload';
  }

  void _runDefaultReload(HomeState state) {
    HapticService.I.onConnectTap();
    if (!state.tunnelUp) {
      unawaited(_rebuildAndStart());
      return;
    }
    final dirty = _subController.configDirty || _needsRestart;
    if (dirty) {
      unawaited(_rebuildAndReconnect());
    } else {
      // §030 — in-place reload через `commandServer.startOrReloadService`.
      // Раньше тут был `reconnect()` (full stop+start с recreate Android Service);
      // новый путь не убивает Service, tunnel дропается на ~3s вместо 5-10s.
      // Long-press menu даёт fallback на full reconnect для случаев когда
      // in-place reload не помог.
      unawaited(_controller.reloadVpn());
    }
  }

  Future<void> _showReloadMenu(BuildContext anchorCtx, HomeState state) async {
    final box = anchorCtx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchorCtx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    final rect = RelativeRect.fromLTRB(
      pos.dx,
      pos.dy + size.height,
      overlay.size.width - pos.dx - size.width,
      overlay.size.height - pos.dy,
    );
    final reconnectLabel = state.tunnelUp ? 'Reconnect' : 'Connect';
    final rebuildReconnectLabel =
        state.tunnelUp ? 'Rebuild config + reconnect' : 'Rebuild config + connect';
    final choice = await showMenu<String>(
      context: context,
      position: rect,
      items: [
        // Reload первый — самый light recovery (in-place через CommandServer.
        // startOrReloadService). Tap по кнопке выполняет это же действие.
        if (state.tunnelUp)
          const PopupMenuItem(
            value: 'reload',
            child: Row(children: [
              Icon(Icons.bolt, size: 18),
              SizedBox(width: 12),
              Text('Reload'),
            ]),
          ),
        PopupMenuItem(
          value: 'reconnect',
          child: Row(children: [
            const Icon(Icons.sync, size: 18),
            const SizedBox(width: 12),
            Text(reconnectLabel),
          ]),
        ),
        const PopupMenuItem(
          value: 'rebuild',
          child: Row(children: [
            Icon(Icons.build_circle_outlined, size: 18),
            SizedBox(width: 12),
            Text('Rebuild config only'),
          ]),
        ),
        PopupMenuItem(
          value: 'rebuild_reconnect',
          child: Row(children: [
            const Icon(Icons.refresh, size: 18),
            const SizedBox(width: 12),
            Text(rebuildReconnectLabel),
          ]),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    HapticService.I.onConnectTap();
    switch (choice) {
      case 'reload':
        unawaited(_controller.reloadVpn());
      case 'reconnect':
        unawaited(_controller.reconnect());
      case 'rebuild':
        unawaited(_rebuildAndClearDirty());
      case 'rebuild_reconnect':
        unawaited(_rebuildAndReconnect());
    }
  }

  /// Rebuild config → reconnect (если up) или start (если down). Очищает
  /// dirty-флаг как и `_rebuildAndClearDirty`.
  Future<void> _rebuildAndReconnect() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (!mounted) return;
    await _controller.reconnect();
  }

  /// Off-state: rebuild then start. Используется как default когда VPN off.
  Future<void> _rebuildAndStart() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (!mounted) return;
    await _controller.start();
    if (mounted && _controller.state.lastError.isNotEmpty && !_controller.state.tunnelUp) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.state.lastError),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _confirmStop(HomeState state) {
    if (state.traffic.activeConnections > 3) {
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop VPN?'),
          content: Text(
            '${state.traffic.activeConnections} active connections will be closed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop'),
            ),
          ],
        ),
      ).then((confirmed) {
        if (confirmed == true) _controller.stop();
      });
    } else {
      _controller.stop();
    }
  }

  Future<void> _startWithAutoRefresh() async {
    // Обновление подписок теперь через AutoUpdater (см. services/subscription/
    // auto_updater.dart) — 4 триггера, общая логика. При Start никакого
    // синхронного HTTP-fetch'а не делаем: если подписки протухли, trigger 2
    // (VPN connected + 2 мин) подтянет их через туннель.
    await _controller.start();
    // Show diagnostic if start failed
    if (mounted && _controller.state.lastError.isNotEmpty && !_controller.state.tunnelUp) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.state.lastError),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _rebuildAndClearDirty() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (mounted) setState(() {});
  }

  /// §076: callback зарегистрированный в `homeReturnObserver`. Срабатывает
  /// когда юзер вернулся на home (root route стал top). Если есть pending
  /// changes и юзер хочет авто-rebuild — пересобираем lazy.
  ///
  /// Re-read `auto_rebuild` на каждый возврат — юзер мог изменить
  /// preference в App Settings между визитами.
  void _onReturnToHome() {
    if (!mounted) return;
    if (!_subController.configDirty) return;
    if (_subController.busy) return;
    unawaited(() async {
      final val = await SettingsStorage.getVar('auto_rebuild', 'true');
      _autoRebuild = val == 'true';
      if (!mounted) return;
      if (_autoRebuild) {
        await _rebuildAndClearDirty();
      } else {
        setState(() {});
      }
    }());
  }

  Future<void> _rebuildConfig() async {
    // Только пересборка конфига — без HTTP-fetch'а подписок. За fetch
    // отвечает AutoUpdater (по 4 триггерам) и manual ⟳ на Servers.
    final config = await _subController.generateConfig();
    if (!mounted) return;
    if (config != null) {
      final ok = await _controller.saveParsedConfig(config);
      if (ok && mounted) {
        final nodeCount = ConfigIntrospection.parse(config).nodeCount;
        // configChangedNeedRestart выставляется внутри saveParsedConfig,
        // AnimatedBuilder переотрисует через _needsRestart getter.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Config rebuilt: $nodeCount nodes${_controller.state.tunnelUp ? " — restart VPN to apply" : ""}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showPingSettings() async {
    final template = await TemplateLoader.load();
    final pingOpts = template.pingOptions;
    final presets = (pingOpts['presets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (!mounted) return;
    // §040: dialog scope — global / per-group. Если у текущей group'ы есть
    // override → стартуем в group-mode и подставляем her значения. Иначе
    // global-mode с глобальным URL/timeout (resolved через storage > template).
    final currentGroup = _controller.state.selectedGroup ?? '';
    final allOpts = await SettingsStorage.getPingOptions();
    final groupsRaw = allOpts['groups'];
    final groupOverride =
        (groupsRaw is Map<String, dynamic>) && currentGroup.isNotEmpty
            ? (groupsRaw[currentGroup] as Map<String, dynamic>?)
            : null;
    final hasGroupOverride = groupOverride != null;

    if (!mounted) return;
    var applyToGroup = hasGroupOverride;
    final initialUrl = hasGroupOverride
        ? (groupOverride['url'] as String?) ?? _controller.pingUrl
        : _controller.pingUrl;
    final initialTimeout = hasGroupOverride
        ? ((groupOverride['timeout_ms'] as num?)?.toInt() ?? _controller.pingTimeout)
        : _controller.pingTimeout;

    final urlCtrl = TextEditingController(text: initialUrl);
    final timeoutCtrl = TextEditingController(text: '$initialTimeout');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // Refresh has-override каждый раз через рестарт sheet'а — но мы
          // не закрывали sheet, так что просто храним в-памяти.
          final canApplyToGroup = currentGroup.isNotEmpty;
          return Padding(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Ping Settings', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                // Scope toggle.
                if (canApplyToGroup) ...[
                  SegmentedButton<bool>(
                    segments: [
                      const ButtonSegment(
                          value: false, label: Text('All channels')),
                      ButtonSegment(
                          value: true,
                          label: Text(currentGroup,
                              overflow: TextOverflow.ellipsis)),
                    ],
                    selected: {applyToGroup},
                    onSelectionChanged: (s) {
                      setSheetState(() => applyToGroup = s.first);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (presets.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: presets.map((p) {
                      final name = p['name']?.toString() ?? '';
                      final url = p['url']?.toString() ?? '';
                      final selected = urlCtrl.text == url;
                      return ChoiceChip(
                        label: Text(name, style: const TextStyle(fontSize: 12)),
                        selected: selected,
                        onSelected: (_) =>
                            setSheetState(() => urlCtrl.text = url),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Test URL',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: timeoutCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Timeout (ms)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (applyToGroup && hasGroupOverride)
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.restart_alt, size: 18),
                          label: const Text('Reset to global'),
                          onPressed: () async {
                            await SettingsStorage.clearGroupPing(currentGroup);
                            await _controller.reloadPingOptions();
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ),
                    if (applyToGroup && hasGroupOverride)
                      const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () async {
                          final url = urlCtrl.text.trim();
                          final timeout =
                              int.tryParse(timeoutCtrl.text) ?? 5000;
                          if (applyToGroup && currentGroup.isNotEmpty) {
                            await SettingsStorage.setGroupPing(
                              currentGroup,
                              url: url,
                              timeoutMs: timeout,
                            );
                          } else {
                            await SettingsStorage.setGlobalPingUrl(url);
                            await SettingsStorage.setGlobalPingTimeout(timeout);
                          }
                          await _controller.reloadPingOptions();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    urlCtrl.dispose();
    timeoutCtrl.dispose();
  }

  void _viewOutboundJson(String tag, HomeState state) {
    if (state.configRaw.isEmpty) return;
    // §085 R2 — config-introspection через единый service.
    final intro = ConfigIntrospection.parse(state.configRaw);
    final chain = intro.outboundChain(tag);
    if (chain.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not found: $tag')),
      );
      return;
    }

    final payload = chain.length == 1 ? chain.first : chain;
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => OutboundViewScreen(
        tag: tag,
        kind: intro.kindOf(tag),
        json: json,
      ),
    ));
  }

  void _copyNodeJson(String tag, HomeState state, String mode) {
    if (state.configRaw.isEmpty) return;

    // §085 R2 — config-introspection через единый service.
    final intro = ConfigIntrospection.parse(state.configRaw);
    final Map<String, dynamic>? server = intro.outboundByTag(tag);
    Map<String, dynamic>? detour;
    if (server != null) {
      final detourTag = intro.detourOf(tag);
      if (detourTag != null) detour = intro.outboundByTag(detourTag);
    }

    if (server == null) return;

    Object toCopy;
    String label;
    switch (mode) {
      case 'detour':
        if (detour == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No detour for this node')),
            );
          }
          return;
        }
        toCopy = Map<String, dynamic>.from(detour)..remove('detour');
        label = 'Detour copied';
      case 'both':
        final cleanServer = Map<String, dynamic>.from(server)..remove('detour');
        if (detour != null) {
          final cleanDetour = Map<String, dynamic>.from(detour)..remove('detour');
          toCopy = [cleanDetour, cleanServer];
        } else {
          toCopy = cleanServer;
        }
        label = 'Server${detour != null ? " + detour" : ""} copied';
      default: // 'server'
        toCopy = Map<String, dynamic>.from(server)..remove('detour');
        label = 'Server copied';
    }

    final json = const JsonEncoder.withIndent('  ').convert(toCopy);
    Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label)));
    }
  }

  /// Lookup исходного `NodeSpec` по display-тэгу (с префиксом подписки).
  /// Возвращает `null` если не нашли (control-узлы direct/auto, чужой
  /// конфиг, или collision-suffix от `allocateTag`). Используется для
  /// "Copy URI" в long-press меню.
  NodeSpec? _findNodeByDisplayTag(String displayTag) {
    for (final e in _subController.entries) {
      final base = TagResolver.stripPrefix(displayTag, e.tagPrefix);
      for (final n in e.list.nodes) {
        if (n.tag == base) return n;
        // Detour-нода живёт под главным как `chained` — в config она тоже
        // получает prefix. Поищем и там.
        final ch = n.chained;
        if (ch != null && ch.tag == base) return ch;
      }
    }
    return null;
  }

  void _copyNodeUri(String tag) {
    final node = _findNodeByDisplayTag(tag);
    if (node == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No source URI for this node')),
        );
      }
      return;
    }
    final uri = node.toUri();
    if (uri.isEmpty) return;
    Clipboard.setData(ClipboardData(text: uri));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URI copied')),
      );
    }
  }

  /// First-run empty-state. Big icon + headline + subtitle + circular `+`
  /// button → SubscriptionsScreen. Замещает controls + node-list когда
  /// `configRaw.isEmpty`, чтобы юзер не упирался в disabled Start.
  /// Empty-state quick-action: open SAF file picker → parse backup file →
  /// `applyImport(merge: false, include: all)` → snackbar + restart hint.
  /// Без preview dialog'а (юзер в empty state, явно хочет restore целиком —
  /// никаких категорий снимать не надо). Polished restore через
  /// `Settings → Backup` остаётся для merge-flow и selective import'а.
  Future<void> _restoreFromBackup() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      String? raw;
      if (file.bytes != null) {
        try {
          raw = const Utf8Decoder(allowMalformed: false).convert(file.bytes!);
        } catch (_) {}
      } else if (file.path != null) {
        raw = await File(file.path!).readAsString();
      }
      if (raw == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read file.')),
          );
        }
        return;
      }

      const service = BackupService();
      final BackupContents contents;
      try {
        contents = await service.parseImport(raw);
      } on FormatException catch (e) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Invalid backup'),
            content: Text(e.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final include = contents.availableCategories();
      final apply = await service.applyImport(
        contents,
        merge: false,
        include: include,
      );
      if (!mounted) return;

      // Re-read storage в in-memory state controller'ов: `applyImport` записал
      // в storage, но `_subController` всё ещё хранит entries времени init'а
      // (когда server_lists был пуст). Без `init()` повтор юзер увидит «нет
      // серверов» пока не перезапустит app.
      await _subController.init();
      // Backup хранит только URL/name/meta подписок — nodes re-fetch'аются.
      // Triggers fetch немедленно (manual + force обходит auto_update_subs
      // toggle и min-retry cooldown).
      unawaited(
          _autoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: true));

      final parts = <String>[];
      if (apply.serverListsApplied > 0) {
        parts.add('${apply.serverListsApplied} server lists');
      }
      if (apply.routingApplied > 0) parts.add('${apply.routingApplied} rules');
      if (apply.appSettingsApplied > 0) {
        parts.add('${apply.appSettingsApplied} app settings');
      }
      if (apply.debugConfigApplied > 0) parts.add('debug config');
      if (apply.vpnSettingsApplied > 0) {
        parts.add('${apply.vpnSettingsApplied} VPN settings');
      }
      final summary = parts.isEmpty
          ? 'Imported nothing'
          : 'Imported: ${parts.join(', ')} · fetching subscriptions…';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(summary),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: ${formatUserError(e)}')),
        );
      }
    }
  }

  Widget _buildNodeList(BuildContext context, HomeState state) {
    if (state.nodes.isEmpty) {
      // Empty state: первый запуск (нет конфига) — гайд с CTA-кнопкой;
      // остальные пустые состояния — пассивный текст-подсказка.
      if (state.configRaw.isEmpty) {
        return Expanded(
          child: AddServerCta(
            controller: _controller,
            subController: _subController,
            autoUpdater: _autoUpdater,
            onRestoreFromBackup: _restoreFromBackup,
          ),
        );
      }
      final cs = Theme.of(context).colorScheme;
      // tunnelUp — нет узлов в текущем selector'е; пассивный hint.
      if (state.tunnelUp) {
        return Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns_outlined,
                      size: 48, color: cs.onSurfaceVariant.withAlpha(120)),
                  const SizedBox(height: 12),
                  Text(
                    'No nodes in this channel.\nTry another one.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      // Конфиг есть, не подключены — большая кликабельная Start-зона.
      // Тап = тот же путь что и FilledButton Start в _buildControls.
      final canStart = !state.busy &&
          state.tunnel != TunnelStatus.connecting &&
          state.tunnel != TunnelStatus.stopping;
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: canStart
                  ? () {
                      HapticService.I.onConnectTap();
                      unawaited(_startWithAutoRefresh());
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline,
                        size: 64, color: cs.primary),
                    const SizedBox(height: 12),
                    Text(
                      'Tap to connect',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    // §048 — двухфазная модель (см. spec):
    // Phase 1 — pool filter: detour show/hide. Нода **отсутствует** в render
    // если detour off и tag detour-prefixed.
    // §070: используем _viewSortedNodes — frozen sort при resortOnManualPing=false
    // (manual single ping не дёргает порядок).
    final allTags = _viewSortedNodes(state);
    final pool = _filter.showDetour
        ? allTags
        : allTags.where((t) => !TagResolver.isDetourMarker(t)).toList();

    // configCache парсится один раз при saveParsedConfig (см. HomeState),
    // здесь просто читаем. Раньше jsonDecode шёл на каждый rebuild
    // ListView — с 50+ нодами и сортировкой это был hot-path выжиматель.
    final cache = state.configCache;

    // §048 Phase 2 — match filter: split pool на matching + nonMatching
    // (control-узлы короткозамкнуты в matching, §078). См. `_splitNodes`.
    final (matching, nonMatching) = _splitNodes(allTags, state);
    final matchingSet = matching.toSet();

    // Render list = matching + (showNonMatching ? nonMatching : []).
    final displayList = _filter.showNonMatching
        ? <String>[...matching, ...nonMatching]
        : matching;

    // Available для chips — из всего pool (не от current filter state).
    // Emoji — из allTags (locked decision #3, включая detour).
    final emojis = NodeFilter.extractEmojis(allTags);
    final availableProtocols = <String>{};
    for (final t in pool) {
      final p = _protocolOfTag(t, state);
      if (p != null) availableProtocols.add(p);
    }
    final subOptions = <(String, String)>[];
    for (final e in _subController.entries) {
      final list = e.list;
      // Показываем подписку только если она enabled И в ней есть хоть 1 нода.
      // Disabled / пустые → шум, не дают полезный chip.
      if (list is SubscriptionServers && e.enabled && list.nodes.isNotEmpty) {
        subOptions.add((e.id, e.displayName));
      }
    }
    // §078 — 'Custom' chip отображается только если в pool есть **payload**
    // тэги с empty subscriptionsOf (= UserServer / imported JSON outbound).
    // Control outbounds (direct/auto/etc.) тоже дают empty Set, но они
    // в свою категорию — exclude'им чтобы chip не появлялся когда у
    // юзера нет UserServer'ов.
    final hasCustom = pool.any((t) =>
        !_isControlTag(t, state) && _subscriptionsOfTag(t).isEmpty);
    if (hasCustom) subOptions.add(('custom', 'Custom'));

    return Expanded(
      child: Column(
        children: [
          if (_filter.panelExpanded)
            _buildFilterPanel(
              context,
              emojis: emojis,
              availableProtocols: availableProtocols.toList()..sort(),
              subOptions: subOptions,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _controller.reloadProxies,
              // §071: ReorderableListView вместо ListView.separated.
              // - buildDefaultDragHandles: false — мы провайдим свои через
              //   transparent strip на левом 5% края каждого non-pinned ряда.
              // - Separator делается через BorderSide bottom внутри itemBuilder
              //   (ReorderableListView не имеет separatorBuilder).
              // - pinnedCount определяется sequential check'ом первых элементов
              //   displayList — robust против фильтра §048 (если pinned попал
              //   в nonMatching, он не на index 0 → pinnedCount=0, корректно).
              child: _buildReorderableNodeList(
                context,
                state: state,
                displayList: displayList,
                cache: cache,
                matchingSet: matchingSet,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// §071 — ReorderableListView для нод. Pinned section (direct/auto)
  /// non-draggable; остальное — Stack с transparent 5%-strip overlay'ом
  /// слева, который ловит long-press+drag через `ReorderableDragStartListener`.
  /// Drag → `commitManualReorder` переключает в `NodeSortMode.manual` +
  /// сохраняет новый порядок.
  Widget _buildReorderableNodeList(
    BuildContext context, {
    required HomeState state,
    required List<String> displayList,
    required ConfigCache cache,
    required Set<String> matchingSet,
  }) {
    // §070+§071: pinnedCount определяем sequential проверкой первых элементов.
    // Если фильтр §048 затолкал pinned в nonMatching → pin не на index 0 →
    // pinnedCount=0 (drag-handle покажется и на pinned, но это корректно
    // т.к. формально он не pinned в текущем render'е).
    int pinnedCount = 0;
    if (state.pinDirect &&
        pinnedCount < displayList.length &&
        displayList[pinnedCount] == 'direct-out') {
      pinnedCount++;
    }
    if (state.pinAuto &&
        pinnedCount < displayList.length &&
        displayList[pinnedCount] == kAutoOutboundTag) {
      pinnedCount++;
    }

    final dividerColor =
        Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: displayList.length,
      onReorder: (oldIndex, newIndex) {
        // ReorderableListView convention: при move-down newIndex отступает.
        if (newIndex > oldIndex) newIndex -= 1;
        if (oldIndex < pinnedCount) return; // pinned ряды не двигаются
        if (newIndex < pinnedCount) newIndex = pinnedCount; // не дроп в pinned
        final restOnly = displayList.skip(pinnedCount).toList();
        final restOld = oldIndex - pinnedCount;
        final restNew = newIndex - pinnedCount;
        final moved = restOnly.removeAt(restOld);
        restOnly.insert(restNew, moved);
        _controller.commitManualReorder(restOnly);
      },
      itemBuilder: (ctx, i) {
        final tag = displayList[i];
        final urltestNow =
            ClashApiClient.urltestNow(state.proxiesJson, tag);
        final proxyEntry = ClashApiClient.proxyEntry(state.proxiesJson, tag);
        final isUrltestGroup = proxyEntry != null &&
            (proxyEntry['type']?.toString().toLowerCase() ?? '')
                .contains('urltest');
        final protoType = cache.protoByTag[tag] ??
            (urltestNow != null ? cache.protoByTag[urltestNow] : null);
        final row = DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: dividerColor, width: 1),
            ),
          ),
          child: NodeRow(
            item: NodeViewItem(
              tag: tag,
              active: tag == state.activeInGroup,
              highlighted: tag == state.highlightedNode,
              delay: state.lastDelay[tag],
              pingBusy: state.pingBusy[tag] == '…',
              tunnelUp: state.tunnelUp,
              busy: state.busy,
              urltestNow: urltestNow,
              hasDetour: cache.detourTags.contains(tag),
              protocolLabel:
                  protoType != null ? _protoLabel(protoType) : null,
              matches: matchingSet.contains(tag),
            ),
            onHighlight: () => _controller.setHighlightedNode(tag),
            onActivate: () => unawaited(_controller.switchNode(tag)),
            onPing: () => unawaited(_controller.runNodeUrltest(tag)),
            onCopy: (mode) => _copyNodeJson(tag, state, mode),
            onCopyUri: () => _copyNodeUri(tag),
            onViewJson: () => _viewOutboundJson(tag, state),
            onRunUrltest: isUrltestGroup
                ? () => unawaited(_controller.runGroupUrltest(tag))
                : null,
          ),
        );
        // Pinned ряды — без grab strip.
        if (i < pinnedCount) {
          return KeyedSubtree(key: ValueKey('node-$tag'), child: row);
        }
        // Non-pinned ряды — overlay strip 5% от ширины слева (transparent).
        // LayoutBuilder даёт actual row width → strip всегда proportional.
        return KeyedSubtree(
          key: ValueKey('node-$tag'),
          child: LayoutBuilder(
            builder: (ctx, c) => Stack(
              children: [
                row,
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: c.maxWidth * 0.08,
                  // ReorderableDelayedDragStartListener (long-press → drag)
                  // вместо ReorderableDragStartListener (immediate). С
                  // immediate scroll-жест Scrollable выигрывает gesture
                  // arena у нашего vertical drag и reorder не начинается.
                  // Delayed обходит арбитраж: scroll работает immediately,
                  // drag активируется после long-press hold.
                  child: ReorderableDelayedDragStartListener(
                    index: i,
                    // Container(color:...) — иначе пустой SizedBox не
                    // hit-testable (RenderConstrainedBox.hitTestSelf=false,
                    // нет child'а → жест проваливается на NodeRow ниже,
                    // InkWell его съедает).
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// §048 — Filter panel (expanded). Composed: regex field + emoji chips +
  /// protocol chips + subscription chips + ping field + Show-detour +
  /// Show-non-matching.
  Widget _buildFilterPanel(
    BuildContext context, {
    required List<String> emojis,
    required List<String> availableProtocols,
    required List<(String, String)> subOptions,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(128)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RegexFilterField(
            controller: _filter.regexController,
            onChanged: _filter.onRegexChanged,
            valid: _filter.regexValid,
            enabled: _filter.regexEnabled,
            onEnabledChanged: _filter.setRegexEnabled,
            invert: _filter.regexInvert,
            onInvertChanged: _filter.setRegexInvert,
            onClear: _filter.clearRegex,
          ),
          if (emojis.isNotEmpty) ...[
            const SizedBox(height: 6),
            EmojiChipsRow(emojis: emojis, onTap: _filter.onEmojiChipTap),
          ],
          if (availableProtocols.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: [
                for (final p in availableProtocols) (p, _protoLabel(p)),
              ],
              enabled: _filter.enabledProtocols,
              onToggle: _filter.toggleProtocol,
            ),
          ],
          if (subOptions.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: subOptions,
              enabled: _filter.enabledSubscriptions,
              onToggle: _filter.toggleSubscription,
            ),
          ],
          const SizedBox(height: 4),
          PingFilterField(
            controller: _filter.pingController,
            onChanged: _filter.onPingChanged,
            enabled: _filter.pingEnabled,
            onEnabledChanged: _filter.setPingEnabled,
            onClear: _filter.clearPing,
          ),
          FilterCheckboxRow(
            label: 'Show detour servers',
            value: _filter.showDetour,
            onChanged: _filter.setShowDetour,
          ),
          FilterCheckboxRow(
            label: 'Show non-matching (dimmed)',
            value: _filter.showNonMatching,
            onChanged: _filter.setShowNonMatching,
          ),
        ],
      ),
    );
  }
}

/// Короткий label протокола для строки ноды. TLS опускаем — у большинства
/// протоколов (VLESS/Trojan/Hy2/TUIC) он дефолт, метить каждую — шум.
String _protoLabel(String type) => switch (type) {
      'vless' => 'VLESS',
      'vmess' => 'VMess',
      'trojan' => 'Trojan',
      'shadowsocks' => 'SS',
      'hysteria2' => 'Hy2',
      'tuic' => 'TUIC',
      'wireguard' => 'WG',
      'ssh' => 'SSH',
      'socks' => 'SOCKS',
      'http' => 'HTTP',
      _ => type.toUpperCase(),
    };
