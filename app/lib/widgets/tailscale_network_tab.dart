import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tunnel_status.dart';
import '../screens/home/node_actions.dart' show endpointToggleErrorText;
import '../services/debug/debug_registry.dart';
import '../services/builder/taildrop_emit.dart' show taildropAllowedByBody;
import '../services/format_utils.dart' show formatBytes;
import '../services/l10n/locale_controller.dart';
import '../services/tailscale_network.dart';
import '../services/url_launcher.dart';
import '../services/wg_peer_status.dart' show wgAgeLabel;
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import 'app_bottom_sheet.dart';
import 'safe_bottom.dart';

/// Задача 581 — вызовы ядра вкладки Network. Отдельно от [CcChannel], чтобы
/// тесты подставляли свои.
class TailscaleNetworkActions {
  const TailscaleNetworkActions();

  Future<String?> setExitNode(String tag, String stableId) =>
      CcChannel.instance.setTailscaleExitNode(tag, stableId);

  Future<String?> logout(String tag) => CcChannel.instance.tailscaleLogout(tag);

  /// §645 — одиночный статус endpoint'а для опроса вкладки.
  Future<CcTailscaleStatusPoll> getStatus(String tag) =>
      CcChannel.instance.getTailscaleStatus(tag);

  Future<void> startPing(String tag, String ip) =>
      CcChannel.instance.startTailscalePing(tag, ip);

  Future<void> stopPing() => CcChannel.instance.stopTailscalePing();

  Stream<CcTailscalePingResult> get pings => CcChannel.instance.tailscalePing;

  /// §707 — входящие Taildrop: поток, подписка ядра, действия над файлами.
  Stream<CcTaildropInbox> get inbox => CcChannel.instance.taildropInbox;

  Future<void> startInbox(String tag) =>
      CcChannel.instance.startTaildropInbox(tag);

  Future<void> stopInbox() => CcChannel.instance.stopTaildropInbox();

  Future<String?> markInboxRead(String tag) =>
      CcChannel.instance.taildropMarkRead(tag);

  Future<CcTaildropResult> saveFile(String tag, String name) =>
      CcChannel.instance.taildropSave(tag, name);

  Future<String?> deleteFile(String tag, String name) =>
      CcChannel.instance.taildropDelete(tag, name);

  Future<String?> cancelReceiving(String tag, String senderId, String name) =>
      CcChannel.instance.taildropCancelReceiving(tag, senderId, name);

  /// §707 итер. 2 — автосохранение принятого в Downloads: настройка
  /// устройства по тегу узла, не тело узла. `null` — настройки нет (канал
  /// недоступен).
  Future<CcTaildropAutoSave?> getAutoSave(String tag) =>
      CcChannel.instance.taildropAutoSave(tag);

  Future<bool> setAutoSave(String tag, bool enabled) =>
      CcChannel.instance.setTaildropAutoSave(tag, enabled);

  /// §707 итер. 4 — разрешения служебных файлов от устройства [peerId]:
  /// вид команды → разрешено. `null` — канала нет.
  Future<Map<String, bool>?> getPermissions(String tag, String peerId) =>
      CcChannel.instance.taildropPermissions(tag, peerId);

  Future<bool> setPermission(String tag, CcTailscalePeer peer, String kind,
          bool allowed) =>
      CcChannel.instance.setTaildropPermission(
          tag, peer.stableId, peer.hostName, kind, allowed);

  /// §707 — системный выбор файлов и отправка пиру (передача — в нативе).
  Future<CcTaildropResult> sendFiles(String tag, CcTailscalePeer peer) =>
      CcChannel.instance.taildropPickAndSend(tag, peer.stableId, peer.hostName);

  /// §706 (ядро SPEC 149) — войти узлом [tag] с новым ключом [authKey], уже
  /// записанным в тело узла (переживёт перезапуск). Туннель не поднят — ядро
  /// не зовётся, ключ применится при старте VPN.
  Future<TailscaleKeyApply> applyNewKey(String tag, String authKey) async {
    final home = DebugRegistry.I.home;
    if (home == null || !home.state.tunnelUp) return TailscaleKeyApply.deferred;
    try {
      await CcChannel.instance.tailscaleLogin(tag, authKey);
      return TailscaleKeyApply.signingIn;
    } on PlatformException catch (e) {
      return TailscaleKeyApply.failed(e.code);
    } on MissingPluginException {
      return TailscaleKeyApply.failed('error');
    }
  }

  /// §706 — изменения состояния узлов в ядре ([endpointState]); `null` — без
  /// контроллера (тогда и состояния нет).
  Listenable? get endpointChanges => DebugRegistry.I.home;

  /// §706 — состояние узла [tag] в ядре (строки [CcEndpointState]); `null` —
  /// туннель не поднят или ядро состояния не дало.
  String? endpointState(String tag) {
    final hs = DebugRegistry.I.home?.state;
    if (hs == null || !hs.tunnelUp) return null;
    final st = hs.endpointStates[tag] ?? '';
    return st.isEmpty ? null : st;
  }

  /// §706 — выключатель узла тем же путём, что Turn off / Turn on списка
  /// узлов: `null` — успех, иначе код отказа ([HomeController.setEndpointEnabled]).
  Future<String?> setEndpointEnabled(String tag, bool enabled) async {
    final home = DebugRegistry.I.home;
    if (home == null) return 'failed_precondition';
    return home.setEndpointEnabled(tag, enabled);
  }
}

/// §706 — исход [TailscaleNetworkActions.applyNewKey].
enum TailscaleKeyApplyKind {
  /// Ядро приняло ключ, вход идёт (отказ ключа виден позже в статусе).
  signingIn,

  /// Туннель не поднят: ключ применится при старте VPN.
  deferred,

  /// Ядро отказало, код — [TailscaleKeyApply.code].
  failed,
}

class TailscaleKeyApply {
  const TailscaleKeyApply._(this.kind, [this.code = '']);
  const TailscaleKeyApply.failed(String code)
      : this._(TailscaleKeyApplyKind.failed, code);

  static const signingIn = TailscaleKeyApply._(TailscaleKeyApplyKind.signingIn);
  static const deferred = TailscaleKeyApply._(TailscaleKeyApplyKind.deferred);

  final TailscaleKeyApplyKind kind;

  /// Код отказа ядра (`failed_precondition` / `not_found` / … / `error`).
  final String code;
}

