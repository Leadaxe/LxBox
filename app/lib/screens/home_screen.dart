import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/home_state.dart';
import '../models/validation.dart';
import '../services/app_log.dart';
import '../services/error_humanize.dart';
import '../services/support/active_time_tracker.dart';
import '../services/support/support_message.dart';
import '../services/support/support_nav.dart';
import '../services/version_info.dart';
import 'about_screen.dart';
import 'app_settings_screen.dart';
import 'config_screen.dart';
import 'debug_screen.dart';
import 'dns_settings_screen.dart';
import 'home/support_message_screen.dart';
import 'routing_screen.dart';
import 'settings_screen.dart';
import 'speed_test_screen.dart';
import 'stats_screen.dart';
import 'home/widgets/detour_cycle_sheet.dart';
import 'home/widgets/traffic_bar.dart';
import 'owner_navigation.dart';
import 'subscriptions_screen.dart';
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
import '../services/settings_storage.dart';
import '../services/rule_set_auto_updater.dart';
import '../services/subscription/auto_updater.dart';
import '../services/update_checker.dart';
import '../vpn/box_vpn_client.dart';
import '../services/l10n/locale_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final HomeController _controller;
  late final SubscriptionController _subController;
  late final AutoUpdater _autoUpdater;

  /// §366 — авто-обновление кэшированных rule-set'ов по TTL.
  late final RuleSetAutoUpdater _ruleSetAutoUpdater;

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

  /// §208 — попап с составом пула round_robin-Направления по его auto-тегу.
  /// Title = label Направления (из groupLabels по базовому tag `<base>-auto`).
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

  /// §338 — авто-применение в полёте: воронка пересобирает при включённой
  /// галке. На это окно (rebuild + reload, ~1–3с) розовая плашка подавляется —
  /// иначе она честно мигает между saveParsedConfig (взвёл флаг) и
  /// завершением reload'а (снял), что читается как «галка не работает».
  bool _autoApplying = false;

  /// §107 (R3): one-shot listener «subController освободился — догнать
  /// pending rebuild», см. [_retryRebuildWhenIdle].
  VoidCallback? _idleRetryListener;

  /// §141 P1.9f — one-shot update-check таймер (5с после старта). Хранится,
  /// чтобы отменить в `dispose()`: `mounted`-guard в колбэке и так
  /// нейтрализует поздний выстрел, но висящий таймер — лишний (гигиена).
  Timer? _updateCheckTimer;

  // §085 R3 — весь node-filter state (§048 regex/protocols/subscriptions/
  // ping + show-detour/show-non-matching + §083 per-direction memory)
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
  UiMsg? _prevError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Порядок: subController first → AutoUpdater видит entries,
    // HomeController holds AutoUpdater для VPN-transitions callback.
    _subController = SubscriptionController();
    _autoUpdater = AutoUpdater(_subController);
    _subController.bindAutoUpdater(_autoUpdater);
    // §366 — авто-обновление rule-set'ов. Создаём до HomeController: он
    // держит ссылку и дёргает `onVpnConnected` на transition.
    _ruleSetAutoUpdater = RuleSetAutoUpdater();
    _controller = HomeController(
      autoUpdater: _autoUpdater,
      ruleSetAutoUpdater: _ruleSetAutoUpdater,
    );
    // §366 — обновившийся `.srs` меняет содержимое конфига (путь тот же, но
    // ядро читает файл при старте) → пересобрать. Без reload: рвать рабочий
    // туннель ради обновлённого списка блокировок не стоит, новый файл
    // подхватится на ближайшем старте.
    _ruleSetAutoUpdater.bindOnChanged(
        () => _reactToSubscriptionUpdate(reload: false));
    // §323 — реакция на авто-обновление подписки. Привязываем ПОСЛЕ создания
    // HomeController (замыкание держит `_controller`, до этой строки его нет).
    _autoUpdater.bindOnUpdateReaction(_reactToSubscriptionUpdate);
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
    // §356 — нативный аптайм туннеля как источник счётчика наработки:
    // переживает смахивание приложения, недостающее доливается при возврате.
    ActiveTimeTracker.I.uptimeMsProvider = _vpn.getTunnelUptimeMs;
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
    // §366 — первая проверка TTL rule-set'ов через 30с после старта.
    _ruleSetAutoUpdater.start();
    unawaited(_loadHapticPref());
    // Track tunnel transitions для side-effect'ов (SnackBar при revoke,
    // animation для connecting, auto-dismiss timer для lastError).
    // AnimatedBuilder уже rebuildит UI на notifyListeners; listener здесь
    // нужен только для эффектов вне build-фазы.
    _prevTunnel = _controller.state.tunnel;
    _prevError = _controller.state.lastError;
    _controller.addListener(_onControllerChange);
    // §274 — «Направление не нашёл узлов» после сборки конфига → транзиентный
    // SnackBar (паттерн §166: всплывашка снизу, не баннер).
    _prevNoNodesStamp = _subController.directionsWithoutNodesStamp;
    _subController.addListener(_onDirectionsWithoutNodes);
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
    // Update check (§036 + §390): снек показываем ТОЛЬКО из кеша, на старте.
    // Сетевой fetch (через 5 сек, throttled 24h) снек НЕ поднимает — его
    // результат ложится в `last_known_version` и всплывёт на следующем
    // запуске, где его подхватит hydrate(). Так уведомление никогда не
    // выскакивает поверх работающего приложения.
    unawaited(_hydrateAndMaybeNotify());
    _updateCheckTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      unawaited(
        UpdateChecker.I.maybeCheck(localVersion: VersionInfo.I.version),
      );
    });
  }

  /// §390 — единственная точка показа update-снека: кеш `last_known_version`
  /// на старте. `UpdateChecker.latest` при этом продолжает жить для About-блока
  /// и §047-эмиттера, но слушателя-показывателя у него больше нет.
  bool _updateSnackbarShown = false;
  Future<void> _hydrateAndMaybeNotify() async {
    await UpdateChecker.I.hydrate(localVersion: VersionInfo.I.version);
    final info = UpdateChecker.I.latest.value;
    if (info == null) return;
    if (_updateSnackbarShown) return;
    if (!mounted) return;
    // Флаг `_updateSnackbarShown` выставляется через `onShown` callback ровно
    // когда SnackBar реально показывается.
    await maybeShowUpdateSnackbar(
      context,
      info,
      onShown: () => _updateSnackbarShown = true,
    );
  }

  /// §274 — сборка конфига нашла Направления с фильтром-без-совпадений (Направление
  /// схлопнулся в block): исчезающая всплывашка снизу. Дедуп по stamp —
  /// один показ на сборку.
  int _prevNoNodesStamp = 0;
  void _onDirectionsWithoutNodes() {
    final stamp = _subController.directionsWithoutNodesStamp;
    if (stamp == _prevNoNodesStamp) return;
    _prevNoNodesStamp = stamp;
    final names = _subController.directionsWithoutNodes;
    if (names.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final msg = names.length == 1
          ? getLocalText.s("Direction \"%s\" matched no nodes — check its node filter.", names.first)
          : getLocalText.plural("%d directions matched no nodes — check their node filters.", names.length);
      // Без hideCurrentSnackBar: этот показ соседствует с actionable-снеками
      // того же rebuild-флоу («Config rebuilt … restart VPN», heal-счётчики)
      // — гасить их нельзя, встаём в очередь ScaffoldMessenger.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ));
    });
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

    // §050 — location-permission stop → AlertDialog with "Open Settings"
    // button instead of plain error. Background: ACCESS_BACKGROUND_LOCATION
    // on API 30+ can only be granted through Settings (not via runtime
    // permission dialog), so we explain and offer button. §279 — native
    // string protocol parsed into typed StopReason at ingestion
    // (HomeController), no string surgery here.
    final nowReason = state.stopReason;
    if (nowError != _prevError &&
        nowReason is StopPermissionLocation &&
        !_permissionDialogShowing) {
      _permissionDialogShowing = true;
      final permName = nowReason.permissions;
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
        nowError != null &&
        nowReason is! StopPermissionLocation) {
      final msg = nowError;
      _controller.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(msg.render()),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ));
      });
    }

    // §083 — per-direction match-filter memory. Направление сменилось → save старого
    // + restore нового. ViewModel сам guard'ит no-op и notify'ит только при
    // реальной смене (→ _onFilterChanged → setState).
    _filter.syncDirection(state.selectedGroup);

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

    // §357 — Debug API `/support/preview`: одноразовый запрос немедленного
    // показа сообщения вне гейтов ленты (пороги/очередь/туннель не важны).
    final preview = _controller.takeSupportPreview();
    if (preview != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_pushSupportMessage(
          preview.feed,
          preview.message,
          dryRun: preview.dryRun,
        ));
      });
    }

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
          //
          // §338 — через общую воронку, а не голый generate+save: VpnService
          // переживает kill приложения, так что холодный старт с dirty при
          // ЖИВОМ туннеле реален — и хук автоприменения должен сработать и
          // здесь, иначе розовая плашка переживает включённую галку.
          // Внутри тот же generateConfig + saveParsedConfig + §107-restore.
          await _rebuildAndClearDirty(silent: true);
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      // §101 review: throw из HomeController.init() (PlatformException из
      // getVpnStatus и т.п.) или saveParsedConfig не должен убивать метод —
      // ниже единственный call-site AutoUpdater.start() во всём app.
      // Bootstrap скипается, работаем с прежним конфигом.
      AppLog.I.error('Bootstrap skipped: ${humanizeError(e).renderEn()}');
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
    _subController.removeListener(_onDirectionsWithoutNodes);
    WidgetsBinding.instance.removeObserver(this);
    homeReturnObserver.clearHandler();
    _autoUpdater.dispose();
    _ruleSetAutoUpdater.dispose();
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
      _ruleSetAutoUpdater.onAppResumed(); // §366
      // §291 — досмотреть подписки на возврате из фона: periodic-таймер спит
      // вместе с замороженным процессом (свёрнут + VPN off), так что вечером
      // «обновлено 14ч назад». Не блокирует resync; `_running`/min-retry сами
      // защищают от частых сворачиваний, тумблер/updateIntervalHours==0 чтит.
      unawaited(_autoUpdater.maybeUpdateAll(UpdateTrigger.resumed));
      _maybeShowSupport();
      _maybeShowResumeSnack(); // §216
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // §141 P0.2 — фон: гасим heartbeat-таймер (resident-drain). Resume вернёт
      // его через onAppResumed. `inactive` НЕ трогаем — это короткие transient
      // переходы (шторка, звонок, app-switcher preview), не настоящий фон.
      _pausedAt = DateTime.now(); // §216
      _controller.onAppPaused();
      // §366 — в фоне rule-set'ы не качаем: отменяем запланированную проверку.
      _ruleSetAutoUpdater.onAppPaused();
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
      SnackBar(
        content: Text(getLocalText.s("Resumed — syncing tunnel…")),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // §105/§356 — состояние показа support-ленты (за процесс).
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  SupportFeed? _supportFeed;
  DateTime? _supportNextFetchAt;
  bool _supportShown = false;
  bool _supportInFlight = false;

  /// §105/§356 — показ очередного сообщения ленты «поддержи автора» при
  /// открытии HOME, когда пользователь реально пользуется: app на переднем
  /// плане, туннель активен, текущая сессия (`now − connectedSince`) ≥
  /// `min_session_minutes` И наработка от baseline ≥ `min_active_hours`
  /// (выбор — `SupportMessageService.nextToShow`). Вызывается из app-resume
  /// и из `_onControllerChange` (тикает ~раз/сек при connected) — гейт ловит
  /// момент, когда сессия дорастает до порога, пока экран открыт.
  /// Терминальный (`_supportShown`) — один показ за процесс; fetch — однократ.
  Future<void> _maybeShowSupport() async {
    if (_supportShown || _supportInFlight || !mounted) return;
    if (_lifecycle != AppLifecycleState.resumed) return;
    final since = _controller.state.connectedSince;
    if (since == null) return; // туннель не активен — гейт «пользуется сейчас»
    _supportInFlight = true;
    try {
      // §356 — fetch до первого успеха, с бэкоффом 30с. Одна попытка за
      // процесс сгорала бы ровно в самый ненадёжный момент: первый тик
      // connected, когда туннель поднят, но нода ещё не пропускает трафик
      // (device-verified на эмуляторе) — и лента молчала до перезапуска.
      if (_supportFeed == null) {
        final next = _supportNextFetchAt;
        if (next != null && DateTime.now().isBefore(next)) return;
        _supportNextFetchAt =
            DateTime.now().add(const Duration(seconds: 30));
        _supportFeed = await SupportMessageService.I.fetchOrCached();
      }
      final feed = _supportFeed;
      if (feed == null || !mounted) return;
      final session = DateTime.now().difference(since).inSeconds;
      final m = await SupportMessageService.I
          .nextToShow(feed, currentSessionSeconds: session);
      if (m == null || _supportShown || !mounted) return;
      _supportShown = true;
      await _pushSupportMessage(feed, m);
    } finally {
      _supportInFlight = false;
    }
  }

  /// §357 — полноэкранный показ сообщения ленты (вместо AlertDialog).
  Future<void> _pushSupportMessage(
    SupportFeed feed,
    SupportMessage m, {
    bool dryRun = false,
  }) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SupportMessageScreen(
        feed: feed,
        message: m,
        dryRun: dryRun,
        buildScreen: _buildSupportScreen,
      ),
    ));
  }

  /// §357 — резолв lxbox-действия в экран приложения. null → кнопка
  /// скрывается (незнакомый маршрут у старой версии / гейт не прошёл).
  /// Контроллеры живут здесь — по той же причине, по которой экраны строит
  /// HomeDrawer.
  Widget? _buildSupportScreen(SupportLinkAction a) {
    if (a.action == 'add') {
      // Prefill поля ввода — добавление подтверждает сам юзер (§357: без
      // авто-add, support.json приезжает с GitHub).
      return SubscriptionsScreen(
        subController: _subController,
        homeController: _controller,
        autoUpdater: _autoUpdater,
        initialInput: a.payload,
      );
    }
    if (a.action != 'route') return null;
    final segs = routeSegments(a);
    final tab = segs.length > 1 ? segs[1] : null;
    switch (segs.first) {
      case 'servers':
        return SubscriptionsScreen(
          subController: _subController,
          homeController: _controller,
          autoUpdater: _autoUpdater,
        );
      case 'routing':
        return RoutingScreen(
          subController: _subController,
          homeController: _controller,
          initialPresetsTab: tab == 'presets',
        );
      case 'dns':
        return DnsSettingsScreen(
          subController: _subController,
          homeController: _controller,
        );
      case 'vpn-settings':
        return SettingsScreen(
          subController: _subController,
          homeController: _controller,
        );
      case 'app-settings':
        return AppSettingsScreen(
          initialTab: switch (tab) {
            'subscriptions' => 1,
            'diagnostics' => 2,
            'automation' => 3,
            _ => 0,
          },
        );
      case 'speedtest':
        return SpeedTestScreen(homeController: _controller);
      case 'stats':
        // Как пункт drawer: без поднятого туннеля данных нет — кнопку прячем.
        if (!_controller.state.tunnelUp) return null;
        return StatsScreen(
          configRaw: _controller.state.activeConfigRaw,
          subController: _subController,
          homeController: _controller,
          initialTab: switch (tab) {
            'connections' => StatsTab.connections,
            'live' => StatsTab.live,
            _ => StatsTab.overview,
          },
        );
      case 'config':
        return ConfigScreen(controller: _controller);
      case 'debug':
        return DebugScreen(
          initialTab: switch (tab) {
            'crashes' => 1,
            'oom' => 2,
            'profiling' => 3,
            _ => 0,
          },
        );
      case 'about':
        // `about/donate` — экран About с сразу открытым попапом способов
        // поддержки (донат — состояние экрана, а не отдельный экран).
        return AboutScreen(openDonate: tab == 'donate');
      case 'profiler':
        // Семантический алиас: трафик-профайлер («куда ходят приложения») —
        // вкладка Live на Statistics (§264-266). НЕ Debug/Profiling: там
        // pprof-слепки ядра, другая фича. Гейт как у stats.
        if (!_controller.state.tunnelUp) return null;
        return StatsScreen(
          configRaw: _controller.state.activeConfigRaw,
          subController: _subController,
          homeController: _controller,
          initialTab: StatsTab.live,
        );
    }
    return null;
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
        // §328 — «нет серверов» считается по payload-нодам (конфиг + entries),
        // а не по наличию файла конфига: шаблонная сборка при нуле серверов
        // оставляет configRaw непустым навсегда. `e.nodeCount` — персистентный
        // кэш: у подписок `list.nodes` до rehydration пуст, по нему одному
        // гайд мигал бы на каждом старте.
        final showEmptyGuide = showAddServerGuide(
          tunnelUp: state.tunnelUp,
          configEmpty: state.configRaw.isEmpty,
          configNodeCount: state.configModel.nodeCount,
          anyServerNodes: _subController.entries
              .any((e) => e.nodeCount > 0 || e.list.nodes.isNotEmpty),
        );
        return Scaffold(
          // l10n-exempt: brand name, идентичен во всех локалях
          appBar: AppBar(title: const Text('L×Box')),
          drawer: HomeDrawer(
            controller: _controller,
            subController: _subController,
            autoUpdater: _autoUpdater,
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Empty state (§328 — нет серверов, не «нет конфига») → guide +
              // CTA берёт на себя весь экран; controls/header не рисуем,
              // чтобы disabled-кнопка не путала первого пользователя.
              if (state.configRaw.isNotEmpty && !showEmptyGuide) ...[
                HomeControls(
                  controller: _controller,
                  subController: _subController,
                  presenter: _nodeList,
                  autoApplying: _autoApplying, // §338

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
                  TrafficBar(
                    state: state,
                    controller: _controller,
                    subController: _subController,
                  ),
                if (_subController.busy &&
                    _subController.progressMessage != null)
                  ProgressBanner(
                      message:
                          _subController.progressMessage!.render()),
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
                showEmptyGuide: showEmptyGuide,
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
    // §254 — reconnect при VPN off = фактический старт (reconnect делегирует
    // start); при VPN up новый конфиг не собран, reconnect поехал бы на старом
    // с диска. Оба — тихая подмена: показываем sheet, дальше не идём.
    if (_showDetourCycleSheetIfAny()) return;
    await _controller.reconnect();
  }

  /// Off-state: rebuild then start. Используется как default когда VPN off.
  Future<void> _rebuildAndStart() async {
    await _rebuildConfig();
    if (!mounted) return;
    // §254 — detour-цикл в пересборке: новый конфиг не собран, а старт со
    // старым с диска был бы тихой подменой. Показываем sheet с виновниками
    // и не стартуем — юзер устраняет причину сам.
    if (_showDetourCycleSheetIfAny()) return;
    await _controller.start();
    // §166 — snackbar ошибки теперь централизован в _onControllerChange
    // (любой источник lastError → всплывашка снизу). Здесь дубль убран.
  }

  /// §254 — если последняя генерация упала на detour-цикле, показывает
  /// bottom sheet со списком нод-виновников. true = показан (старт прервать).
  bool _showDetourCycleSheetIfAny() {
    final cycles =
        _subController.lastFatalIssues.whereType<DetourCycle>().toList();
    if (cycles.isEmpty) return false;
    unawaited(showDetourCycleSheet(context, cycles,
        onCulpritTap: _goToCulpritOwner));
    return true;
  }

  /// §255 — тап по ноде-виновнику в sheet: закрыть sheet и открыть экран
  /// владельца. Сама навигация (папка+подсветка / подписка / одиночный /
  /// Направление) — общий §258 `openTagOwner`. Владелец не найден (custom JSON) →
  /// открываем список Servers как fallback.
  void _goToCulpritOwner(String culpritTag) {
    Navigator.of(context).pop(); // закрыть sheet
    unawaited(openTagOwner(
      context,
      culpritTag,
      subController: _subController,
      homeController: _controller,
      onOwnerNotFound: () {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SubscriptionsScreen(
            subController: _subController,
            homeController: _controller,
            autoUpdater: _autoUpdater,
          ),
        ));
      },
    ));
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
    if (!mounted) return;
    // §254 — detour-цикл в свежей пересборке → sheet + отмена старта (см.
    // _rebuildAndStart).
    if (_showDetourCycleSheetIfAny()) return;
    // Обновление подписок теперь через AutoUpdater (см. services/subscription/
    // auto_updater.dart) — 4 триггера, общая логика. При Start никакого
    // синхронного HTTP-fetch'а не делаем: если подписки протухли, trigger 2
    // (VPN connected + 2 мин) подтянет их через туннель.
    await _controller.start();
    // §219 — inline error-snackbar удалён: он был мёртвым кодом. start()
    // эмитит lastError через _emit→notifyListeners→_onControllerChange, который
    // СИНХРОННО показывает snackbar и зовёт clearError() до возврата сюда →
    // lastError.isNotEmpty здесь всегда false. Ошибки централизованы в
    // _onControllerChange (см. коммент §166 выше).
  }

  /// §107 single-flight: параллельные триггеры (возврат на home + гейт на
  /// Start) делят одну пересборку. Dirty-флаг сбрасывает только успешный
  /// generate+save внутри `_rebuildConfig`.
  ///
  /// §323 — `silent` действует только на пересборку, которую этот вызов
  /// реально запустил. Присоединиться к чужой (уже летящей) и переубедить её
  /// молчать нельзя — snackbar там уже запланирован её инициатором. Для
  /// авто-обновления это верно по смыслу: юзер в тот момент что-то нажимал,
  /// его пересборка и отчитывается.
  Future<void> _rebuildAndClearDirty({bool silent = false}) {
    return _rebuildInFlight ??= () async {
      try {
        // §338 — одно чтение флага на пересборку: и текст snackbar'а, и хук
        // ниже должны судить по одному значению (иначе юзер прочтёт
        // «перезагружаю», а галку он снял между двумя чтениями).
        final autoReload = await SettingsStorage.getAutoReloadOnChange();
        if (!mounted) return;
        // §338 — подавить розовую плашку на окно применения (см. поле).
        if (autoReload) setState(() => _autoApplying = true);
        final ok = await _rebuildConfig(silent: silent, autoReload: autoReload);
        if (mounted) setState(() {});
        // §338 — единственная воронка всех путей пересборки (возврат на home
        // §076, retry-when-idle §107, реакция подписки §323, гейт на Start,
        // bootstrap). Хук здесь, а не на 25+ сайтах `configDirty = true`: тот
        // флаг живёт статикой в SettingsStorage (§113) и notifyListeners не
        // даёт.
        if (ok && autoReload) await _maybeAutoReload();
      } finally {
        _rebuildInFlight = null;
        if (_autoApplying && mounted) setState(() => _autoApplying = false);
        _autoApplying = false;
      }
    }();
  }

  /// §338 — автоперезапуск VPN при смене настроек. Применяем ТОЛЬКО когда есть
  /// что применять: туннель поднят и §324-вердикт сказал, что saved разошёлся с
  /// running (`fresh` → ядро уже на этом конфиге, рвать незачем). Саму галку
  /// проверяет вызывающий (`_rebuildAndClearDirty`) — там же, откуда её значение
  /// уходит в текст snackbar'а. Дальше `reloadVpn` со своим `canReload`:
  /// cooldown 3с, гейт на не-connected и сброс `configChangedNeedRestart` при
  /// успехе (§323 fix).
  Future<void> _maybeAutoReload() async {
    if (!mounted) return;
    final state = _controller.state;
    // Туннель лежит — «перезапуск» ≠ «запуск»: конфиг подхватится на Start.
    if (!state.tunnelUp) return;
    if (!state.configChangedNeedRestart) {
      AppLog.I.debug('§338: reload skipped — config identical to running');
      return;
    }
    // §338 — cooldown-гейт reloadVpn (3с) молча глотает вызов; для авто-пути
    // это значит «применение пропало без следа». Логируем причину явно —
    // плашка, оставшаяся из-за скипа, перестаёт быть загадкой. Флаг остаётся
    // взведённым, плашка после окна подавления — честный fallback.
    if (!_controller.canReload) {
      AppLog.I.warning(
          '§338: reload skipped — cooldown/not-connected, banner stays');
      return;
    }
    AppLog.I.info('§338: auto-reload on settings change');
    await _controller.reloadVpn();
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

  /// §323 — реакция на успешное авто-обновление подписки. Привязана в
  /// `initState` через `AutoUpdater.bindOnUpdateReaction`; зовётся один раз за
  /// проход апдейтера (не на каждую подписку).
  ///
  /// `reload=false` (режим `rebuild`, дефолт): пересобрать и записать. Туннель
  /// продолжает крутить старый конфиг, плашка «restart to apply» остаётся —
  /// применяет юзер.
  ///
  /// `reload=true` (режим `reload`): то же плюс in-place reload ядра. Гейт:
  /// reload'им ТОЛЬКО когда saved config реально разошёлся с running. Диff
  /// живёт в `saveParsedConfig` (§116) и после него виден как
  /// `configChangedNeedRestart`; провайдер, отдавший тот же список нод, даёт
  /// `changed=false` → флаг погашен → рвать туннель незачем.
  Future<void> _reactToSubscriptionUpdate({required bool reload}) async {
    if (!mounted) return;
    // Пересборка `silent`: юзер ничего не нажимал, snackbar был бы шумом.
    //
    // §331 (ревью) — чужую пересборку в полёте ждём, но своей НЕ пропускаем.
    // Чужая могла прочитать storage ДО того, как фетч записал новые ноды:
    // её generateConfig собрал старый состав и по завершении сбросил
    // configDirty — изменение подписки молча терялось, а reload ниже толкнул
    // бы ядру устаревший конфиг. Проверить это по configDirty после await
    // нельзя (сброс идёт ПОСЛЕ генерации — флаг уже чист), поэтому просто
    // пересобираем сами: если чужая всё же успела взять свежие ноды, наша
    // даст changed=false и обойдётся без побочных эффектов.
    final inFlight = _rebuildInFlight;
    if (inFlight != null) {
      await inFlight;
      if (!mounted) return;
    }
    await _rebuildAndClearDirty(silent: true);
    if (!mounted) return;
    // §338 — при включённой галке reload уже сделал хук внутри
    // `_rebuildAndClearDirty` (и погасил флаг). Свой путь не нужен: гейт ниже
    // всё равно отсеял бы его, но зависеть от порядка гашения не хочется.
    if (!reload) return;
    // Туннель не поднят — reload'ить нечего, конфиг подхватится на Start.
    if (!_controller.state.tunnelUp) return;
    // Гейт «состав не изменился»: пересборка дала конфиг, идентичный
    // работающему. Ядро уже на нём — 3-секундный разрыв был бы ни за что.
    if (!_controller.state.configChangedNeedRestart) {
      AppLog.I.debug('§323: reload skipped — config identical to running');
      return;
    }
    // canReload внутри отсеет cooldown (3с) и не-connected состояние; сброс
    // `configChangedNeedRestart` при успехе тоже там (§323 fix).
    await _controller.reloadVpn();
  }

  /// Только пересборка конфига — без HTTP-fetch'а подписок. За fetch
  /// отвечает AutoUpdater (по 4 триггерам) и manual ⟳ на Servers.
  ///
  /// §107: `configDirty` сбрасывает успешная генерация (`generateConfig`,
  /// до записи на диск); если save не состоялся — восстанавливаем флаг,
  /// конфиг на диске остался старым.
  /// §323 — `silent`: пересборка не по нажатию юзера (авто-обновление
  /// подписки в фоне). Snackbar «Config rebuilt: N nodes» в этом случае —
  /// шум: юзер ничего не нажимал, а всплывашка раз в час раздражает не
  /// меньше плашки, из-за которой §323 и затевался.
  ///
  /// §338 — `autoReload`: галка «автоперезапуск при смене настроек» включена.
  /// Влияет только на ТЕКСТ snackbar'а: сам reload делает `_maybeAutoReload`
  /// после нас. Читается вызывающим (одно чтение storage на пересборку), чтобы
  /// текст и хук судили по одному значению.
  Future<bool> _rebuildConfig({
    bool silent = false,
    bool autoReload = false,
  }) async {
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
    if (mounted && !silent) {
      final nodeCount = ParsedConfig.parse(config).nodeCount;
      // §338 — при включённой галке звать юзера перезапускать VPN нельзя: это
      // сделает `_maybeAutoReload` сразу после нас. Текст должен отчитаться о
      // применении, а не просить действия. `willAutoReload` — то же условие,
      // что в самом хуке (галка + туннель up + конфиг разошёлся с running).
      //
      // §338 (device-скрин 02.08) — «restart VPN to apply» показываем ТОЛЬКО
      // при needRestart: до этого ветка (tunnelUp, !willAutoReload) звала
      // перезапускать и при changed=false — конфиг идентичен работающему,
      // применять нечего, текст врал. Ложь древняя (до §338 текст при живом
      // туннеле был безусловным), галка её лишь высветила.
      final needRestart = _controller.state.configChangedNeedRestart;
      final willAutoReload =
          autoReload && _controller.state.tunnelUp && needRestart;
      // configChangedNeedRestart выставляется внутри saveParsedConfig,
      // AnimatedBuilder переотрисует через _needsRestart getter.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !_controller.state.tunnelUp || !needRestart
                ? getLocalText.plural("Config rebuilt: %d nodes", nodeCount)
                : willAutoReload
                    ? getLocalText.plural(
                        "Config rebuilt: %d nodes — reloading VPN", nodeCount)
                    : getLocalText.plural(
                        "Config rebuilt: %d nodes — restart VPN to apply",
                        nodeCount),
          ),
        ),
      );
    }
    return true;
  }
}
