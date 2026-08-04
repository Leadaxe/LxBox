import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/route_config.dart';
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import '../config/config_parse.dart';
import '../models/channel.dart' show UrltestMode;
import '../models/home_state.dart';
import '../services/app_log.dart';
import '../services/automation/event_emitter.dart';
import '../services/config_staleness.dart';
import '../services/error_format.dart';
import '../services/file_import.dart';
import '../services/probe/probe_lifecycle.dart';
import '../services/rule_name_resolver.dart';
import '../services/selector_info.dart';
import '../services/settings_storage.dart';
import '../services/support/support_message.dart';
import '../services/template_loader.dart';
import '../services/haptic_service.dart';
import '../services/rule_set_auto_updater.dart';
import '../services/subscription/auto_updater.dart';

part 'home_controller/config_io.dart';
part 'home_controller/heartbeat.dart';
part 'home_controller/ping_orchestration.dart';

class HomeController extends ChangeNotifier
    with _ConfigIoMixin, _HeartbeatMixin, _PingMixin {
  HomeController({
    AutoUpdater? autoUpdater,
    RuleSetAutoUpdater? ruleSetAutoUpdater,
  })  : _autoUpdater = autoUpdater,
        _ruleSetAutoUpdater = ruleSetAutoUpdater;

  @override
  final BoxVpnClient _vpn = BoxVpnClient();
  final AutoUpdater? _autoUpdater;

  /// §366 — авто-обновление rule-set'ов. Опционален: тесты и headless-пути
  /// живут без него.
  final RuleSetAutoUpdater? _ruleSetAutoUpdater;
  StreamSubscription<TunnelStatusEvent>? _statusSub;

  /// §122 — единый канал данных от libbox CommandClient (заменил `ClashApiClient`
  /// HTTP-петли). Данные текут push-стримами `status`/`groups`.
  @override
  final CcChannel _cc = CcChannel.instance;

  /// §122 — подписки на push-стримы CommandClient'а. `status` (always-on:
  /// скорость/память/watchdog), `groups` (дерево групп → синтез `proxiesJson`).
  StreamSubscription<CcStatus>? _ccStatusSub;
  StreamSubscription<List<CcGroup>>? _ccGroupsSub;

  /// §193 — resyncForReopen (§185 cold-start) делаем ОДИН раз за жизнь движка.
  /// На реконнектах refcount валиден (тот же движок) → resync только рвал бы
  /// connections-доставку (single-shot, без pull). false на свежем движке.
  bool _didColdStartResync = false;

  /// §125 — кеш tag→label каналов (storage). Кладётся в state.groupLabels для
  /// home-dropdown. Обновляется в init + после правок каналов.
  Map<String, String> _channelLabels = const {};

  /// §208 — auto-теги каналов в режиме round_robin (`<tag>-auto`). Для гейта
  /// пункта «View pool» в меню auto-ноды (показываем только для round_robin —
  /// у least_test пула нет). Обновляется вместе с _channelLabels.
  Set<String> _roundRobinAutoTags = const {};

  /// §322 — auto-теги ВСЕХ каналов (`vpn-N-auto`). Строгий различитель:
  /// ядру и наша группа §322, и двойник канала — одинаковый `urltest`, а
  /// спец-обращение (подмена имени на «✨ Auto», пин в верхнюю секцию)
  /// положено только двойнику. Тег канала генерит билдер, он не совпадает
  /// со сгенерированным из имени тегом группы §322.
  Set<String> _channelAutoTags = const {};

  @override
  HomeState _state = HomeState();
  HomeState get state => _state;

  /// §141 P1.9a — выставляется в `dispose()` (перед `super.dispose()`).
  /// Async-колбэки, переживающие dispose (delayed cooldown в `reloadVpn`,
  /// in-flight future'ы), проверяют флаг перед `notifyListeners()`, иначе
  /// «Bad state: cannot notify listeners after dispose» на hot-reload /
  /// быстрой навигации.
  bool _disposed = false;

  /// UI-only override: при `true` `HomeScreen` рендерит empty-state как
  /// при чистой инсталляции, **не трогая** реальные данные `_state`.
  /// Управляется через Debug API `POST /action/preview-empty-state?on=...`.
  /// Полезно для скриншотов / UX-демо / регресс-тестинга empty-state'ов
  /// без `pm clear` и потери подписок.
  bool _previewEmpty = false;
  bool get previewEmpty => _previewEmpty;
  void setPreviewEmpty(bool on) {
    if (_previewEmpty == on) return;
    _previewEmpty = on;
    notifyListeners();
  }

  /// §357 — одноразовый запрос показа support-сообщения от Debug API
  /// (`POST /support/preview`). Паттерн preview-empty-state: handler кладёт
  /// запрос + notify, home_screen забирает через [takeSupportPreview] и
  /// пушит полноэкранный SupportMessageScreen вне гейтов ленты.
  SupportPreviewRequest? _supportPreview;
  void requestSupportPreview(SupportPreviewRequest req) {
    _supportPreview = req;
    notifyListeners();
  }

  SupportPreviewRequest? takeSupportPreview() {
    final r = _supportPreview;
    _supportPreview = null;
    return r;
  }

  /// Cooldown timestamps для recovery actions (reloadVpn / resetNetwork) —
  /// чтобы юзер не спамил кнопками при тревоге. См. spec 030 / 031.
  DateTime? _lastReloadTap;
  DateTime? _lastResetNetworkTap;
  static const _recoveryCooldown = Duration(seconds: 3);

  /// One-shot timer for auto-ping-on-connect (5s after tunnel up). Отменяется
  /// при disconnect чтобы не стрельнул в уже отключённом состоянии.
  @override
  Timer? _autoPingTimer;

  /// Safety-timeout для transient-состояний (Starting/Stopping): если
  /// native застрял дольше порога — форсим disconnected в UI + force-stop
  /// сервиса (§129). Один Timer на всю жизнь контроллера, cancel'им при любой
  /// смене статуса (чтобы не срабатывал на уже разрешённом состоянии) и
  /// пересоздаём при новой transient-фазе.
  ///
  /// §140 — пороги РАЗДЕЛЕНЫ по фазе. `stopping` завис на 10с → ядро реально не
  /// отдаёт Stopped → force-stop оправдан. `connecting` дольше 15с — это чаще
  /// просто медленный, но ЖИВОЙ старт (сотовая, WARP-gen/AWG handshake), а не
  /// зависон; force-kill убивал бы рабочее подключение. Даём connecting больше.
  ///
  /// §140 — пороги ПЕРЕМЕННЫЕ (не `static const`): инициализируются из дефолтов
  /// ниже, но Debug API (`POST /action/set-transient-timeout` с query
  /// `connecting`/`stopping` в мс) может их переопределить для on-device теста
  /// force-stop'а (например, connecting=500мс, чтобы не ждать реальный зависон ядра).
  Timer? _transientTimeoutTimer;
  // §287 — 3с (было 10с): при stop с активным mass-ping'ом libbox `closeService()`
  // синхронно ждёт teardown всех WG-endpoint'ов, порождённых пингом (device-verified:
  // stop без пинга 0.16с, с пингом — упирался в этот таймаут ~10с). Снижение порога
  // раньше отдаёт управление force-stop-пути (`doForceStop`, teardown под
  // withTimeout(2с)) — юзер не ждёт зависший WG-teardown. box.Close() при этом не
  // обрывается: Kotlin перестаёт ЖДАТЬ, но Go-горутина доигрывает endpoint.Close()
  // по цепочке в фоне (воркеры гаснут по порядку, не зомби). Чистый stop = 0.16с,
  // запас до 3с большой; корень (closeService не должен ждать пинг-dial'ы) — в ядре.
  static const _defaultStoppingTimeout = Duration(seconds: 3);
  static const _defaultConnectingTimeout = Duration(seconds: 15);
  Duration _stoppingTimeout = _defaultStoppingTimeout;
  Duration _connectingTimeout = _defaultConnectingTimeout;

  /// §140 — debug-only: переопределить transient-пороги (в миллисекундах).
  /// `null` аргумент = не трогать этот порог. Возвращает применённые значения.
  /// Используется `POST /action/set-transient-timeout` для on-device теста.
  ({int connectingMs, int stoppingMs}) debugSetTransientTimeouts({
    int? connectingMs,
    int? stoppingMs,
  }) {
    if (connectingMs != null) {
      _connectingTimeout = Duration(milliseconds: connectingMs);
    }
    if (stoppingMs != null) {
      _stoppingTimeout = Duration(milliseconds: stoppingMs);
    }
    _addDebug(DebugSource.app,
        '[vpn] transient timeouts set: connecting=${_connectingTimeout.inMilliseconds}ms stopping=${_stoppingTimeout.inMilliseconds}ms');
    return (
      connectingMs: _connectingTimeout.inMilliseconds,
      stoppingMs: _stoppingTimeout.inMilliseconds,
    );
  }

  /// §140 — debug-only: текущие transient-пороги (мс), для `GET`-чтения.
  ({int connectingMs, int stoppingMs}) get debugTransientTimeouts => (
        connectingMs: _connectingTimeout.inMilliseconds,
        stoppingMs: _stoppingTimeout.inMilliseconds,
      );

  /// §140 — debug-only: напрямую дёрнуть force-stop native-сервиса (минуя
  /// transient-таймаут). Для on-device проверки `doForceStop`-пути (порт 63130).
  Future<bool> debugForceStopVpn() => _vpn.forceStopVPN();

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    await _loadSavedConfig();
    await refreshChannelLabels(); // §125 — labels для home-dropdown
    await reloadPingOptions();
    _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent);
    // Native шлёт broadcast только на переходы. Если Flutter-процесс умер,
    // а foreground-service выжил (keep-on-exit), при reattach мы не узнаём
    // что туннель уже Started — поле застревает в `disconnected`, а Start-
    // кнопка может оказаться неактивна. Pull'им текущий статус и пропускаем
    // через тот же handler — он сам решит что эмитить.
    final pulled = await _vpn.getVpnStatus();
    _handleStatusEvent(TunnelStatusEvent(status: pulled, raw: pulled.name));
  }

  /// §125 — перечитать tag→label каналов из storage и положить в state. Зовётся
  /// из init и после редактирования каналов (Routing), чтобы home-dropdown
  /// показывал актуальные имена.
  Future<void> refreshChannelLabels() async {
    final channels = await SettingsStorage.getChannels();
    if (_disposed) return;
    // §248/§274 — detour-канал получает ⚙-префикс (display-only,
    // централизован в displayLabel): маркер «разрешён как detour-мишень».
    _channelLabels = {
      for (final c in channels) c.tag: c.displayLabel,
    };
    // §322 — auto-теги всех каналов (различитель «двойник канала vs группа»).
    _channelAutoTags = {for (final c in channels) c.autoTag};
    // §208 — auto-теги round_robin-каналов (для гейта «View pool»).
    _roundRobinAutoTags = {
      for (final c in channels)
        if (c.auto?.mode == UrltestMode.roundRobin) c.autoTag,
    };
    // §251 — storage-fallback тегов селекторов: fold «селектор (выбор)» в
    // routing-строках работает и до первого подключения (двойники тоже —
    // detour-ссылка может указывать на `<tag>-auto`).
    SelectorInfo.I.setFallbackTags([
      for (final c in channels) ...[c.tag, c.autoTag],
    ]);
    _emit(_state.copyWith(
      groupLabels: _channelLabels,
      channelAutoTags: _channelAutoTags, // §322 — гейт пина в верхнюю секцию
    ));
  }

  /// §322 — true, если [tag] — auto-двойник КАНАЛА (`vpn-N-auto`), а не наша
  /// группа автовыбора. Только двойник получает подмену имени и пин наверх.
  bool isChannelAutoTag(String tag) => _channelAutoTags.contains(tag);

  // ── §322 — ленивый кэш живых пулов для значков в списке ──
  //
  // `getPool` — unary-RPC ядра; дёргать его на каждый ребилд строки нельзя.
  // Тянем ОДИН раз на группу и держим до следующего пинг-раунда: состав пула
  // меняется вместе с задержками, а `pingBatchGen` — ровно тот сигнал.
  final _poolCache = <String, List<CcPoolSlot>>{};
  final _poolInFlight = <String>{};
  int _poolCacheGen = -1;

  /// Живой состав пула [tag] из кэша. `null` — ещё не тянули: вызов ставит
  /// фоновый запрос, результат приедет через `notifyListeners`.
  List<CcPoolSlot>? poolSlots(String tag) {
    // Пинг-раунд сменился → прежние слоты устарели.
    if (_poolCacheGen != _state.pingBatchGen) {
      _poolCacheGen = _state.pingBatchGen;
      _poolCache.clear();
      _poolInFlight.clear();
    }
    final cached = _poolCache[tag];
    if (cached != null) return cached;
    if (!_state.tunnelUp || !_poolInFlight.add(tag)) return null;
    unawaited(_fetchPool(tag));
    return null;
  }

  Future<void> _fetchPool(String tag) async {
    final slots = await _cc.getPool(tag);
    if (_disposed || slots == null) return;
    _poolCache[tag] = slots;
    notifyListeners();
  }

  /// §208/§322 — true, если у urltest-группы [autoTag] есть пул: это либо
  /// auto-двойник round_robin-канала, либо узел автовыбора (§322) в режиме
  /// round_robin. Sync-геттер для гейта пункта «View pool» (least_test → пула
  /// нет). Для §322 смотрим тип прямо в конфиге: `balancer{}` в outbound'е
  /// есть только под round_robin (см. AutoSelectParams.toJson).
  bool isRoundRobinAuto(String autoTag) =>
      _roundRobinAutoTags.contains(autoTag) ||
      _state.configModel.rawOf(autoTag)?['balancer'] != null;

  /// §208/§209 — снапшот пула round_robin-группы [autoTag] (ядро SPEC 019 V2).
  /// `null` = CC-клиент недоступен (сервис down) — НЕ пустой пул. `[]` = пул
  /// пуст (не round_robin / нет данных). Идёт через незасыпающий pingClient →
  /// работает и в фоне (§209).
  Future<List<CcPoolSlot>?> getPool(String autoTag) => _cc.getPool(autoTag);

  @override
  void dispose() {
    _disposed = true; // §141 P1.9a — до super.dispose, гейтит async-колбэки
    _stopHeartbeat();
    _autoPingTimer?.cancel();
    _transientTimeoutTimer?.cancel();
    _statusSub?.cancel();
    _ccStatusSub?.cancel();
    _ccGroupsSub?.cancel();
    _groupsPullTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // State helpers
  // ---------------------------------------------------------------------------

  @override
  void _emit(HomeState next) {
    // §221 — единый гейт use-after-dispose: любой _emit после dispose
    // (async-колбэк из start/stop/reconnect/switchNode/pullToRefresh, вернувшийся
    // за await) молча no-op вместо `notifyListeners after dispose`. Радикально
    // закрывает весь класс разом; точечные `if (_disposed) return` после await
    // (§219) остаются как ранний выход, но больше не единственная защита.
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void _addDebug(DebugSource source, String message) {
    AppLog.I.log(
      source == DebugSource.core ? DebugLevel.info : DebugLevel.debug,
      message,
      source: source,
    );
  }

  // ---------------------------------------------------------------------------
  // Native VPN events
  // ---------------------------------------------------------------------------

  /// §250 — тестовый мост к приватному [_handleStatusEvent]: юнит-тесты
  /// прогоняют статус-события через реальный handler без native-стрима.
  @visibleForTesting
  void debugHandleStatusEvent(TunnelStatusEvent event) =>
      _handleStatusEvent(event);

  /// §290 — засеять минимум state для тестов `switchNode`-гейта и
  /// automation-preconditions (группа/tunnel/активная нода/список групп) без
  /// прогона всего стрима групп. §325 — плюс `delayByChannel` для регресса
  /// «mass-ping не стирает замеры чужих каналов».
  @visibleForTesting
  void debugSeedNodeState({
    required String group,
    required String activeNode,
    bool tunnelUp = true,
    List<String>? groups,
    Map<String, Map<String, int>>? delayByChannel,
  }) =>
      _emit(_state.copyWith(
        tunnel: tunnelUp ? TunnelStatus.connected : TunnelStatus.disconnected,
        selectedGroup: group,
        activeInGroup: activeNode,
        highlightedNode: activeNode,
        groups: groups ?? <String>[group],
        delayByChannel: delayByChannel,
      ));

  void _handleStatusEvent(TunnelStatusEvent event) {
    final tunnel = event.status;
    final prevTunnel = _state.tunnel;
    _addDebug(DebugSource.core,
        'status=${event.raw}${event.errorReason != null ? " reason=${event.errorReason}" : ""}');
    _addDebug(DebugSource.app,
        '[vpn] _handleStatusEvent raw="${event.raw}" tunnel=${tunnel.name} prev=${prevTunnel.name} need_restart_before=${_state.configChangedNeedRestart}');

    // Все мутации state складываем в **одно** copyWith в конце — было три
    // отдельных _emit (tunnel; then connectedSince+stale; then cleanup-
    // поля), каждый триггерил notifyListeners → 3 rebuild'а UI на одно
    // событие. Теперь один emit, одно rebuild.

    if (tunnel == TunnelStatus.connected) {
      _emit(_state.copyWith(
        tunnel: tunnel,
        connectedSince: DateTime.now(),
        configChangedNeedRestart: false,
        // §311 — новая сессия ядра → старый снапшот протух; захват ниже.
        // На ДУБЛЕ connected (broadcast + §187-pull) НЕ сбрасываем: сессия та
        // же, иначе теряли бы уже захваченный снапшот и слали лишний RPC.
        runningConfigRaw: prevTunnel == TunnelStatus.connected
            ? _state.runningConfigRaw
            : _invalidateRunningConfig(),
        // §250 — успешный старт = ЕДИНСТВЕННОЕ место очистки lastStartError
        // (clearError/оптимистичные lastError: null его не трогают).
        lastStartError: '',
        lastStartErrorAt: null,
      ));
      // §187 — на cold-start (swipe-reopen) `connected` приходит pull'ом и
      // connectedSince выше = «сейчас», теряя реальное время старта. Подтянуть
      // native-uptime (переживает swipe) и скорректировать назад. Свежий старт →
      // uptime≈0 → коррекции нет (без регресса). Async — не блокирует отклик.
      unawaited(_syncUptimeFromNative());
      // §311 — снапшот работающего конфига: тянем СРАЗУ по факту старта сессии,
      // не дожидаясь groups-push'а (тот при reload может не прийти вовсе).
      // На дубле connected снапшот уже есть — guard внутри вернётся сразу.
      if (prevTunnel != TunnelStatus.connected) {
        unawaited(_captureRunningConfig());
      }
      // §122 — рантайм-данные текут из CommandClient-стримов (status/groups).
      // §185 — теперь async (resync протухшего refcount перед connectScreen).
      unawaited(_startCcStreams());
      // §165 — наполнить резолвер имён правил из custom_rules (для Stats/Conns
      // «Traffic by Rule»: c.rule ядра → title правила). Конфиг уже актуален
      // (раз connected) → правила те же, что зашиты в running-конфиг.
      // §279 — template даёт live-label'ы preset-правил (локализованный кэш;
      // холодный кэш → fallback на name-снапшоты, relocalize догонит).
      unawaited(SettingsStorage.getCustomRules().then((r) =>
          RuleNameResolver.I
              .setRules(r, template: TemplateLoader.cachedOrNull())));
      _startHeartbeat();
      _heartbeatFailNotified = false;
      HapticService.I.onVpnConnected();
      // AutoUpdater триггер #2: через 2 мин после connected.
      _autoUpdater?.onVpnConnected();
      // §366 — проверка TTL rule-set'ов через 30с после connected.
      _ruleSetAutoUpdater?.onVpnConnected();
      unawaited(_scheduleAutoPing());
      // §047 — outgoing lifecycle event (gated, default OFF).
      AutomationEventEmitter.I.emitVpnConnected();
    } else if (tunnel == TunnelStatus.disconnected ||
        tunnel == TunnelStatus.revoked) {
      // §122 — guard от stale-терминала. Если мы УЖЕ в терминальном состоянии
      // (disconnected/revoked), повторный `Stopped` — это дребезг teardown'а
      // (несколько setStatus(Stopped)-путей в native) и НЕ должен повторно рвать
      // CC-стримы/обнулять state. Главный фикс дребезга — native dedup в
      // BoxService.setStatus; это вторая линия (defense-in-depth) на случай
      // error-несущего повтора, который native пропускает.
      if (prevTunnel == TunnelStatus.disconnected ||
          prevTunnel == TunnelStatus.revoked) {
        _addDebug(DebugSource.app,
            '[vpn] stale terminal ignored (tunnel=${tunnel.name} prev=${prevTunnel.name})');
        // Обновим только tunnel-статус (revoked поверх disconnected — важно для
        // haptic/UI), но НЕ трогаем groups/nodes/streams.
        if (tunnel != prevTunnel) _emit(_state.copyWith(tunnel: tunnel));
        _transientTimeoutTimer?.cancel();
        _transientTimeoutTimer = null;
        return;
      }
      _stopHeartbeat();
      // §141 P1.2b / §286 — единый контракт «tunnel down»: гасим ВСЁ пробирование
      // (mass-ping + auto-ping-таймер + folder-probe sweep'ы) ПЕРЕД гашением
      // канала, симметрично `_onTunnelDead`. Иначе воркеры/пробы дописывают
      // stale-результаты в мёртвую сессию (epoch-гейт mass-ping'а их самоисцелит,
      // но folder-probe не epoch-aware — явная отмена детерминирована).
      haltAllProbing();
      // §122 — гасим CommandClient-стримы и screenClient (disconnectScreen).
      // На следующем `connected` пересоберём (`_startCcStreams`).
      _stopCcStreams();
      // §165 — сброс кэша имён правил (правила могут смениться к след. запуску).
      RuleNameResolver.I.clear();
      // §251 — выборы групп протухли (туннель down); ТЕГИ остаются — история
      // профайлера/закрытых conns продолжает фолдиться корректно.
      SelectorInfo.I.clearSelected();
      // §279 — строковый native-протокол (errorReason + revoked-флаг)
      // парсится в typed StopReason здесь, при ingestion; UI ветвится по
      // типу, не по подстрокам. lastError хранит типизированный UiMsg
      // (рендер в build); машинный дубль (Debug API/AppLog) — renderEn().
      final stopReason = StopReason.fromEvent(
          revoked: tunnel == TunnelStatus.revoked,
          errorReason: event.errorReason);
      final reasonEn = stopReason?.renderEn() ?? '';
      _emit(
        _state.copyWith(
          tunnel: tunnel,
          lastError: stopReason != null
              ? StopReasonMsg(stopReason)
              : _state.lastError,
          stopReason: stopReason ?? _state.stopReason,
          // §250 — диагностический дубль для Debug API: живёт до следующего
          // УСПЕШНОГО старта (UI-consume через clearError его не затирает).
          // Пустой reason (чистый user-stop) НЕ затирает предыдущее значение —
          // симметрично поведению lastError строкой выше. Всегда English
          // (wire-поверхность, spec §4.4).
          lastStartError:
              reasonEn.isNotEmpty ? reasonEn : _state.lastStartError,
          lastStartErrorAt:
              reasonEn.isNotEmpty ? DateTime.now() : _state.lastStartErrorAt,
          ccGroups: const <CcGroup>[],
          groups: <String>[],
          nodes: <String>[],
          highlightedNode: null,
          traffic: TrafficSnapshot.zero,
          connectedSince: null,
          configChangedNeedRestart: false,
          runningConfigRaw: _invalidateRunningConfig(), // §311 — running перестал существовать
        ),
      );
      // Haptic — на революд/краш тяжёлый, на user-инициированный stop лёгкий.
      // Триггерим только если был up (не из connecting → disconnect).
      if (prevTunnel == TunnelStatus.connected) {
        if (tunnel == TunnelStatus.revoked) {
          HapticService.I.onVpnCrashed();
        } else {
          HapticService.I.onVpnDisconnected();
        }
        // AutoUpdater триггер #4: только если реально ушли из connected
        // (чтобы не срабатывать при revoked → disconnected дубле).
        _autoUpdater?.onVpnStopped();
      }
      if (reasonEn.isNotEmpty) {
        _addDebug(DebugSource.core, reasonEn);
      }
      // §047 — outgoing lifecycle events (gated, default OFF). revoked → своё
      // событие; ошибочный stop (errorReason present) → VPN_ERROR + DISCONNECTED;
      // чистый user-stop → DISCONNECTED reason=user.
      if (tunnel == TunnelStatus.revoked) {
        AutomationEventEmitter.I.emitVpnRevoked();
        AutomationEventEmitter.I.emitVpnDisconnected('revoked');
      } else if (event.errorReason != null) {
        AutomationEventEmitter.I.emitVpnError('tunnel_error', event.errorReason!);
        AutomationEventEmitter.I.emitVpnDisconnected('error');
      } else {
        AutomationEventEmitter.I.emitVpnDisconnected('user');
      }
    } else if (tunnel == TunnelStatus.stopping || tunnel == TunnelStatus.connecting) {
      _stopHeartbeat();
      _emit(_state.copyWith(tunnel: tunnel));
      _armTransientTimeout(tunnel);
      return;
    } else {
      _stopHeartbeat();
      _emit(_state.copyWith(tunnel: tunnel));
    }

    // non-transient terminal event — safety-timer больше не нужен.
    _transientTimeoutTimer?.cancel();
    _transientTimeoutTimer = null;
  }

  /// Перезапускает safety-timer на transient-фазу. Cancel'ит предыдущий
  /// (защита от спама `Future.delayed` при множественных stopping/
  /// connecting подряд) и стартует новый. §140 — порог зависит от фазы:
  /// `connecting` (медленный старт) — длиннее, `stopping` (реальный зависон) — 3с (§287).
  void _armTransientTimeout(TunnelStatus expected) {
    _transientTimeoutTimer?.cancel();
    final timeout = expected == TunnelStatus.connecting
        ? _connectingTimeout
        : _stoppingTimeout;
    _transientTimeoutTimer = Timer(timeout, () async {
      if (_state.tunnel != expected) return;
      _addDebug(
          DebugSource.app, 'Timeout in ${expected.name}, forcing disconnect');
      // §129 — таймаут transient-фазы = ядро НЕ отдало Stopped само (зависло
      // вхолостую: detour AWG→WG #2 — tun0 жив, 0 трафика, dial заклинен).
      // Раньше тут был только _emit(disconnected) — UI «disconnected», а
      // VpnService продолжал жить и роутить вхолостую, кнопка не реагировала.
      // Теперь принудительно прибиваем сервис (stopSelf в обход зависшего
      // teardown). НЕ обычный stopVPN — тот кооперативный, ждёт Stopped и сам
      // виснет. forceStopVPN — fire-and-forget. После — синхронизируем UI.
      await _vpn.forceStopVPN();
      if (_disposed) return; // §219 — могли dispose'нуться за await → не эмитим
      _addDebug(DebugSource.app, '[vpn] forceStopVPN sent (timeout in ${expected.name})');
      if (_state.tunnel != expected) return;
      // §251 — синтезированный tunnel-down: настоящий Stopped потом проглотит
      // stale-terminal guard, его clearSelected недостижим — чистим здесь.
      SelectorInfo.I.clearSelected();
      _emit(_state.copyWith(
        tunnel: TunnelStatus.disconnected,
        lastError: const ErrMsg(ErrKey.connectionTimedOut),
        ccGroups: const <CcGroup>[],
        groups: <String>[],
        nodes: <String>[],
        traffic: TrafficSnapshot.zero,
        connectedSince: null,
        configChangedNeedRestart: false,
        runningConfigRaw: _invalidateRunningConfig(), // §311 — синтезированный down
      ));
    });
  }

  // Tunnel heartbeat (_startHeartbeat / _stopHeartbeat / _checkHeartbeat /
  // _onTunnelDead / _tryCleanStop) вынесен в `home_controller/heartbeat.dart`
  // (`_HeartbeatMixin`).

  // Config persistence + import (clipboard / file) вынесены в
  // `home_controller/config_io.dart` (`_ConfigIoMixin`): _loadSavedConfig /
  // saveParsedConfig / saveConfigRaw / readFromClipboard / readFromFile.
  // §122 — Clash endpoint rebuild выпилен (данные текут CommandClient-стримами).

  // ---------------------------------------------------------------------------
  // VPN tunnel control
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // stop/start/reconnect — intent-based primitives
  //
  // Дизайн (после sink-fix в BoxVpnClient + blocking stopVPN на native):
  //   - `_stopInternal` / `_startInternal` — внутренние примитивы, делают
  //     один native call + intent-based reset `configChangedNeedRestart=false`
  //     на успехе. Без busy-management.
  //   - `stop` / `start` — public, оборачивают internal в `busy=true/false`
  //     try/finally + error surfacing в `lastError`.
  //   - `reconnect` — композиция `_stopInternal` → `_startInternal` под
  //     одним `busy`-wrap'ом. Никакого `firstWhere`/`timeout` на Dart
  //     стороне: `stopVPN` теперь блокирующий на native, caller получает
  //     control только после `setStatus(Stopped)`.
  //
  // Почему intent-based reset `configChangedNeedRestart=false` в _stopInternal
  // и _startInternal (а не только в _handleStatusEvent на Stopped/Started):
  //   1. Семантическая чистота. Юзер явно применил namерение (stop = "туннель
  //      прекращается, saved больше не vs running"; start = "running теперь
  //      и есть saved"). Флаг сбрасывается по причине, а не по следствию.
  //   2. Broadcast-канал остаётся unreliable-by-design на системном уровне
  //      (Doze, OOM, process kill) — intent reset не зависит от доставки.
  //   3. `_handleStatusEvent` reset (строки 101/127) остаётся как defense
  //      in depth: если transition пришёл без intent (например, revoke
  //      от другого VPN), флаг тоже сбросится. Идемпотентно, конфликтов нет.
  // ---------------------------------------------------------------------------

  /// Atomic stop: blocking native call + intent-based sticky reset.
  /// Returns true если native реально остановился, false на timeout.
  Future<bool> _stopInternal() async {
    final ok = await _vpn.stopVPN();
    _addDebug(DebugSource.app, '[vpn] stopVPN returned $ok');
    if (ok) {
      // Intent-based reset: юзер остановил туннель, saved конфиг больше
      // не "stale vs running" — running перестал существовать.
      _emit(_state.copyWith(configChangedNeedRestart: false));
    }
    return ok;
  }

  /// §123 — собрать и отправить строки foreground-уведомления.
  ///   title = `L×Box [final = <route.final>]` (сырое route.final)
  ///   text  = `<селектор>: <выбранная нода>`, напр. `vpn-1: L: 🇫🇮⚡Финляндия-2`.
  ///           Селектор = selectedGroup, нода = его `now` (= activeInGroup,
  ///           которое applyGroup заполняет из entry['now'] группы).
  ///           Нет ноды → только селектор; нет конфига → пусто (native подставит
  ///           статусный fallback "Connected").
  /// Dart владеет обеими строками — native при своих show(...) не затирает их.
  Future<void> _pushNotificationLabels() async {
    // §311 — шторка описывает ТЕКУЩИЙ туннель → route.final из среза ядра
    // (activeConfigRaw; фоллбэк на файл, если снапшот ещё не подтянут).
    final routeFinal = RouteConfig.finalTag(_state.activeConfigRaw);
    final title = (routeFinal == null || routeFinal.isEmpty)
        ? 'L×Box'
        : 'L×Box [final = $routeFinal]';

    // selectedGroup = активный селектор (vpn-1), activeInGroup = его выбранная
    // нода (`now`). Формат подтекста: «<селектор>: <нода>».
    final group = _state.selectedGroup;
    final node = _state.activeInGroup;
    final String text;
    if (group != null && group.isNotEmpty) {
      text = (node != null && node.isNotEmpty) ? '$group: $node' : group;
    } else {
      text = (node != null && node.isNotEmpty) ? node : (routeFinal ?? '');
    }

    await _vpn.setNotificationTitle(title);
    await _vpn.setNotificationText(text);
  }

  /// Atomic start: native call + intent-based sticky reset.
  /// Returns true если startVPN принят (reached Starting), false иначе.
  Future<bool> _startInternal() async {
    await _pushNotificationLabels();
    final ok = await _vpn.startVPN();
    _addDebug(DebugSource.app, '[vpn] startVPN returned $ok');
    if (ok) {
      // Intent-based reset: running теперь = saved (или станет через
      // мгновение на Started). Плашка "нужен restart" неактуальна.
      _emit(_state.copyWith(configChangedNeedRestart: false));
    }
    return ok;
  }

  Future<void> start() async {
    _emit(_state.copyWith(busy: true, lastError: null));
    try {
      final ok = await _startInternal();
      if (!ok) {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.failedToStartVpn)));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'startVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  Future<void> stop() async {
    _emit(_state.copyWith(busy: true, lastError: null));
    try {
      final ok = await _stopInternal();
      if (!ok) {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.stopTimedOut)));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'stopVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  /// Можно ли сейчас триггерить in-place reload (cooldown-aware). UI bind'ит
  /// `IconButton.onPressed` к этому, чтобы кнопка disabled на 3s после tap'а
  /// и недоступна когда туннель не up.
  bool get canReload =>
      _state.tunnel == TunnelStatus.connected &&
      (_lastReloadTap == null ||
          DateTime.now().difference(_lastReloadTap!) > _recoveryCooldown);

  /// In-place reload sing-box runtime через `commandServer.startOrReloadService`.
  /// Tunnel дропается на ~3s, Android Service не убивается. См. spec 030.
  Future<void> reloadVpn() async {
    if (!canReload) return;
    final prevReloadTap = _lastReloadTap;
    _lastReloadTap = DateTime.now();
    notifyListeners();
    // §141 P1.9b — раньше исключение из reloadVPN проглатывалось (uncaught
    // async) → cooldown оставался занятым, юзер не видел ошибки. Теперь
    // surface'им через _emit(lastError) и откатываем cooldown, чтобы повтор
    // был доступен сразу.
    // §311 — reload пересоздаёт box → снапшот running config протухает.
    // Запоминаем прежний ДО сброса: по нему захват ниже отличит «ядро уже
    // подменило box» от «ещё отдаёт старое». Сброс до native-вызова, epoch-bump
    // обесценивает ответ in-flight запроса от старого box'а.
    final staleSnapshot = _state.runningConfigRaw;
    _emit(_state.copyWith(runningConfigRaw: _invalidateRunningConfig()));
    try {
      final ok = await _vpn.reloadVPN();
      _addDebug(DebugSource.app, '[vpn] reload → ok=$ok');
      // §323 — intent-based reset, как в `_startInternal()`: ядро перечитало
      // конфиг с диска (`ConfigManager.load()` → `startOrReloadService`), значит
      // running == saved и плашка «restart to apply» неактуальна. Раньше флаг
      // выживал успешный reload, и юзер видел плашку над уже применённым
      // конфигом — жать было нечего. Только при ok: провалившийся reload
      // оставил ядро на старом конфиге, плашка там честная.
      if (ok && !_disposed) {
        _emit(_state.copyWith(configChangedNeedRestart: false));
      }
    } catch (e) {
      _lastReloadTap = prevReloadTap; // откат cooldown
      _addDebug(DebugSource.app, '[vpn] reload error: $e');
      if (!_disposed) {
        _emit(_state.copyWith(
            lastError: PrefixedMsg(ErrPrefix.reloadFailed, formatUserError(e))));
      }
      return;
    }
    // §311 — ПЕРЕзахват снапшота после reload'а. Прямой триггер обязателен:
    // groups-push при in-place reload может не прийти вовсе (CommandClient
    // переживает reload, дерево групп то же, а `_startGroupsPull` заводится
    // только на переходе в connected, которого при reload нет — §049 F4).
    // Device-факт 26.07: пока захват висел на `_applyGroups`, снапшот залипал
    // в null до конца сессии, и весь UI молча деградировал на saved-файл.
    //
    // staleRaw — вторая половина того же device-факта: `reloadVPN` шлёт
    // broadcast и сразу возвращает управление, а ядро в этот момент ещё
    // STARTED со СТАРЫМ box'ом и честно отдаёт доreload'ный конфиг (ретрай
    // «по null» его не отсеет). Поэтому ждём ответ, ОТЛИЧНЫЙ от прежнего.
    unawaited(_captureRunningConfig(staleRaw: staleSnapshot));

    // §367 — автопинг после in-place reload. Та же дыра, что у снапшота выше
    // (§311) и у `_startGroupsPull` (§049 F4): `_scheduleAutoPing` висит на
    // ПЕРЕХОДЕ в connected, а при reload перехода нет — статус остаётся
    // connected. Симптом: сменил подписку с включённой галкой автоприменения,
    // экран перерисовался новым составом узлов, но все они без задержек —
    // пинга никто не запускал (при обычном старте он идёт сам).
    //
    // Состав узлов после reload другой, значит прежние `lastDelay` к ним не
    // относятся. Тот же 5-секундный отложенный запуск, что на connect: ядру
    // нужно время поднять новые outbound'ы. Гейты (галка `auto_ping_on_start`,
    // tunnelUp, непустой список) — внутри `_scheduleAutoPing`.
    //
    // ВАЖНО: сначала подтянуть группы, потом планировать пинг. `_state.nodes`
    // (по которому пингуем) наполняет `_applyGroups` из groups-стрима, а тот
    // при in-place reload может не прийти вовсе — ровно то, о чём §311-коммент
    // выше. Device-факт 03.08: reload отработал, снапшот захватился, а
    // groups-push не пришёл — таймер срабатывал на пустом/устаревшем списке и
    // тихо выходил по `nodes.isEmpty`. Пинга не было, хотя экран показывал
    // новый состав (его рисует saved-конфиг, не ядро). Тот же unary-`getGroups`,
    // что делает pull-to-refresh — им юзер и «чинил» это руками.
    unawaited(() async {
      await pullToRefresh();
      await _scheduleAutoPing();
    }());

    // Cooldown timer перерендерит canReload через 3s — назначаем future
    // notifyListeners (без heavy timer'а; achievable через delayed Future).
    // §141 P1.9a — гейт `_disposed`: контроллер мог умереть за время cooldown.
    Future.delayed(_recoveryCooldown, () {
      if (!_disposed && _lastReloadTap != null) notifyListeners();
    });
  }

  /// Reset network sub-state (experimental, spec 031). Не дропает runtime.
  /// UI пока не использует — только через Debug API для экспериментов.
  Future<bool> resetNetwork() async {
    if (_state.tunnel != TunnelStatus.connected) return false;
    if (_lastResetNetworkTap != null &&
        DateTime.now().difference(_lastResetNetworkTap!) < _recoveryCooldown) {
      return false;
    }
    _lastResetNetworkTap = DateTime.now();
    final ok = await _vpn.resetNetwork();
    _addDebug(DebugSource.app, '[vpn] resetNetwork → ok=$ok');
    return ok;
  }

  /// Reconnect = `_stopInternal` → `_startInternal`. Blocking на native
  /// даёт нам уверенность что между stop и start нет race окна в
  /// `onStartCommand` guard'е. busy=true держится на всю цепочку, чтобы
  /// UI не дал повторно нажать.
  ///
  /// Если туннель уже down — просто делегируем в `start()`.
  Future<void> reconnect() async {
    final wasUp = _state.tunnel == TunnelStatus.connected ||
        _state.tunnel == TunnelStatus.connecting;
    if (!wasUp) {
      await start();
      return;
    }
    _emit(_state.copyWith(busy: true, lastError: null));
    try {
      final stopped = await _stopInternal();
      if (!stopped) {
        _emit(_state.copyWith(
            lastError: const ErrMsg(ErrKey.stopTimedOutReconnectAborted)));
        _addDebug(DebugSource.app, 'reconnect: stop timed out, aborting start');
        return;
      }
      final started = await _startInternal();
      if (!started) {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.failedToStartVpn)));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'reconnect exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  // ---------------------------------------------------------------------------
  // §122 — CommandClient data streams (заменяют Clash API HTTP-петли)
  // ---------------------------------------------------------------------------

  /// Таймстемп последнего status-снапшота — для watchdog (§122 заменяет
  /// heartbeat HTTP-fail: «тишина» стрима = ядро не отвечает).
  DateTime? _lastCcStatusAt;
  @override
  DateTime? get lastCcStatusAt => _lastCcStatusAt;

  /// §187 — скорректировать `connectedSince` по реальному uptime туннеля из
  /// native (companion, переживает swipe). Зовётся на `connected`. На свежем
  /// старте uptime≈0 → коррекции нет; на cold-start (reopen) uptime значимый →
  /// сдвигаем `connectedSince` назад на реальное время старта. Порог 2с отсекает
  /// дребезг свежего старта (мелкая задержка между Started и pull).
  Future<void> _syncUptimeFromNative() async {
    final uptimeMs = await _vpn.getTunnelUptimeMs();
    if (_disposed || _state.tunnel != TunnelStatus.connected) return;
    if (uptimeMs < 2000) return; // свежий старт — connectedSince≈now уже верно
    final realStart = DateTime.now().subtract(Duration(milliseconds: uptimeMs));
    _emit(_state.copyWith(connectedSince: realStart));
  }

  /// Поднять push-стримы CommandClient'а и `screenClient` (outbounds+groups+
  /// connections). Зовётся на `connected`. Идемпотентно — отменяет прежние
  /// подписки перед новыми (защита от двойного connect).
  Future<void> _startCcStreams() async {
    _ccStatusSub?.cancel();
    _ccGroupsSub?.cancel();
    // §122 КРИТИЧНО — ПОРЯДОК: сперва навешиваем Dart-подписки (это
    // инициализирует ленивые `late final` стримы CcChannel → ставит native
    // sink'и через EventChannel.onListen), и ТОЛЬКО ПОТОМ connectScreen().
    // Иначе race: connectScreen() поднимает screenClient, ядро эмитит РАЗОВЫЙ
    // снапшот groups до того как Dart-подписка успела встать → снапшот
    // отбрасывается (sink ещё null) → «главный экран пустой при старте».
    _ccStatusSub = _cc.status.listen(_onCcStatus, onError: (Object e) {
      _addDebug(DebugSource.app, 'cc status stream error: $e');
    });
    _ccGroupsSub = _cc.groups.listen(_onCcGroups, onError: (Object e) {
      _addDebug(DebugSource.app, 'cc groups stream error: $e');
    });
    // §185 — cold-start после swipe-keep: native screenRefs протух (PERSISTENT
    // поле CC, пережил swipe; Dart-движок умер без disconnectScreen). Сбросить
    // refcount/паузу + закрыть осиротевший screen/profiler-клиент ПЕРЕД
    // connectScreen, иначе тот увидит refs>0 → не переподнимет screenClient на
    // свежие sink'и → пустой UI.
    //
    // §193 — resync зовём ТОЛЬКО на ПЕРВЫЙ `_startCcStreams` нового Dart-движка
    // (cold-start). Раньше — на КАЖДЫЙ `connected` (реконнект тоже): resync
    // disconnect'ит screenClient, а connections — single-shot (нет pull, нет
    // нового reset при refcount>0) → Stats терял соединения на любой реконнект.
    // groups самоисцелялись pull'ом, connections — нет. На реконнектах refcount
    // консистентен (тот же движок) → resync не нужен, обычный connectScreen.
    if (!_didColdStartResync) {
      _didColdStartResync = true;
      await _cc.resyncForReopen();
      if (_disposed || !_state.tunnelUp) return; // ушли за await
    }
    // §2.8 — теперь sink'и стоят + refcount чист → поднимаем screenClient.
    unawaited(_cc.connectScreen());
    // §122/SPEC015 — детерминированный pull стартового снапшота групп. Раньше
    // тут был watchdog, пересоздававший весь screenClient (`refreshScreen`) —
    // он НЕ заставлял ядро переслать снапшот (device-факт: 2 ретрая впустую).
    // Теперь честный unary `getGroups`: читает дерево групп напрямую, минуя
    // гонку стартового push'а (`waitForStarted`/SubscribeGroups). Push-стрим
    // остаётся для live-обновлений; pull — гарантия что экран не пуст.
    _startGroupsPull();
  }

  /// §311 — guard от параллельных захватов снапшота.
  bool _fetchingRunningConfig = false;

  /// §311 — пауза перед первым запросом снапшота после `reloadVpn`.
  /// `reloadVPN` шлёт broadcast и сразу возвращает управление; ядро в этот
  /// момент ещё STARTED со старым box'ом, поэтому мгновенный RPC отдал бы
  /// доreload'ный конфиг (device-факт 26.07). 1.2с — с запасом к наблюдаемой
  /// подмене; ретраи ниже добирают, если ядро задержалось.
  static const _reloadCapturePause = Duration(milliseconds: 1200);

  /// §311 — epoch сессии ядра для снапшота. Bump'ается ВМЕСТЕ с каждым
  /// сбросом `runningConfigRaw`. Нужен потому, что `tunnelUp` НЕ различает
  /// сессии: in-place reload идёт **без status-flap** (§049 F4 — ядро остаётся
  /// `Started`), CommandServer его переживает, а groups-стрим не гасится.
  /// Без epoch'а fetch, стартовавший до/во время reload'а, отвечал бы конфигом
  /// СТАРОГО box'а и коммитил его ПОСЛЕ сброса — pre-check `!= null` затем
  /// блокировал бы refetch, и stale-снапшот управлял бы `activeModel` до конца
  /// сессии (ровно класс бага §311). Образец — epoch-гейт mass-ping'а.
  int _runningConfigEpoch = 0;

  /// §311 — инвалидация снапшота: bump epoch'а + сам сброс одним движением.
  /// Возвращает `null` для передачи в `copyWith(runningConfigRaw: ...)`, чтобы
  /// «сбросили, но забыли bump'нуть» было невыразимо. Зовётся на КАЖДОМ
  /// переходе сессии ядра (см. вызовы).
  @override
  String? _invalidateRunningConfig() {
    _runningConfigEpoch++;
    return null;
  }

  /// §311 — захват снапшота работающего конфига (kernel SPEC 036).
  ///
  /// Триггерится **прямо** на сменах сессии ядра — переход в `connected` и
  /// `reloadVpn` — а не побочным эффектом чужого пути. Раньше висел на
  /// `_applyGroups`, и device-тест 26.07 показал дыру: при in-place reload
  /// groups-push может не прийти вовсе (CommandClient переживает reload, дерево
  /// групп то же, а `_startGroupsPull` заводится только на переходе в connected,
  /// которого при reload не бывает — §049 F4) → снапшот залипал в `null` на всю
  /// сессию, и весь UI молча деградировал на saved-файл.
  ///
  /// Неблокирующе (`unawaited` на вызывающей стороне) + короткий ретрай:
  /// `startOrReloadService` асинхронный, сразу после старта/reload'а новый box
  /// ещё не `STARTED` и RPC отвечает `FailedPrecondition` (обвязка → null).
  /// Шаги те же, что у groups-pull (SPEC015). Исчерпали попытки — остаёмся без
  /// снапшота: `activeModel` деградирует к saved-файлу (поведение до §311).
  Future<void> _captureRunningConfig({String? staleRaw}) async {
    if (_disposed || _fetchingRunningConfig) return;
    if (!_state.tunnelUp) return;
    _fetchingRunningConfig = true;
    final epoch = _runningConfigEpoch;
    try {
      // §311 — после reload'а первый ответ приходит от ЕЩЁ НЕ подменённого
      // box'а: `reloadVPN` шлёт broadcast и сразу возвращает управление, ядро
      // в этот момент STARTED со старым конфигом. RPC при этом не ошибается —
      // он честно отдаёт доreload'ный документ, поэтому ретрай «по null» его
      // не отсеивает (device-факт 26.07). Отсеиваем по содержимому: пока ответ
      // равен известному устаревшему снапшоту — ждём и спрашиваем снова.
      if (staleRaw != null) await Future<void>.delayed(_reloadCapturePause);
      for (var attempt = 0; attempt < _groupsPullMaxAttempts; attempt++) {
        final raw = await _cc.getRunningConfig();
        // §219 — dispose/ушли из connected за await → не эмитим.
        if (_disposed || !_state.tunnelUp) return;
        // §311 — сессия ядра сменилась за время RPC (reload/реконнект): ответ
        // от СТАРОГО box'а, коммитить нельзя. Свой захват уже запущен новой
        // сессией — эта петля просто уходит.
        if (epoch != _runningConfigEpoch) {
          _addDebug(DebugSource.app,
              '[cc] running config dropped (epoch $epoch → $_runningConfigEpoch)');
          return;
        }
        if (raw != null && raw != staleRaw) {
          _emit(_state.copyWith(runningConfigRaw: raw));
          _addDebug(DebugSource.app,
              '[cc] running config captured (${raw.length} bytes)');
          return;
        }
        // null = ядро ещё не STARTED; == staleRaw = box ещё не подменён.
        await Future<void>.delayed(_groupsPullStep);
      }
      if (!_disposed) {
        _addDebug(DebugSource.app,
            '[cc] running config unavailable after $_groupsPullMaxAttempts attempts');
      }
    } finally {
      _fetchingRunningConfig = false;
    }
  }

  Timer? _groupsPullTimer;
  // getGroups бросает (status.Error), пока сервис не STARTED — ретраим короткими
  // шагами, ПОКА не получим снапшот. Не «N попыток и сдаёмся»: pull дешёвый и
  // детерминированный, тянем до успеха либо до ухода из connected.
  static const _groupsPullStep = Duration(milliseconds: 400);
  static const _groupsPullMaxAttempts = 12; // ~5с суммарно — щедрый STARTED- window

  void _startGroupsPull([int attempt = 0]) {
    _groupsPullTimer?.cancel();
    _groupsPullTimer = Timer(_groupsPullStep, () async {
      if (!_state.tunnelUp) return; // ушли из connected — pull неактуален
      // Группы уже наполнены (push доехал) — pull не нужен.
      if (_state.ccGroups.isNotEmpty) return;
      final groups = await _cc.getGroups();
      if (_disposed || !_state.tunnelUp) return; // §219 — dispose/ушли за await
      if (groups == null) {
        // Ядро ещё не STARTED (getGroups бросил) — ретраим.
        if (attempt + 1 < _groupsPullMaxAttempts) {
          _startGroupsPull(attempt + 1);
        } else {
          _addDebug(DebugSource.app,
              '[cc] getGroups still unavailable after $_groupsPullMaxAttempts attempts');
        }
        return;
      }
      if (groups.isEmpty) {
        // STARTED, но групп реально нет (конфиг без selector'ов) — применим как
        // есть (один раз), повторно не тянем.
        _addDebug(DebugSource.app, '[cc] getGroups → empty (no selector groups)');
        _applyGroups(groups);
        return;
      }
      _addDebug(DebugSource.app,
          '[cc] getGroups pull → ${groups.length} groups');
      _applyGroups(groups);
    });
  }

  /// Отменить подписки + опустить `screenClient`. Зовётся на disconnect/dead.
  @override
  void _stopCcStreams() {
    _ccStatusSub?.cancel();
    _ccStatusSub = null;
    _ccGroupsSub?.cancel();
    _ccGroupsSub = null;
    _groupsPullTimer?.cancel();
    _groupsPullTimer = null;
    _lastCcStatusAt = null;
    // §122 — сбросить replay-кэши, чтобы при следующем connect новый подписчик
    // не получил устаревший снапшот прошлой сессии (мигание старых групп/нод).
    _cc.resetCaches();
    unawaited(_cc.disconnectScreen());
  }

  /// §122 — status-стрим тикает часто (0.1с). На главном экране скорость в
  /// шапке не нужна с такой частотой, а `_emit` ребилдит весь HomeScreen
  /// (node-list 95 нод) → 10 ребилдов/сек = лаги/батарея. Эмитим traffic не
  /// чаще [_trafficEmitThrottle]; Stats/Conns берут полный 0.1с-поток напрямую.
  static const _trafficEmitThrottle = Duration(seconds: 1);
  DateTime? _lastTrafficEmitAt;

  /// §3.1 — статус-снапшот. `*Total` — накопленный объём (traffic).
  /// `connectionsIn/Out` — для бейджа активных.
  void _onCcStatus(CcStatus s) {
    if (!_state.tunnelUp) return;
    final now = DateTime.now();
    // Watchdog обновляем на КАЖДЫЙ тик (дёшево, без emit) — он гейтит dead-tunnel.
    _lastCcStatusAt = now;
    _heartbeatFailures = 0;
    // Throttle тяжёлого _emit (ребилд node-list): не чаще 1с.
    if (_lastTrafficEmitAt != null &&
        now.difference(_lastTrafficEmitAt!) < _trafficEmitThrottle) {
      return;
    }
    _lastTrafficEmitAt = now;
    _emit(_state.copyWith(
      traffic: TrafficSnapshot(
        uploadTotal: s.uplinkTotal,
        downloadTotal: s.downlinkTotal,
        activeConnections: s.connectionsIn + s.connectionsOut,
        connectionsIn: s.connectionsIn, // §194 — раздельно для шапки ↑In ↓Out
        connectionsOut: s.connectionsOut,
        memory: s.memory,
        // byRule/byApp — из connections-стрима (stats-экран), не из status.
        byRule: _state.traffic.byRule,
        byApp: _state.traffic.byApp,
      ),
    ));
  }

  /// §2.4 — снапшот дерева групп из CommandClient. Кладём в `state.ccGroups`
  /// (источник истины) и пере-применяем логику выбора группы. reset-снапшот:
  /// каждый снапшот ПОЛНОСТЬЮ заменяет `ccGroups` (replace-not-merge, §2.8).
  void _onCcGroups(List<CcGroup> groups) {
    if (!_state.tunnelUp) return;
    // §122 КОРЕНЬ пустых групп — стабилизация push'а. Ядро (гонка
    // waitForStarted/SubscribeGroups) ИЗРЕДКА шлёт пустой снапшот groups поверх
    // уже наполненного дерева — это шум, а НЕ «групп больше нет»: при поднятом
    // туннеле с живым трафиком selector-группа в конфиге есть всегда. Принять
    // пустой снапшот = перетереть live `ccGroups/groups/nodes` пустотой
    // (device-факт: groups мелькают 95→0). Игнорируем пустой push, если уже есть
    // непустой снапшот. Первый легитимный пустой (старт, ccGroups ещё пуст)
    // проходит. Детерминированное наполнение — unary `getGroups`-pull
    // (`_startGroupsPull`, SPEC015); этот guard — защита live-данных от пустых
    // push'ей и при наличии pull (не «обезьянье тыканье»: пустых групп при
    // connected не бывает).
    if (groups.isEmpty && _state.ccGroups.isNotEmpty) {
      _addDebug(DebugSource.app,
          '[cc] empty groups push ignored (have ${_state.ccGroups.length} live)');
      return;
    }
    _applyGroups(groups);
  }

  /// Общее ядро: из свежего снапшота групп пересчитать список selector-групп,
  /// выбрать активную (sticky → route.final → первая) и применить её ноды.
  /// Вызывается из стрима И из `reloadProxies` (pull-refresh / после switchNode).
  void _applyGroups(List<CcGroup> ccGroups) {
    // §251 — снапшот «тег группы → её текущий выбор» для fold'а
    // «селектор (выбор)» в routing-строках и пикере detour. Все группы
    // (selector + urltest): detour-ссылка может указывать и на двойник.
    // §344 — пустое `selected` НЕ выбор: у round_robin-группы (§208/§322)
    // одного выбранного нет по определению, ядро отдаёт ''. Пропустив его,
    // мы бы нарушили контракт `selectedOf` («null = выбор неизвестен») и
    // цепочка §258 нарисовала бы хоп с пустым тегом.
    SelectorInfo.I.setGroups({
      for (final g in ccGroups)
        if (g.selected.isNotEmpty) g.tag: g.selected,
    });
    // Сначала фиксируем свежий снапшот в state, чтобы производные геттеры
    // (`selectorGroupTags`/`groupOf`) считали по новым данным.
    var next = _state.copyWith(ccGroups: ccGroups);

    final groups = next.selectorGroupTags
        .where((name) => name != 'GLOBAL')
        .toList();

    String? initial = next.selectedGroup;
    if (initial == null || !groups.contains(initial)) {
      // §311 — осознанно configRaw (НЕ activeConfigRaw): этот путь — триггер
      // lazy-fetch'а снапшота, на первом проходе снапшота ещё нет. Выбор
      // группы идёт по тегам селекторов; их переименование и так требует
      // рестарта, так что файл здесь безопасен.
      final finalTag = RouteConfig.finalTag(next.configRaw);
      if (finalTag != null && groups.contains(finalTag)) {
        initial = finalTag;
      } else {
        initial = groups.isNotEmpty ? groups.first : null;
      }
    }

    _emit(next.copyWith(
        groups: groups, groupLabels: _channelLabels, selectedGroup: initial));
    unawaited(applyGroup(initial));
    // §355 — выбор групп сменился → пересчитать граф зависимостей (мёртвая
    // нода могла стать/перестать быть корнем беды через выбор канала).
    _recomputeDependencyHealth();
  }

  /// Переприменение после switchNode|groupUrltest. §122 — данные текут стримом;
  /// здесь лишь пере-применяем логику выбора группы поверх ПОСЛЕДНЕГО снапшота.
  @override
  Future<void> reloadProxies() async {
    if (!_state.tunnelUp) return;
    _applyGroups(_state.ccGroups);
  }

  // §355 — граф detour-зависимостей активного конфига (parse-once дисциплина
  // §091: пересоздаётся только на смену raw). Динамика (выбор групп, замеры)
  // подаётся в computeSick аргументами из state.
  DependencyGraph _depGraph = const DependencyGraph.empty();
  String _depGraphRaw = '';

  /// §355 — актуализировать граф под текущий activeConfigRaw (ленивая
  /// parse-once инвалидация, общая для computeSick и UI-запросов).
  DependencyGraph _ensureDepGraph() {
    final raw = _state.activeConfigRaw;
    if (raw != _depGraphRaw) {
      _depGraphRaw = raw;
      _depGraph = DependencyGraph.fromConfig(raw);
    }
    return _depGraph;
  }

  /// §355 — прямые зависимые ноды/канала (кто ссылается detour'ом): вкладка
  /// «Dependents» в OutboundViewScreen. Статический срез графа, без health.
  List<DependentRef> directDependentsOf(String tag) =>
      _ensureDepGraph().directDependents(tag);

  /// §355 — пересчёт «корней беды» (мёртвая нода → зависимые DNS/ноды).
  /// Дёргается на двух событиях (новой диагностики нет by design): замер
  /// пинга (см. ping_orchestration) и смена выбора групп (_applyGroups).
  /// Эмитит только при фактическом изменении результата; баннер lastError —
  /// только для DNS-ветки (решение юзера, spec §4.3) и только на НОВУЮ
  /// dns-жертву; исчезновение всех dns-жертв снимает наш баннер (чужие
  /// lastError не трогаем).
  @override
  void _recomputeDependencyHealth() {
    _ensureDepGraph();
    final selections = <String, String>{
      for (final g in _state.ccGroups)
        if (g.selectable && g.selected.isNotEmpty) g.tag: g.selected,
    };
    final sick = _depGraph.computeSick(
      selections: selections,
      delays: _state.delayByChannel,
    );
    if (_sickRootsEqual(sick, _state.sickRoots)) return;

    final prevDnsVictims = <String>{
      for (final list in _state.sickRoots.values)
        for (final d in list)
          if (d.isDns) d.tag,
    };
    DnsViaDeadNodeMsg? banner;
    for (final e in sick.entries) {
      for (final d in e.value) {
        if (d.isDns && !prevDnsVictims.contains(d.tag)) {
          banner = DnsViaDeadNodeMsg(d.tag, e.key, d.via ?? '');
          break;
        }
      }
      if (banner != null) break;
    }
    final hasDnsVictims =
        sick.values.any((list) => list.any((d) => d.isDns));
    if (banner != null) {
      _addDebug(DebugSource.app, banner.renderEn());
      _emit(_state.copyWith(sickRoots: sick, lastError: banner));
    } else if (!hasDnsVictims && _state.lastError is DnsViaDeadNodeMsg) {
      _emit(_state.copyWith(sickRoots: sick, lastError: null));
    } else {
      _emit(_state.copyWith(sickRoots: sick));
    }
  }

  static bool _sickRootsEqual(
    Map<String, List<DependentRef>> a,
    Map<String, List<DependentRef>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || !listEquals(e.value, other)) return false;
    }
    return true;
  }

  /// §122/SPEC015 — ручной pull-to-refresh (свайп вниз на списке нод). Тянет
  /// свежий снапшот групп через unary `getGroups` (детерминированно, не
  /// пересоздавая screenClient как раньше). `null` (ядро не STARTED) → оставляем
  /// текущее; непустой → применяем. Закрывает остаточную гонку push'а.
  Future<void> pullToRefresh() async {
    if (!_state.tunnelUp) {
      _applyGroups(_state.ccGroups);
      return;
    }
    final groups = await _cc.getGroups();
    if (!_state.tunnelUp) return;
    if (groups != null) {
      _applyGroups(groups);
    } else {
      _applyGroups(_state.ccGroups);
    }
  }

  Future<void> applyGroup(String? tag) async {
    if (tag == null) {
      _emit(
        _state.copyWith(
          nodes: <String>[],
          activeInGroup: null,
          highlightedNode: null,
        ),
      );
      return;
    }
    final group = _state.groupOf(tag);
    if (group == null) return;
    final nodes = group.items.map((e) => e.tag).toList();
    final now = group.selected.isEmpty ? null : group.selected;
    _emit(
      _state.copyWith(
        nodes: nodes,
        activeInGroup: now,
        highlightedNode: now,
      ),
    );
    // §047 Шаг 2 — mirror в native-кеш: активная нода/группа (для condition-
    // плагина) + списки нод текущей группы и всех групп (для Spinner'а выбора
    // в edit-Activity setting-плагина). Покрывает авто-выбор URLTest.
    BoxVpnClient.I.setAutomationActiveState(
      node: now,
      group: tag,
      nodes: nodes,
      groups: _state.groups,
    );
    // §123 — activeInGroup стал известен → обновить подтекст шторки.
    await _pushNotificationLabels();
  }

  Future<void> switchNode(String nodeTag) async {
    final group = _state.selectedGroup;
    if (group == null || !_state.tunnelUp) return;
    final prevNode = _state.activeInGroup;
    // §290 — уже активна: не делать re-select и не рвать соединения группы
    // (interrupt-on-switch §143) на ровном месте. Общий путь UI + automation:
    // тап по подсвеченной ноде тоже не должен дёргать сеть. Ждущему Tasker'у
    // шлём лёгкое подтверждение (gated за State), иначе Wait Event уйдёт в
    // timeout — смены нет, поэтому НЕ ACTIVE_NODE_CHANGED.
    if (prevNode == nodeTag) {
      AutomationEventEmitter.I.emitNodeAlreadyActive(nodeTag, group);
      return;
    }
    _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
    try {
      // §122 — выбор ноды через CommandClient `selectOutbound` (unary RPC),
      // не Clash PUT /proxies/<group>.
      final ok = await _cc.selectOutbound(group, nodeTag);
      if (!ok) throw const FormatException('selectOutbound rejected');
      // §143 — точечный обрыв соединений переключаемой группы (opt-in тугл),
      // чтобы трафик сразу ушёл на новую ноду. §122 — через CommandClient:
      // снапшот соединений уже в `_state` (connections-стрим), id'ы цепочки
      // закрываем `closeConnection`. Best-effort.
      if (await SettingsStorage.getInterruptOnSwitch()) {
        try {
          final ids = await _connectionIdsInGroup(group);
          await Future(() async {
            for (final id in ids) {
              try {
                await _cc.closeConnection(id);
              } catch (_) {/* соединение уже закрылось — игнор */}
            }
          }).timeout(const Duration(seconds: 5), onTimeout: () {});
          _addDebug(
              DebugSource.app, 'Interrupted ${ids.length} conns in $group');
        } catch (e) {
          _addDebug(DebugSource.app, 'Interrupt-on-switch failed: $e');
        }
      }
      // §122/SPEC015 — после selectOutbound ТЯНЕМ свежий снапшот через
      // getGroups-pull, а не reloadProxies() поверх СТАРОГО `_state.ccGroups`
      // (там `selected` ещё прежний → горела старая нода до ручного свайпа).
      // Раньше выручал groups-push с новым `selected`, но он приходит не сразу/
      // не всегда — pull детерминирован. Оптимистично сразу подсветим выбранную
      // (highlightedNode уже = nodeTag), затем pull подтвердит `activeInGroup`.
      final fresh = await _cc.getGroups();
      if (fresh != null) {
        _applyGroups(fresh);
      } else {
        // ядро не отдало (редко) — пере-применим что есть + оптимистично выбор.
        _applyGroups(_state.ccGroups);
        _emit(_state.copyWith(activeInGroup: nodeTag));
      }
      _addDebug(DebugSource.app, 'Node selected: $nodeTag');
      // §047 — outgoing state event (gated, default OFF). reason=user: явный
      // выбор ноды (через UI или automation SWITCH_NODE — оба идут сюда).
      AutomationEventEmitter.I
          .emitNodeChanged(prevNode, nodeTag, group, 'user');
      // §047 Шаг 2 — mirror в native-кеш для Locale condition-плагина.
      BoxVpnClient.I.setAutomationActiveState(node: nodeTag, group: group);
    } catch (e) {
      _emit(_state.copyWith(
          lastError: PrefixedMsg(ErrPrefix.switchFailed, formatUserError(e))));
      _addDebug(DebugSource.app, 'Node switch error: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  /// §143 / §122 — id'ы активных соединений группы [group] для точечного обрыва
  /// при switchNode (interrupt-on-switch).
  ///
  /// **§122-gap закрыт после §174:** `chains` (цепочка outbound'ов
  /// selector→urltest→node) восстановлены в ядре (`Connection.chain()`-итератор,
  /// device-verified 26.06) и приходят в `CcConnection.chains`. Матчим соединение
  /// на selector-группу через `chains.contains(group)` — [group] = текущий
  /// `_state.selectedGroup`, тот же selector-тег, что в `selectOutbound` и в
  /// `chains` (urltest исключён из dropdown §078, префиксов на selector-теге нет).
  ///
  /// Снапшот соединений берём из `_cc.connections` — у стрима replay-кэш (§122),
  /// поэтому `.first` отдаёт ТЕКУЩИЙ снапшот мгновенно (не ждёт нового события).
  /// HomeState список соединений НЕ хранит (только агрегаты connectionsIn/Out).
  /// Закрываем только живые (`!isClosed`).
  Future<List<String>> _connectionIdsInGroup(String group) async {
    final conns = await _cc.connections.first
        .timeout(const Duration(seconds: 1), onTimeout: () => const []);
    return conns
        .where((c) => !c.isClosed && c.chains.contains(group))
        .map((c) => c.id)
        .where((id) => id.isNotEmpty)
        .toList();
  }

  // Ping / URLTest оркестрация (runNodeUrltest, ping-option resolve chain,
  // reloadPingOptions, _scheduleAutoPing, runGroupUrltest, runMassUrltest,
  // _runAllUrltestGroups, cancelMassPing, massPingRunning) вынесена в
  // `home_controller/ping_orchestration.dart` (`_PingMixin`).

  // ---------------------------------------------------------------------------
  // UI selection helpers
  // ---------------------------------------------------------------------------

  void setSelectedGroup(String? group) {
    final prevGroup = _state.selectedGroup;
    // §070: bump cache gen — group switch = новый pool, sort заново.
    _emit(_state.copyWith(
      selectedGroup: group,
      pingBatchGen: _state.pingBatchGen + 1,
    ));
    // §047 — outgoing state event (gated, default OFF). Эмитим только на
    // реальную смену группы (не повторный select той же).
    if (group != null && group != prevGroup) {
      AutomationEventEmitter.I.emitGroupChanged(prevGroup, group, 'user');
    }
  }

  void setHighlightedNode(String nodeTag) {
    _emit(_state.copyWith(highlightedNode: nodeTag));
  }

  void cycleSortMode() {
    // §100 — manualOrder больше НЕ сбрасывается при уходе из manual: порядок
    // персистится, повторный выбор «Custom» восстанавливает его.
    _emit(_state.copyWith(sortMode: _state.sortMode.next));
    _persistSort();
  }

  /// §100 — выбрать режим сортировки напрямую (из sort-меню), включая `manual`
  /// (раньше manual входился только через drag). При выборе manual — видимые
  /// grab-strip'ы (§098). Порядок ручной сортировки сохраняется.
  void setSortMode(NodeSortMode mode) {
    if (mode == _state.sortMode) return;
    _emit(_state.copyWith(sortMode: mode));
    _persistSort();
  }

  /// §100 — персист текущего режима + manual-порядка в `lxbox_settings.json`.
  void _persistSort() {
    unawaited(
        SettingsStorage.setNodeSort(_state.sortMode.name, _state.manualOrder));
  }

  // §070 — sort options setters (per-session toggle'ы).
  void setPinDirect(bool v) => _emit(_state.copyWith(pinDirect: v));
  void setPinAuto(bool v) => _emit(_state.copyWith(pinAuto: v));
  void setResortOnManualPing(bool v) =>
      _emit(_state.copyWith(resortOnManualPing: v));

  /// §076: external mark «running tunnel config устарел, нужен restart».
  /// Используется когда настройка применяется **вне** config pipeline:
  /// VpnService.Builder native toggles (allow_bypass / keep_on_exit /
  /// background_mode) — они set'ятся на establish(), restart обновит.
  /// Если tunnel down — флаг не set'им (новое значение подхватится на
  /// следующем start без restart'а).
  void markConfigChangedNeedRestart() {
    if (_state.tunnelUp) {
      _emit(_state.copyWith(configChangedNeedRestart: true));
    }
  }

  /// §071: commit drag-reorder в manual mode.
  /// [newOrder] — полный non-pinned порядок (без direct/auto если они pinned).
  /// Заодно переключает sortMode на `manual`.
  void commitManualReorder(List<String> newOrder) {
    _emit(_state.copyWith(
      sortMode: NodeSortMode.manual,
      manualOrder: List<String>.unmodifiable(newOrder),
    ));
    _persistSort(); // §100 — сохранить порядок ручной сортировки
  }

  void clearError() {
    if (_state.lastError != null) {
      _emit(_state.copyWith(lastError: null));
    }
  }

  /// Called when the app returns from background. Verifies tunnel health:
  ///   1. One-shot pull `getVpnStatus` → если native divergent от Dart state
  ///      (напр., service умер силой Doze/OOM пока app был suspended, и
  ///      broadcast'а не было) — прогоняем через тот же `_handleStatusEvent`,
  ///      чтобы UI синхронизировался.
  ///   2. Если после pull'а туннель всё ещё up — heartbeat для проверки что
  ///      Clash отвечает.
  ///
  /// Event-driven (не polling) — дёргается только на lifecycle resume,
  /// в steady-state ничего не крутится.
  void onAppResumed() {
    unawaited(_resyncOnResume());
  }

  /// §141 P0.2 — app ушёл в фон: останавливаем heartbeat-таймер. Это
  /// единственный always-on resident-drain (Timer.periodic(20s) → 2 loopback-
  /// HTTP + парсинг всего списка соединений на каждый тик). В фоне UI не виден,
  /// stale-state не важен, а dead-tunnel в фоне поймает native-broadcast путь
  /// (`onStatusChanged` → `_handleStatusEvent`), не heartbeat.
  ///
  /// Симметрично `onAppResumed`/`_resyncOnResume`: resume пере-синхронизирует
  /// статус и (если tunnelUp) делает немедленный `_checkHeartbeat`, который сам
  /// перезапускает таймер через первый успешный тик? Нет — `_checkHeartbeat`
  /// таймер не создаёт. Поэтому на resume рестартуем явно (см. `_resyncOnResume`).
  void onAppPaused() {
    _stopHeartbeat();
    // §286 — folder-probe sweep / auto-ping-таймер переживали фон, т.к.
    // onAppPaused гасил только status+screen-клиенты, и «молотили после
    // сворачивания». Безусловно (не завязано на tunnelUp) — headless-проба
    // папки может идти и при down-туннеле.
    // §307 — но mass-ping в фоне НЕ рвём: «запустил пинг списка и свернул» —
    // штатный сценарий, а автоперезапуска на resume нет.
    haltBackgroundProbing();
    // §164 — энергомодель: в фоне UI не виден → гасим status+screen CC-клиенты
    // (0 тиков/0 drain). profilerClient НЕ трогаем (recording живёт в фоне).
    // Выключение VPN в фоне ловит нативный broadcast (не CC) → не слепнем.
    if (_state.tunnelUp) unawaited(_cc.pauseClients());
  }

  Future<void> _resyncOnResume() async {
    try {
      final native = await _vpn.getVpnStatus();
      if (native != _state.tunnel) {
        _addDebug(DebugSource.app,
            '[vpn] onAppResumed: divergence native=${native.name} state=${_state.tunnel.name} — re-sync');
        _handleStatusEvent(TunnelStatusEvent(status: native, raw: native.name));
      }
    } catch (e) {
      _addDebug(DebugSource.app, '[vpn] onAppResumed pull error: $e');
    }
    // §164 — возврат из фона: поднимаем status(NORMAL)+screen(если потребители
    // живы). Делаем ПОСЛЕ resync статуса — если туннель за время фона лёг,
    // _handleStatusEvent уже погасил CC через _stopCcStreams, и resume не нужен.
    if (_state.tunnelUp) unawaited(_cc.resumeClients());
    // §141 P0.2 — heartbeat был остановлен на paused; если туннель всё ещё жив,
    // перезапускаем таймер и делаем немедленный тик (подтянуть свежий traffic
    // сразу, не ждать первые 20с). `_resyncOnResume` мог уже синхронизировать
    // tunnel через native-pull выше — если он лёг, `_handleStatusEvent` сам
    // не стартовал heartbeat (только connected-ветка стартует).
    if (_state.tunnelUp) {
      // §216 — инфо о пробуждении: в фоне status-стрим и heartbeat были погашены
      // (§141/§164, экономия батареи). Пишем в лог явный маркер, чтобы «тишина»
      // после сна не читалась как сбой, и взводим грейс — первый heartbeat-тик
      // не штрафуем, ждём восстановления стрима.
      _addDebug(DebugSource.app,
          'Resumed from background — re-syncing tunnel (heartbeat/streams were paused)');
      _skipNextHeartbeatFail = true;
      _startHeartbeat();
      unawaited(_checkHeartbeat());
    }
  }
}