/// Задача 581 — вкладка Network узла Tailscale (экраны `node_settings_screen`
/// и `node_inspect_screen`): состояние узла, свой узел, exit node, устройства
/// сети.
///
/// [liveTag] — тег узла в работающем конфиге. [body] — тело узла (источник
/// записанного `exit_node`). [onSaveExitNode] — запись выбора в тело узла
/// (`null` убирает поле); `null` — кнопки Save choice нет (узел подписки).
class TailscaleNetworkTab extends StatefulWidget {
  const TailscaleNetworkTab({
    super.key,
    required this.liveTag,
    required this.body,
    this.onSaveExitNode,
    this.onSaveFields,
    this.statusSource,
    this.inboxSource,
    this.vpnUp,
    this.actions = const TailscaleNetworkActions(),
  });

  final String liveTag;
  final Map<String, dynamic> body;
  final Future<void> Function(String? value)? onSaveExitNode;

  /// §613 — запись полей тела узла (значение `null` убирает поле) тем же
  /// путём, что Save choice; `null` — переключателя advertise и кнопки
  /// Replace key (§706) нет (узел подписки; блок Settings тогда только с
  /// автосохранением Taildrop, §707). `true` — записано.
  final Future<bool> Function(Map<String, Object?> fields)? onSaveFields;

  /// Тесты: поток состояния вместо [CcChannel.tailscaleStatus] (подписка ядра
  /// тогда не поднимается).
  @visibleForTesting
  final Stream<List<CcTailscaleStatus>>? statusSource;

  /// §707 — тесты: поток входящих вместо [TailscaleNetworkActions.inbox].
  /// При заданном [statusSource] без него входящие не слушаются.
  @visibleForTesting
  final Stream<CcTaildropInbox>? inboxSource;

  /// Тесты: VPN включён / выключен без обращения к сервису.
  @visibleForTesting
  final bool? vpnUp;

  final TailscaleNetworkActions actions;

  @override
  State<TailscaleNetworkTab> createState() => _TailscaleNetworkTabState();
}

