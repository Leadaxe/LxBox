import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/import_rule.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../models/ui_msg.dart';
import '../models/subscription_meta.dart';
import '../models/validation.dart';
import '../services/app_log.dart';
import '../services/automation/event_emitter.dart';
import '../services/config_dirty_check.dart';
import '../services/error_humanize.dart';
import '../services/parse_hints.dart';
import '../services/relative_time.dart';
import '../services/node_emoji.dart';
import '../services/node_hash.dart';
import '../services/node_identity.dart';
import '../services/url_mask.dart';
import '../services/builder/build_config.dart';
import '../services/builder/core_chain_capability.dart';
import '../vpn/box_vpn_client.dart';
import '../services/parser/body_decoder.dart';
import '../services/parser/ini_parser.dart';
import '../services/parser/parse_all.dart';
import '../services/parser/uri_parsers.dart';
import '../services/parser/uri_utils.dart';
import '../services/haptic_service.dart';
import '../services/settings_storage.dart';
import '../services/tag_resolver.dart';
import '../services/subscription/auto_updater.dart';
import '../services/subscription/http_cache.dart';
import '../services/subscription/import_rules.dart';
import '../services/subscription/input_helpers.dart';
import '../services/subscription/sources.dart';
import '../services/subscription/subscription_identity.dart';
import '../services/warp/masque_account.dart';
import '../services/warp/masquerade_params.dart';
import '../services/warp/warp_account.dart';
import '../services/warp/warp_client.dart';
import '../services/warp/warp_endpoint_picker.dart';
import '../services/warp/scan/candidate_generator.dart';
import '../services/warp/scan/scan_models.dart';
import '../services/warp/scan/scan_node_builder.dart';
import '../services/warp/scan/scan_pool.dart';

// Та же библиотека (`part`), поэтому library-private доступ
// (`_replaceList`, `_formatAgo`) к/между основным файлом и part'ом доступен.
part 'subscription_controller/subscription_entry.dart';

