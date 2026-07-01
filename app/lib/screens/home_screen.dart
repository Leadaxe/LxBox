import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/home_state.dart';
import '../services/app_log.dart';
import '../services/error_humanize.dart';
import '../services/support/active_time_tracker.dart';
import '../services/support/support_message.dart';
import '../services/version_info.dart';
import 'home/widgets/traffic_bar.dart';
import 'home/widgets/progress_banner.dart';
import 'home/widgets/nodes_header.dart';
import 'home/widgets/home_drawer.dart';
import 'home/widgets/home_controls.dart';
import 'home/widgets/node_list.dart';
import 'home/widgets/status_chip.dart';
import '../widgets/pool_view_dialog.dart';
import 'home/home_menus.dart';
import 'home/home_dialogs.dart';
import 'home/node_filter_view_model.dart';
import 'home/node_list_presenter.dart';
import 'home/restore_backup.dart';
import 'home/startup_wizard.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/debug_registry.dart';
import '../services/haptic_service.dart';
import '../services/nav/home_return_observer.dart';
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

  /// §203 — per-tag GlobalKey'и строк node-list'а для `Scrollable.ensureVisible`
  /// («Select server» в меню auto-ноды скроллит к выбранному urltest-серверу).
  /// Ленивая карта: ключ на тег создаётся один раз и переживает rebuild'ы
  /// (иначе ensureVisible получил бы свежий несмонтированный context).
  final Map<String, GlobalKey> _nodeRowKeys = {};

  GlobalKey _nodeRowKey(String tag) =>
      _nodeRowKeys.putIfAbsent(tag, () => GlobalKey());

  /// §203 — подсветить ноду [tag] и best-effort проскроллить к ней. Подсветка
  /// ставится всегда (state); скролл — только если строка смонтирована
  /// (ensureVisible по её GlobalKey). Дальняя нода в ленивом списке может быть
  /// не построена — тогда подсветка останется, юзер увидит её при прокрутке.
  void _scrollToNode(String tag) {
    _controller.setHighlightedNode(tag);
    final ctx = _nodeRowKeys[tag]?.currentContext;
    if (ctx == null) return;
    unawaited(Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    ));
  }

  /// §208 — попап с составом пула round_robin-канала по его auto-тегу.
  /// Title = label канала (из groupLabels по базовому tag `<base>-auto`).
  void _showPool(String autoTag) {
    final base = autoTag.endsWith('-auto')
        ? autoTag.substring(0, autoTag.length - '-auto'.length)
        : autoTag;
    final label = _controller.state.groupLabels[base] ?? base;
    unawaited(showPoolDialog(
      context,
      autoTag: autoTag,
      title: label,
      fetch: _controller.getPool,
    ));
  }

  /// §101 — future от `_controller.init()`: bootstrap в
  /// `_initSubsAndAutoUpdate` ждёт его вместо слепой задержки 100ms.
  late final Future<void> _controllerInit;
  late final AnimationController _connectingAnim;
  final BoxVpnClient _vpn = BoxVpnClient();

  /// §107 single-flight: текущая пересборка конфига. Гейт на Start и
  /// повторные триггеры await'ят её вместо параллельного запуска второй.
  Future<void>? _rebuildInFlight;

  /// §107 (R3): one-shot listener «subController освободился — догнать
  /// pending rebuild», см. [_retryRebuildWhenIdle].
  VoidCallback? _idleRetryListener;

  /// §141 P1.9f — one-shot update-check таймер (5с после старта). Хранится,
  /// чтобы отменить в `dispose()`: `mounted`-guard в колбэке и так
  /// нейтрализует поздний выстрел, но висящий таймер — лишний (гигиена).
  Timer? _updateCheckTimer;

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
    // §168 — profiler берёт connections из CommandClient-стрима напрямую
    // (CcChannel.connections + profilerClient), источник внутренний. bindRuntime
    // удалён: пустой Clash-fetcher §122 давал buffer_count=0 (профайлер слеп).
    unawaited(applyDebugApiSettings());
    _controllerInit = _controller.init();
    unawaited(_controllerInit);
    unawaited(_initSubsAndAutoUpdate());
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
      // Единый стартовый визард: notification → battery → add-tile,
      // последовательно (см. startup_wizard.dart). Раньше эти промпты шли
      // параллельно через unawaited и наезжали друг на друга.
      unawaited(StartupWizard(context, _vpn).run());
      // §105 — cold-start: на этот момент статус туннеля обычно ещё не
      // пришёл от native (connectedSince=null) → no-op; реальный показ
      // ловит _onControllerChange, когда придёт connected и сессия дорастёт.
      unawaited(_maybeShowSupport());
    });
    // Update check (§036): hydrate cached "last known version" сразу,
    // network fetch — через 5 сек чтобы не мешать запуску VPN. Throttled
    // 24h в самом UpdateChecker. Listener подхватывает результат и
    // показывает SnackBar если есть newer + не dismissed.
    UpdateChecker.I.latest.addListener(_onLatestUpdateChanged);
    unawaited(UpdateChecker.I.hydrate(localVersion: VersionInfo.I.version));
    _updateCheckTimer = Timer(const Duration(seconds: 5), () {
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
    }
    // §166 — обычные ошибки показываем ВСПЛЫВАШКОЙ СНИЗУ (SnackBar), не красным
    // баннером сверху. Новая lastError (не location-alert, тот обработан выше) →
    // snackbar + clearError, чтобы верхний banner не зажёгся. Location-alert и
    // config_load_error идут своими путями (dialog / отдельный banner-ключ).
    if (nowError != _prevError &&
        nowError.isNotEmpty &&
        !nowError.contains('alert:permission_location:')) {
      final msg = nowError;
      _controller.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(msg),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ));
      });
    }

    // §083 — per-channel match-filter memory. Канал сменился → save старого
    // + restore нового. ViewModel сам guard'ит no-op и notify'ит только при
    // реальной смене (→ _onFilterChanged → setState).
    _filter.syncChannel(state.selectedGroup);

    // §105 — накопление активного времени туннеля (порог support-диалога).
    // tick() дешёвый: пишет не чаще раза в минуту, сам решает когда.
    final wasUp = _prevTunnel == TunnelStatus.connected;
    final isUp = now == TunnelStatus.connected;
    if (wasUp != isUp) {
      unawaited(ActiveTimeTracker.I.onTunnelChanged(isUp));
    } else if (isUp) {
      unawaited(ActiveTimeTracker.I.tick());
    }
    // §105 — пока туннель активен и экран открыт, проверяем порог показа
    // (gate внутри: foreground + сессия ≥5мин + суммарно ≥3ч). Терминальный.
    if (isUp) unawaited(_maybeShowSupport());

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

    // §101 — bootstrap обязан дождаться:
    //   1. rehydrationDone — ноды подписок восстановлены из HTTP-кеша
    //      (иначе соберём конфиг из nodes=[] и молча потеряем подписку);
    //   2. _controllerInit — HomeController прочитал существующий config
    //      (нужен для решения `configRaw.isEmpty`; раньше — delay 100ms).
    try {
      await Future.wait([_subController.rehydrationDone, _controllerInit]);
      if (mounted) {
        final hasEntries = _subController.entries.isNotEmpty;
        final emptyConfig = _controller.state.configRaw.isEmpty;
        final tunnelUp = _controller.state.tunnelUp;
        final dirty = _subController.configDirty;
        // §116 — лог триггера для девайс-смока (какой путь bootstrap'а горит).
        AppLog.I.info('bootstrap: entries=$hasEntries emptyConfig=$emptyConfig '
            'tunnelUp=$tunnelUp dirty=$dirty');

        if (hasEntries && emptyConfig && tunnelUp) {
          // §116 case B — конфиг не прочёлся, но туннель жив и несёт рабочий
          // конфиг. НЕ пересобираем (нечего примирять, пересборка+tunnelUp =
          // ложный «config changed»). Постоянная error-плашка + рестарт.
          _controller.markConfigLoadError();
        } else if (hasEntries && (emptyConfig || dirty)) {
          // case A (нет конфига, туннель не поднят) или реальный dirty →
          // пересобрать. Дифф в saveParsedConfig снимет ложный «config changed»,
          // если конфиг совпал с работающим.
          final config = await _subController.generateConfig();
          if (config != null && mounted) {
            // §107: generateConfig сбросил configDirty до записи на диск —
            // при неудачном save восстанавливаем (конфиг на диске стар).
            final ok = await _controller.saveParsedConfig(config);
            if (!ok) _subController.configDirty = true;
            setState(() {});
          }
        }
      }
    } catch (e) {
      // §101 review: throw из HomeController.init() (PlatformException из
      // getVpnStatus и т.п.) или saveParsedConfig не должен убивать метод —
      // ниже единственный call-site AutoUpdater.start() во всём app.
      // Bootstrap скипается, работаем с прежним конфигом.
      AppLog.I.error('Bootstrap skipped: ${humanizeError(e)}');
    } finally {
      // §101 — AutoUpdater после bootstrap'а: его appStart-fetch'и персистят
      // настройки (mtime bump) и не должны попадать в окно сборки конфига.
      // mounted-guard: после dispose (autoUpdater остановлен) не рестартуем.
      if (mounted) _autoUpdater.start();
    }
  }

  Future<void> _loadHapticPref() async {
    await HapticService.I.loadFromPrefs();
  }

  @override
  void dispose() {
    // Порядок: сначала отменяем side-effects (timer, listener),
    // потом сами владельцы (autoUpdater имеет ref на subController,
    // controller имеет ref на autoUpdater — dispose в обратном порядке
    // созданию).
    final idleRetry = _idleRetryListener;
    if (idleRetry != null) {
      _subController.removeListener(idleRetry);
      _idleRetryListener = null;
    }
    _updateCheckTimer?.cancel(); // §141 P1.9f
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

  // §216 — когда app ушёл в настоящий фон (для замера длительности сна).
  DateTime? _pausedAt;
  static const _bgSnackThreshold = Duration(seconds: 30);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
      _maybeShowSupport();
      _maybeShowResumeSnack(); // §216
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // §141 P0.2 — фон: гасим heartbeat-таймер (resident-drain). Resume вернёт
      // его через onAppResumed. `inactive` НЕ трогаем — это короткие transient
      // переходы (шторка, звонок, app-switcher preview), не настоящий фон.
      _pausedAt = DateTime.now(); // §216
      _controller.onAppPaused();
    }
  }

  // §216 — после ДОЛГОГО фона (> порога) при активном туннеле показываем
  // ненавязчивый SnackBar: стрим/heartbeat поднимаются после сна. Короткие
  // переходы (шторка/switcher) порога не достигают → без спама.
  void _maybeShowResumeSnack() {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return;
    if (DateTime.now().difference(pausedAt) < _bgSnackThreshold) return;
    if (!_controller.state.tunnelUp) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Resumed — syncing tunnel…'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // §105 — состояние показа support-диалога (за процесс).
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  SupportMessage? _supportMsg;
  bool _supportFetchTried = false;
  bool _supportShown = false;
  bool _supportInFlight = false;

  /// §105 — показ «поддержи автора» при открытии HOME, когда пользователь
  /// реально пользуется: app на переднем плане, туннель активен, текущая
  /// сессия (`now − connectedSince`) ≥ `min_session_minutes` И суммарное
  /// время ≥ `min_active_hours`. Вызывается из app-resume и из
  /// `_onControllerChange` (тикает ~раз/сек при connected) — гейт ловит
  /// момент, когда сессия дорастает до порога, пока экран открыт.
  /// Терминальный (`_supportShown`) — один показ за процесс; fetch — однократ.
  Future<void> _maybeShowSupport() async {
    if (_supportShown || _supportInFlight || !mounted) return;
    if (_lifecycle != AppLifecycleState.resumed) return;
    final since = _controller.state.connectedSince;
    if (since == null) return; // туннель не активен — гейт «пользуется сейчас»
    _supportInFlight = true;
    try {
      if (!_supportFetchTried) {
        _supportFetchTried = true; // одна попытка fetch за процесс
        _supportMsg = await SupportMessageService.I.fetchOrCached();
      }
      final m = _supportMsg;
      if (m == null || !mounted) return;
      final session = DateTime.now().difference(since).inSeconds;
      final ok = await SupportMessageService.I
          .shouldShow(m, currentSessionSeconds: session);
      if (!ok || _supportShown || !mounted) return;
      _supportShown = true;
      await showSupportDialog(context, m);
    } finally {
      _supportInFlight = false;
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
                  // §116 — таймер теперь в BannerStack; здесь только clear.
                  errorTimerOnDismiss: _controller.clearError,
                  onStartWithAutoRefresh: () =>
                      unawaited(_startWithAutoRefresh()),
                  onRebuildAndClearDirty: _rebuildAndClearDirty,
                  onRebuildAndReconnect: _rebuildAndReconnect,
                  onRebuildAndStart: _rebuildAndStart,
                ),
                // §095 Filter mode — при открытой фильтр-панели прячем
                // стат-полосу + Nodes-хедер, освобождая зону под ноды.
                if (state.tunnelUp && !_filter.panelExpanded)
                  TrafficBar(state: state, controller: _controller),
                if (_subController.busy && _subController.progressMessage.isNotEmpty)
                  ProgressBanner(message: _subController.progressMessage),
                // §095 — NODES-строка только когда подключено И фильтр закрыт.
                // STOP-режим: нод нет → фильтровать нечего → строку прячем.
                if (state.tunnelUp && !_filter.panelExpanded) ...[
                  const SizedBox(height: 12),
                  NodesHeader(
                    controller: _controller,
                    subController: _subController,
                    filter: _filter,
                    onSortLongPress: () =>
                        showSortOptionsMenu(context, _controller),
                  ),
                  const SizedBox(height: 4),
                ],
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
                rowKeyFor: _nodeRowKey, // §203
                onSelectServer: _scrollToNode, // §203
                onViewPool: _showPool, // §208
              ),
            ],
          ),
        );
      },
    );
  }


  /// Rebuild config → reconnect (если up) или start (если down). §107:
  /// dirty-флаг сбрасывает только успешный rebuild (внутри `_rebuildConfig`);
  /// при ошибке reconnect идёт со старым конфигом, banner остаётся.
  Future<void> _rebuildAndReconnect() async {
    await _rebuildConfig();
    if (!mounted) return;
    await _controller.reconnect();
  }

  /// Off-state: rebuild then start. Используется как default когда VPN off.
  Future<void> _rebuildAndStart() async {
    await _rebuildConfig();
    if (!mounted) return;
    await _controller.start();
    // §166 — snackbar ошибки теперь централизован в _onControllerChange
    // (любой источник lastError → всплывашка снизу). Здесь дубль убран.
  }

  Future<void> _startWithAutoRefresh() async {
    // Если уже активен VPN другого приложения — наш старт молча отзовёт его
    // (onRevoke). Спросим подтверждение перед перебиванием чужого туннеля.
    // Только для ручного старта из UI; фоновые точки (tile/automation) не трогаем.
    if (await _vpn.isForeignVpnActive()) {
      if (!mounted) return;
      final ok = await showForeignVpnDialog(context);
      if (ok != true) return;
    }
    // §107 гейт: pending-изменения или пересборка в полёте — сначала довести
    // конфиг на диске до актуального, потом стартовать. При ошибке сборки
    // (configDirty остаётся true) стартуем со старым конфигом — banner
    // продолжает гореть. Lock §037: generateConfig вернёт null silently,
    // стартуем с pinned-конфигом.
    final inFlight = _rebuildInFlight;
    if (inFlight != null) await inFlight;
    if (_subController.configDirty) await _rebuildAndClearDirty();
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

  /// §107 single-flight: параллельные триггеры (возврат на home + гейт на
  /// Start) делят одну пересборку. Dirty-флаг сбрасывает только успешный
  /// generate+save внутри `_rebuildConfig`.
  Future<void> _rebuildAndClearDirty() {
    return _rebuildInFlight ??= () async {
      try {
        await _rebuildConfig();
        if (mounted) setState(() {});
      } finally {
        _rebuildInFlight = null;
      }
    }();
  }

  /// §076/§107: callback зарегистрированный в `homeReturnObserver`.
  /// Срабатывает когда юзер вернулся на home (root route стал top). Если
  /// есть pending changes — пересобираем lazy (всегда автоматически;
  /// настройка `auto_rebuild` удалена в §107). Staged-кэш (§107) к этому
  /// моменту уже содержит мутации экрана — гонки с dispose-flush'ем нет.
  void _onReturnToHome() {
    if (!mounted) return;
    if (!_subController.configDirty) return;
    if (_subController.busy) {
      // §107 (R3): сейчас не запустить (fetch/rebuild в полёте) — догнать,
      // когда controller освободится, не теряя триггер.
      _retryRebuildWhenIdle();
      return;
    }
    unawaited(_rebuildAndClearDirty());
  }

  /// §107 (R3): one-shot подписка — на первом `!busy` перепроверяем
  /// configDirty и догоняем pending rebuild.
  void _retryRebuildWhenIdle() {
    if (_idleRetryListener != null) return;
    void listener() {
      if (_subController.busy) return;
      _subController.removeListener(listener);
      _idleRetryListener = null;
      if (!mounted || !_subController.configDirty) return;
      unawaited(_rebuildAndClearDirty());
    }

    _idleRetryListener = listener;
    _subController.addListener(listener);
  }

  /// Только пересборка конфига — без HTTP-fetch'а подписок. За fetch
  /// отвечает AutoUpdater (по 4 триггерам) и manual ⟳ на Servers.
  ///
  /// §107: `configDirty` сбрасывает успешная генерация (`generateConfig`,
  /// до записи на диск); если save не состоялся — восстанавливаем флаг,
  /// конфиг на диске остался старым.
  Future<bool> _rebuildConfig() async {
    final config = await _subController.generateConfig();
    if (config == null) return false;
    if (!mounted) {
      _subController.configDirty = true;
      return false;
    }
    final ok = await _controller.saveParsedConfig(config);
    if (!ok) {
      _subController.configDirty = true;
      return false;
    }
    if (mounted) {
      final nodeCount = ParsedConfig.parse(config).nodeCount;
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
    return true;
  }
}