class _TailscaleNetworkTabState extends State<TailscaleNetworkTab>
    with WidgetsBindingObserver {
  bool _vpnUp = false;
  bool _hasData = false;
  CcTailscaleStatus? _status;
  StreamSubscription<List<CcTailscaleStatus>>? _sub;
  StreamSubscription<TunnelStatusEvent>? _vpnSub;
  bool _acquired = false;

  // Раздел «Риски»: не чаще раза в секунду.
  static const _minRedraw = Duration(seconds: 1);
  DateTime _lastRedraw = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _redrawTimer;

  /// Последняя запись узла из потока или опроса; `null` — узла нет в
  /// работающем конфиге. [_hasPending] — запись ждёт перерисовки.
  CcTailscaleStatus? _pending;
  bool _hasPending = false;

  bool _busy = false;

  /// §706 — идёт вызов выключателя (Node enabled, Restart node).
  bool _endpointBusy = false;

  // §645 — опрос `GetTailscaleStatus` раз в 3 с, пока вкладка на экране и
  // VPN включён. Ядро без метода — опрос снят до закрытия вкладки.
  static const _pollInterval = Duration(seconds: 3);
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _pollUnsupported = false;
  bool _onScreen = true;
  bool _appResumed = true;

  /// §707 итер. 6 — открыта страница устройства: опрос идёт, хотя вкладка
  /// перекрыта; [_live] — запись узла для страницы.
  bool _devicePageOpen = false;
  final _live = ValueNotifier<CcTailscaleStatus?>(null);

  /// Устройства (`stableId`), у которых раскрыты адреса сверх двух.
  final _expanded = <String>{};

  // §707 — входящие Taildrop узла: подписка ядра, пока вкладка открыта и
  // VPN включён. [_inboxListening] — слушаем ли вообще (тесты без
  // [TailscaleNetworkTab.inboxSource] — нет).
  StreamSubscription<CcTaildropInbox>? _inboxSub;
  CcTaildropInbox? _inbox;
  bool _inboxListening = false;
  bool _inboxStarted = false;

  /// Сколько принятых файлов было, когда входящие отметили прочитанными.
  int _markedFiles = 0;

  /// Файлы, по которым идёт Save / Delete / Cancel (кнопки неактивны).
  final _fileBusy = <String>{};

  /// §707 итер. 2 — переключатель автосохранения; `null` — не показывается.
  CcTaildropAutoSave? _autoSave;
  bool _autoSaveBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final life = WidgetsBinding.instance.lifecycleState;
    _appResumed = life == null || life == AppLifecycleState.resumed;
    final forced = widget.vpnUp;
    if (forced != null) {
      _vpnUp = forced;
    } else {
      unawaited(
        BoxVpnClient.I.getVpnStatus().then((s) {
          if (!mounted) return;
          setState(() => _vpnUp = s.isUp);
          _syncPolling();
          _syncInbox();
        }),
      );
      _vpnSub = BoxVpnClient.I.onStatusChanged.listen((e) {
        if (!mounted) return;
        setState(() => _vpnUp = e.status.isUp);
        _syncPolling();
        _syncInbox();
      });
    }
    final source = widget.statusSource;
    if (source != null) {
      _sub = source.listen(_onStatus);
    } else {
      // §122 — слушатель до старта подписки.
      _sub = CcChannel.instance.tailscaleStatus.listen(_onStatus);
      _acquired = true;
      unawaited(CcChannel.instance.acquireTailscaleStatus());
    }
    unawaited(_loadAutoSave());
    final inboxSource = widget.inboxSource ??
        (widget.statusSource == null ? widget.actions.inbox : null);
    if (inboxSource != null) {
      _inboxListening = true;
      _inboxSub = inboxSource.listen(_onInbox);
      _syncInbox();
    }
  }

  /// §707 — подписка ядра на входящие: поднята, пока VPN включён; после
  /// перезапуска VPN — заново (клиент прежнего сервиса умер).
  void _syncInbox() {
    if (!_inboxListening) return;
    if (_vpnUp && !_inboxStarted) {
      _inboxStarted = true;
      unawaited(widget.actions.startInbox(widget.liveTag));
    } else if (!_vpnUp && _inboxStarted) {
      _inboxStarted = false;
    }
  }

  void _onInbox(CcTaildropInbox inbox) {
    if (!mounted || inbox.tag != widget.liveTag) return;
    setState(() => _inbox = inbox);
    _markReadIfShown();
  }

  /// Блок на экране и принятых стало больше — ядру «просмотрено».
  void _markReadIfShown() {
    final files = _inbox?.files.length ?? 0;
    if (files == 0) {
      _markedFiles = 0;
      return;
    }
    if (!_onScreen || !_appResumed || files <= _markedFiles) return;
    _markedFiles = files;
    unawaited(widget.actions.markInboxRead(widget.liveTag));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Маршрут перекрыт другим или вкладка за кадром — тикеры выключены.
    _onScreen = TickerMode.valuesOf(context).enabled;
    _syncPolling();
    _markReadIfShown();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncPolling();
    _markReadIfShown();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _redrawTimer?.cancel();
    _live.dispose();
    unawaited(_sub?.cancel());
    unawaited(_vpnSub?.cancel());
    unawaited(_inboxSub?.cancel());
    if (_inboxStarted) unawaited(widget.actions.stopInbox());
    if (_acquired) unawaited(CcChannel.instance.releaseTailscaleStatus());
    super.dispose();
  }

  /// §645 — опрос идёт, пока вкладка на экране, приложение на переднем плане,
  /// VPN включён и ядро знает метод. Запуск — первый вызов сразу. Страница
  /// устройства (§707 итер. 6) считается «на экране».
  void _syncPolling() {
    final want = mounted &&
        (_onScreen || _devicePageOpen) &&
        _appResumed &&
        _vpnUp &&
        !_pollUnsupported;
    if (!want) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_pollTick()));
    unawaited(_pollTick());
  }

  /// Вызов ещё не вернулся — тик пропускается.
  Future<void> _pollTick() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final r = await widget.actions.getStatus(widget.liveTag);
      if (!mounted) return;
      if (r.unsupported) {
        _pollUnsupported = true;
        _syncPolling();
        return;
      }
      final s = r.status;
      // Пропуск тика: тег не найден, endpoint не запущен, опрос снят.
      if (s == null || s.tag != widget.liveTag || _pollTimer == null) return;
      _offer(s);
    } finally {
      _pollInFlight = false;
    }
  }

  void _onStatus(List<CcTailscaleStatus> list) =>
      _offer(list.where((s) => s.tag == widget.liveTag).firstOrNull);

  /// Запись из потока или опроса: на экране — пришедшая последней.
  void _offer(CcTailscaleStatus? s) {
    _pending = s;
    _hasPending = true;
    final wait = _minRedraw - DateTime.now().difference(_lastRedraw);
    if (!_hasData || wait <= Duration.zero) {
      _applyPending();
      return;
    }
    _redrawTimer ??= Timer(wait, () {
      _redrawTimer = null;
      _applyPending();
    });
  }

  void _applyPending() {
    if (!_hasPending || !mounted) return;
    final s = _pending;
    _pending = null;
    _hasPending = false;
    _lastRedraw = DateTime.now();
    setState(() {
      _hasData = true;
      _status = s;
    });
    _live.value = s;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _snack(getLocalText.s("Copied"));
  }

  @override
  Widget build(BuildContext context) {
    if (!_vpnUp) {
      return _centerText(getLocalText.s("Start VPN to see the network."));
    }
    if (!_hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _status;
    if (s == null) {
      return _centerText(
        getLocalText.s("The node is not in the running config."),
      );
    }
    // Выход остаётся и в Devices: меню строки (пинг, копирование) есть только
    // там, у пункта Exit node его нет.
    final devices = sortDevices(s.peers);
    final grouped = showOwnerGroups(s);
    // §706 — вне сети активного выхода у ядра нет: выбор и сверка с
    // записанным только в Running, иначе — записанное значение строкой.
    final running = s.backendState == 'Running';
    final recordedExit = recordedExitNode(widget.body);
    final children = <Widget>[
      if (s.health.isNotEmpty) _healthBlock(context, s.health),
      _statusSection(context, s),
      if (s.self != null) _thisDeviceBlock(context, s.self!, running),
      if (running)
        _exitNodeBlock(context, s)
      else if (recordedExit != null)
        _savedExitNodeBlock(context, recordedExit),
      if (widget.onSaveFields != null || (_autoSave != null && _taildropOn))
        _settingsBlock(context),
      _devicesHeader(context, devices),
      if (devices.isEmpty)
        ListTile(dense: true, title: Text(getLocalText.s("No devices"))),
    ];
    // Устройства — ленивой частью списка (сети из сотен устройств).
    final rows = <Object>[];
    if (grouped) {
      for (final g in s.userGroups) {
        if (g.peers.isEmpty) continue;
        rows.add(g.title);
        rows.addAll(sortDevices(g.peers));
      }
    } else {
      rows.addAll(devices);
    }
    // §707 — входящие под Devices.
    final inbox = _inboxRows(context, s);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24).withSafeBottom(context),
      itemCount: children.length + rows.length + inbox.length,
      itemBuilder: (ctx, i) {
        if (i < children.length) return children[i];
        if (i >= children.length + rows.length) {
          return inbox[i - children.length - rows.length];
        }
        final r = rows[i - children.length];
        if (r is String) return _groupTitle(ctx, r);
        return _deviceRow(ctx, s, r as CcTailscalePeer);
      },
    );
  }

  Widget _centerText(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  /// §645 — `Devices` и вторичным цветом `· 2 online / 6` (всего — устройства
  /// списка).
  Widget _devicesHeader(BuildContext context, List<CcTailscalePeer> devices) {
    final theme = Theme.of(context);
    final online = devices.where((p) => p.online).length;
    final counts = getLocalText.s(
      "%s online / %s",
      '$online',
      '${devices.length}',
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: getLocalText.s("Devices")),
            if (devices.isNotEmpty)
              TextSpan(
                text: ' · $counts',
                style: TextStyle(
                  fontWeight: FontWeight.normal,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        key: const ValueKey('tailscale-devices-header'),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _groupTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  // ── Status ──

  /// §706 — блок Status перерисовывается и по состоянию узла в ядре
  /// (выключатель, Restart node), не только по статусу Tailscale.
  Widget _statusSection(BuildContext context, CcTailscaleStatus s) {
    final changes = widget.actions.endpointChanges;
    if (changes == null) return _statusBlock(context, s);
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) => _statusBlock(context, s),
    );
  }

  Widget _statusBlock(BuildContext context, CcTailscaleStatus s) {
    final needsLogin = s.backendState == 'NeedsLogin';
    final running = s.backendState == 'Running';
    // §706 — ключ отвергнут или его нет: заменить можно только у узла,
    // который пишется с вкладки (узел подписки — нет).
    final replaceKey = needsLogin && widget.onSaveFields != null;
    // §706 (ядро SPEC 149) — выключатель и перезапуск узла, пока туннель
    // поднят и ядро отдало состояние узла.
    final ep = widget.actions.endpointState(widget.liveTag);
    final restart = ep != null && ep != CcEndpointState.disabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("Status")),
        ListTile(
          dense: true,
          title: Text(tailscaleStateLabel(s)),
          subtitle: s.networkName.isEmpty ? null : Text(s.networkName),
          // §706 — вне сети ключ мог быть отвергнут: чип только в Running.
          trailing: s.keyAuth && running
              ? Chip(label: Text(getLocalText.s("signed in with a key")))
              : null,
        ),
        if (ep != null)
          SwitchListTile(
            key: const ValueKey('tailscale-node-enabled'),
            dense: true,
            title: Text(getLocalText.s("Node enabled")),
            subtitle: Text(getLocalText
                .s("Stays off until you turn it on or stop the VPN.")),
            value: ep != CcEndpointState.disabled,
            onChanged: _endpointBusy
                ? null
                : (on) => unawaited(_setNodeEnabled(on)),
          ),
        if ((needsLogin && s.authUrl.isNotEmpty) ||
            running ||
            replaceKey ||
            restart)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                if (needsLogin && s.authUrl.isNotEmpty)
                  FilledButton(
                    onPressed: () => unawaited(UrlLauncher.open(s.authUrl)),
                    child: Text(getLocalText.s("Sign in")),
                  ),
                if (running)
                  OutlinedButton(
                    onPressed: _busy ? null : () => unawaited(_logout(s)),
                    child: Text(getLocalText.s("Log out")),
                  ),
                if (replaceKey)
                  OutlinedButton(
                    key: const ValueKey('tailscale-replace-key'),
                    onPressed: _busy ? null : () => unawaited(_replaceKey()),
                    child: Text(getLocalText.s("Replace key")),
                  ),
                if (restart)
                  OutlinedButton(
                    key: const ValueKey('tailscale-restart-node'),
                    onPressed:
                        _endpointBusy ? null : () => unawaited(_restartNode()),
                    child: Text(getLocalText.s("Restart node")),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _logout(CcTailscaleStatus s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Log out?")),
        content: Text(
          s.keyAuth
              ? getLocalText.s(
                  "The node leaves the network. The node has a sign-in key, so it signs in again on the next start.",
                )
              : getLocalText.s(
                  "The node leaves the network. To join again, sign in from this tab.",
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Log out")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final err = await widget.actions.logout(widget.liveTag);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _snack(getLocalText.s("Failed: %s", err));
  }

  /// §706 — Replace key: новый ключ пишется в тело узла тем же путём, что
  /// Save choice, затем [TailscaleNetworkActions.applyNewKey].
  Future<void> _replaceKey() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => const _ReplaceKeyDialog(),
    );
    final save = widget.onSaveFields;
    if (key == null || save == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await save({'auth_key': key})) return;
      final r = await widget.actions.applyNewKey(widget.liveTag, key);
      _snack(switch (r.kind) {
        TailscaleKeyApplyKind.signingIn =>
          getLocalText.s("Signing in with the new key…"),
        TailscaleKeyApplyKind.deferred =>
          getLocalText.s("Key saved. It applies when the VPN starts."),
        TailscaleKeyApplyKind.failed => r.code == 'failed_precondition' &&
                widget.actions.endpointState(widget.liveTag) ==
                    CcEndpointState.disabled
            ? getLocalText.s("Turn the node on first.")
            : getLocalText.s("Could not sign in with the new key."),
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §706 — Node enabled: тот же путь и тексты отказа, что Turn off / Turn on
  /// списка узлов.
  Future<void> _setNodeEnabled(bool enable) async {
    setState(() => _endpointBusy = true);
    try {
      final code =
          await widget.actions.setEndpointEnabled(widget.liveTag, enable);
      if (code != null) {
        _snack(endpointToggleErrorText(code, widget.liveTag, enable: enable));
      }
    } finally {
      if (mounted) setState(() => _endpointBusy = false);
    }
  }

  /// §706 — Restart node: выключить и сразу включить узел в ядре.
  Future<void> _restartNode() async {
    setState(() => _endpointBusy = true);
    try {
      final tag = widget.liveTag;
      final off = await widget.actions.setEndpointEnabled(tag, false);
      if (off != null) {
        _snack(endpointToggleErrorText(off, tag, enable: false));
        return;
      }
      final on = await widget.actions.setEndpointEnabled(tag, true);
      _snack(on == null
          ? getLocalText.s("Node restarted.")
          : endpointToggleErrorText(on, tag, enable: true));
    } finally {
      if (mounted) setState(() => _endpointBusy = false);
    }
  }

  // ── This device ──

  Widget _thisDeviceBlock(
    BuildContext context,
    CcTailscalePeer self,
    bool running,
  ) {
    // §706 — вне сети ядро имени ещё не знает (или отдаёт `localhost`).
    final unknownName =
        !running && (self.hostName.isEmpty || self.hostName == 'localhost');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("This device")),
        if (unknownName)
          ListTile(
            dense: true,
            title: Text(getLocalText.s("Name")),
            subtitle: const Text('—'),
          )
        else
          _copyTile(getLocalText.s("Name"), self.hostName),
        _copyTile(getLocalText.s("MagicDNS name"), self.dnsNameClean),
        if (self.ips.isNotEmpty) _addressTile(self.ips),
        if (self.keyExpiry > 0)
          ListTile(
            dense: true,
            title: Text(getLocalText.s("Key expiry")),
            subtitle: Text(_date(self.keyExpiry)),
          ),
      ],
    );
  }

  Widget _copyTile(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(value),
      onTap: () => unawaited(_copy(value)),
    );
  }

  /// §645 — один заголовок Address, адреса столбиком в порядке ядра; тап по
  /// строке копирует этот адрес.
  Widget _addressTile(List<String> ips) => ListTile(
    dense: true,
    title: Text(getLocalText.s("Address")),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final ip in ips)
          InkWell(
            onTap: () => unawaited(_copy(ip)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(ip),
            ),
          ),
      ],
    ),
  );

  static String _date(int unixSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // ── Exit node ──

  /// §706 — узел не в Running: записанный `exit_node` строкой, без выбора и
  /// без Save choice (активного выхода у ядра нет, сверять не с чем).
  Widget _savedExitNodeBlock(BuildContext context, String recorded) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("Exit node")),
        ListTile(
          key: const ValueKey('tailscale-saved-exit-node'),
          dense: true,
          title: Text(getLocalText.s("Saved: %s", recorded)),
          subtitle: Text(getLocalText.s("Applies when the node is online.")),
        ),
      ],
    );
  }

  Widget _exitNodeBlock(BuildContext context, CcTailscaleStatus s) {
    final options = exitNodeOptions(s);
    final active = s.exitNode;
    final recorded = recordedExitNode(widget.body);
    final mismatch = exitNodeMismatch(
      recorded: recorded,
      active: active,
      magicDnsSuffix: s.magicDnsSuffix,
    );
    final activeId = active?.stableId ?? '';
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _header(context, getLocalText.s("Exit node"))),
            if (mismatch != ExitNodeMismatch.none)
              Padding(
                padding: const EdgeInsets.only(right: 16, top: 12),
                child: Icon(
                  Icons.warning_amber_rounded,
                  key: const ValueKey('exit-node-warning'),
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        RadioGroup<String>(
          groupValue: activeId,
          onChanged: (v) {
            if (v != null && !_busy) unawaited(_choose(v));
          },
          child: Column(
            children: [
              RadioListTile<String>(
                dense: true,
                value: '',
                title: Text(getLocalText.s("None")),
              ),
              for (final p in options)
                RadioListTile<String>(
                  dense: true,
                  value: p.stableId,
                  title: Text(p.hostName),
                  subtitle: _exitSubtitle(p, active),
                ),
            ],
          ),
        ),
        if (mismatch != ExitNodeMismatch.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              exitNodeWarningText(mismatch),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (mismatch != ExitNodeMismatch.none && widget.onSaveExitNode != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: FilledButton(
              onPressed: _busy ? null : () => unawaited(_save(active)),
              child: Text(getLocalText.s("Save choice")),
            ),
          ),
      ],
    );
  }

  Future<void> _choose(String stableId) async {
    setState(() => _busy = true);
    final err = await widget.actions.setExitNode(widget.liveTag, stableId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) _snack(getLocalText.s("Failed: %s", err));
  }

  Future<void> _save(CcTailscalePeer? active) async {
    final save = widget.onSaveExitNode;
    if (save == null) return;
    setState(() => _busy = true);
    try {
      await save(active == null ? null : exitNodeConfigValue(active));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §613 — строка пути устройства: путь и возраст хендшейка (`0` — без
  /// возраста). `NONE` — пусто, строка не рисуется.
  static String _pathLine(CcTailscalePeer p) {
    final path = tailscalePathLabel(p);
    if (path.isEmpty) return '';
    if (p.lastHandshake <= 0) return path;
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - p.lastHandshake;
    return '$path · ${getLocalText.s("handshake %s", wgAgeLabel(age))}';
  }

  /// §613 — подпись пункта Exit node: у действующего выхода — путь до него
  /// (§645 — с иконкой пути).
  Widget? _exitSubtitle(CcTailscalePeer p, CcTailscalePeer? active) {
    final offline = p.online ? '' : getLocalText.s("offline");
    final path = active != null && active.stableId == p.stableId
        ? _pathLine(active)
        : '';
    if (offline.isEmpty && path.isEmpty) return null;
    return Text.rich(
      TextSpan(
        children: [
          if (offline.isNotEmpty)
            TextSpan(text: path.isEmpty ? offline : '$offline · '),
          if (path.isNotEmpty) ..._pathSpans(tailscalePathKind(active!), path),
        ],
      ),
    );
  }

  /// §645 — иконка пути (цветная только она) и текст подписи.
  static List<InlineSpan> _pathSpans(TailscalePathKind? kind, String text) {
    final look = tailscalePathIcon(kind);
    return [
      if (look != null)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(look.icon, size: 15, color: look.color),
          ),
        ),
      TextSpan(text: text),
    ];
  }

  // ── Settings ──

  /// §613 — `advertise_exit_node` тела узла. Ядро не совмещает его с
  /// `exit_node` (реестр: `field_conflict`) — при записанном выходе его можно
  /// только снять. `exit_node_allow_lan_access` в UI нет (§646): ядро на
  /// Android его не применяет, локальную сеть ведёт пресет «Private IPs».
  Widget _settingsBlock(BuildContext context) {
    final body = widget.body;
    final hasExit = recordedExitNode(body) != null;
    final advertise = body['advertise_exit_node'] == true;
    final autoSave = _taildropOn ? _autoSave : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, getLocalText.s("Settings")),
        if (widget.onSaveFields != null) SwitchListTile(
          key: const ValueKey('tailscale-advertise-exit'),
          dense: true,
          title: Text(getLocalText.s("Advertise this device as exit node")),
          subtitle: hasExit && !advertise
              ? Text(
                  getLocalText.s("Not available while an exit node is used."),
                )
              : null,
          value: advertise,
          onChanged: _busy || (hasExit && !advertise)
              ? null
              : (v) => unawaited(_saveField('advertise_exit_node', v)),
        ),
        // §707 итер. 4 — «Allow Taildrop»: вкл пишет в тело
        // `disable_taildrop: false`, выкл снимает поле (сборка тогда пишет
        // `true`, контракт 1.1.150). Ядро на лету не переключает — действует
        // после перезапуска VPN, как прочие поля узла.
        if (widget.onSaveFields != null) SwitchListTile(
          key: const ValueKey('tailscale-allow-taildrop'),
          dense: true,
          title: Text(getLocalText.s("Allow Taildrop (send and receive files)")),
          value: _taildropOn,
          onChanged: _busy
              ? null
              : (v) => unawaited(_saveTaildrop(v)),
        ),
        if (autoSave != null)
          SwitchListTile(
            key: const ValueKey('tailscale-taildrop-autosave'),
            dense: true,
            title: Text(getLocalText.s("Save received files to Downloads")),
            subtitle: autoSave.supported
                ? null
                : Text(getLocalText.s("Needs Android 10 or later.")),
            value: autoSave.enabled && autoSave.supported,
            onChanged: _autoSaveBusy || !autoSave.supported
                ? null
                : (v) => unawaited(_setAutoSave(v)),
          ),
      ],
    );
  }

  /// §707 итер. 2 — настройка автосохранения узла (своя у каждого тега).
  Future<void> _loadAutoSave() async {
    final v = await widget.actions.getAutoSave(widget.liveTag);
    if (!mounted || v == null) return;
    setState(() => _autoSave = v);
  }

  Future<void> _setAutoSave(bool enabled) async {
    final cur = _autoSave;
    if (cur == null) return;
    setState(() => _autoSaveBusy = true);
    final ok = await widget.actions.setAutoSave(widget.liveTag, enabled);
    if (!mounted) return;
    setState(() {
      _autoSaveBusy = false;
      if (ok) {
        _autoSave = CcTaildropAutoSave(enabled: enabled, supported: cur.supported);
      }
    });
  }

  /// §707 итер. 4 — Taildrop узла включён: явное `disable_taildrop: false`
  /// в теле (нет поля — выключен, контракт 1.1.150).
  bool get _taildropOn => taildropAllowedByBody(widget.body);

  /// Вкл — `false` в тело, выкл — поле снимается.
  Future<void> _saveTaildrop(bool allow) async {
    final save = widget.onSaveFields;
    if (save == null) return;
    setState(() => _busy = true);
    try {
      await save({'disable_taildrop': allow ? false : null});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Выключенное значение — поле убирается (по умолчанию `false`).
  Future<void> _saveField(String key, bool value) async {
    final save = widget.onSaveFields;
    if (save == null) return;
    setState(() => _busy = true);
    try {
      await save({key: value ? true : null});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Health ──

  /// §613 (ядро SPEC 115) — предупреждения бэкенда, по строке на запись.
  /// Текст ядра, не переводится.
  Widget _healthBlock(BuildContext context, List<String> health) {
    final theme = Theme.of(context);
    const color = Colors.orange;
    return Container(
      key: const ValueKey('tailscale-health'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in health)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(h, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Devices ──

  /// §645 — строка устройства:
  /// 1. точка в сети / нет, имя; справа первый адрес;
  /// 2. ОС и роли; справа второй адрес и `+N` (раскрывает остальные адреса);
  /// 3. как подключено ([tailscaleConnectionText]) с иконкой пути.
  ///
  /// Не влезает по ширине — обрезается левая часть, адрес справа целый.
  Widget _deviceRow(
    BuildContext context,
    CcTailscaleStatus s,
    CcTailscalePeer p,
  ) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final tail = tailscaleAddressTail(p.ips);
    final expanded = tail.more > 0 && _expanded.contains(p.stableId);
    final details = tailscaleDeviceDetails(p);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final connection = tailscaleConnectionText(p, now);
    final rowKey = p.stableId.isEmpty ? p.hostName : p.stableId;
    return ListTile(
      key: ValueKey('tailscale-device-$rowKey'),
      dense: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              p.hostName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (p.firstIp.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(p.firstIp, style: small),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (details.isNotEmpty || tail.second.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
                if (tail.second.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _secondAddress(p, tail, expanded, small),
                ],
              ],
            ),
          if (expanded)
            for (final ip in p.ips.skip(2))
              Align(
                alignment: Alignment.centerRight,
                child: Text(ip, style: small),
              ),
          if (connection.isNotEmpty)
            Text.rich(
              TextSpan(children: _pathSpans(tailscalePathKind(p), connection)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small,
            ),
        ],
      ),
      leading: Icon(
        Icons.circle,
        size: 10,
        color: p.online ? Colors.green : theme.disabledColor,
      ),
      onTap: () => unawaited(_openDevice(p)),
      onLongPress: () =>
          unawaited(_copy(p.firstIp.isNotEmpty ? p.firstIp : p.hostName)),
    );
  }

  /// Второй адрес; при адресах сверх двух — `+N` и стрелка, тап раскрывает и
  /// сворачивает остальные адреса.
  Widget _secondAddress(
    CcTailscalePeer p,
    ({String second, int more}) tail,
    bool expanded,
    TextStyle? style,
  ) {
    final address = Text(tail.second, style: style);
    if (tail.more == 0) return address;
    return InkWell(
      key: ValueKey('tailscale-more-${p.stableId}'),
      onTap: () => setState(() {
        if (!_expanded.remove(p.stableId)) _expanded.add(p.stableId);
      }),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          address,
          const SizedBox(width: 4),
          Text('+${tail.more}', style: style), // l10n-exempt: count
          Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16),
        ],
      ),
    );
  }

  // ── Taildrop (§707) ──

  Future<void> _sendFiles(CcTailscalePeer p) async {
    final r = await widget.actions.sendFiles(widget.liveTag, p);
    if (!mounted) return;
    switch (r.status) {
      case 'started':
        _snack(getLocalText.s("Sending to %s", p.hostName));
      case 'cancelled':
        break;
      default:
        _snack(getLocalText.s("Couldn't send: %s", _reason(r.error)));
    }
  }

  /// Причина отказа из натива: коды — подписью, прочее — текстом ядра.
  static String _reason(String code) => switch (code) {
    'vpn_off' => getLocalText.s("the VPN is off"),
    'cant_read' => getLocalText.s("can't read the file"),
    'no file picker' => getLocalText.s("no file picker on this device"),
    _ => code, // l10n-exempt: core error text as is
  };

  /// Строки блока Inbox: пусто и право есть — блока нет.
  List<Widget> _inboxRows(BuildContext context, CcTailscaleStatus s) {
    if (!_inboxListening) return const [];
    // §707 итер. 4 — Taildrop узла выключен: входящих нет, вместо блока —
    // строка (лежащие файлы остаются на диске до включения).
    if (!_taildropOn) {
      return [
        ListTile(
          key: const ValueKey('taildrop-node-off'),
          dense: true,
          leading: const Icon(Icons.info_outline),
          title: Text(getLocalText.s("Taildrop is off for this node.")),
        ),
      ];
    }
    final inbox = _inbox;
    final sharingOff = s.backendState == 'Running' && !s.canShareFiles;
    final empty = inbox == null || inbox.isEmpty;
    if (empty && !sharingOff) return const [];
    return [
      _header(context, getLocalText.s("Inbox")),
      if (sharingOff)
        ListTile(
          key: const ValueKey('taildrop-sharing-off'),
          dense: true,
          leading: const Icon(Icons.info_outline),
          title: Text(getLocalText.s(
            "File sharing is off for this tailnet. Turn on Taildrop in the "
            "Tailscale admin console.",
          )),
        ),
      if (inbox != null) ...[
        for (final r in inbox.receiving) _receivingRow(context, r),
        for (final f in inbox.files) _fileRow(context, f),
      ],
    ];
  }

  Widget _receivingRow(BuildContext context, CcTaildropReceiving r) {
    final small = Theme.of(context).textTheme.bodySmall;
    final key = 'rx:${r.senderId}/${r.name}';
    final amount = r.size > 0
        ? getLocalText.s(
            "%s of %s",
            formatBytes(r.receivedBytes, spaced: true),
            formatBytes(r.size, spaced: true),
          )
        : formatBytes(r.receivedBytes, spaced: true);
    return ListTile(
      key: ValueKey('taildrop-receiving-${r.senderId}-${r.name}'),
      dense: true,
      leading: const Icon(Icons.downloading),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            r.senderName.isEmpty
                ? amount
                : '$amount · ${getLocalText.s("from %s", r.senderName)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: r.progress),
        ],
      ),
      trailing: TextButton(
        onPressed: _fileBusy.contains(key)
            ? null
            : () => unawaited(_cancelReceiving(r, key)),
        child: Text(getLocalText.s("Cancel")),
      ),
    );
  }

  Widget _fileRow(BuildContext context, CcTaildropFile f) {
    final small = Theme.of(context).textTheme.bodySmall;
    final key = 'file:${f.name}';
    final busy = _fileBusy.contains(key);
    final size = formatBytes(f.size, spaced: true);
    return ListTile(
      key: ValueKey('taildrop-file-${f.name}'),
      dense: true,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        f.senderName.isEmpty
            ? size
            : '$size · ${getLocalText.s("from %s", f.senderName)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: small,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: getLocalText.s("Save"),
            icon: const Icon(Icons.download),
            onPressed: busy ? null : () => unawaited(_saveFile(f, key)),
          ),
          IconButton(
            tooltip: getLocalText.s("Delete"),
            icon: const Icon(Icons.delete_outline),
            onPressed: busy ? null : () => unawaited(_deleteFile(f, key)),
          ),
        ],
      ),
    );
  }

  Future<void> _withBusy(String key, Future<void> Function() body) async {
    setState(() => _fileBusy.add(key));
    try {
      await body();
    } finally {
      if (mounted) setState(() => _fileBusy.remove(key));
    }
  }

  Future<void> _saveFile(CcTaildropFile f, String key) => _withBusy(key, () async {
    final r = await widget.actions.saveFile(widget.liveTag, f.name);
    if (!mounted) return;
    switch (r.status) {
      case 'saved':
        _snack(r.where == 'downloads'
            ? getLocalText.s("Saved to Downloads")
            : getLocalText.s("Saved"));
      case 'cancelled':
        break;
      default:
        _snack(getLocalText.s("Couldn't save: %s", _reason(r.error)));
    }
  });

  Future<void> _deleteFile(CcTaildropFile f, String key) => _withBusy(key, () async {
    final err = await widget.actions.deleteFile(widget.liveTag, f.name);
    if (!mounted || err == null) return;
    _snack(getLocalText.s("Couldn't delete: %s", err));
  });

  Future<void> _cancelReceiving(CcTaildropReceiving r, String key) =>
      _withBusy(key, () async {
        final err = await widget.actions
            .cancelReceiving(widget.liveTag, r.senderId, r.name);
        if (!mounted || err == null) return;
        _snack(getLocalText.s("Couldn't cancel: %s", err));
      });

  /// §707 итер. 6 — страница устройства: сводка, Ping и Send file…,
  /// адреса с копированием, разрешения служебных файлов от устройства.
  Future<void> _openDevice(CcTailscalePeer p) async {
    final perms = _taildropOn && p.stableId.isNotEmpty && !p.shareeNode
        ? await widget.actions.getPermissions(widget.liveTag, p.stableId)
        : null;
    if (!mounted) return;
    _live.value = _status;
    _devicePageOpen = true;
    _syncPolling();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _DevicePage(
            initial: p,
            live: _live,
            tag: widget.liveTag,
            actions: widget.actions,
            permissions: perms,
            sendBlock: _sendBlock,
            onSend: _sendFiles,
            onCopy: _copy,
            onPermission: (kind, v) =>
                widget.actions.setPermission(widget.liveTag, p, kind, v),
          ),
        ),
      );
    } finally {
      _devicePageOpen = false;
      if (mounted) _syncPolling();
    }
  }

  /// Почему Send file… неактивна; `null` — отправить можно. Выключенный
  /// Taildrop на той стороне ядро не публикует — он выясняется отказом при
  /// отправке.
  String? _sendBlock(CcTailscalePeer p) {
    if (!_taildropOn) return getLocalText.s("Taildrop is off for this node.");
    if (!(_status?.canShareFiles ?? false)) {
      return getLocalText.s("File sharing is off in this tailnet.");
    }
    if (!p.online) return getLocalText.s("Device is offline.");
    if (p.shareeNode) return getLocalText.s("Device belongs to another user.");
    if (!p.canReceiveFiles) return getLocalText.s("Device can't receive files.");
    return null;
  }
}