/// §368 — исход добавления JSON-формы. Три состояния, а не bool: «форму не
/// узнали» и «форму узнали, но узлов не собралось» дают разные сообщения, и
/// bool заставлял вызывающего затирать более точную ошибку общей.
enum _JsonAdd { added, empty, notJson }

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

  /// §360 — узкий флаг «сейчас идёт `generateConfig`». Нужен `_persist`, чтобы
  /// не поднимать `configDirty` на собственных служебных записях пересборки, не
  /// глуша при этом мутации от юзера (см. коммент в `_persist`).
  bool _generating = false;

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

  UiMsg? _lastError;

  /// §279 Phase 4 — хранимая ошибка = [UiMsg] (рендер в build). null = нет.
  UiMsg? get lastError => _lastError;

  /// §254 — структурный дубль [lastError]: fatal-issues последней генерации.
  /// UI различает по типу (DetourCycle → bottom sheet со списком виновников
  /// вместо плоского SnackBar). Очищается на входе в generateConfig,
  /// заполняется только из [FatalValidationException].
  List<ValidationIssue> _lastFatalIssues = const [];
  List<ValidationIssue> get lastFatalIssues => _lastFatalIssues;

  /// §274 — Направления, чей node_filter отсёк все ноды в последней УСПЕШНОЙ
  /// сборке (display-имена; Направление схлопнулось в block-fallback). [stamp]
  /// монотонно растёт на каждой сборке с непустым списком — Home дедупит
  /// по нему транзиентный SnackBar (один показ на сборку, не на rebuild
  /// виджетов).
  List<String> _directionsWithoutNodes = const [];
  List<String> get directionsWithoutNodes => _directionsWithoutNodes;
  int _directionsWithoutNodesStamp = 0;
  int get directionsWithoutNodesStamp => _directionsWithoutNodesStamp;

  UiMsg? _progressMessage;
  UiMsg? get progressMessage => _progressMessage;

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
    // §331 (ревью) — keepDirtyFlag: sweep inProgress→failed — метаданные.
    // Иначе после крэша во время фетча каждый старт app начинался бы с синей
    // плашки. `configDirty` на init и так восстановлен mtime-сравнением выше —
    // sweep не должен его перебивать.
    if (swept) await _persist(keepDirtyFlag: true);
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
          // §302 — применяем те же import-rules к кэшу: иначе после рестарта
          // узлы вернулись бы в ДОзаменном виде, их nodeIdentityHash не совпал
          // бы с персистентными DISABLE-хешами → выключение слетело бы до
          // следующего сетевого refresh, а REPLACE не применился бы. GC и
          // пересчёт disable здесь НЕ делаем — регидрация не сигнал «узел ушёл»
          // (§283).
          _applyRulesToNodes(nodes, list.activeImportRules);
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
          entry.status =
              SubStatusNodes(nodes.length, detours: detours, cached: true);
          AppLog.I.info(
              'Re-hydrated ${nodes.length} nodes from cache: ${maskSubscriptionUrl(list.url)}');
        } catch (e) {
          AppLog.I.warning(
              'Re-hydrate failed for ${maskSubscriptionUrl(list.url)}: ${humanizeError(e).renderEn()}');
        }
      }
      notifyListeners();
    } finally {
      if (!_rehydrated.isCompleted) _rehydrated.complete();
    }
  }

  /// §302 — применяет import-rules к разобранным узлам и возвращает
  /// identity-хеши узлов, помеченных к выключению (Disable) и к
  /// принудительному включению (Enable, §332).
  ///
  /// REPLACE патчит `NodeSpec.patchedJson` (узел эмитится из него), поэтому
  /// хеш считаем ПОСЛЕ применения — выключение и роутинг работают с итоговым
  /// видом узла, как его увидит билдер.
  ({Set<String> disable, Set<String> enable}) _applyRulesToNodes(
      List<NodeSpec> nodes, List<ImportRule> rules) {
    // §307 — правила НЕ инкрементальны: каждый прогон стартует с чистого
    // узла (движок читает `emitRaw`), поэтому прошлый патч всегда сбрасываем.
    // Сегодня узлы в обоих call-site'ах свежераспарсенные и сброс — no-op,
    // но если сюда когда-нибудь придёт живой список, накопления не будет.
    for (final n in nodes) {
      n.patchedJson = null;
      n.ruleTrail = const [];
    }
    if (rules.isEmpty || nodes.isEmpty) return (disable: const {}, enable: const {});
    final result = applyImportRules(nodes, rules);
    if (result.isEmpty) return (disable: const {}, enable: const {});

    final disable = <String>{};
    final enable = <String>{};
    result.outcomes.forEach((i, outcome) {
      if (i < 0 || i >= nodes.length) return;
      final node = nodes[i];
      if (outcome.patchedJson != null) {
        node.patchedJson = outcome.patchedJson;
        node.ruleTrail = outcome.replacements;
      }
      if (outcome.disabled == true) disable.add(nodeIdentityHash(node));
      if (outcome.disabled == false) enable.add(nodeIdentityHash(node));
    });

    // §322 — правила могли переписать `server`/`uuid`, и тогда идентичность
    // узла другая, а синонимы группы указывают на прежнюю. Пересобираем
    // таблицу по патченым узлам: тег провайдера тот же, ключ новый.
    _remapAutoSelectSynonyms(nodes);
    return (disable: disable, enable: enable);
  }

  /// §322 — пересчёт таблицы синонимов после §302-правил. Тег провайдера
  /// (ключ таблицы) правила не трогают — меняется только идентичность, на
  /// которую он указывает.
  void _remapAutoSelectSynonyms(List<NodeSpec> nodes) {
    final autos = nodes.whereType<AutoSelectSpec>().toList();
    if (autos.isEmpty) return;
    // Старая идентичность → новая. Считаем по узлам, которые правила задели.
    final moved = <String, String>{};
    for (final n in nodes) {
      if (n.patchedJson == null) continue;
      final before = nodeIdentityKeyRaw(n);
      final after = nodeIdentityKey(n);
      if (before != null && after != null && before != after) {
        moved[before] = after;
      }
    }
    if (moved.isEmpty) return;
    for (var i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      if (a is! AutoSelectSpec || a.tagSynonyms.isEmpty) continue;
      nodes[i] = a.copyWith(tagSynonyms: {
        for (final e in a.tagSynonyms.entries) e.key: moved[e.value] ?? e.value,
      });
    }
  }

  /// §074 — add a fully-constructed UserServer (used by Add server wizard
  /// для SOCKS5 form тab). Не парсит — caller уже построил `UserServer` с
  /// нодами. Persist + lastError-aware (паттерн как `addFromInput`).
  /// URI/JSON tabs идут через [addFromInput] напрямую — тут только
  /// structured form path.
  Future<void> addUserServer(UserServer us) async {
    _busy = true;
    _lastError = null;
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
    // §304 — persistent keepalive (секунды) для узла: держит NAT/сессию живыми
    // при простое. null → не писать keepalive (как раньше). Ручная регистрация
    // подставляет 25 из Advanced; генератор §284 сюда не ходит.
    int? persistentKeepalive,
    WarpClient? client,
  }) async {
    _busy = true;
    _lastError = null;
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
      // §305 — v6-endpoint только если в системе включён IPv6 (иначе мёртв).
      final allowV6 = (await SettingsStorage.getVar('ipv6_enabled', 'false'))
              .toLowerCase() ==
          'true';
      final resolvedEndpoint = userPicked
          ? endpoint
          : (obfuscate
              ? (picker.randomEndpoint(allowV6: allowV6) ?? endpoint)
              : endpoint);

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
        await _addWarpObfuscated(account, tag, withReserved,
            persistentKeepalive: persistentKeepalive);
      } else {
        await _addWarpPlain(account, tag, withReserved,
            persistentKeepalive: persistentKeepalive);
      }
      if (_lastError != null) return null;
      return account;
    } catch (e) {
      _lastError = humanizeError(e);
      AppLog.I.error('addWarp failed: ${_lastError?.renderEn()}');
      return null;
    } finally {
      if (client == null) warp.close();
      _busy = false;
      notifyListeners();
    }
  }

  /// §130 — регистрирует MASQUE-WARP и добавляет узел. Отдельный путь от
  /// [addWarp] (ECDSA-крипта, двухшаговый enroll, Outbound вместо Endpoint).
  /// [vhttp] — версия HTTP `h3` (дефолт) или `h2`; §393: свойство узла, не
  /// аккаунта, поэтому в кеш не пишется. Кеш переиспользуется как в §025.
  Future<MasqueAccount?> addMasque({
    String vhttp = 'h3',
    String? sni,
    String? idleTimeout,
    String? keepAlive,
    // §305 — ручной override endpoint. null → endpoint из регистрации. Пишется
    // только в узел, НЕ в кеш аккаунта (кеш держит канонический server реги).
    String? server,
    int? port,
    bool reuse = true,
    bool forceNew = false,
    WarpClient? client,
  }) async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    final warp = client ?? WarpClient();
    try {
      MasqueAccount? account = (reuse && !forceNew)
          ? await SettingsStorage.getMasqueAccount()
          : null;

      account ??= await warp.registerMasque(
        nowIso8601: DateTime.now().toUtc().toIso8601String(),
        sni: sni,
        idleTimeout: idleTimeout,
        keepAlive: keepAlive,
      );

      // SNI/тюнинг — клиентские, применяем к кешу без ре-регистрации.
      // Версия HTTP сюда не идёт (§393): она уходит прямо в URI узла.
      account = account.copyWith(
        sni: sni,
        idleTimeout: idleTimeout,
        keepAlive: keepAlive,
      );

      await SettingsStorage.setMasqueAccount(account);

      // §305 — override endpoint применяем ТОЛЬКО к узлу (после setMasqueAccount,
      // чтобы кеш держал server реги). Срабатывает если задан server ИЛИ port
      // (порт-only override не теряется). Пустое поле → значение из реги.
      // copyWith не несёт server/port → полный конструктор (как _masqueUri).
      final hasServerOverride = server != null && server.trim().isNotEmpty;
      final hasPortOverride = port != null && port > 0;
      if (hasServerOverride || hasPortOverride) {
        account = MasqueAccount(
          privKeyDer: account.privKeyDer,
          serverPubDer: account.serverPubDer,
          clientV4: account.clientV4,
          clientV6: account.clientV6,
          server: hasServerOverride ? server.trim() : account.server,
          port: hasPortOverride ? port : account.port,
          deviceId: account.deviceId,
          token: account.token,
          createdAt: account.createdAt,
          sni: account.sni,
          idleTimeout: account.idleTimeout,
          keepAlive: account.keepAlive,
        );
      }

      final tag = _uniqueWarpTag(MasqueAccount.nodeTag());
      await _addMasqueNode(account, tag, vhttp: vhttp);
      if (_lastError != null) return null;
      return account;
    } catch (e) {
      _lastError = humanizeError(e);
      AppLog.I.error('addMasque failed: ${_lastError?.renderEn()}');
      return null;
    } finally {
      if (client == null) warp.close();
      _busy = false;
      notifyListeners();
    }
  }

  /// §130 — MASQUE-узел через `masque://` URI (аналог [_addWarpPlain]).
  Future<void> _addMasqueNode(MasqueAccount account, String tag,
      {String vhttp = 'h3'}) async {
    final spec = parseMasqueUri(account.toMasqueUri(vhttp: vhttp));
    if (spec == null) {
      _lastError = const ErrMsg(ErrKey.invalidMasqueConfig);
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
      vhttp: spec.vhttp,
      sni: spec.sni,
      disableSni: spec.disableSni,
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
      WarpAccount account, String tag, bool includeReserved,
      {int? persistentKeepalive}) async {
    final spec = parseWireguardIni(account.toWireguardConf(
        includeReserved: includeReserved,
        persistentKeepalive: persistentKeepalive));
    if (spec == null) {
      _lastError = const ErrMsg(ErrKey.invalidWarpConfigObfuscated);
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
      WarpAccount account, String tag, bool includeReserved,
      {int? persistentKeepalive}) async {
    final spec = parseWireguardUri(account.toWireguardUri(
        includeReserved: includeReserved,
        persistentKeepalive: persistentKeepalive));
    if (spec == null) {
      _lastError = const ErrMsg(ErrKey.invalidWarpConfig);
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

  /// §243 — [nameHint] (имя файла без расширения при импорте из файла)
  /// становится tag'ом узла для WG/AWG INI-ветки (фрагмент синтетического
  /// URI, живёт в rawBody ⇒ переживает рестарт). Ветка `vpn://` hint
  /// сознательно НЕ получает: её rawBody = оригинальная ссылка, имя
  /// потерялось бы при ре-парсе после рестарта.
  /// [origin] — откуда приехала строка. Дефолт `paste` сохраняет поведение
  /// всех существующих вызовов; §375 (QR-сканер) передаёт `UserSource.qr`.
  Future<void> addFromInput(String input,
      {String? nameHint, UserSource origin = UserSource.paste}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    _busy = true;
    _lastError = null;
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
        final spec = parseWireguardIni(trimmed, nameHint: nameHint);
        if (spec == null) {
          _lastError = const ErrMsg(ErrKey.invalidWireguardConfig);
          return;
        }
        final wgServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
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
          _lastError = const ErrMsg(ErrKey.noWgInVpnLink);
          return;
        }
        final vpnServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
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
          _lastError = const ErrMsg(ErrKey.couldNotParseDirectLink);
          return;
        }
        final dlServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
          createdAt: DateTime.now(),
          rawBody: trimmed,
          nodes: [spec],
        ));
        _entries.add(SubscriptionEntry(
            list: dlServer, nodeCount: dlServer.nodes.length));
        await _persist();
      } else {
        switch (await _addJsonNodes(trimmed, origin: origin)) {
          case _JsonAdd.added:
            await _persist();
          case _JsonAdd.empty:
            // Форму опознали, узлов не собралось — ошибку уже выставил
            // `_addJsonNodes`, и она точнее, чем «не распознано».
            break;
          case _JsonAdd.notJson:
            _lastError = const ErrMsg(ErrKey.inputNotRecognized);
        }
      }
    } catch (e) {
      _lastError = humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// §368 — JSON любой из четырёх форм (одиночный outbound, массив
  /// outbound'ов, полный конфиг, массив конфигов) → одна запись.
  ///
  /// Гейт один — `decode` + flavor; своей эвристики («начинается с `{` и
  /// содержит `"type"`») здесь больше нет: она была третьей по счёту и
  /// разошлась с превью (§368 §1).
  ///
  /// Одна запись, а не N: раньше массив outbound'ов раскладывался по одной
  /// записи на элемент («v1 behavior parity»). Вставленный файл — один
  /// источник, и обновляться он должен целиком.
  Future<_JsonAdd> _addJsonNodes(String text,
      {UserSource origin = UserSource.paste}) async {
    final decoded = decode(text);
    if (decoded is! JsonConfig) return _JsonAdd.notJson;
    switch (decoded.flavor) {
      case JsonFlavor.singboxOutbound:
      case JsonFlavor.singboxArray:
      case JsonFlavor.singboxConfig:
      case JsonFlavor.singboxMulti:
      case JsonFlavor.xrayArray:
        break;
      case JsonFlavor.clashYaml:
      case JsonFlavor.unknown:
        return _JsonAdd.notJson;
    }

    final nodes = parseAll(decoded);
    if (nodes.isEmpty) {
      _lastError = const ErrMsg(ErrKey.noValidOutboundsInJson);
      return _JsonAdd.empty;
    }

    // §368 — контейнер по числу узлов, тем же порогом, что и файловый импорт
    // (§129): один узел — это сервер, несколько — набор.
    //
    // `UserServer` устроен как «один сервер»: подпись в списке берётся от
    // протокола первого узла, тап открывает экран одного узла, а операции над
    // отдельными узлами (выключение §283, правила импорта §302) есть только у
    // подписки. Конфиг sing-box на десяток узлов с группой в такой контейнер
    // не помещается — он приезжает файловой подпиской (`file:<uuid>`,
    // автообновление выключено), как импорт файла с >1 нодой.
    if (nodes.length > 1) {
      final url = 'file:${newUuidV4()}';
      await HttpCache.save(url, text, const {});
      final list = SubscriptionServers(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
        lastUpdated: DateTime.now(),
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: nodes.length,
        updateIntervalHours: -1, // §129 — файловая: авто-обновления нет
        nodes: nodes,
      );
      _entries.add(SubscriptionEntry(list: list, nodeCount: nodes.length));
      return _JsonAdd.added;
    }

    final jsonServer = _autoEmoji(UserServer(
      id: newUuidV4(),
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: origin,
      createdAt: DateTime.now(),
      rawBody: text,
      nodes: nodes,
    ));
    _entries.add(SubscriptionEntry(
        list: jsonServer, nodeCount: jsonServer.nodes.length));
    return _JsonAdd.added;
  }

  /// §393 D2 — сколько позиций цепочек вычищено последним удалением источника.
  ///
  /// Читается экраном сразу после `await`-а мутации и показывается snackbar'ом
  /// — тем же механизмом, что rules/detours/includes-heal (§202/§248).
  /// Укорачивание маршрута обязано быть заметным: цепочка 3+ хопов после
  /// вычистки эмитится УКОРОЧЕННЫМ маршрутом, и промолчать об этом значило бы
  /// подменить пользователю маршрут молча.
  int _lastChainPositionsRemoved = 0;
  int get lastChainPositionsRemoved => _lastChainPositionsRemoved;
  void clearChainHealNotice() => _lastChainPositionsRemoved = 0;

  /// §393 D2 — вычистить позиции цепочек, ссылавшиеся на удалённый источник.
  ///
  /// Зовётся ТОЛЬКО из осознанного удаления пользователем. Обновление
  /// подписки сюда не приходит намеренно (граница зафиксирована оператором):
  /// пропавший узел может вернуться следующим обновлением, и фоновое событие
  /// не вправе молча резать маршруты, написанные руками, — там остаётся
  /// деградация билдера `chain_hop_missing`.
  /// §393 D2 — теги папки, которые исчезают при роспуске с сохранением
  /// серверов: сам префикс (группы больше нет) и члены в ПРЕФИКСНОЙ форме.
  /// Голые теги членов остаются жить одиночными серверами — позиции цепочек
  /// на них законны и после роспуска.
  Set<String> _folderPrefixedTags(FolderServers f) {
    final out = <String>{if (f.tagPrefix.isNotEmpty) f.tagPrefix};
    if (f.tagPrefix.isEmpty) return out;
    for (final t in sourceConfigTags(f)) {
      if (t.startsWith('${f.tagPrefix} ')) out.add(t);
    }
    return out;
  }

  Future<void> _healChainsForRemoved(Iterable<String> tags) async {
    var removed = 0;
    for (final t in tags) {
      final r = await SettingsStorage.healChainHops(t);
      removed += r.positions;
    }
    if (removed > 0) {
      _lastChainPositionsRemoved += removed;
      AppLog.I.info('Chain heal: $removed position(s) removed with the source');
    }
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    final gone = _entries.removeAt(index);
    await _persist();
    // §393 D2 — после снятия источника: цепочки, стоявшие на его узлах,
    // теряют ПОЗИЦИЮ, а не себя целиком.
    await _healChainsForRemoved(sourceConfigTags(gone.list));
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
  Future<UiMsg?> updateSourceAt(int index,
      {String? httpUrl, String? fileBody}) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.invalidSubscription);
    }
    final entry = _entries[index];
    final old = entry.list;
    if (old is! SubscriptionServers) {
      return const ErrMsg(ErrKey.notASubscription);
    }

    final toFile = fileBody != null;
    final newUrl = toFile ? 'file:${newUuidV4()}' : (httpUrl ?? '').trim();
    if (newUrl.isEmpty) return const ErrMsg(ErrKey.noSourceProvided);

    _busy = true;
    notifyListeners();
    try {
      // 1. Получаем НОВЫЙ источник (ещё ничего не трогаем).
      // §289 — сохраняем per-subscription идентичность при смене источника.
      final result = toFile
          ? await parseFromSource(InlineSource(fileBody))
          : await parseFromSource(UrlSource(newUrl, identity: old.identity),
              client: httpClientForTesting);

      // 2. Успех нового = > 0 нод. Иначе — полный откат (§101-инвариант).
      if (result.nodes.isEmpty) {
        return const ErrMsg(ErrKey.couldNotLoadNewSource);
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
      return null;
    } catch (e) {
      AppLog.I.warning('updateSourceAt failed (kept current): $e');
      return const ErrMsg(ErrKey.couldNotLoadNewSource);
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

  /// §284 — имя папки-генератора WARP-узлов. Повторный GENERATE её пересоздаёт.
  static const kScanFolderName = 'WARP GENERATOR';

  /// §284 — заметка о последней генерации (напр. почему пропал MASQUE).
  /// Показывается снеком в визарде. null = без замечаний.
  String? lastScanNote;

  /// §284 — WARP GENERATOR: собирает [seedCount] случайных узлов (Монте-Карло по
  /// {IP × port × protocol{AWG,h3,h2} × SNI × приманка}) поверх ОДНОЙ
  /// регистрации, кладёт в (пере)созданную папку «WARP GENERATOR». Пробы НЕ
  /// гоняет и мёртвые НЕ удаляет — пользователь сам тестирует штатной кнопкой
  /// Test в папке. Возвращает индекс папки в [entries] (для навигации) или null.
  ///
  /// [rng]/[client] инъектируются для тестов.
  Future<int?> generateWarp({
    int seedCount = 100,
    Random? rng,
    WarpClient? client,
    // §305 — override пула из JSON-окна эксперимента. null → bundled asset.
    ScanPool? poolOverride,
  }) async {
    lastScanNote = null;
    final pool = poolOverride ?? (await WarpEndpointPicker.load()).scan;
    if (pool == null) return null;

    // Аккаунты: кеш → или регистрация один раз (обоих типов — для смешанного
    //   посева). Кешированный аккаунт (ручной MASQUE §130) переиспользуем без
    //   реги. Регистрация может частично не удаться — используем что есть.
    final warp = client ?? WarpClient();
    ScanNodeBuilder builder;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      var warpAcc = await SettingsStorage.getWarpAccount();
      warpAcc ??= await _tryRegisterWarp(warp, now);
      var masqueAcc = await SettingsStorage.getMasqueAccount();
      masqueAcc ??= await _tryRegisterMasque(warp, now);
      if (warpAcc == null && masqueAcc == null) return null;
      // §313 — keepalive для WG/AWG-узлов берётся из того же пула, что CIDR/
      // порты/SNI (правится JSON-окном эксперимента без пересборки).
      builder = ScanNodeBuilder(
        warp: warpAcc,
        masque: masqueAcc,
        wgKeepalive: pool.wgKeepalive,
      );
    } finally {
      if (client == null) warp.close();
    }

    // Посев → URI-узлы (пропускаем протоколы без аккаунта) → папка.
    // §305 — v6-кандидаты только если в системе включён IPv6 (иначе мёртвы).
    final allowV6 =
        (await SettingsStorage.getVar('ipv6_enabled', 'false')).toLowerCase() ==
            'true';
    final gen = CandidateGenerator(pool, rng: rng, allowV6: allowV6);
    final seedUris = _candidatesToUris(gen.seed(seedCount), builder);
    if (seedUris.isEmpty) return null;
    return _recreateScanFolder(seedUris);
  }

  Future<WarpAccount?> _tryRegisterWarp(WarpClient warp, String now) async {
    try {
      final acc = await warp.register(endpoint: WarpAccount.defaultEndpoint, nowIso8601: now);
      await SettingsStorage.setWarpAccount(acc);
      return acc;
    } catch (e) {
      AppLog.I.warning('generateWarp: WARP register failed: $e');
      return null;
    }
  }

  Future<MasqueAccount?> _tryRegisterMasque(WarpClient warp, String now) async {
    try {
      final acc = await warp.registerMasque(nowIso8601: now);
      await SettingsStorage.setMasqueAccount(acc);
      return acc;
    } catch (e) {
      AppLog.I.warning('generateWarp: MASQUE register failed: $e');
      lastScanNote = 'MASQUE (h3/h2) unavailable: registration failed — $e';
      return null;
    }
  }

  List<String> _candidatesToUris(List<ScanCandidate> cs, ScanNodeBuilder b) =>
      [for (final c in cs) b.uriFor(c)].whereType<String>().toList();

  /// Индекс папки «WARP GENERATOR» в [_entries] или null.
  int? _scanFolderIndex() {
    for (var i = 0; i < _entries.length; i++) {
      final l = _entries[i].list;
      if (l is FolderServers && l.name == kScanFolderName) return i;
    }
    return null;
  }

  /// §284 — DNS-независимый ping-URL для папки «WARP GENERATOR»: HTTP через сам
  /// тестируемый узел на IP-литерал (без резолва). Кладётся в саму папку
  /// (FolderServers.pingUrl) — Test в папке идёт по нему.
  static const kScanProbeUrl = 'https://1.1.1.1/cdn-cgi/trace';

  /// Пересоздаёт папку «WARP GENERATOR» с заданными узлами. Возвращает её индекс.
  /// Папка несёт свой ping-URL (IP, без DNS) в собственном объекте — при
  /// пересоздании/удалении опции уходят вместе с ней.
  Future<int> _recreateScanFolder(List<String> uris) async {
    final old = _scanFolderIndex();
    if (old != null) _entries.removeAt(old);
    _entries.add(SubscriptionEntry(
      list: FolderServers(
        id: newUuidV4(),
        name: kScanFolderName,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [for (final u in uris) FolderMember(raw: u)],
        pingUrl: kScanProbeUrl,
        pingTimeoutMs: 3000,
      ),
      nodeCount: uris.length,
    ));
    await _persist();
    notifyListeners();
    return _entries.length - 1;
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
    // §393 D2 — при `keepServers` члены остаются в конфиге одиночными
    // серверами, но уже БЕЗ префикса папки: исчезают только сам префикс
    // (группа) и теги в префиксной форме, а голые продолжают жить. Без
    // keepServers уходит вся папка целиком.
    await _healChainsForRemoved(
        keepServers ? _folderPrefixedTags(list) : sourceConfigTags(list));
    notifyListeners();
    AppLog.I.info(
        'Folder deleted: ${list.name} (${keepServers ? 'servers kept' : 'servers removed'})');
  }

  /// Добавить вход (paste / тело файла) в папку. Вход сплитится на членов
  /// 1:1 по нодам. [nameFallback] — имя для нод без собственного (имя
  /// файла); коллизии внутри вызова получают суффикс « 2», « 3»…
  /// Возвращает '' при успехе, иначе текст ошибки.
  Future<UiMsg?> addMembersToFolder(int index, String input,
      {String? nameFallback}) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);

    List<NodeSpec> nodes;
    try {
      // §243 — INI-ноды получают имя файла прямо во фрагмент синтетического
      // URI (rawUri) — фолбэк-цикл ниже до них не дойдёт (_rawHasOwnName).
      nodes = parseAll(decode(input.trim()), nameHint: nameFallback);
    } catch (e) {
      return humanizeError(e);
    }
    if (nodes.isEmpty) return const ErrMsg(ErrKey.noServersFoundInInput);

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
    return null;
  }

  /// Одноразовый импорт в папку по ссылке: fetch → parse → статичные члены.
  /// Снапшот: meta/auto-update не сохраняются, URL не хранится.
  Future<UiMsg?> addUrlSnapshotToFolder(int index, String url) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    if (entry.list is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    _busy = true;
    notifyListeners();
    try {
      final result = await parseFromSource(UrlSource(url.trim()),
          client: httpClientForTesting);
      if (result.nodes.isEmpty) {
        return const ErrMsg(ErrKey.noServersFoundAtUrl);
      }
      // Guard после await: entry могли удалить/подменить.
      final cur = entry.list;
      if (cur is! FolderServers || !_entries.contains(entry)) {
        return const ErrMsg(ErrKey.folderNotFound);
      }
      final added =
          result.nodes.map((n) => FolderMember(raw: memberRawFor(n))).toList();
      entry._replaceList(cur.copyWith(members: [...cur.members, ...added]));
      entry.nodeCount = entry.list.nodes.length;
      await _persist();
      AppLog.I.info(
          'Folder "${cur.name}": +${added.length} servers (URL snapshot)');
      return null;
    } catch (e) {
      return humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// §283 — вкл/выкл одной ноды подписки. Ключ — identity-хеш сути узла
  /// (node_hash.dart): переживает refresh/рестарт/переименование ноды
  /// провайдером; дубли одного сервера с разными лейблами гасятся одним
  /// toggle (by design). При выключении lastSeen = now (старт TTL-отсчёта,
  /// GC — на успешном сетевом refresh в _fetchEntryByRef).
  Future<void> toggleSubscriptionNode(int index, NodeSpec node) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    final hash = nodeIdentityHash(node);
    final next = Map<String, DateTime>.from(list.disabledHashes);
    if (next.containsKey(hash)) {
      next.remove(hash);
    } else {
      next[hash] = DateTime.now();
    }
    entry._replaceList(list.copyWith(disabledHashes: next));
    await _persist();
    notifyListeners();
  }

  /// §332 — вкл/выкл ВСЕХ нод подписки разом (кнопка на вкладке Nodes).
  ///
  /// enable: карта отметок очищается целиком — ручные (§283),
  /// правило-отметки (§302) и TTL-хвосты ушедших узлов. DISABLE-правила при
  /// следующем refresh поставят свои отметки заново (правило — источник
  /// истины). disable: merge поверх существующих — TTL-отметки временно
  /// отсутствующих узлов не теряются, GC доделает своё.
  Future<void> setAllSubscriptionNodes(int index,
      {required bool enabled}) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    final Map<String, DateTime> next;
    if (enabled) {
      if (list.disabledHashes.isEmpty) return;
      next = const {};
    } else {
      if (list.nodes.isEmpty) return;
      final now = DateTime.now();
      next = {
        ...list.disabledHashes,
        for (final n in list.nodes) nodeIdentityHash(n): now,
      };
    }
    entry._replaceList(list.copyWith(disabledHashes: next));
    await _persist();
    notifyListeners();
  }

  /// §388 — вкл/выкл ПАЧКИ нод подписки (bulk-действия по результатам probe:
  /// «Disable unreachable» / «Disable slower than…»). Отметки — та же карта
  /// ручных §283 (identity-хеш, TTL + GC на успешном refresh); ENABLE-правила
  /// фильтров при следующем refresh снимут их (§332 — правило источник
  /// истины), экран предупреждает до действия.
  Future<void> setSubscriptionNodesEnabled(int index, Iterable<NodeSpec> nodes,
      {required bool enabled}) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    final hashes = {for (final n in nodes) nodeIdentityHash(n)};
    if (hashes.isEmpty) return;
    final Map<String, DateTime> next;
    if (enabled) {
      next = Map<String, DateTime>.from(list.disabledHashes)
        ..removeWhere((h, _) => hashes.contains(h));
    } else {
      final now = DateTime.now();
      next = {...list.disabledHashes, for (final h in hashes) h: now};
    }
    entry._replaceList(list.copyWith(disabledHashes: next));
    await _persist();
    notifyListeners();
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
  Future<UiMsg?> updateMemberAt(
      int index, int memberIndex, String newRaw) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final trimmed = newRaw.trim();
    final probe = FolderMember(raw: trimmed);
    if (probe.node == null) {
      return const ErrMsg(ErrKey.memberParseKeepCurrent);
    }
    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(raw: trimmed);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    return null;
  }

  /// Удалить члена из папки (совсем).
  Future<void> removeMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final gone = folder.members[memberIndex];
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    // §393 D2 — член папки — такой же источник узла, как одиночный сервер.
    await _healChainsForRemoved(_memberTags(folder, gone));
    notifyListeners();
  }

  /// §393 D2 — теги конфига одного члена папки: голый и с префиксом папки.
  Set<String> _memberTags(FolderServers f, FolderMember m) {
    final bare = m.node?.tag ?? '';
    if (bare.isEmpty) return const {};
    return {bare, TagResolver.displayTag(f.tagPrefix, bare)}
      ..removeWhere((t) => t.trim().isEmpty);
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

  /// §237/§239 — личный detour члена: для цели из СВОЕЙ папки хранится
  /// ГОЛЫЙ тег члена (resolve при сборке — переживает смену префикса), для
  /// внешней — display-form (§080). Отклоняет self и ребро, замыкающее
  /// интра-цикл. Возвращает '' при успехе, иначе текст ошибки.
  Future<UiMsg?> setMemberDetour(
      int index, int memberIndex, String detour) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }

    if (detour.isNotEmpty) {
      // Интра-цикл: ребро member→target замыкает петлю, если из target по
      // существующим интра-рёбрам достижим сам member.
      final bare = <String, int>{};
      for (var k = 0; k < folder.members.length; k++) {
        final t = folder.members[k].node?.tag;
        if (t != null && t.isNotEmpty) bare.putIfAbsent(t, () => k);
      }
      final target = bare[detour];
      if (target == memberIndex) {
        return const ErrMsg(ErrKey.detourSelf);
      }
      if (target != null) {
        int? edgeOf(int k) {
          if (k == memberIndex) return target; // новое ребро
          final d = folder.members[k].detour;
          if (d.isEmpty) return null;
          final j = bare[d];
          return (j != null && j != k) ? j : null;
        }

        final seen = <int>{};
        int? cur = target;
        while (cur != null && seen.add(cur)) {
          if (cur == memberIndex) {
            return const ErrMsg(ErrKey.detourLoopInFolder);
          }
          cur = edgeOf(cur);
        }
      }
    }

    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(detour: detour);
    entry._replaceList(folder.copyWith(members: members));
    await _persist();
    notifyListeners();
    return null;
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
    final gone = [
      for (var i = 0; i < folder.members.length; i++)
        if (memberIndexes.contains(i)) folder.members[i],
    ];
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    // §393 D2 — как одиночное удаление члена, только пачкой.
    await _healChainsForRemoved(
        {for (final m in gone) ..._memberTags(folder, m)});
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
  Future<UiMsg?> moveMemberToFolder(
      int fromIndex, int memberIndex, int toIndex) async {
    if (fromIndex < 0 || fromIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    if (toIndex < 0 || toIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    if (fromIndex == toIndex) return null;
    final fromEntry = _entries[fromIndex];
    final toEntry = _entries[toIndex];
    final from = fromEntry.list;
    final to = toEntry.list;
    if (from is! FolderServers || to is! FolderServers) {
      return const ErrMsg(ErrKey.notAFolder);
    }
    if (memberIndex < 0 || memberIndex >= from.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final member = from.members[memberIndex];
    final fromMembers = [...from.members]..removeAt(memberIndex);
    fromEntry._replaceList(from.copyWith(members: fromMembers));
    fromEntry.nodeCount = fromEntry.list.nodes.length;
    toEntry._replaceList(to.copyWith(members: [...to.members, member]));
    toEntry.nodeCount = toEntry.list.nodes.length;
    await _persist();
    notifyListeners();
    return null;
  }

  /// Перенести одиночный сервер в папку. rawBody сплитится на членов 1:1 по
  /// нодам; личные tag_prefix/detour_policy сервера отбрасываются — действуют
  /// папочные (осознанный trade-off §234). Одиночная запись удаляется.
  Future<UiMsg?> moveServerToFolder(int serverIndex, int folderIndex) async {
    if (serverIndex < 0 || serverIndex >= _entries.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    if (folderIndex < 0 || folderIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final serverEntry = _entries[serverIndex];
    final folderEntry = _entries[folderIndex];
    final server = serverEntry.list;
    final folder = folderEntry.list;
    if (server is! UserServer) {
      return const ErrMsg(ErrKey.onlySingleServersCanBeMoved);
    }
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);

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
    return null;
  }

  /// Публичный refresh для AutoUpdater. Помечает попытку
  /// (`lastUpdateAttempt` + `lastUpdateStatus`) и персистит, чтобы триггер #1
  /// (app start) после рестарта мог принять решение.
  ///
  /// §331 (ревью) — возвращает «состав узлов изменился» (true только при
  /// успешном фетче с реально новым составом). AutoUpdater по этому значению
  /// гейтит реакцию `onUpdateAction`: без гейта подписка с тем же списком нод
  /// запускала бы пересборку (а в режиме reload — и попытку reload) на каждом
  /// часовом тике. Ручной путь (⟳ → `_fetchEntryByRef`) гейтится тем же
  /// `sameComposition` внутри.
  Future<bool> refreshEntry(SubscriptionEntry entry,
      {UpdateTrigger? trigger}) =>
      _fetchEntryByRef(entry, trigger: trigger);

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
      // §254 — не дать залипшему DetourCycle прошлой генерации показать
      // ложный sheet и отменить старт с запиненным конфигом.
      _lastFatalIssues = const [];
      return null;
    }
    _busy = true;
    _generating = true;
    _lastError = null;
    _lastFatalIssues = const [];
    notifyListeners();
    // §360 — снимок состава на момент, с которого `_generate` начнёт читать
    // `_entries`. Мутация, прилетевшая из UI ПОКА мы генерируем (toggle
    // подписки на экране Servers), в этот конфиг уже не попала: гасить по ней
    // `configDirty` — значит молча выбросить изменение до следующей случайной
    // мутации. Сравниваем снимок с составом на выходе и гасим флаг, только
    // если под нами ничего не поменялось.
    final before = _compositionSignature();
    try {
      final config = await _generate();
      _lastGeneratedConfig = config;
      if (_compositionSignature() == before) {
        configDirty = false;
      } else {
        AppLog.I.info(
            '§360: entries changed during rebuild — configDirty kept');
      }
      return config;
    } catch (e) {
      _lastError = humanizeError(e);
      // §254 — сохранить структуру fatal-issues для UI (DetourCycle → sheet).
      if (e is FatalValidationException) _lastFatalIssues = e.issues;
      return null;
    } finally {
      _busy = false;
      _generating = false;
      _progressMessage = null;
      notifyListeners();
    }
  }

  Future<String> _generate() async {
    AppLog.I.info('Generating config...');
    _progressMessage = const SubStatusBuildingConfig();
    notifyListeners();

    final settings = BuildSettings(
      userVars: await SettingsStorage.getAllVars(),
      enabledGroups: await SettingsStorage.getEnabledGroups(),
      customRules: await SettingsStorage.getCustomRules(),
      routeFinal: await SettingsStorage.getRouteFinal(),
      directions: await SettingsStorage.getDirections(), // §125
      chains: await SettingsStorage.getChains(), // §393 C2
      // §393 C5 — гейт возможностей ядра живёт в СБОРКЕ, не в UI: цепочку
      // может добавить и Debug API, и restore бэкапа с новой машины, а
      // отвергнутый ядром конфиг оставит пользователя без VPN целиком.
      // Кэшируется на сессию — версия ядра вкомпилирована в APK и не меняется
      // (см. [CoreVersionCache]).
      coreVersion:
          await CoreVersionCache.ensure(BoxVpnClient().getCoreVersion),
      tunApps: await SettingsStorage.getTunApps(),
      vpnMode: await SettingsStorage.getVpnMode(),
      idleSuspend: await SettingsStorage.getIdleSuspend(), // §215
      idleSuspendReachable:
          await SettingsStorage.getIdleSuspendReachable(), // §272
      passiveCheck: await SettingsStorage.getPassiveCheck(), // §272
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
        AppLog.I.error('Validation: ${issue.renderEn()}');
      }
      throw FatalValidationException(fatal);
    }
    // §274 — пустые Направления (фильтр отсёк все ноды) → транзиентный SnackBar
    // на Home. Только успешная сборка: при fatal юзер получает свой sheet,
    // дублировать шум не надо.
    _directionsWithoutNodes = result.directionsWithoutNodes;
    if (_directionsWithoutNodes.isNotEmpty) {
      _directionsWithoutNodesStamp++;
      notifyListeners();
    }
    return result.configJson;
  }

  Future<bool> _fetchEntry(int index, {UpdateTrigger? trigger}) async {
    if (index < 0 || index >= _entries.length) return false;
    return _fetchEntryByRef(_entries[index], trigger: trigger);
  }

  /// Fetch по ссылке на entry, а не индексу. Защищает от race conditions:
  /// если между добавлением entry и `await _persist` подмешался ещё один
  /// `addFreeList` / `addFromInput`, индекс уже сместился, но ссылка валидна.
  ///
  /// Записывает `lastUpdateAttempt` (всегда) и `lastUpdateStatus` (ok|failed)
  /// в `SubscriptionServers` и сразу персистит — чтобы AutoUpdater после
  /// рестарта app не пытался обновить ту же подписку через 5 секунд.
  ///
  /// §331 (ревью) — возвращает «состав узлов изменился»: true ТОЛЬКО при
  /// успешном фетче с новым составом (см. `_compositionKey`). Скипы, фейлы и
  /// «тот же список» → false. Контракт для гейта реакции в AutoUpdater.
  Future<bool> _fetchEntryByRef(SubscriptionEntry entry,
      {UpdateTrigger? trigger}) async {
    final list = entry.list;
    if (list is! SubscriptionServers) return false;

    // §129 — файловая подписка: источник локальный, снапшот живёт в HttpCache.
    // Автоматически перечитать файл нельзя (Вариант Б: доступ между сессиями не
    // храним). Поэтому fetch/auto-update = keep-previous: ноды остаются из кэша,
    // подписка НЕ слетает при массовом апдейте онлайн-подписок. Обновление
    // файловой — только вручную через Edit source → Choose file (updateSourceAt).
    if (isFileSubscription(list.url)) {
      AppLog.I.debug('Skip fetch (file subscription): keeping cached nodes');
      return false;
    }

    // Дедупликация: если предыдущий fetch этой же подписки ещё идёт
    // (ручной refresh нажали 2 раза подряд, или manual + триггер совпали),
    // не стартуем второй HTTP. Guard снимается по успеху/фейлу в том же
    // вызове (status→ok|failed). Crash-safe: init() sweep чистит зависший
    // inProgress.
    if (list.lastUpdateStatus == UpdateStatus.inProgress) {
      AppLog.I.debug(
          'Fetch skipped — already inProgress: ${maskSubscriptionUrl(list.url)}');
      return false;
    }

    // Масированный URL (T2-3): char-truncation раньше мог оставить токен
    // в логе (провайдеры вроде `https://host/sub/<token>` укладываются в 60
    // символов). `maskSubscriptionUrl` рубит на host.
    final shortUrl = maskSubscriptionUrl(list.url);
    final triggerName = trigger?.name ?? 'manual';
    AppLog.I.info('Fetching subscription [$triggerName]: $shortUrl');
    final attemptAt = DateTime.now();
    var compositionChanged = false;
    try {
      entry.status = const SubStatusFetching();
      // Помечаем попытку до начала fetch'а, чтобы при крэше app
      // (или kill процесса) AutoUpdater всё равно увидел, что мы пробовали.
      //
      // §331 (ревью) — keepDirtyFlag: пометка попытки — чистые метаданные
      // (`lastUpdateAttempt`, `inProgress`), билдер их не читает, пересобирать
      // не из чего. Ранний вариант поднимал здесь флаг и «восстанавливал» его
      // после fetch'а — с гонкой: реальная правка юзера, сделанная ВО ВРЕМЯ
      // fetch'а (сетевые секунды), затиралась восстановлением. Не поднимаем —
      // и восстанавливать нечего, гонка исчезает по построению.
      entry._replaceList(list.copyWith(
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.inProgress,
      ));
      await _persist(keepDirtyFlag: true);
      notifyListeners();

      // §289 — per-subscription идентичность (null → глобальная).
      // §302 — import-rules здесь не участвуют: применяются ниже, к уже
      // разобранным узлам.
      final result = await parseFromSource(
          UrlSource(list.url, identity: list.identity),
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
            ? SubStatusUpdateFailed(entry.nodeCount, zeroParsed: true)
            : SubStatusZeroNodes(hint);
        final current = entry.list as SubscriptionServers;
        entry._replaceList(current.copyWith(
          lastUpdateAttempt: attemptAt,
          lastUpdateStatus: UpdateStatus.failed,
          consecutiveFails: current.consecutiveFails + 1,
        ));
        try {
          // §331 (ревью) — keepDirtyFlag: фейл-статус — метаданные, состав
          // узлов не менялся. Без гейта каждый неудачный фетч (провайдер лёг,
          // авиарежим) поднимал синюю плашку «Settings changed» — раз в час,
          // на конфиге, который никто не трогал.
          await _persist(keepDirtyFlag: true);
        } catch (e) {
          // §101 review: persist-фейл не должен уйти в общий catch — там
          // consecutiveFails инкрементится повторно и haptic дублируется.
          // In-memory состояние уже корректно; теряем только запись на диск.
          AppLog.I.error(
              'Persist failed after empty fetch: ${humanizeError(e).renderEn()}');
        }
        if (trigger == UpdateTrigger.manual) HapticService.I.onFetchError();
        // §047 — outgoing subscription event (gated, default OFF, throttled).
        AutomationEventEmitter.I
            .emitSubRefreshFailed(shortUrl, '0 nodes parsed');
        notifyListeners();
        return false;
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
      entry.status = SubStatusNodes(result.nodes.length, detours: detours);

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
      // §302 — import-rules применяем к УЖЕ РАЗОБРАННЫМ узлам (их emit-JSON):
      // REPLACE патчит узел (`patchedJson` → уходит в конфиг), DISABLE даёт
      // identity-хеши для §283. Делаем это ДО GC ниже, чтобы GC (now -
      // lastSeen = 0 ≤ TTL) свежие пометки не снял: правило — источник истины
      // и переставляется на КАЖДОМ refresh.
      //
      // Хеш считается ПОСЛЕ патча, тем же путём, что у билдера (обе стороны —
      // `nodeIdentityHash` того же инстанса), поэтому пометка гарантированно
      // совпадает с узлом, который билдер увидит.
      final ruleNow = DateTime.now();
      final ruleMarks =
          _applyRulesToNodes(result.nodes, current.activeImportRules);

      // §283 — GC отметок disable ТОЛЬКО здесь (успешный сетевой fetch =
      // единственный сигнал «нода ушла из подписки»; failed fetch и
      // регидрация из кэша состав не проясняют, file:-подписки сюда не
      // доходят — guard выше). Хеш свежих нод считаем лишь когда есть что
      // чистить.
      final baseDisabled =
          current.disabledHashes.isEmpty && ruleMarks.disable.isEmpty
              ? current.disabledHashes
              : gcDisabledHashes(
                  current.disabledHashes,
                  {for (final n in result.nodes) nodeIdentityHash(n)},
                  updateIntervalHours: nextInterval,
                  now: ruleNow,
                );
      // §332 — итог правил поверх GC (правило > GC): ENABLE снимает отметки
      // (включая ручные §283), DISABLE ставит.
      final nextDisabled = applyRuleMarks(
        baseDisabled,
        enable: ruleMarks.enable,
        disable: ruleMarks.disable,
        now: ruleNow,
      );
      final next = current.copyWith(
        name: nextName,
        meta: result.meta,
        lastUpdated: DateTime.now(),
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: result.nodes.length,
        consecutiveFails: 0,
        updateIntervalHours: nextInterval,
        disabledHashes: nextDisabled,
        nodes: result.nodes,
      );
      entry._replaceList(next);
      // §331 — состав узлов тот же ⇒ пересобирать конфиг не из чего, синюю
      // плашку «Settings changed» не поднимаем. На диск пишем всё равно:
      // last_updated / last_update_attempt / GC-отметки обновиться должны.
      //
      // Что входит в «состав» — ровно то, что видит билдер: identity-хеши
      // узлов В ПОРЯДКЕ следования (порядок значим — от него зависят
      // suffixes allocateTag и порядок в пулах) плюс набор disable-отметок
      // (§283: снятая/поставленная отметка меняет, что эмитится, при том же
      // списке узлов). Всё прочее в подписке — метаданные, конфиг от них не
      // зависит.
      final sameComposition = _compositionKey(current.nodes, current.disabledHashes.keys) ==
          _compositionKey(result.nodes, nextDisabled.keys);
      // §349 — выключенная подписка в конфиг не эмитится (билдер пропускает
      // `!list.enabled`): её состав на конфиг не влияет, флаг не поднимаем.
      // Иначе §337 («обновлять выключенные») давал ложную синюю плашку на
      // каждом проходе с новым составом — пересборке нечего менять. При
      // включении подписки dirty поднимет сам тоггл enabled.
      final affectsConfig = current.enabled;
      // Единственный persist фетч-пути, которому ПОЗВОЛЕНО поднять флаг — и
      // только при реально изменившемся составе. Все остальные (попытка,
      // фейлы, sweep) — метаданные с keepDirtyFlag: true, поэтому никакого
      // «запомнить и восстановить» здесь больше нет (см. историю §331: у
      // restore-варианта была гонка с правками юзера во время fetch'а).
      await _persist(keepDirtyFlag: sameComposition || !affectsConfig);
      compositionChanged = !sameComposition;
      if (sameComposition) {
        AppLog.I.debug('§331: composition unchanged for $shortUrl');
      }
      // §331 — ручной ⟳ идёт сюда, минуя `AutoUpdater.maybeUpdateAll`, поэтому
      // реакцию подписки (`onUpdateAction`) применяем здесь сами. Только при
      // РЕАЛЬНО изменившемся составе: иначе кнопка «обновить» на неизменной
      // подписке рвала бы туннель на 3 секунды ни за что.
      //
      // Авто-триггеры реакцию получают в `maybeUpdateAll` — там она
      // агрегируется за весь проход (один reload на N подписок, а не N).
      // §349 — и реакция только для включённой: выключенная не в конфиге,
      // пересборка/reload ей нечего применять (зеркало гейта auto_updater).
      if (trigger == UpdateTrigger.manual && !sameComposition && affectsConfig) {
        switch (next.onUpdateAction) {
          case SubscriptionOnUpdateAction.reload:
            await _autoUpdater?.applyReaction(reload: true);
          case SubscriptionOnUpdateAction.rebuild:
            await _autoUpdater?.applyReaction(reload: false);
          case SubscriptionOnUpdateAction.none:
            break;
        }
      }
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
          ? SubStatusUpdateFailed(entry.nodeCount)
          : PrefixedMsg(ErrPrefix.error, RawMsg('$e'));
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
        // §331 (ревью) — keepDirtyFlag: как в empty-parse ветке выше — фейл
        // пишет только метаданные, синяя плашка от него не законна.
        await _persist(keepDirtyFlag: true);
      }
      if (trigger == UpdateTrigger.manual) HapticService.I.onFetchError();
      // §047 — outgoing subscription event (gated, default OFF; throttled
      // 1/min на sub_id в эмиттере, чтобы network-outage не заспамил Tasker).
      AutomationEventEmitter.I
          .emitSubRefreshFailed(shortUrl, humanizeError(e).renderEn());
    }
    notifyListeners();
    return compositionChanged;
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
      // §243 — displayName у UserServer name игнорирует (legacy v2.11.0 мог
      // записать туда имя файла); при пересохранении затираем совсем.
      name: '',
      rawBody: connections.join('\n'),
      nodes: nodes,
    );
    _entries[index]._replaceList(next);
    _entries[index].nodeCount = nodes.length;
    _entries[index].status = const SubStatusJsonOutbound();
    await _persist();
    notifyListeners();
  }

  /// §331 — отпечаток «состава» подписки: то и только то, от чего зависит
  /// собранный конфиг. Одинаковый отпечаток ⇒ пересборка дала бы тот же
  /// результат ⇒ поднимать `configDirty` не за что.
  ///
  /// Что входит:
  /// - identity-хеши узлов **в порядке следования** — порядок значим: от него
  ///   зависят суффиксы `allocateTag` (`X` / `X-1`) и порядок внутри пулов
  ///   `urltest`/`selector`. Провайдер переставил узлы — это изменение;
  /// - набор disable-отметок (§283) — при том же списке узлов снятая или
  ///   поставленная отметка меняет, что билдер эмитит. Сортируем: порядок
  ///   ключей map'а сам по себе ничего не значит.
  ///
  /// Что НЕ входит и не должно: `last_updated`, `last_update_attempt`,
  /// `lastUpdateStatus`, `meta` (HTTP-заголовки, трафик, срок), `name`,
  /// `consecutiveFails`, `updateIntervalHours` — билдер их не читает.
  ///
  /// Хеши считаются от УЖЕ пропатченных §302-правилами узлов (метод зовётся
  /// после `_applyRulesToNodes`), тем же `nodeIdentityHash`, что у билдера.
  @visibleForTesting
  static String compositionKeyForTesting(
    List<NodeSpec> nodes,
    Iterable<String> disabledHashes,
  ) =>
      _compositionKey(nodes, disabledHashes);

  static String _compositionKey(
    List<NodeSpec> nodes,
    Iterable<String> disabledHashes,
  ) {
    // Длина каждого элемента в префиксе — иначе конкатенация склеивается
    // неоднозначно: две отметки `x`,`y` дали бы то же, что одна `x,y` (тест
    // §331 «разделитель не даёт коллизии»). Хеши узлов фиксированной длины, но
    // отметки приходят из storage и гарантий не дают.
    String lenPrefixed(Iterable<String> items) =>
        items.map((s) => '${s.length}:$s').join();
    final tags = lenPrefixed(nodes.map(nodeIdentityHash));
    final disabled = lenPrefixed(disabledHashes.toList()..sort());
    return '$tags|$disabled';
  }

  /// §360 — отпечаток состава ВСЕХ entries: что увидит билдер, если собрать
  /// конфиг прямо сейчас. Служит одной цели — понять, менялись ли `_entries`
  /// под летящей пересборкой (см. `generateConfig`).
  ///
  /// В отличие от §331-`_compositionKey` (одна подписка, вопрос «фетч принёс
  /// новое?») здесь входит и `enabled`: выключенная подписка отдаёт билдеру
  /// пустой набор узлов, так что сам флаг — часть состава. Порядок entries
  /// значим по той же причине, что и порядок узлов внутри списка.
  String _compositionSignature() {
    final parts = _entries.map((e) {
      final l = e.list;
      final nodes = l.nodes.map(nodeIdentityHash).join(',');
      return '${l.id}:${l.enabled ? 1 : 0}:$nodes';
    });
    return parts.map((s) => '${s.length}:$s').join();
  }

  /// [keepDirtyFlag] — §331: записать на диск, НЕ поднимая `configDirty`.
  /// Единственный законный случай: успешный fetch, в котором состав узлов
  /// оказался тем же. На диск писать всё равно надо (`last_updated`,
  /// `last_update_attempt`, GC-отметки), но пересобирать конфиг не из чего —
  /// а синяя плашка «Settings changed» именно это и предлагала, раз в час, на
  /// подписке, которая не менялась.
  ///
  /// Для всех прочих вызовов дефолт неизменен: любая запись = pending changes.
  ///
  /// §360 — гейт здесь смотрит на `_generating`, а НЕ на `_busy`. `_busy`
  /// поднимают ещё и `addUserServer`/`addFromInput`/fetch/`addMembersToFolder`
  /// — операции, которые обязаны быть dirty; под общим гейтом они молча теряли
  /// флаг. Хуже того, гейт ловил и мутации, пришедшие из UI ПОКА летит чужая
  /// пересборка (toggle подписки сразу после возврата на home): изменение
  /// применялось в `_entries`, но `configDirty` не вставал, а `generateConfig`
  /// следом гасил его в false — новый состав нод не доезжал до конфига до
  /// следующей случайной мутации. Самозагрязнение самой пересборки закрыто
  /// явным `keepDirtyFlag: true` на её внутренних вызовах, отдельный гейт для
  /// этого не нужен.
  Future<void> _persist({bool keepDirtyFlag = false}) async {
    if (!_generating && !keepDirtyFlag) configDirty = true;
    await SettingsStorage.saveServerLists(_entries.map((e) => e.list).toList());
  }

  /// §248 — ресинк in-memory `_entries` после storage-heal detour-ссылок
  /// (снятие галки detour / disable / delete Направления): storage уже вылечен
  /// `updateDirection`/`deleteDirection`, но `_entries` живёт с init() — без
  /// зеркального сброса следующий `_persist()` (rename, toggle члена,
  /// авто-refresh подписки) воскресил бы ссылку на диске, а
  /// `generateConfig()` собирал бы конфиг с ней вопреки показанному юзеру
  /// уведомлению. Повторный `_persist` не нужен — на диске уже верно.
  void syncDetourDirectionRefsCleared(String tag) {
    var changed = false;
    for (final e in _entries) {
      final r = clearDetourDirectionRefs(e.list, tag);
      if (r.healed != null) {
        e._replaceList(r.healed!);
        changed = true;
      }
    }
    if (changed) notifyListeners();
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
