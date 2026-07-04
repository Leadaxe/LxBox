import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/subscription_meta.dart';
import '../models/validation.dart';
import '../services/app_log.dart';
import '../services/automation/event_emitter.dart';
import '../services/config_dirty_check.dart';
import '../services/error_humanize.dart';
import '../services/parse_hints.dart';
import '../services/relative_time.dart';
import '../services/node_emoji.dart';
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
import '../services/warp/masque_account.dart';
import '../services/warp/masquerade_params.dart';
import '../services/warp/warp_account.dart';
import '../services/warp/warp_client.dart';
import '../services/warp/warp_endpoint_picker.dart';

// Та же библиотека (`part`), поэтому library-private доступ
// (`_replaceList`, `_formatAgo`) к/между основным файлом и part'ом доступен.
part 'subscription_controller/subscription_entry.dart';

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

  /// §113 — флаг живёт в `SettingsStorage` (объект, где меняются настройки):
  /// config-значимые сейверы сами его поднимают. Здесь — делегат, чтобы все
  /// существующие read/write-сайты (home, debug, bootstrap) не менялись.
  bool get configDirty => SettingsStorage.configDirty;
  set configDirty(bool v) => SettingsStorage.configDirty = v;

  /// §101 — завершение стартового восстановления нод из HTTP-кеша.
  /// Bootstrap-rebuild (home_screen) обязан дождаться, иначе соберёт конфиг
  /// из подписок с ещё пустыми `nodes` и молча потеряет их outbounds.
  final Completer<void> _rehydrated = Completer<void>();
  Future<void> get rehydrationDone => _rehydrated.future;

  /// §101 — test seam: подменный HTTP-клиент для `_fetchEntryByRef`.
  @visibleForTesting
  http.Client? httpClientForTesting;

  /// §219 — test seam: future последнего unawaited `HttpCache.save` в
  /// success-path. Тесты `await`-ят его вместо хрупкого `Future.delayed`,
  /// чтобы детерминированно дождаться записи кэша.
  @visibleForTesting
  Future<void>? lastCacheSaveForTesting;

  String _lastError = '';
  String get lastError => _lastError;

  String _progressMessage = '';
  String get progressMessage => _progressMessage;

  String? _lastGeneratedConfig;
  String? get lastGeneratedConfig => _lastGeneratedConfig;

  Future<void> init() async {
    try {
      await _initBody();
    } catch (_) {
      // §101 review: если init упал ДО запуска rehydrate, completer не
      // должен зависнуть навечно для сторонних awaiter'ов rehydrationDone
      // (restore-flow вызывает init() повторно; тесты).
      if (!_rehydrated.isCompleted) _rehydrated.complete();
      rethrow;
    }
  }

  Future<void> _initBody() async {
    final lists = await SettingsStorage.getServerLists();
    _entries = lists.map((l) => SubscriptionEntry(list: l)).toList();
    // §076: bootstrap mtime compare — restore in-memory configDirty после
    // possible kill mid-session. Если settings новее чем saved config →
    // есть pending changes, нужен rebuild. Триггерится в home_screen
    // bootstrap path или при первом возврате на home.
    configDirty = await ConfigDirtyCheck.isDirty();
    if (configDirty) {
      AppLog.I.info('init: configDirty=true via mtime compare');
    }
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
    try {
      // §101 — обход по снапшоту ссылок (паттерн _fetchEntryByRef): между
      // await'ами юзер может перетащить (§098 moveEntry) или удалить entry,
      // запись по индексу затёрла бы list ЧУЖОЙ entry.
      final entries = List<SubscriptionEntry>.of(_entries);
      for (final entry in entries) {
        final list = entry.list;
        if (list is! SubscriptionServers) continue;
        if (list.nodes.isNotEmpty) continue;
        final body = await HttpCache.loadBody(list.url);
        if (body == null || body.isEmpty) continue;
        try {
          final decoded = decode(body);
          final nodes = parseAll(decoded);
          if (nodes.isEmpty) {
            // §101 — раньше скипали молча; UI-счётчик при этом показывает
            // stale lastNodeCount. Логируем с подсказкой, что в кеше.
            final hint = diagnoseEmptyParse(body);
            AppLog.I.warning(
                'Re-hydrate: cached body parsed to 0 nodes for '
                '${maskSubscriptionUrl(list.url)}${hint != null ? ' — $hint' : ''}');
            continue;
          }
          // §101 — guard после await'ов: entry могли удалить; list мог
          // подменить конкурентный fetch или UI-сеттер (rename/enabled —
          // они сохраняют nodes как есть). Применяем кеш только если у
          // ТЕКУЩЕГО list по-прежнему нет нод, и копируем на него (не на
          // устаревший снимок) — правки юзера не теряются.
          if (!_entries.contains(entry)) continue;
          final cur = entry.list;
          if (cur is! SubscriptionServers ||
              cur.url != list.url ||
              cur.nodes.isNotEmpty) {
            continue;
          }
          final next = cur.copyWith(nodes: nodes, lastNodeCount: nodes.length);
          entry._replaceList(next);
          final detours = nodes.where((n) => n.chained != null).length;
          entry.nodeCount = nodes.length;
          entry.status = detours > 0
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
    } finally {
      if (!_rehydrated.isCompleted) _rehydrated.complete();
    }
  }

  /// §074 — add a fully-constructed UserServer (used by Add server wizard
  /// для SOCKS5 form тab). Не парсит — caller уже построил `UserServer` с
  /// нодами. Persist + lastError-aware (паттерн как `addFromInput`).
  /// URI/JSON tabs идут через [addFromInput] напрямую — тут только
  /// structured form path.
  Future<void> addUserServer(UserServer us) async {
    _busy = true;
    _lastError = '';
    notifyListeners();
    try {
      final tagged = _autoEmoji(us);
      _entries
          .add(SubscriptionEntry(list: tagged, nodeCount: tagged.nodes.length));
      await _persist();
      AppLog.I.info(
          'addUserServer: ${us.id} ${us.name} (${us.nodes.length} node)');
    } catch (e) {
      _lastError = humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// §025 — «Get WARP». Регистрирует устройство в Cloudflare (приватный ключ
  /// генерится на телефоне) и добавляет готовый WireGuard-узел как UserServer.
  ///
  /// Идемпотентность: при `reuse=true` (default) переиспользует закешированный
  /// аккаунт вместо новой регистрации. Перед добавлением убирает прежний
  /// WARP-узел (по тегу WARP/WARP+), чтобы не плодить дубли. `forceNew=true` —
  /// чистит кеш и регистрирует заново.
  ///
  /// Возвращает зарегистрированный [WarpAccount] (для UI-статуса) или бросает —
  /// caller показывает [lastError].
  Future<WarpAccount?> addWarp({
    String? licenseKey,
    String endpoint = WarpAccount.defaultEndpoint,
    bool reuse = true,
    bool forceNew = false,
    bool obfuscate = false,
    QuicParams quicParams = const QuicParams(),
    // §142 — класть ли reserved (client_id). null → дефолт по галке: обфускация
    // ВКЛ → false (привязка к устройству режется), ВЫКЛ → true (§025).
    bool? includeReserved,
    WarpClient? client,
  }) async {
    _busy = true;
    _lastError = '';
    notifyListeners();
    final warp = client ?? WarpClient();
    try {
      WarpAccount? account =
          (reuse && !forceNew) ? await SettingsStorage.getWarpAccount() : null;

      // Если есть кеш, но юзер ввёл новый license, а аккаунт ещё free —
      // регистрируем заново, чтобы привязать (PATCH к чужой сессии хрупок).
      final wantsLicense = licenseKey != null && licenseKey.trim().isNotEmpty;
      if (account != null && wantsLicense && !account.warpPlus) {
        account = null;
      }

      // §143 — резолвим masquerade-домен (пустой id → рандом из пула) и
      // рандомный endpoint (только при обфускации + дефолтном endpoint).
      final picker = await WarpEndpointPicker.load();
      final resolvedParams = (quicParams.sni.trim().isEmpty &&
              picker.randomSni().isNotEmpty)
          ? quicParams.copyWith(sni: picker.randomSni())
          : quicParams;
      // §138 — endpoint, который реально должен попасть в узел. Юзер вписал
      // свой (не дефолт) → он; обфускация+дефолт → рандомный §136; иначе дефолт.
      final userPicked = endpoint != WarpAccount.defaultEndpoint;
      final resolvedEndpoint = userPicked
          ? endpoint
          : (obfuscate ? (picker.randomEndpoint() ?? endpoint) : endpoint);

      account ??= await warp.register(
        licenseKey: licenseKey,
        endpoint: resolvedEndpoint,
        nowIso8601: DateTime.now().toUtc().toIso8601String(),
        obfuscate: obfuscate,
        quicParams: resolvedParams,
        // register сам не рандомит — endpoint уже резолвлен здесь (§138).
        randomEndpoint: null,
      );

      // §138 — ПРИМЕНЯЕМ резолвнутый endpoint к аккаунту независимо от того,
      // свежий он или из кеша. Корень бага: при закешированном аккаунте
      // register() минуется (account ??=), и выбранный в Advanced endpoint
      // игнорировался → в узел шёл старый endpoint из кеша.
      if (resolvedEndpoint != account.endpoint &&
          (userPicked || obfuscate)) {
        account = account.copyWith(endpoint: resolvedEndpoint);
      }

      // §126 — обфускация чисто клиентская (не требует ре-регистрации в
      // Cloudflare). Если переиспользуем кеш, но галка/параметры сменились —
      // (пере)генерируем awg поверх существующего аккаунта; off → снимаем.
      account = _syncWarpObfuscation(account, obfuscate, resolvedParams);

      await SettingsStorage.setWarpAccount(account);

      // §137 — НЕ удаляем прежние WARP-узлы: каждый Get WARP добавляет новый,
      // юзер сам решает нужны ли дубли (разные endpoint/SNI/обфускация). Тег с
      // коллизия-суффиксом (` 2`/` 3`), эмодзи внутри тега (☁️ plain / ⛈️ AWG).
      final tag = _uniqueWarpTag(
          WarpAccount.nodeTag(warpPlus: account.warpPlus, hasAwg: account.awg != null));

      // §142 — reserved (client_id): дефолт по галке. Обфускация → false
      // (привязка к устройству режется), plain → true (§025 своя регистрация).
      final withReserved = includeReserved ?? !obfuscate;

      // §126 — обфусцированный узел добавляем через `.conf` (i1 ~1700b удобнее
      // провести INI-путём); plain WARP — короткий URI как раньше.
      if (account.awg != null) {
        await _addWarpObfuscated(account, tag, withReserved);
      } else {
        await _addWarpPlain(account, tag, withReserved);
      }
      if (_lastError.isNotEmpty) return null;
      return account;
    } catch (e) {
      _lastError = humanizeError(e);
      AppLog.I.error('addWarp failed: $_lastError');
      return null;
    } finally {
      if (client == null) warp.close();
      _busy = false;
      notifyListeners();
    }
  }

  /// §130 — регистрирует MASQUE-WARP и добавляет узел. Отдельный путь от
  /// [addWarp] (ECDSA-крипта, двухшаговый enroll, Outbound вместо Endpoint).
  /// [network] — `h3` (дефолт) или `h2`. Кеш переиспользуется как в §025.
  Future<MasqueAccount?> addMasque({
    String network = 'h3',
    String? sni,
    String? idleTimeout,
    String? keepAlive,
    bool reuse = true,
    bool forceNew = false,
    WarpClient? client,
  }) async {
    _busy = true;
    _lastError = '';
    notifyListeners();
    final warp = client ?? WarpClient();
    try {
      MasqueAccount? account = (reuse && !forceNew)
          ? await SettingsStorage.getMasqueAccount()
          : null;

      account ??= await warp.registerMasque(
        nowIso8601: DateTime.now().toUtc().toIso8601String(),
        network: network,
        sni: sni,
        idleTimeout: idleTimeout,
        keepAlive: keepAlive,
      );

      // Транспорт/SNI/тюнинг — клиентские, применяем к кешу без ре-регистрации.
      account = account.copyWith(
        network: network,
        sni: sni,
        idleTimeout: idleTimeout,
        keepAlive: keepAlive,
      );

      await SettingsStorage.setMasqueAccount(account);

      final tag = _uniqueWarpTag(MasqueAccount.nodeTag());
      await _addMasqueNode(account, tag);
      if (_lastError.isNotEmpty) return null;
      return account;
    } catch (e) {
      _lastError = humanizeError(e);
      AppLog.I.error('addMasque failed: $_lastError');
      return null;
    } finally {
      if (client == null) warp.close();
      _busy = false;
      notifyListeners();
    }
  }

  /// §130 — MASQUE-узел через `masque://` URI (аналог [_addWarpPlain]).
  Future<void> _addMasqueNode(MasqueAccount account, String tag) async {
    final spec = parseMasqueUri(account.toMasqueUri());
    if (spec == null) {
      _lastError = 'Invalid MASQUE config';
      return;
    }
    final tagged = MasqueSpec(
      id: spec.id,
      tag: tag,
      label: tag,
      server: spec.server,
      port: spec.port,
      rawUri: spec.rawUri,
      privateKeyDer: spec.privateKeyDer,
      publicKeyDer: spec.publicKeyDer,
      localAddresses: spec.localAddresses,
      profile: spec.profile,
      network: spec.network,
      sni: spec.sni,
      mtu: spec.mtu,
      idleTimeout: spec.idleTimeout,
      keepAlive: spec.keepAlive,
      warnings: spec.warnings,
    );
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: tagged.toUri(),
        nodes: [tagged],
      ),
      nodeCount: 1,
    ));
    await _persist();
  }

  /// §126 — приводит obfuscation у [account] к запрошенному состоянию.
  /// Обфускация клиентская → меняем `awg` без ре-регистрации в Cloudflare.
  /// `obfuscate` off → снимаем awg (если был); on → ставим, если его нет
  /// (свежий register уже проставил — тогда no-op; кешированный аккаунт без
  /// awg или с awg — перегенерируем, чтобы применить актуальный шаблон).
  WarpAccount _syncWarpObfuscation(
      WarpAccount account, bool obfuscate, QuicParams quicParams) {
    if (!obfuscate) {
      return account.awg == null ? account : account.copyWith(clearAwg: true);
    }
    return account.copyWith(awg: WarpClient.buildAmneziaAwg(quicParams));
  }

  /// §137 — базовый [base]-тег + суффикс ` 2`/` 3`/… если уже занят среди
  /// активных узлов. Эмодзи уже в [base] (☁️/⛈️).
  String _uniqueWarpTag(String base) {
    final existing = <String>{
      for (final e in _entries)
        if (e.list is UserServer)
          for (final n in (e.list as UserServer).nodes) n.tag,
    };
    if (!existing.contains(base)) return base;
    for (var i = 2;; i++) {
      final candidate = '$base $i';
      if (!existing.contains(candidate)) return candidate;
    }
  }

  /// §126/§137/§142 — обфусцированный WARP-узел через `.conf`/[parseWireguardIni]
  /// (несёт AWG; reserved по [includeReserved]). [tag] (с эмодзи ⛈️ +
  /// коллизия-суффикс) ставится принудительно (INI-путь иначе дал бы `WireGuard`).
  Future<void> _addWarpObfuscated(
      WarpAccount account, String tag, bool includeReserved) async {
    final spec =
        parseWireguardIni(account.toWireguardConf(includeReserved: includeReserved));
    if (spec == null) {
      _lastError = 'Invalid WARP config (obfuscated)';
      return;
    }
    final tagged = WireguardSpec(
      id: spec.id,
      tag: tag,
      label: tag,
      server: spec.server,
      port: spec.port,
      rawUri: spec.rawUri,
      privateKey: spec.privateKey,
      localAddresses: spec.localAddresses,
      peers: spec.peers,
      mtu: spec.mtu,
      rawIni: spec.rawIni,
      awg: spec.awg,
      warnings: spec.warnings,
    );
    // rawBody = toUri() (с тегом во фрагменте) → тег переживает reload/re-parse.
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: tagged.toUri(),
        nodes: [tagged],
      ),
      nodeCount: 1,
    ));
    await _persist();
  }

  /// §137/§142 — plain WARP-узел (без AWG) через короткий URI с [tag].
  /// reserved по [includeReserved].
  Future<void> _addWarpPlain(
      WarpAccount account, String tag, bool includeReserved) async {
    final spec = parseWireguardUri(
        account.toWireguardUri(includeReserved: includeReserved));
    if (spec == null) {
      _lastError = 'Invalid WARP config';
      return;
    }
    final tagged = WireguardSpec(
      id: spec.id,
      tag: tag,
      label: tag,
      server: spec.server,
      port: spec.port,
      rawUri: spec.rawUri,
      privateKey: spec.privateKey,
      localAddresses: spec.localAddresses,
      peers: spec.peers,
      mtu: spec.mtu,
      rawIni: spec.rawIni,
      awg: spec.awg,
      warnings: spec.warnings,
    );
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: tagged.toUri(),
        nodes: [tagged],
      ),
      nodeCount: 1,
    ));
    await _persist();
  }

  /// §090 G2b — авто-эмодзи при создании UserServer: если в теге первой ноды
  /// нет эмодзи, кладём дефолтный (по протоколу/серверу) в name-часть rawBody
  /// и ре-деривим nodes из него (UserServer персистит только rawBody). На
  /// ошибку парса / отсутствие изменений — возвращаем исходный.
  UserServer _autoEmoji(UserServer us) {
    if (us.nodes.isEmpty || us.rawBody.isEmpty) return us;
    final newRaw = withDefaultEmoji(us.rawBody, us.nodes.first);
    if (newRaw == us.rawBody) return us;
    try {
      final newNodes = parseAll(decode(newRaw));
      return newNodes.isEmpty ? us : us.copyWith(rawBody: newRaw, nodes: newNodes);
    } catch (_) {
      return us;
    }
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
        final wgServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: spec.rawUri,
          nodes: [spec],
        ));
        _entries.add(SubscriptionEntry(
            list: wgServer, nodeCount: wgServer.nodes.length));
        await _persist();
      } else if (isAmneziaVpnLink(trimmed)) {
        // §110 — Amnezia vpn://: один UserServer на ссылку, нод может быть
        // несколько (по WG/AWG контейнеру). rawBody = оригинальная ссылка,
        // fromJson ре-парсит её тем же decode-путём.
        final nodes = parseAll(decode(trimmed));
        if (nodes.isEmpty) {
          _lastError = 'No WireGuard/AmneziaWG config in vpn:// link';
          return;
        }
        final vpnServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: trimmed,
          nodes: nodes,
        ));
        _entries.add(SubscriptionEntry(
            list: vpnServer, nodeCount: vpnServer.nodes.length));
        await _persist();
      } else if (isDirectLink(trimmed)) {
        final spec = parseUri(trimmed);
        if (spec == null) {
          _lastError = 'Could not parse direct link';
          return;
        }
        final dlServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          rawBody: trimmed,
          nodes: [spec],
        ));
        _entries.add(SubscriptionEntry(
            list: dlServer, nodeCount: dlServer.nodes.length));
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
      final jsonServer = _autoEmoji(UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: jsonEncode(ob),
        nodes: nodes,
      ));
      _entries.add(SubscriptionEntry(
          list: jsonServer, nodeCount: jsonServer.nodes.length));
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

  /// §129 — новая файловая подписка из тела файла. Парсит тело; при > 1 ноде
  /// создаёт `SubscriptionServers(url: file:<uuid>)` + снапшот в HttpCache.
  /// Возвращает true, если создана файловая подписка; false — если нод ≤ 1
  /// (caller должен упасть на старое поведение `addFromInput`).
  Future<bool> addFileSubscription(String body, String fileName) async {
    final result = await parseFromSource(InlineSource(body));
    if (result.nodes.length <= 1) return false; // ≤1 → не файловая (spec 129)

    final url = 'file:${newUuidV4()}';
    await HttpCache.save(url, body, const {});
    final name = result.meta?.profileTitle ?? _stripExt(fileName);
    final list = SubscriptionServers(
      id: newUuidV4(),
      name: name,
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: url,
      meta: result.meta,
      lastUpdated: DateTime.now(),
      lastUpdateStatus: UpdateStatus.ok,
      lastNodeCount: result.nodes.length,
      updateIntervalHours: -1, // §129 — файловая: никогда не обновлять авто (-1)
      nodes: result.nodes,
    );
    final entry = SubscriptionEntry(list: list, nodeCount: result.nodes.length);
    _entries.add(entry);
    await _persist();
    notifyListeners();
    AppLog.I.info('Added file subscription "$name": ${result.nodes.length} nodes');
    return true;
  }

  /// §129 — транзакционная смена источника подписки (Edit source: online↔file).
  /// Ровно один из: [httpUrl] (online `http(s)://…`) или [fileBody] (тело нового
  /// файла → file-режим, url = свежий `file:<uuid>`). **Инвариант: старый
  /// кэш/url/ноды сбрасываются ТОЛЬКО после успеха нового (> 0 нод), иначе
  /// полный откат — подписка остаётся на прежнем источнике, юзер не остаётся без
  /// нод.** Возвращает пустую строку при успехе, текст ошибки — при откате.
  Future<String> updateSourceAt(int index,
      {String? httpUrl, String? fileBody}) async {
    if (index < 0 || index >= _entries.length) return 'Invalid subscription';
    final entry = _entries[index];
    final old = entry.list;
    if (old is! SubscriptionServers) return 'Not a subscription';

    final toFile = fileBody != null;
    final newUrl = toFile ? 'file:${newUuidV4()}' : (httpUrl ?? '').trim();
    if (newUrl.isEmpty) return 'No source provided';

    _busy = true;
    notifyListeners();
    try {
      // 1. Получаем НОВЫЙ источник (ещё ничего не трогаем).
      final result = toFile
          ? await parseFromSource(InlineSource(fileBody))
          : await parseFromSource(UrlSource(newUrl),
              client: httpClientForTesting);

      // 2. Успех нового = > 0 нод. Иначе — полный откат (§101-инвариант).
      if (result.nodes.isEmpty) {
        return 'Couldn\'t load new source — keeping current subscription';
      }

      // 3. Коммит: снапшот нового + чистка старого кэша + подмена url/nodes.
      if (isFileSubscription(newUrl)) {
        await HttpCache.save(newUrl, fileBody!, const {});
      }
      if (old.url != newUrl) {
        await HttpCache.remove(old.url); // осиротевший ключ старого источника
      }
      // §129 — file → interval -1 (никогда авто, сервера нет); online → если был
      // ≤0 (пришли с файла / «не обновлять»), вернуть дефолт 24, иначе текущий.
      final nextInterval = toFile
          ? -1
          : (old.updateIntervalHours <= 0 ? 24 : old.updateIntervalHours);
      final next = old.copyWith(
        url: newUrl,
        meta: result.meta,
        lastUpdated: DateTime.now(),
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: result.nodes.length,
        consecutiveFails: 0,
        updateIntervalHours: nextInterval,
        nodes: result.nodes,
      );
      entry._replaceList(next);
      entry.nodeCount = result.nodes.length;
      await _persist();
      notifyListeners();
      AppLog.I.info(
          'Source changed → ${maskSubscriptionUrl(newUrl)}: ${result.nodes.length} nodes');
      return '';
    } catch (e) {
      AppLog.I.warning('updateSourceAt failed (kept current): $e');
      return 'Couldn\'t load new source — keeping current subscription';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Имя файла без расширения — дефолтное имя файловой подписки.
  static String _stripExt(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// Публичный доступ к [_stripExt] для UI (§234 — имя из имени файла).
  static String fileBaseName(String fileName) => _stripExt(fileName);

  // ──────────────────────── §234 — Server folders ────────────────────────

  /// Самодостаточный raw-фрагмент для члена папки: `rawUri` (оригинал), если
  /// он парсится ровно в одну ноду; иначе канонический `toUri()`. Держит
  /// инвариант member ↔ нода 1:1 (у нод multi-нодных контейнеров вроде
  /// `vpn://` одинаковый rawUri на всех — им нужен toUri()).
  static String memberRawFor(NodeSpec n) {
    final raw = n.rawUri.trim();
    if (raw.isNotEmpty) {
      try {
        if (parseAll(decode(raw)).length == 1) return raw;
      } catch (_) {}
    }
    return n.toUri();
  }

  /// Есть ли у raw собственное имя (URI-фрагмент `#name` / JSON `tag`).
  static bool _rawHasOwnName(String raw) {
    final t = raw.trim();
    if (t.startsWith('{')) return t.contains('"tag"');
    return !t.contains('\n') && t.contains('://') && t.contains('#');
  }

  /// Проставить имя в raw-фрагмент: URI → `#fragment`, JSON → `tag`.
  /// Многострочные формы (INI) сюда не приходят — caller передаёт `toUri()`.
  static String _rawWithName(String raw, String name) {
    final t = raw.trim();
    if (t.startsWith('{')) {
      try {
        final m = jsonDecode(t);
        if (m is Map<String, dynamic>) {
          m['tag'] = name;
          return jsonEncode(m);
        }
      } catch (_) {}
      return raw;
    }
    if (t.contains('\n') || !t.contains('://')) return raw;
    final hash = t.indexOf('#');
    final base = hash >= 0 ? t.substring(0, hash) : t;
    return '$base#${Uri.encodeComponent(name)}';
  }

  /// Одиночный сервер из [member] (для ungroup / delete-с-выносом).
  /// §237 — личный detour члена переезжает в overrideDetour одиночного.
  static UserServer _memberToUserServer(FolderMember m) => UserServer(
        id: newUuidV4(),
        name: '',
        enabled: m.enabled,
        tagPrefix: '',
        detourPolicy: m.detour.isEmpty
            ? DetourPolicy.defaults
            : DetourPolicy.defaults.copyWith(overrideDetour: m.detour),
        origin: UserSource.manual,
        createdAt: DateTime.now(),
        rawBody: m.raw,
        nodes: [if (m.node != null) m.node!],
      );

  /// Создать пустую папку.
  Future<void> addFolder(String name) async {
    _entries.add(SubscriptionEntry(
      list: FolderServers(
        id: newUuidV4(),
        name: name,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
      ),
      nodeCount: 0,
    ));
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder created: $name');
  }

  /// Удалить папку. [keepServers] = вынести членов одиночными серверами на
  /// место папки (порядок и per-member enabled сохраняются).
  Future<void> deleteFolderAt(int index, {required bool keepServers}) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! FolderServers) return;
    _entries.removeAt(index);
    if (keepServers) {
      _entries.insertAll(
        index,
        list.members.map((m) {
          final us = _memberToUserServer(m);
          return SubscriptionEntry(list: us, nodeCount: us.nodes.length);
        }),
      );
    }
    await _persist();
    notifyListeners();
    AppLog.I.info(
        'Folder deleted: ${list.name} (${keepServers ? 'servers kept' : 'servers removed'})');
  }

  /// Добавить вход (paste / тело файла) в папку. Вход сплитится на членов
  /// 1:1 по нодам. [nameFallback] — имя для нод без собственного (имя
  /// файла); коллизии внутри вызова получают суффикс « 2», « 3»…
  /// Возвращает '' при успехе, иначе текст ошибки.
  Future<String> addMembersToFolder(int index, String input,
      {String? nameFallback}) async {
    if (index < 0 || index >= _entries.length) return 'Folder not found';
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return 'Not a folder';

    List<NodeSpec> nodes;
    try {
      nodes = parseAll(decode(input.trim()));
    } catch (e) {
      return humanizeError(e);
    }
    if (nodes.isEmpty) return 'No servers found in input';

    final usedNames = <String>{};
    final added = <FolderMember>[];
    for (final n in nodes) {
      var raw = memberRawFor(n);
      if (nameFallback != null &&
          nameFallback.isNotEmpty &&
          !_rawHasOwnName(raw)) {
        var candidate = nameFallback;
        var i = 2;
        while (!usedNames.add(candidate)) {
          candidate = '$nameFallback ${i++}';
        }
        raw = _rawWithName(n.toUri(), candidate);
      }
      added.add(FolderMember(raw: raw));
    }
    entry._replaceList(folder.copyWith(members: [...folder.members, ...added]));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder "${folder.name}": +${added.length} servers');
    return '';
  }

  /// Одноразовый импорт в папку по ссылке: fetch → parse → статичные члены.
  /// Снапшот: meta/auto-update не сохраняются, URL не хранится.
  Future<String> addUrlSnapshotToFolder(int index, String url) async {
    if (index < 0 || index >= _entries.length) return 'Folder not found';
    final entry = _entries[index];
    if (entry.list is! FolderServers) return 'Not a folder';
    _busy = true;
    notifyListeners();
    try {
      final result = await parseFromSource(UrlSource(url.trim()),
          client: httpClientForTesting);
      if (result.nodes.isEmpty) return 'No servers found at this URL';
      // Guard после await: entry могли удалить/подменить.
      final cur = entry.list;
      if (cur is! FolderServers || !_entries.contains(entry)) {
        return 'Folder not found';
      }
      final added =
          result.nodes.map((n) => FolderMember(raw: memberRawFor(n))).toList();
      entry._replaceList(cur.copyWith(members: [...cur.members, ...added]));
      entry.nodeCount = entry.list.nodes.length;
      await _persist();
      AppLog.I.info(
          'Folder "${cur.name}": +${added.length} servers (URL snapshot)');
      return '';
    } catch (e) {
      return humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Вкл/выкл одного члена папки.
  Future<void> toggleMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final members = [...folder.members];
    members[memberIndex] =
        members[memberIndex].copyWith(enabled: !members[memberIndex].enabled);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// Правка raw-фрагмента члена. Новый raw обязан парситься ≥1 ноды, иначе
  /// откат (возврат текста ошибки, старый член не трогается).
  Future<String> updateMemberAt(
      int index, int memberIndex, String newRaw) async {
    if (index < 0 || index >= _entries.length) return 'Folder not found';
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return 'Not a folder';
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return 'Server not found';
    }
    final trimmed = newRaw.trim();
    final probe = FolderMember(raw: trimmed);
    if (probe.node == null) {
      return 'Could not parse server config — keeping current';
    }
    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(raw: trimmed);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    return '';
  }

  /// Удалить члена из папки (совсем).
  Future<void> removeMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// Ручной порядок членов внутри папки (drag-reorder).
  Future<void> reorderMember(int index, int from, int to) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (from < 0 || from >= folder.members.length) return;
    if (to < 0 || to >= folder.members.length) return;
    final members = [...folder.members];
    final m = members.removeAt(from);
    members.insert(to, m);
    entry._replaceList(folder.copyWith(members: members));
    await _persist();
    notifyListeners();
  }

  /// Вынести члена из папки в одиночный сервер (вставляется сразу после
  /// папки). Личные prefix/policy папки НЕ наследуются — дефолты.
  Future<void> ungroupMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final member = folder.members[memberIndex];
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    final us = _memberToUserServer(member);
    _entries.insert(
        index + 1, SubscriptionEntry(list: us, nodeCount: us.nodes.length));
    await _persist();
    notifyListeners();
  }

  /// §237 — личный detour члена (display-form тег outbound'а; '' = нет).
  /// Политика папки применяется к нему в builder'е (см. server_list_build).
  Future<void> setMemberDetour(
      int index, int memberIndex, String detour) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(detour: detour);
    entry._replaceList(folder.copyWith(members: members));
    await _persist();
    notifyListeners();
  }

  /// §236 — массовый toggle членов (Disable slower than N ms и т.п.).
  Future<void> setMembersEnabled(
      int index, Set<int> memberIndexes, bool enabled) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    var changed = false;
    final members = [...folder.members];
    for (final i in memberIndexes) {
      if (i < 0 || i >= members.length) continue;
      if (members[i].enabled == enabled) continue;
      members[i] = members[i].copyWith(enabled: enabled);
      changed = true;
    }
    if (!changed) return;
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// §236 — массовое удаление членов (Delete unreachable).
  Future<void> removeMembersAt(int index, Set<int> memberIndexes) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    final members = <FolderMember>[
      for (var i = 0; i < folder.members.length; i++)
        if (!memberIndexes.contains(i)) folder.members[i],
    ];
    if (members.length == folder.members.length) return;
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// §236 — применить перестановку членов (Sort by ping). [order] — список
  /// старых индексов в новом порядке; обязан быть полной перестановкой.
  Future<void> applyMembersOrder(int index, List<int> order) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (order.length != folder.members.length) return;
    if (order.toSet().length != order.length) return;
    if (order.any((i) => i < 0 || i >= folder.members.length)) return;
    entry._replaceList(folder.copyWith(
        members: [for (final i in order) folder.members[i]]));
    await _persist();
    notifyListeners();
  }

  /// Перенести члена из папки [fromIndex] в папку [toIndex].
  Future<String> moveMemberToFolder(
      int fromIndex, int memberIndex, int toIndex) async {
    if (fromIndex < 0 || fromIndex >= _entries.length) return 'Folder not found';
    if (toIndex < 0 || toIndex >= _entries.length) return 'Folder not found';
    if (fromIndex == toIndex) return '';
    final fromEntry = _entries[fromIndex];
    final toEntry = _entries[toIndex];
    final from = fromEntry.list;
    final to = toEntry.list;
    if (from is! FolderServers || to is! FolderServers) return 'Not a folder';
    if (memberIndex < 0 || memberIndex >= from.members.length) {
      return 'Server not found';
    }
    final member = from.members[memberIndex];
    final fromMembers = [...from.members]..removeAt(memberIndex);
    fromEntry._replaceList(from.copyWith(members: fromMembers));
    fromEntry.nodeCount = fromEntry.list.nodes.length;
    toEntry._replaceList(to.copyWith(members: [...to.members, member]));
    toEntry.nodeCount = toEntry.list.nodes.length;
    await _persist();
    notifyListeners();
    return '';
  }

  /// Перенести одиночный сервер в папку. rawBody сплитится на членов 1:1 по
  /// нодам; личные tag_prefix/detour_policy сервера отбрасываются — действуют
  /// папочные (осознанный trade-off §234). Одиночная запись удаляется.
  Future<String> moveServerToFolder(int serverIndex, int folderIndex) async {
    if (serverIndex < 0 || serverIndex >= _entries.length) {
      return 'Server not found';
    }
    if (folderIndex < 0 || folderIndex >= _entries.length) {
      return 'Folder not found';
    }
    final serverEntry = _entries[serverIndex];
    final folderEntry = _entries[folderIndex];
    final server = serverEntry.list;
    final folder = folderEntry.list;
    if (server is! UserServer) return 'Only single servers can be moved';
    if (folder is! FolderServers) return 'Not a folder';

    // §237 — личный detour одиночного (overrideDetour) переезжает в члена;
    // прочая политика (register-флаги и т.п.) заменяется папочной.
    final personalDetour = server.detourPolicy.useDetourServers
        ? server.detourPolicy.overrideDetour
        : '';
    final added = server.nodes.isEmpty
        // Битый/пустой raw — переносим как есть (член будет виден и правим).
        ? [
            FolderMember(
                raw: server.rawBody,
                enabled: server.enabled,
                detour: personalDetour),
          ]
        : [
            for (final n in server.nodes)
              FolderMember(
                  raw: memberRawFor(n),
                  enabled: server.enabled,
                  detour: personalDetour),
          ];
    folderEntry._replaceList(
        folder.copyWith(members: [...folder.members, ...added]));
    folderEntry.nodeCount = folderEntry.list.nodes.length;
    _entries.remove(serverEntry);
    await _persist();
    notifyListeners();
    AppLog.I.info(
        'Server moved to folder "${folder.name}" (+${added.length})');
    return '';
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

  Future<String?> generateConfig() async {
    // §037: Когда юзер pin'ит свой config через Debug API `PUT /config`,
    // ставится lock var. Любые UI-driven rebuild'ы возвращают null
    // silently — config.json остаётся как был. Все 24+ callsite'а уже
    // делают `if (json != null)` skip-check, так что null не ломает ничего.
    if (await SettingsStorage.getConfigLockedForDebug()) {
      AppLog.I.info('generateConfig: skipped (config_locked_for_debug=true)');
      return null;
    }
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
      customRules: await SettingsStorage.getCustomRules(),
      routeFinal: await SettingsStorage.getRouteFinal(),
      channels: await SettingsStorage.getChannels(), // §125
      tunApps: await SettingsStorage.getTunApps(),
      vpnMode: await SettingsStorage.getVpnMode(),
      idleSuspend: await SettingsStorage.getIdleSuspend(), // §215
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
    for (final w in result.emitWarnings) {
      AppLog.I.warning(w);
    }
    // §141 P0.1 — fatal-валидация теперь блокирующая (контракт `validation.dart`
    // «Fatal → UI отказывается запускать VPN»). Раньше issues только логировались,
    // а битый configJson всё равно возвращался → доезжал до save/ядра. Бросаем
    // исключение ПОСЛЕ записи generatedVars (clash_api/secret уже персистнуты —
    // безвредно), но ДО возврата json: `generateConfig`-catch выставит
    // `_lastError` и вернёт null, все callsite сделают skip-save.
    if (result.validation.hasFatal) {
      final fatal = result.validation.fatal;
      for (final issue in fatal) {
        AppLog.I.error('Validation: ${issue.message}');
      }
      throw FatalValidationException(fatal);
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

    // §129 — файловая подписка: источник локальный, снапшот живёт в HttpCache.
    // Автоматически перечитать файл нельзя (Вариант Б: доступ между сессиями не
    // храним). Поэтому fetch/auto-update = keep-previous: ноды остаются из кэша,
    // подписка НЕ слетает при массовом апдейте онлайн-подписок. Обновление
    // файловой — только вручную через Edit source → Choose file (updateSourceAt).
    if (isFileSubscription(list.url)) {
      AppLog.I.debug('Skip fetch (file subscription): keeping cached nodes');
      return;
    }

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

      final result = await parseFromSource(UrlSource(list.url),
          client: httpClientForTesting);
      AppLog.I.info(
          'Fetched ${result.nodes.length} nodes from $shortUrl'
          '${result.meta?.profileTitle == null ? "" : " (title: ${result.meta!.profileTitle})"}');

      // §101 (R4) — HTTP 200, но тело распарсилось в 0 нод (HTML-заглушка,
      // DDoS-challenge, чужой формат). Это failure, не success: НЕ затираем
      // рабочий кеш на диске и in-memory ноды последнего удачного fetch'а.
      // Parse hint (night T3-3) диагностирует, что пришло вместо подписки.
      if (result.nodes.isEmpty) {
        final hint = diagnoseEmptyParse(result.rawBody);
        if (hint != null) AppLog.I.warning('Parse hint: $hint');
        AppLog.I.warning(
            'Fetch returned 0 nodes for $shortUrl — keeping previous state');
        entry.status = entry.nodeCount > 0
            ? '${entry.nodeCount} nodes (update failed: 0 parsed)'
            : (hint != null ? '0 nodes — $hint' : '0 nodes');
        final current = entry.list as SubscriptionServers;
        entry._replaceList(current.copyWith(
          lastUpdateAttempt: attemptAt,
          lastUpdateStatus: UpdateStatus.failed,
          consecutiveFails: current.consecutiveFails + 1,
        ));
        try {
          await _persist();
        } catch (e) {
          // §101 review: persist-фейл не должен уйти в общий catch — там
          // consecutiveFails инкрементится повторно и haptic дублируется.
          // In-memory состояние уже корректно; теряем только запись на диск.
          AppLog.I.error(
              'Persist failed after empty fetch: ${humanizeError(e)}');
        }
        if (trigger == UpdateTrigger.manual) HapticService.I.onFetchError();
        // §047 — outgoing subscription event (gated, default OFF, throttled).
        AutomationEventEmitter.I
            .emitSubRefreshFailed(shortUrl, '0 nodes parsed');
        notifyListeners();
        return;
      }

      // Кешируем сырое тело и заголовки на диск для офлайн-реактивации после
      // перезапуска (см. `_rehydrateFromCache`) и для Source-вкладки (fallback).
      // §219 — трекаем future для детерминированного await в тестах.
      final saveFuture = HttpCache.save(list.url, result.rawBody, result.headers);
      lastCacheSaveForTesting = saveFuture;
      unawaited(saveFuture);
      final warnNodes = result.nodes.where((n) => n.warnings.isNotEmpty).length;
      if (warnNodes > 0) {
        AppLog.I.warning('$warnNodes nodes with warnings (XHTTP fallback etc.)');
      }
      entry.nodeCount = result.nodes.length;
      final detours = result.nodes.where((n) => n.chained != null).length;
      entry.status = detours > 0
          ? '${result.nodes.length} +$detours⚙ nodes'
          : '${result.nodes.length} nodes';

      final current = entry.list as SubscriptionServers;
      final nextName = current.name.isEmpty && result.meta?.profileTitle != null
          ? result.meta!.profileTitle!
          : current.name;

      // §129 — семантика интервала:
      //   -1 = «Don't auto-update», игнорируем серверный profile-update-interval;
      //    0 = «Never (respect server)» — сами не по расписанию, но серверный
      //        заголовок ПРИНИМАЕМ (станет реальным числом → авто по нему);
      //   >0 = обновлять раз в N часов (сервер тоже может переопределить).
      final nextInterval = current.updateIntervalHours < 0
          ? current.updateIntervalHours // -1: жёстко, сервер не переубедит
          : (result.meta?.updateIntervalHours ?? current.updateIntervalHours);
      final next = current.copyWith(
        name: nextName,
        meta: result.meta,
        lastUpdated: DateTime.now(),
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: result.nodes.length,
        consecutiveFails: 0,
        updateIntervalHours: nextInterval,
        nodes: result.nodes,
      );
      entry._replaceList(next);
      await _persist();
      // Haptic только на user-инициированные fetch'и — auto/periodic тихие.
      if (trigger == UpdateTrigger.manual) HapticService.I.onFetchSuccess();
      // §047 — outgoing subscription event (gated, default OFF). delta =
      // прирост нод относительно прошлого успешного fetch'а. sub_id = masked
      // host (стабильный, не утекает токен).
      AutomationEventEmitter.I.emitSubRefreshed(
        shortUrl,
        result.nodes.length,
        result.nodes.length - current.lastNodeCount,
      );
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
      // §047 — outgoing subscription event (gated, default OFF; throttled
      // 1/min на sub_id в эмиттере, чтобы network-outage не заспамил Tasker).
      AutomationEventEmitter.I
          .emitSubRefreshFailed(shortUrl, humanizeError(e));
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

  ServerList _renameList(ServerList l, String name) => switch (l) {
        SubscriptionServers() => l.copyWith(name: name),
        UserServer() => l.copyWith(name: name),
        FolderServers() => l.copyWith(name: name),
      };

  ServerList _toggleEnabled(ServerList l, bool enabled) => switch (l) {
        SubscriptionServers() => l.copyWith(enabled: enabled),
        UserServer() => l.copyWith(enabled: enabled),
        FolderServers() => l.copyWith(enabled: enabled),
      };
}