/// §645 — иконка и цвет пути до устройства: напрямую — молния цвета точки
/// «в сети», через DERP и через пира-ретранслятора — оранжевые; пути нет —
/// без иконки.
({IconData icon, Color color})? tailscalePathIcon(
  TailscalePathKind? kind,
) => switch (kind) {
  TailscalePathKind.direct => (icon: Icons.bolt, color: Colors.green),
  TailscalePathKind.derp => (icon: Icons.cloud_outlined, color: Colors.orange),
  TailscalePathKind.peerRelay => (icon: Icons.device_hub, color: Colors.orange),
  null => null,
};

/// Подпись состояния узла — значения таблицы раздела 3 спеки 579; прочие
/// состояния — текстом ядра.
String tailscaleStateLabel(CcTailscaleStatus s) => switch (s.backendState) {
  'Running' => getLocalText.s("running"),
  'NeedsLogin' => getLocalText.s("sign-in needed"),
  'Stopped' => getLocalText.s("stopped"),
  _ =>
    s.stateText.isNotEmpty
        ? s
              .stateText // l10n-exempt: core state text as is
        : s.backendState, // l10n-exempt: core state as is
};

/// Задача 581 раздел 7 — проверка устройства: до закрытия листа или пяти
/// ответов.
class TailscalePingSheet extends StatefulWidget {
  const TailscalePingSheet({
    super.key,
    required this.tag,
    required this.peer,
    this.actions = const TailscaleNetworkActions(),
  });

