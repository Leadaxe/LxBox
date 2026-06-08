import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/home_state.dart';
import '../services/config_introspection.dart';
import '../services/version_info.dart';
import 'home/widgets/traffic_bar.dart';
import 'home/widgets/progress_banner.dart';
import 'home/widgets/nodes_header.dart';
import 'home/widgets/home_drawer.dart';
import 'home/widgets/home_controls.dart';
import 'home/widgets/node_list.dart';
import 'home/widgets/status_chip.dart';
import 'home/home_menus.dart';
import 'home/home_dialogs.dart';
import 'home/node_filter_view_model.dart';
import 'home/node_list_presenter.dart';
import 'home/restore_backup.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/debug_registry.dart';
import '../services/haptic_service.dart';
import '../services/nav/home_return_observer.dart';
import '../services/settings_storage.dart';
import '../services/traffic_profiler.dart';
import '../services/subscription/auto_updater.dart';
import '../services/update_checker.dart';
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

  // §070 frozen-sort cache живёт в presenter'е (создаётся один раз в
  // initState → переживает rebuild'ы, cache-семантика идентична оригиналу).
  late final NodeListPresenter _nodeList;

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
    // Создаём presenter один раз тут чтобы §070 frozen-sort cache переживал
    // rebuild'ы (как и раньше когда жил в State).
    _nodeList = NodeListPresenter(
      controller: _controller,
      subController: _subController,
      filter: _filter,
    );
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
      if (!mounted) return;
      unawaited(maybeShowNotificationPermissionDialog(context));
      unawaited(maybeShowBatteryOptimizationDialog(context, _vpn));
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
    // Флаг `_updateSnackbarShown` выставляется через `onShown` callback ровно
    // когда SnackBar реально показывается.
    if (!mounted) return;
    unawaited(maybeShowUpdateSnackbar(
      context,
      info,
      onShown: () => _updateSnackbarShown = true,
    ));
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
      showRevokedSnackBar(context, _controller);
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
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showLocationPermissionDialog(context, permName);
        _permissionDialogShowing = false;
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
                HomeControls(
                  controller: _controller,
                  subController: _subController,
                  presenter: _nodeList,
                  connectingAnimChild: StatusChip(
                    state: state,
                    isRevoked: state.tunnel == TunnelStatus.revoked,
                    isConnecting: state.tunnel == TunnelStatus.connecting,
                    connectingAnim: _connectingAnim,
                  ),
                  state: state,
                  startActive: startActive,
                  startEnabled: startEnabled,
                  stopEnabled: stopEnabled,
                  needsRestart: _needsRestart,
                  errorTimerOnDismiss: () {
                    _errorTimer?.cancel();
                    _errorTimer = null;
                    _controller.clearError();
                  },
                  onStartWithAutoRefresh: () =>
                      unawaited(_startWithAutoRefresh()),
                  onRebuildAndClearDirty: _rebuildAndClearDirty,
                  onRebuildAndReconnect: _rebuildAndReconnect,
                  onRebuildAndStart: _rebuildAndStart,
                ),
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
              HomeNodeList(
                controller: _controller,
                subController: _subController,
                autoUpdater: _autoUpdater,
                filter: _filter,
                presenter: _nodeList,
                state: state,
                onRestoreFromBackup: () =>
                    restoreFromBackup(context, _subController, _autoUpdater),
                onTapToConnect: () => unawaited(_startWithAutoRefresh()),
              ),
            ],
          ),
        );
      },
    );
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
}