  final String tag;
  final CcTailscalePeer peer;
  final TailscaleNetworkActions actions;

  static const maxReplies = 5;

  @override
  State<TailscalePingSheet> createState() => _TailscalePingSheetState();
}

class _TailscalePingSheetState extends State<TailscalePingSheet> {
  final _results = <CcTailscalePingResult>[];
  StreamSubscription<CcTailscalePingResult>? _sub;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.actions.pings.listen((r) {
      if (!mounted || _stopped) return;
      setState(() => _results.add(r));
      if (_results.length >= TailscalePingSheet.maxReplies) _stop();
    });
    unawaited(widget.actions.startPing(widget.tag, widget.peer.firstIp));
  }

  void _stop() {
    if (_stopped) return;
    _stopped = true;
    unawaited(widget.actions.stopPing());
  }

  @override
  void dispose() {
    _stop();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peer.hostName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_results.isEmpty && !_stopped) const LinearProgressIndicator(),
            for (final r in _results)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(_line(r), style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }

  static String _line(CcTailscalePingResult r) {
    if (r.error.isNotEmpty) return getLocalText.s("No reply: %s", r.error);
    final ms = r.latencyMs.toStringAsFixed(r.latencyMs < 10 ? 1 : 0);
    if (r.isDirect) {
      return r.endpoint.isEmpty
          ? getLocalText.s("%s ms, direct", ms)
          : getLocalText.s("%s ms, direct, %s", ms, r.endpoint);
    }
    return r.derpRegionCode.isEmpty
        ? getLocalText.s("%s ms, relay", ms)
        : getLocalText.s("%s ms, relay %s", ms, r.derpRegionCode);
  }
}

/// §706 — диалог Replace key: одно скрытое поле (как Auth key мастера Add
/// server → Tailscale). Возвращает ключ без пробелов по краям; пустой Save не
/// принимает.
class _ReplaceKeyDialog extends StatefulWidget {
  const _ReplaceKeyDialog();

  @override
  State<_ReplaceKeyDialog> createState() => _ReplaceKeyDialogState();
}

class _ReplaceKeyDialogState extends State<_ReplaceKeyDialog> {
  final _ctrl = TextEditingController();
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = _ctrl.text.trim();
    return AlertDialog(
      title: Text(getLocalText.s("Replace key")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('tailscale-replace-key-field'),
            controller: _ctrl,
            autofocus: true,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: getLocalText.s("Auth key"),
              // l10n-exempt: key format sample
              hintText: 'tskey-auth-…',
              suffixIcon: IconButton(
                tooltip: _show
                    ? getLocalText.s("Hide")
                    : getLocalText.s("Show"),
                icon: Icon(
                  _show ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        FilledButton(
          key: const ValueKey('tailscale-replace-key-save'),
          onPressed: key.isEmpty ? null : () => Navigator.pop(context, key),
          child: Text(getLocalText.s("Save")),
        ),
      ],
    );
  }
}

/// §707 итер. 6 — страница устройства (макет — в задаче 707): сводка,
/// Ping и Send file…, адреса с копированием по тапу, разрешения служебных
/// файлов. Запись устройства берётся из [live] по stable ID; пропало из
/// записи — остаётся последнее известное.
class _DevicePage extends StatefulWidget {
  const _DevicePage({
    required this.initial,
    required this.live,
    required this.tag,
    required this.actions,
    required this.permissions,
    required this.sendBlock,
    required this.onSend,
    required this.onCopy,
    required this.onPermission,
  });

  final CcTailscalePeer initial;
  final ValueListenable<CcTailscaleStatus?> live;
  final String tag;
  final TailscaleNetworkActions actions;
  final Map<String, bool>? permissions;
  final String? Function(CcTailscalePeer) sendBlock;
  final Future<void> Function(CcTailscalePeer) onSend;
  final Future<void> Function(String) onCopy;
  final Future<bool> Function(String kind, bool allowed) onPermission;

  @override
  State<_DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<_DevicePage> {
  late CcTailscalePeer _peer = widget.initial;

  CcTailscalePeer _current(CcTailscaleStatus? s) {
    final id = widget.initial.stableId;
    final found = s?.peers.where(
      (p) => id.isNotEmpty
          ? p.stableId == id
          : p.hostName == widget.initial.hostName,
    );
    if (found != null && found.isNotEmpty) _peer = found.first;
    return _peer;
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<CcTailscaleStatus?>(
        valueListenable: widget.live,
        builder: (context, s, _) => _page(context, _current(s)),
      );

  Widget _page(BuildContext context, CcTailscalePeer p) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final connection = tailscaleConnectionText(p, now);
    final summary = [
      p.online ? getLocalText.s("online") : getLocalText.s("offline"),
      if (tailscaleDeviceDetails(p) case final d when d.isNotEmpty) d,
    ].join(' · '); // l10n-exempt: separator
    final block = widget.sendBlock(p);
    final perms = widget.permissions;
    return Scaffold(
      appBar: AppBar(title: Text(p.hostName)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16).withSafeBottom(context),
        children: [
          ListTile(
            key: const ValueKey('tailscale-device-summary'),
            leading: Icon(
              Icons.circle,
              size: 10,
              color: p.online ? Colors.green : theme.disabledColor,
            ),
            title: Text(summary),
            subtitle: connection.isEmpty
                ? null
                : Text.rich(
                    TextSpan(
                      children: _TailscaleNetworkTabState._pathSpans(
                        tailscalePathKind(p),
                        connection,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                if (p.firstIp.isNotEmpty) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('tailscale-device-ping'),
                      icon: const Icon(Icons.network_ping),
                      label: Text(getLocalText.s("Ping")),
                      onPressed: () => unawaited(_ping(p)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('tailscale-device-send'),
                    icon: const Icon(Icons.upload_file),
                    label: Text(getLocalText.s("Send file…")),
                    onPressed:
                        block == null ? () => unawaited(widget.onSend(p)) : null,
                  ),
                ),
              ],
            ),
          ),
          if (block != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                block,
                key: const ValueKey('tailscale-device-send-block'),
                style: small,
              ),
            ),
          _header(context, getLocalText.s("Addresses")),
          _copyRow(context, getLocalText.s("Name"), p.hostName),
          if (p.dnsNameClean.isNotEmpty)
            _copyRow(
              context,
              'MagicDNS', // l10n-exempt: product name
              p.dnsNameClean,
            ),
          for (final ip in p.ips)
            _copyRow(
              context,
              ip.contains(':')
                  ? 'IPv6' // l10n-exempt: protocol name
                  : 'IPv4', // l10n-exempt: protocol name
              ip,
            ),
          if (perms != null && perms.isNotEmpty) ...[
            _header(context, 'Taildrop'), // l10n-exempt: product name
            _PermissionSwitches(
              initial: perms,
              onChanged: widget.onPermission,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _ping(CcTailscalePeer p) => showAppBottomSheet<void>(
    context: context,
    builder: (_) =>
        TailscalePingSheet(tag: widget.tag, peer: p, actions: widget.actions),
  );

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  /// Подпись слева, значение справа целиком (переносится), значок
  /// копирования; тап по строке копирует значение.
  Widget _copyRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('tailscale-device-copy-$value'),
      onTap: () => unawaited(widget.onCopy(value)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 88, child: Text(label)),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.copy, size: 18, color: theme.hintColor),
          ],
        ),
      ),
    );
  }
}

/// §707 итер. 4 — переключатели разрешений служебных файлов на странице
/// устройства. Виды — те, что вернул натив (реестр `service_files.json`);
/// вид без подписи не показывается.
class _PermissionSwitches extends StatefulWidget {
  const _PermissionSwitches({required this.initial, required this.onChanged});

  final Map<String, bool> initial;
  final Future<bool> Function(String kind, bool allowed) onChanged;

  @override
  State<_PermissionSwitches> createState() => _PermissionSwitchesState();
}

class _PermissionSwitchesState extends State<_PermissionSwitches> {
  late final Map<String, bool> _values = Map.of(widget.initial);
  final _busy = <String>{};

  static String? _label(String kind) => switch (kind) {
    'clipboard' => getLocalText.s("Clipboard from this device"),
    'open_url' => getLocalText.s("Links from this device"),
    _ => null,
  };

  Future<void> _set(String kind, bool v) async {
    setState(() => _busy.add(kind));
    final ok = await widget.onChanged(kind, v);
    if (!mounted) return;
    setState(() {
      _busy.remove(kind);
      if (ok) _values[kind] = v;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final e in _values.entries)
        if (_label(e.key) case final String label)
          SwitchListTile(
            key: ValueKey('taildrop-permission-${e.key}'),
            dense: true,
            title: Text(label),
            value: e.value,
            onChanged: _busy.contains(e.key)
                ? null
                : (v) => unawaited(_set(e.key, v)),
          ),
    ],
  );
}
