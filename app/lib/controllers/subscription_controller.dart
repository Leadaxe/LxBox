import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/auto_select.dart';
import '../models/core_reject_verdict.dart';
import '../models/import_rule.dart';
import '../models/node_link.dart';
import '../models/node_sections.dart';
import '../models/node_spec.dart';
import '../models/node_warning.dart';
import '../models/codec/source_record.dart';
import '../models/server_list.dart';
import '../models/source_replace.dart';
import '../models/source_entry.dart';
import '../models/tailscale_bundle.dart';
import '../models/ui_msg.dart';
import '../models/subscription_meta.dart';
import '../models/tunnel_status.dart';
import '../models/validation.dart';
import '../services/app_log.dart';
import 'subscription_controller/core_reject_ops.dart';
import '../services/core_reject/core_reject_guard.dart';
import '../services/automation/event_emitter.dart';
import '../services/config_dirty_check.dart';
import '../services/error_humanize.dart';
import '../services/parse_hints.dart';
import '../services/record_vars.dart';
import '../services/relative_time.dart';
import '../services/node_emoji.dart';
import '../services/node_hash.dart';
import '../services/node_identity.dart';
import '../services/node_link_address.dart';
import '../services/settings_storage/node_link_registry.dart';
import '../services/tailscale_state/state_keys.dart';
import '../services/tailscale_state/state_store.dart';
import '../services/url_mask.dart';
import '../services/builder/build_config.dart';
import '../services/builder/if_engine.dart' show TemplateWarning;
import '../services/builder/core_chain_capability.dart';
import '../vpn/box_vpn_client.dart';
import '../services/parser/body_decoder.dart';
import '../services/parser/ini_parser.dart';
import '../services/parser/parse_all.dart';
import '../services/parser/tailscale_split.dart';
import '../services/parser/uri_parsers.dart';
import '../services/parser/uri_utils.dart';
import '../services/haptic_service.dart';
import '../services/settings_storage.dart';
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
import '../services/workspaces/workspace_controller.dart';
import '../services/workspaces/workspace_store.dart';

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
  /// §515 — поколение Workspaces, в котором контроллер родился. Сцена на диске
  /// принадлежит ровно одному слоту, а `_persist()` переписывает весь набор
  /// контейнеров целиком (§524 — `sources_rules.dart` → `_writeEntries` через
  /// фасад `saveServerLists`) — без привязки к слоту. Пересоздание экрана (`main.dart`, ключ по
  /// `WorkspaceController.generation`) даёт новый контроллер, но асинхронные
  /// хвосты старого (летящий HTTP подписки, 10-секундная пауза апдейтера между
  /// подписками, `toggleAt` из ещё живого обработчика) продолжают жить и
  /// пишут состав ПРЕЖНЕГО слота в файл, который к тому моменту принадлежит
  /// НОВОМУ. Ближайший `load`/`saveAs` копирует испорченную сцену в папку
  /// слота — подмена закрепляется на диске.
  ///
  /// Барьер стоит на уровне контроллера, а не в писателе хранения: там под
  /// него попали бы легитимные писатели, не принадлежащие `HomeScreen`
  /// (импорт бэкапа, Debug API, шаги `_reloadStateFromDisk`), и их записи
  /// молча терялись бы.
  final int _bornGeneration = WorkspaceController.I.generation;

  /// §515 — контроллер прошёл `dispose()`. Проверяется в `_persist()` и после
  /// каждого `await` в долгих асинхронных проходах.
  bool _disposed = false;

  /// §515 — «этот контроллер больше не владеет сценой»: либо его уже
  /// disposed'нули, либо Workspaces успел сменить слот. Публичный, чтобы
  /// асинхронные проходы (fetch, регидрация) могли выйти рано, не дожидаясь
  /// собственного `_persist`.
  bool get stale =>
      _disposed || WorkspaceController.I.generation != _bornGeneration;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// §515 — disposed-контроллер молчит вместо `assert`-падения. У контроллера
  /// 58 точек `_persist` + `notifyListeners`, и любой асинхронный хвост
  /// (летящий фетч, ещё не отработавший обработчик кнопки) доходит до notify
  /// уже после `HomeScreen.dispose()`. Барьер в `_persist` запись отменяет, но
  /// `ChangeNotifier.notifyListeners` на этом же пути роняет debug-сборку
  /// assert'ом «used after being disposed» — на проде это был бы тихий no-op,
  /// а в тестах и профиле падение на месте, не имеющем отношения к дефекту.
  /// Слушателей после `dispose()` нет по построению, уведомлять некого.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  List<SubscriptionEntry> _entries = [];
  List<SubscriptionEntry> get entries => _entries;

  /// §446 — подстановка состава подписок в тестах, без похода в хранение и
  /// сеть. Продовый путь наполнения — `loadFromStorage` / `add*`.
  @visibleForTesting
  void debugSetEntries(List<SubscriptionEntry> entries) {
    _entries = entries;
  }

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

  /// Фича 478 — обратная карта последней сборки «финальный тег → исходный
  /// узел» (PARSING_PRINCIPLES §9.3). Живёт ровно до следующей сборки: страховка
  /// пересобирает конфиг перед каждым кругом и читает карту сразу.
  Map<String, NodeSpec> _lastTagMap = const {};
  Map<String, NodeSpec> get lastEmittedTagMap => _lastTagMap;

  /// §505 — предупреждения сборки по финальному config-тегу (гард реестра).
  Map<String, List<NodeWarning>> _lastBuildWarningsByTag = const {};
  Map<String, List<NodeWarning>> get lastBuildWarningsByTag =>
      _lastBuildWarningsByTag;

  /// §498 — подмена обратной карты последней сборки в тестах навигации листа.
  @visibleForTesting
  void debugSetLastEmittedTagMap(Map<String, NodeSpec> map) {
    _lastTagMap = map;
  }

  @visibleForTesting
  void debugSetLastBuildWarningsByTag(Map<String, List<NodeWarning>> map) {
    _lastBuildWarningsByTag = map;
  }

  /// §274 — Направления, чей node_filter отсёк все ноды в последней УСПЕШНОЙ
  /// сборке (display-имена; Направление схлопнулось в block-fallback). [stamp]
  /// монотонно растёт на каждой сборке с непустым списком — Home дедупит
  /// по нему транзиентный SnackBar (один показ на сборку, не на rebuild
  /// виджетов).
  List<String> _directionsWithoutNodes = const [];
  List<String> get directionsWithoutNodes => _directionsWithoutNodes;
  int _directionsWithoutNodesStamp = 0;
  int get directionsWithoutNodesStamp => _directionsWithoutNodesStamp;

  /// §555 / задача 570 — предупреждения движка шаблона последней успешной
  /// сборки (`template_degraded`): Home показывает их коротким снеком
  /// «Template: N warnings» с переходом в шторку кодов. Сохранение они не
  /// блокируют. Stamp растёт на каждую сборку с непустым списком — один
  /// показ на сборку.
  /// §565 / задача 570 — выбор члена ручной группы записан в состояние при
  /// живом туннеле, а конфиг на диске не пересобран (ядро уже переключено
  /// вживую). Старт VPN обязан пересобрать конфиг, иначе следующий запуск
  /// взял бы прежний `default`. Сбрасывается любой сборкой.
  bool _groupDefaultsPending = false;
  bool get groupDefaultsPending => _groupDefaultsPending;

  List<TemplateWarning> _templateWarnings = const [];
  List<TemplateWarning> get templateWarnings => _templateWarnings;
  int _templateWarningsStamp = 0;
  int get templateWarningsStamp => _templateWarningsStamp;

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
    // §447 — флаг, поднятый в этом процессе (загрузка слота Workspaces,
    // restore), mtime-сравнение не опускает: он живёт статикой в
    // SettingsStorage и переживает пересоздание HomeScreen, а mtime к этому
    // моменту уже мог выровнять любой `_save()`.
    if (configDirty) {
      AppLog.I.info('init: configDirty=true kept from this process');
    } else {
      configDirty = await ConfigDirtyCheck.isDirty();
      if (configDirty) {
        AppLog.I.info('init: configDirty=true via mtime compare');
      }
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
        // §515 — регидрация стартует `unawaited` из `_initBody`: контроллер
        // прежнего слота может дожить до неё уже после переключения.
        if (stale) return;
        if (body == null || body.isEmpty) continue;
        try {
          final decoded = decode(body);
          // §561 — `dropped[]` сводки источника восстанавливается тем же
          // разбором кэша, что и узлы: в кодек записи он не пишется.
          final dropped = <NodeWarning>[];
          final nodes = parseAll(decoded, dropped: dropped);
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
          // §400 (IDENTITY.md §5.1) — регидрация кэша это тоже первый разбор
          // источника: узлы появились, значит legacy-ключи можно опознать, не
          // дожидаясь сетевого refresh. GC здесь по-прежнему НЕ делаем —
          // кэш не сигнал «узел ушёл» (§283), а миграция чистит только те
          // ключи, содержимого которых в теле нет.
          final migrated =
              migrateLegacyDisabledKeys(cur.disabledHashes, nodes);
          // Фича 478 — вердикт ядра пересчётом по телу не воспроизводится:
          // дописываем его на разобранные узлы, иначе регидрация из кэша
          // покажет узел выключенным без причины.
          stampStoredVerdicts(nodes, cur.nodeWarnings);
          final next = cur.copyWith(
            nodes: nodes,
            lastNodeCount: nodes.length,
            disabledHashes: migrated,
            dropped: summaryDropped(dropped),
          );
          entry._replaceList(next);
          // Результат миграции обязан лечь на диск: иначе legacy-ключи
          // прогоняются заново на каждом старте. Метаданные — флаг пересборки
          // не поднимаем (регидрация состав конфига не меняет).
          if (!identical(migrated, cur.disabledHashes)) {
            await _persist(keepDirtyFlag: true);
          }
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
  /// идентичности узлов, помеченных к выключению (Disable) и к
  /// принудительному включению (Enable, §332).
  ///
  /// §400 — REPLACE патчит `NodeSpec.patchedJson` (узел эмитится из него), но
  /// идентичность считается от ТЕГА, а патч тег не трогает: правило, меняющее
  /// server/uuid, отметку больше не срывает.
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
    // §400 — идентичность узла от его тега, поэтому REPLACE-патч её НЕ
    // меняет: правило может переписать server/uuid, отметка остаётся на том
    // же ключе. Карта считается один раз на весь список.
    final identities = sourceNodeIdentities(nodes);
    result.outcomes.forEach((i, outcome) {
      if (i < 0 || i >= nodes.length) return;
      final node = nodes[i];
      if (outcome.patchedJson != null) {
        node.patchedJson = outcome.patchedJson;
        node.ruleTrail = outcome.replacements;
      }
      final identity = identities[node];
      if (identity == null) return; // группа/безымянный — отметок не имеет
      if (outcome.disabled == true) disable.add(identity);
      if (outcome.disabled == false) enable.add(identity);
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
    final spec =
        parseLinkViaPipeline(account.toMasqueUri(vhttp: vhttp)) as MasqueSpec?;
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
      rawSource: spec.rawSource,
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
      tlsExtra: spec.tlsExtra,
      warnings: spec.warnings,
    )..bodyDelta = spec.bodyDelta; // §560/§570 — поля тела вне модели
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
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
      rawSource: spec.rawSource,
      privateKey: spec.privateKey,
      localAddresses: spec.localAddresses,
      peers: spec.peers,
      mtu: spec.mtu,
      awg: spec.awg,
      warnings: spec.warnings,
    )..bodyDelta = spec.bodyDelta; // §560/§570 — поля тела вне модели
    // rawBody = toUri() (с тегом во фрагменте) → тег переживает reload/re-parse.
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
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
    final spec = parseLinkViaPipeline(account.toWireguardUri(
        includeReserved: includeReserved,
        persistentKeepalive: persistentKeepalive)) as WireguardSpec?;
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
      rawSource: spec.rawSource,
      privateKey: spec.privateKey,
      localAddresses: spec.localAddresses,
      peers: spec.peers,
      mtu: spec.mtu,
      awg: spec.awg,
      warnings: spec.warnings,
    )..bodyDelta = spec.bodyDelta; // §560/§570 — поля тела вне модели
    _entries.add(SubscriptionEntry(
      list: UserServer(
        id: newUuidV4(),
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
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

  /// §500 — отказ одиночного ввода: базовая фраза + причины в шторке.
  void _setParseInputReject(
    ErrKey key,
    String input, {
    RegistryWarning? verdict,
    List<NodeWarning>? dropped,
  }) {
    final all = <NodeWarning>[
      ?verdict,
      ...?dropped,
    ];
    final sorted = maskSecretDropWarnings(sortedDropWarnings(all));
    if (sorted.isEmpty) {
      _lastError = ErrMsg(key);
      return;
    }
    _lastError = ParseInputRejectedMsg(
      key,
      dropped: sorted,
      sourceLabel: inputSourceLabel(input),
    );
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
        final verdict = XrayDropVerdict();
        var spec = parseWireguardIni(trimmed,
            nameHint: nameHint, dropped: verdict);
        if (spec == null) {
          _setParseInputReject(ErrKey.invalidWireguardConfig, trimmed,
              verdict: verdict.reason);
          return;
        }
        // §090 G2b × §456 — в INI тега нет, эмодзи некуда дописать (как в
        // ссылку или JSON), поэтому оно ставится прямо в тег узла. Тег —
        // поле записи, так что эмодзи переживает рестарт: при чтении узел
        // разбирается с ним как с nameHint.
        if (!hasEmoji(spec.tag)) {
          final emoji = defaultEmojiFor(spec);
          spec = WireguardSpec(
            id: spec.id,
            tag: '$emoji ${spec.tag}',
            // label — то же имя, что и tag (оба из имени узла); список
            // серверов показывает label, поэтому эмодзи нужно и здесь.
            label: spec.label.isEmpty ? '' : '$emoji ${spec.label}',
            server: spec.server,
            port: spec.port,
            rawSource: spec.rawSource,
            privateKey: spec.privateKey,
            localAddresses: spec.localAddresses,
            peers: spec.peers,
            mtu: spec.mtu,
            awg: spec.awg,
            warnings: spec.warnings,
          )..bodyDelta = spec.bodyDelta; // §560 — поля тела вне модели
        }
        final wgServer = UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
          rawBody: spec.rawSource,
          nodes: [spec],
        );
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
          rawBody: trimmed,
          nodes: nodes,
        ));
        _entries.add(SubscriptionEntry(
            list: vpnServer, nodeCount: vpnServer.nodes.length));
        await _persist();
      } else if (isDirectLink(trimmed)) {
        final verdict = XrayDropVerdict();
        final spec = parseUri(trimmed, dropped: verdict);
        if (spec == null) {
          _setParseInputReject(ErrKey.couldNotParseDirectLink, trimmed,
              verdict: verdict.reason);
          return;
        }
        final dlServer = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
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
  /// Гейт один — `decode` и ветка, которой опознан документ; своей эвристики
  /// («начинается с `{` и содержит `"type"`») здесь больше нет: она была
  /// третьей по счёту и разошлась с превью (§368 §1).
  ///
  /// Одна запись, а не N: раньше массив outbound'ов раскладывался по одной
  /// записи на элемент («v1 behavior parity»). Вставленный файл — один
  /// источник, и обновляться он должен целиком.
  Future<_JsonAdd> _addJsonNodes(String text,
      {UserSource origin = UserSource.paste}) async {
    final decoded = decode(text);
    // §480 Д-4 — список ссылок, завёрнутый в base64 целиком. Декодер такое
    // тело разворачивает и отдаёт `UriLines` (ветка `base64_wrapped`
    // реестра), но сюда приходит только JSON, и вставка отвечала «не
    // распознано» — при том, что ТОТ ЖЕ текст без base64 проходил, а
    // подписка с таким телом по ссылке читается штатно.
    //
    // Гейт — `wrapped`, а не «похоже на base64»: голый список ссылок
    // приезжает тем же `UriLines`, и его разбирают ветки выше (`isDirectLink`
    // для одной ссылки); перехватывать его здесь значило бы заводить
    // второй путь для уже работающего входа.
    if (decoded is UriLines && !_looksLikeUriList(text)) {
      return _addUriLines(decoded, text, origin: origin);
    }
    if (decoded is! JsonConfig) return _JsonAdd.notJson;
    // §483 — «форма даёт узлы» спрашивается у самой ветки: вид без маппера
    // (Clash, нераспознанный JSON) элементов не имеет по определению.
    // Перечислять виды здесь незачем — список разъезжался бы с реестром
    // молча, а новый вид источника получал бы «не распознано».
    if (decoded.source.mapper == null) return _JsonAdd.notJson;

    final dropped = <NodeWarning>[];
    final nodes = parseAll(decoded, dropped: dropped);
    if (nodes.isEmpty) {
      _setParseInputReject(ErrKey.noValidOutboundsInJson, text,
          dropped: dropped);
      return _JsonAdd.empty;
    }

    // §437 — узлы Tailscale из многоузловой вставки выделяются в свои
    // `UserServer`: связка (маршрут в tailnet + DNS-сервер узла) есть только у
    // свободных узлов, а внутри подписки она бы пропала — устройство видно в
    // консоли tailnet, а связи с пирами нет. Остаток уезжает прежним путём
    // ТЕКСТОМ без tailscale-записей: у файловой подписки тело лежит в кэше и
    // перечитывается на старте, и узел вернулся бы дублем.
    if (nodes.length > 1 && nodes.any((n) => n is TailscaleSpec)) {
      final rest = textWithoutTailscale(decoded);
      var added = false;
      for (final n in nodes.whereType<TailscaleSpec>()) {
        final srv = _autoEmoji(UserServer(
          id: newUuidV4(),
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: origin,
          rawBody: n.toUri(),
          sections: sectionsForNewNode(n),
          nodes: [n],
        ));
        _entries.add(SubscriptionEntry(list: srv, nodeCount: 1));
        added = true;
      }
      if (rest != null) {
        final tail = await _addJsonNodes(rest, origin: origin);
        // Остаток из одних групп — не ошибка вставки: узлы Tailscale уже
        // добавлены, а сообщение «нет пригодных outbound'ов» соврало бы.
        if (tail == _JsonAdd.empty && added) _lastError = null;
      }
      if (added) return _JsonAdd.added;
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
        dropped: summaryDropped(dropped),
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
      rawBody: text,
      // §435 — связка из целого конфига с одним узлом / документа с
      // `sections` (NODE_SECTIONS.md §6): хозяин секций — контейнер. §437 —
      // узел Tailscale без извлечённых записей получает каноническую связку.
      sections: sectionsForNewNode(nodes.first),
      nodes: nodes,
    ));
    _entries.add(SubscriptionEntry(
        list: jsonServer, nodeCount: jsonServer.nodes.length));
    return _JsonAdd.added;
  }

  /// §480 Д-4 — ввод УЖЕ является списком ссылок, оболочку снимать не с чего.
  ///
  /// Спрашивается исходный текст, а не форма ответа: `UriLines` приходит и от
  /// голого списка, и от завёрнутого в base64, а различать их нужно — голый
  /// список разбирают ветки выше.
  static bool _looksLikeUriList(String text) => text.contains('://');

  /// §480 Д-4 — список ссылок из снятой оболочки → запись.
  ///
  /// Контейнер выбирается тем же порогом, что и у JSON (§368/§129): один
  /// узел — сервер, несколько — файловая подписка. В кэш кладётся ИСХОДНЫЙ
  /// текст (завёрнутый): тело подписки перечитывается на старте тем же
  /// `decode`, и он развернёт оболочку заново.
  Future<_JsonAdd> _addUriLines(UriLines decoded, String text,
      {UserSource origin = UserSource.paste}) async {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decoded, dropped: dropped);
    if (nodes.isEmpty) {
      _setParseInputReject(ErrKey.noValidOutboundsInJson, text,
          dropped: dropped);
      return _JsonAdd.empty;
    }

    if (nodes.length > 1) {
      final url = 'file:${newUuidV4()}';
      await HttpCache.save(url, text, const {});
      _entries.add(SubscriptionEntry(
        list: SubscriptionServers(
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
          dropped: summaryDropped(dropped),
          nodes: nodes,
        ),
        nodeCount: nodes.length,
      ));
      return _JsonAdd.added;
    }

    final srv = _autoEmoji(UserServer(
      id: newUuidV4(),
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: origin,
      rawBody: text,
      sections: sectionsForNewNode(nodes.first),
      nodes: nodes,
    ));
    _entries.add(SubscriptionEntry(list: srv, nodeCount: srv.nodes.length));
    return _JsonAdd.added;
  }

  /// §439 (D-114) — уведомления о ссылках, погашенных удалением узла или
  /// источника: кого удалили и какие detour'ы и позиции цепочек задело.
  ///
  /// Читаются экраном после мутации и показываются snackbar'ом — тем же
  /// механизмом, что rules/detours/includes-heal (§202/§248). Молчать нельзя:
  /// снятый detour меняет маршрут узла, цепочка 3+ хопов после вычистки
  /// эмитится УКОРОЧЕННЫМ маршрутом.
  final List<NodeLinkNotice> _linkNotices = [];

  /// Забрать накопленные уведомления (экран показывает, контроллер копит: у
  /// контроллера нет `BuildContext`).
  List<NodeLinkNotice> takeLinkNotices() {
    if (_linkNotices.isEmpty) return const [];
    final out = List<NodeLinkNotice>.of(_linkNotices);
    _linkNotices.clear();
    return out;
  }

  /// Реестр ссылок переписал цепочки хранения: экраны с буфером цепочек
  /// перечитывают их ([takeChainsRelinked]).
  bool _chainsRelinked = false;

  /// Забрать флаг «цепочки переписаны реестром ссылок».
  bool takeChainsRelinked() {
    final v = _chainsRelinked;
    _chainsRelinked = false;
    return v;
  }

  List<ServerList> _lists() => [for (final e in _entries) e.list];

  /// §439 — реестр ссылок (D-113, D-114) после мутации `_entries`: адреса
  /// узлов [before] → текущие. Удалённые гаснут (и все пары на контейнеры
  /// [goneContainers]), перенесённые и переименованные переписываются — в
  /// источниках (`_entries`) и в цепочках хранения. Зовётся ДО `_persist()`:
  /// источники ложатся на диск уже с переписанными ссылками.
  ///
  /// [renamed] — узел, заменивший прежний (правка тела). [subject] — что
  /// удалено, для уведомления; без него погашенное только логируется.
  Future<NodeLinkChange?> _relink(
    List<ServerList> before, {
    Map<NodeSpec, NodeSpec> renamed = const {},
    Set<String> goneContainers = const {},
    NodeLinkSubject? subject,
  }) async {
    final after = _lists();
    // §445 — записи каталогов состояния Tailscale идут за узлами. До раннего
    // выхода: перестановка тёзок меняет ключ записи, но не адрес узла.
    await _relinkTailscaleState(before, after, renamed);
    final diff = diffNodeAddresses(before, after, renamed: renamed);
    if (diff.moves.isEmpty && diff.gone.isEmpty && goneContainers.isEmpty) {
      return null;
    }
    final chains = await SettingsStorage.getChains();
    final r = relinkNodeLinks(
      after,
      chains,
      moves: diff.moves,
      gone: diff.gone,
      goneContainers: goneContainers,
    );
    for (var i = 0; i < _entries.length && i < r.lists.length; i++) {
      if (!identical(r.lists[i], after[i])) _entries[i]._replaceList(r.lists[i]);
    }
    if (r.cleared.chainsChanged || r.rewritten.chainsChanged) {
      await SettingsStorage.setChains(r.chains);
      _chainsRelinked = true;
    }
    final cleared = r.cleared;
    if (!cleared.isEmpty) {
      AppLog.I.info('Node links cleared: ${cleared.detourCarriers.length} '
          'detour(s), ${cleared.groupMembers} group member(s), '
          '${cleared.positions} chain position(s)');
      if (subject != null) {
        _linkNotices.add(NodeLinkNotice(subject: subject, change: cleared));
      }
    }
    if (!r.rewritten.isEmpty) {
      AppLog.I.info('Node links rewritten: '
          '${r.rewritten.detourCarriers.length} detour(s), '
          '${r.rewritten.groupMembers} group member(s), '
          '${r.rewritten.positions} chain position(s)');
    }
    return cleared;
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    final before = _lists();
    final gone = _entries.removeAt(index);
    final list = gone.list;
    // §439 (D-114) — ссылки на узлы удалённого источника гаснут: detour
    // снимается, позиция уходит из цепочки (цепочка остаётся, §393 D2).
    await _relink(
      before,
      goneContainers: {if (list is! UserServer) list.id},
      subject: NodeLinkSubject.of(list, name: gone.displayName),
    );
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
      dropped: summaryDropped(result.dropped),
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
        dropped: summaryDropped(result.dropped),
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

  /// §456 — имя члена папки, хранимое полем записи: у INI-источника тег в
  /// тексте не лежит, у ссылки и JSON — лежит (пусто).
  static String memberNameHintFor(NodeSpec n) =>
      originKindOf(n.rawSource) == 'wg_ini' ? n.tag : '';

  /// §439 — члены-группы разобранного входа (sing-box-конфиг с
  /// `urltest`/`selector`) → члены `kind: auto` папки [folderId]. [added]
  /// выровнен с [nodes] 1:1. Ссылка группы на сырой тег члена входа
  /// (`sourceNodeRawTags`) становится парой `{id папки, тег узла члена}`;
  /// член, не ставший узлом папки, из состава уходит.
  static List<FolderMember> _bindAutoMembers(
    List<FolderMember> added,
    List<NodeSpec> nodes,
    String folderId,
  ) {
    if (nodes.length != added.length || !nodes.any((n) => n.isGroup)) {
      return added;
    }
    final rawTags = sourceNodeRawTags(nodes);
    final memberTag = <String, String>{};
    for (var i = 0; i < nodes.length; i++) {
      final raw = rawTags[nodes[i]];
      final tag = added[i].node?.tag ?? '';
      if (!nodes[i].isGroup && raw != null && tag.isNotEmpty) {
        memberTag[raw] = tag;
      }
    }
    return [
      for (var i = 0; i < added.length; i++)
        switch (nodes[i]) {
          final AutoSelectSpec g => FolderMember.auto(
              g.copyWith(
                membership: switch (g.membership) {
                  ExplicitMembers(:final members) => ExplicitMembers([
                      for (final l in members)
                        if (memberTag[l.tag] case final t?)
                          NodeLink(folderId: folderId, tag: t),
                    ]),
                  final RuleMembers m => m,
                },
              ),
              enabled: added[i].enabled,
            ),
          _ => added[i],
        },
    ];
  }

  /// §439 — член-группа, перенесённая в папку [toId]: её явный состав
  /// адресовал узлы папки [fromId], а группа не выходит за свой контейнер.
  /// Пары переезжают на новую папку с теми же тегами — как до §439 ключи
  /// состава искались среди членов папки, куда группа легла.
  static FolderMember _rehomeAutoMember(
      FolderMember m, String fromId, String toId) {
    final g = m.node;
    if (g is! AutoSelectSpec) return m;
    final membership = g.membership;
    if (membership is! ExplicitMembers) return m;
    return FolderMember.auto(
      g.copyWith(
        membership: ExplicitMembers([
          for (final l in membership.members)
            l.isRoot || l.folderId == fromId
                ? NodeLink(folderId: toId, tag: l.tag)
                : l,
        ]),
      ),
      enabled: m.enabled,
    );
  }

  /// Есть ли у raw собственное имя (URI-фрагмент `#name` / JSON `tag`).
  static bool _rawHasOwnName(String raw) {
    final t = raw.trim();
    if (t.startsWith('{')) return t.contains('"tag"');
    return !t.contains('\n') && t.contains('://') && t.contains('#');
  }

  /// Проставить имя в raw-фрагмент: URI → `#fragment`, JSON → `tag`.
  /// Многострочные формы (INI) остаются как есть — caller передаёт `toUri()`.
  /// §455 — публичный: экран узла ставит тег ссылке при Save вкладки Source.
  static String rawWithName(String raw, String name) {
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
        // Узел тот же объект: реестр ссылок узнаёт в нём бывшего члена.
        origin: UserSource.manual,
        rawBody: m.raw,
        sections: m.sections, // §435
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
  /// место папки (порядок и per-member enabled сохраняются). Авто-узлы
  /// удаляются и при [keepServers]: текста у группы нет, одиночным сервером
  /// она стала бы пустой записью, а её пул — узлы этой папки.
  Future<void> deleteFolderAt(int index, {required bool keepServers}) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! FolderServers) return;
    final before = _lists();
    _entries.removeAt(index);
    if (keepServers) {
      _entries.insertAll(
        index,
        list.members.where((m) => m.node?.isGroup != true).map((m) {
          final us = _memberToUserServer(m);
          return SubscriptionEntry(list: us, nodeCount: us.nodes.length);
        }),
      );
    }
    // §439 — при `keepServers` члены остаются одиночными серверами: ссылки
    // на них переписываются с пары на корневой адрес (D-113). Без
    // keepServers уходит вся папка — ссылки на её членов гаснут (D-114).
    await _relink(
      before,
      goneContainers: {if (!keepServers) list.id},
      subject: NodeLinkSubject.of(list),
    );
    await _persist();
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
    // §506 — причины отбраковки записей: без них «серверов не найдено» не
    // отличалось от пустого ввода.
    final dropped = <NodeWarning>[];
    try {
      // §243 — INI-ноды получают имя файла прямо во фрагмент синтетического
      // URI (rawSource) — фолбэк-цикл ниже до них не дойдёт (_rawHasOwnName).
      nodes = parseAll(decode(input.trim()),
          nameHint: nameFallback, dropped: dropped);
    } catch (e) {
      return humanizeError(e);
    }
    if (nodes.isEmpty) {
      final sorted = maskSecretDropWarnings(sortedDropWarnings(dropped));
      if (sorted.isEmpty) return const ErrMsg(ErrKey.noServersFoundInInput);
      return ParseInputRejectedMsg(
        ErrKey.noServersFoundInInput,
        dropped: sorted,
        sourceLabel: inputSourceLabel(input),
      );
    }

    final usedNames = <String>{};
    final added = <FolderMember>[];
    for (final n in nodes) {
      // §456 — источник члена = источник узла как есть (§454); INI несёт имя
      // через `nameHint`, JSON — в теле. Фолбэк имени файла — только ссылке
      // без своего фрагмента. §439 — группе имя не раздаётся (`kind: auto`).
      var raw = n.rawSource;
      if (!n.isGroup &&
          nameFallback != null &&
          nameFallback.isNotEmpty &&
          originKindOf(raw) == 'uri' &&
          !_rawHasOwnName(raw)) {
        var candidate = nameFallback;
        var i = 2;
        while (!usedNames.add(candidate)) {
          candidate = '$nameFallback ${i++}';
        }
        raw = rawWithName(raw, candidate);
      }
      // §435 — секции из целого конфига / документа с `sections` едут в
      // члена папки вместе с телом; §437 — узел Tailscale без них получает
      // каноническую связку.
      added.add(FolderMember(
          raw: raw,
          nameHint: memberNameHintFor(n),
          sections: sectionsForNewNode(n)));
    }
    added.setAll(0, _bindAutoMembers(added, nodes, folder.id));
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
        // §506 — причины из `dropped[]` разбора доезжают и сюда.
        final sorted = maskSecretDropWarnings(sortedDropWarnings(result.dropped));
        if (sorted.isEmpty) return const ErrMsg(ErrKey.noServersFoundAtUrl);
        return ParseInputRejectedMsg(
          ErrKey.noServersFoundAtUrl,
          dropped: sorted,
          sourceLabel: inputSourceLabel(url),
        );
      }
      // Guard после await: entry могли удалить/подменить.
      final cur = entry.list;
      if (cur is! FolderServers || !_entries.contains(entry)) {
        return const ErrMsg(ErrKey.folderNotFound);
      }
      final added = _bindAutoMembers(
          result.nodes
              .map((n) => FolderMember(
                  raw: n.rawSource,
                  nameHint: memberNameHintFor(n),
                  sections: sectionsForNewNode(n)))
              .toList(),
          result.nodes,
          cur.id);
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

  /// §283 — вкл/выкл одной ноды подписки. Ключ — идентичность узла (§400:
  /// тег, уникализированный внутри источника, node_hash.dart): переживает
  /// refresh/рестарт и ротацию адреса под тем же именем; переименование ноды
  /// провайдером отметку теряет — имя и есть идентичность. Дубли одного
  /// сервера под РАЗНЫМИ именами — разные узлы, гасятся раздельно. При
  /// выключении lastSeen = now (старт TTL-отсчёта, GC — на успешном сетевом
  /// refresh в _fetchEntryByRef).
  Future<void> toggleSubscriptionNode(int index, NodeSpec node) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    // §400 — идентичность берём из карты источника: она зависит от соседей
    // (тёзки нумеруются `X`, `X-2`). Узла без идентичности выключить нельзя.
    final hash = sourceNodeIdentities(list.nodes)[node];
    if (hash == null) return;
    final next = Map<String, DateTime>.from(list.disabledHashes);
    final enabling = next.containsKey(hash);
    if (enabling) {
      next.remove(hash);
    } else {
      next[hash] = DateTime.now();
    }
    // Фича 478 / PARSING_PRINCIPLES §9.4 — человек включил узел обратно: вердикт ядра
    // стирается, следующий старт проверит узел заново. Выключение рукой
    // вердикта не ставит (его ставит только страховка).
    var nextList = list.copyWith(disabledHashes: next);
    if (enabling) {
      nextList = clearSubscriptionVerdict(nextList, hash);
      unstampCoreRejected(node);
    }
    entry._replaceList(nextList);
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
      // Фича 478 — «включить все» снимает и вердикты: узлы проверятся заново.
      entry._replaceList(list.copyWith(
          disabledHashes: const {}, nodeWarnings: const {}));
      await _persist();
      notifyListeners();
      return;
    } else {
      if (list.nodes.isEmpty) return;
      final now = DateTime.now();
      next = {
        ...list.disabledHashes,
        // Узлы без идентичности (группы §322, безымянные) отметки не
        // получают — их в карте попросту нет.
        for (final id in sourceNodeIdentities(list.nodes).values) id: now,
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
    // §400 — идентичности от ПОЛНОГО списка источника, а не от переданной
    // пачки: уникализация тёзок считается по соседям, и подмножество дало бы
    // другие номера.
    final identities = sourceNodeIdentities(list.nodes);
    final hashes = {for (final n in nodes) ?identities[n]};
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
    final on = !members[memberIndex].enabled;
    members[memberIndex] = members[memberIndex].copyWith(
      enabled: on,
      // Фича 478 — ручное включение снимает вердикт ядра.
      warnings: on ? dropVerdict(members[memberIndex].warnings) : null,
    );
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// Правка raw-фрагмента члена. Новый raw обязан парситься ≥1 ноды, иначе
  /// откат (возврат текста ошибки, старый член не трогается).
  /// §456 — [nameHint]: имя для INI-текста (поле Tag редактора).
  Future<UiMsg?> updateMemberAt(int index, int memberIndex, String newRaw,
      {String? nameHint}) async {
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
    final hint = nameHint ?? folder.members[memberIndex].nameHint;
    final probe = FolderMember(raw: trimmed, nameHint: hint);
    if (probe.node == null) {
      return const ErrMsg(ErrKey.memberParseKeepCurrent);
    }
    final before = _lists();
    final members = [...folder.members];
    // §435 — голое тело секции не трогает; документ с `sections` или с
    // `dns`/`route` (извлечение) замещает их целиком (NODE_SECTIONS.md §7).
    final imported = probe.node!.importedSections;
    final previous = members[memberIndex].node;
    members[memberIndex] = members[memberIndex].copyWith(
      raw: trimmed,
      nameHint: hint,
      sections: imported,
    );
    var current = members[memberIndex].node;
    // Фича 478 / PARSING_PRINCIPLES §9.4 п. 1 — человек правил тело в редакторе: вердикт
    // ядра привязан к ТЕЛУ, и на изменённом теле он недействителен. Запись
    // стирается И узел включается обратно — тем же составом полей, что у
    // ручного включения (`toggleMemberAt`). Тело то же (правка имени, пробелы)
    // → вердикт держится.
    if (verdictDroppedByEdit(
      warnings: members[memberIndex].warnings,
      before: previous,
      after: current,
    )) {
      members[memberIndex] = members[memberIndex].copyWith(
        enabled: true,
        warnings: dropVerdict(members[memberIndex].warnings),
      );
      current = members[memberIndex].node;
    }
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-113) — правка тела могла сменить тег: ссылки идут за узлом.
    await _relink(before, renamed: {
      if (previous != null && current != null) previous: current,
    });
    await _persist();
    notifyListeners();
    return null;
  }

  /// §439 — добавить в папку узел автовыбора (член `kind: auto`). Члены
  /// группы — ссылки на узлы этой же папки, их собирает редактор.
  Future<UiMsg?> addAutoMemberToFolder(int index, AutoSelectSpec group) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    entry._replaceList(folder.copyWith(
        members: [...folder.members, FolderMember.auto(group)]));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder "${folder.name}": +1 auto node');
    return null;
  }

  /// §439 — заменить группу члена-группы [memberIndex]; `enabled` члена
  /// остаётся.
  Future<UiMsg?> updateAutoMemberAt(
      int index, int memberIndex, AutoSelectSpec group) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final before = _lists();
    final members = [...folder.members];
    final previous = members[memberIndex].node;
    members[memberIndex] =
        FolderMember.auto(group, enabled: members[memberIndex].enabled);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-113) — переименование группы переписывает ссылки на неё.
    await _relink(before, renamed: {?previous: group});
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
    final before = _lists();
    final gone = folder.members[memberIndex];
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-114) — ссылки на удалённого члена гаснут; тёзка, чей сырой тег
    // сдвинулся (`X-2` → `X`), уносит свои ссылки с собой.
    await _relink(before, subject: NodeLinkSubject.member(folder, gone));
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
    final before = _lists();
    final members = [...folder.members];
    final m = members.removeAt(from);
    members.insert(to, m);
    entry._replaceList(folder.copyWith(members: members));
    // §439 — перестановка тёзок меняет их сырые теги (`X`/`X-2`).
    await _relink(before);
    await _persist();
    notifyListeners();
  }

  /// Вынести члена из папки в одиночный сервер (вставляется сразу после
  /// папки). Личные prefix/policy папки НЕ наследуются — дефолты. Авто-узел
  /// не выносится (no-op): см. [deleteFolderAt].
  Future<void> ungroupMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final member = folder.members[memberIndex];
    if (member.node?.isGroup == true) return;
    final before = _lists();
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    final us = _memberToUserServer(member);
    _entries.insert(
        index + 1, SubscriptionEntry(list: us, nodeCount: us.nodes.length));
    // §439 (D-113) — член стал корневым узлом: пара → корневой адрес.
    await _relink(before);
    await _persist();
    notifyListeners();
  }

  /// §237/§239 — личный detour члена: ссылка на узел (D-112) — сосед по
  /// папке парой с `id` этой папки, прочее — как выбрано в пикере. Отклоняет
  /// self и ребро, замыкающее интра-цикл. Возвращает null при успехе, иначе
  /// ошибку.
  Future<UiMsg?> setMemberDetour(
      int index, int memberIndex, NodeLink detour) async {
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
      final raw = <String, int>{};
      for (var k = 0; k < folder.members.length; k++) {
        final a = folderMemberAddress(folder, k);
        if (a != null) raw.putIfAbsent(a.tag, () => k);
      }
      int? intra(NodeLink l) => l.folderId == folder.id ? raw[l.tag] : null;
      final target = intra(detour);
      if (target == memberIndex) {
        return const ErrMsg(ErrKey.detourSelf);
      }
      if (target != null) {
        int? edgeOf(int k) {
          if (k == memberIndex) return target; // новое ребро
          final j = intra(folder.members[k].detour);
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
    final before = _lists();
    final gone = [
      for (var i = 0; i < folder.members.length; i++)
        if (memberIndexes.contains(i)) folder.members[i],
    ];
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-114) — как одиночное удаление члена, только пачкой.
    await _relink(
      before,
      subject: gone.length == 1
          ? NodeLinkSubject.member(folder, gone.single)
          : NodeLinkSubject.servers(gone.length),
    );
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
    final before = _lists();
    entry._replaceList(folder.copyWith(
        members: [for (final i in order) folder.members[i]]));
    // §439 — перестановка тёзок меняет их сырые теги (`X`/`X-2`).
    await _relink(before);
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
    final before = _lists();
    final moved = from.members[memberIndex];
    final member = _rehomeAutoMember(moved, from.id, to.id);
    final fromMembers = [...from.members]..removeAt(memberIndex);
    fromEntry._replaceList(from.copyWith(members: fromMembers));
    fromEntry.nodeCount = fromEntry.list.nodes.length;
    toEntry._replaceList(to.copyWith(members: [...to.members, member]));
    toEntry.nodeCount = toEntry.list.nodes.length;
    // §439 (D-113) — перенос: `folder_id` меняется, ссылки идут за узлом
    // (группа пересоздаётся с составом на новую папку — узел сопоставляется
    // явно).
    await _relink(before, renamed: {
      if (moved.node != null && member.node != null && moved.node != member.node)
        moved.node!: member.node!,
    });
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

    final before = _lists();
    // §237 — личный detour одиночного (overrideDetour) переезжает в члена;
    // прочая политика (register-флаги и т.п.) заменяется папочной.
    final personalDetour = server.detourPolicy.useDetourServers
        ? server.detourPolicy.overrideDetour
        : NodeLink.none;
    final added = server.nodes.isEmpty
        // Битый/пустой raw — переносим как есть (член будет виден и правим).
        ? [
            FolderMember(
                raw: server.rawBody,
                enabled: server.enabled,
                detour: personalDetour),
          ]
        : _bindAutoMembers([
            for (final n in server.nodes)
              FolderMember(
                  raw: n.rawSource,
                  nameHint: memberNameHintFor(n),
                  enabled: server.enabled,
                  detour: personalDetour,
                  // §435 — секции одиночного едут с его (единственным) узлом.
                  sections: identical(n, server.nodes.first)
                      ? server.sections
                      : null),
          ], server.nodes, folder.id);
    folderEntry._replaceList(
        folder.copyWith(members: [...folder.members, ...added]));
    folderEntry.nodeCount = folderEntry.list.nodes.length;
    _entries.remove(serverEntry);
    // §439 (D-113) — узлы сервера стали членами папки: корневой адрес →
    // пара. Член разбирает свой текст заново, узел сопоставляется по месту.
    await _relink(before, renamed: {
      for (var k = 0; k < server.nodes.length && k < added.length; k++)
        server.nodes[k]: ?added[k].node,
    });
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
    final list = _entries[index].list;
    final enabling = !list.enabled;
    final ServerList next = switch (list) {
      UserServer u when enabling =>
        u.copyWith(enabled: true, warnings: dropVerdict(u.warnings)),
      _ => _toggleEnabled(list, enabling),
    };
    _entries[index]._replaceList(next);
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

  /// §524 — ВЕСЬ список источников в порядке `sources[]`: подписки, серверы,
  /// папки и цепочки одним рядом. Один упорядоченный список — единственный
  /// источник истины о порядке; до §524 порядок жил `List<String>` в state
  /// одного экрана, а контроллер держал только половину записей.
  ///
  /// Контейнеры берутся из [entries] (живой состав с fetch-состоянием),
  /// цепочки и нечитаемые записи — с диска: цепочка написана пользователем
  /// руками и переживает и обновление подписки, и её удаление.
  Future<List<SourceEntry>> sourceEntries() async {
    final disk = await SettingsStorage.getSourceEntries();
    final live = {for (final e in _entries) sourceKeyForIdOf(e.id): e.list};
    final seen = <String>{};
    final out = <SourceEntry>[];
    for (final e in disk) {
      final k = e.sourceKey;
      if (e is ContainerEntry) {
        final l = live[k];
        // Запись, которой в контроллере уже нет (удалена, но диск ещё не
        // перечитан), в список не попадает: состав задаёт контроллер.
        if (l == null) continue;
        out.add(ContainerEntry(l));
      } else {
        out.add(e);
      }
      seen.add(k);
    }
    // Записи контроллера, которых на диске ещё нет (только что добавленные и
    // не долетевший `_persist`) — в конец, как встают новые записи.
    for (final e in _entries) {
      if (seen.add(sourceKeyForIdOf(e.id))) out.add(ContainerEntry(e.list));
    }
    return out;
  }

  /// §524 — применить порядок общего списка ОДНОЙ записью на диск.
  ///
  /// [keys] — новый порядок ключей любого рода ([SourceEntry.sourceKey]):
  /// `id:<uuid>` у контейнера, `chain:<tag>` у цепочки. До §524 экран делал
  /// на один drag ДВЕ независимо падающие записи (`reorderSources` +
  /// `applyEntryOrder`); здесь запись одна, и `_entries` синхронизируется с
  /// ней в памяти, без второго `_persist`.
  ///
  /// `false` — перестановка отвергнута (состав не совпал), порядок не тронут;
  /// причина в AppLog (§511 m4: раньше отказ был тихим).
  Future<bool> applySourceOrder(List<String> keys) async {
    if (stale) return false; // §515 — чужая сцена, писать нечего
    final ok = await SettingsStorage.reorderSources(keys);
    if (!ok) return false;
    final rank = <String, int>{
      for (var i = 0; i < keys.length; i++) keys[i]: i,
    };
    // Взаимный порядок контейнеров зеркалим в `_entries`: без этого
    // следующий `_persist()` (toggle, rename, авто-refresh) вернул бы на диск
    // прежний порядок контейнеров.
    _entries.sort((a, b) =>
        (rank[sourceKeyForIdOf(a.id)] ?? rank.length)
            .compareTo(rank[sourceKeyForIdOf(b.id)] ?? rank.length));
    configDirty = true;
    notifyListeners();
    return true;
  }

  /// §509/§524 — взаимный порядок контейнеров. Состав [ids] обязан совпасть с
  /// текущими записями; места цепочек и нечитаемых записей не двигаются.
  ///
  /// Перестановка ОБЩЕГО списка (drag на Servers) идёт через
  /// [applySourceOrder]: одна запись на жест вместо двух.
  ///
  /// `false` — состав не совпал, порядок не тронут; причина в AppLog
  /// (§511 m4: раньше отказ был тихим).
  Future<bool> applyEntryOrder(List<String> ids) async {
    final byId = {for (final e in _entries) e.id: e};
    if (ids.length != _entries.length || ids.toSet() != byId.keys.toSet()) {
      AppLog.I.warning('applyEntryOrder rejected: '
          'ids=${ids.length}, entries=${_entries.length}');
      return false;
    }
    _entries
      ..clear()
      ..addAll([for (final id in ids) byId[id]!]);
    await _persist();
    notifyListeners();
    return true;
  }

  /// Замена `entry.list` на новый ServerList (для экранов, меняющих политику
  /// или tagPrefix). Сам ServerList immutable; вызывающий строит новый через
  /// `copyWith` на subscription/user-обёртке.
  /// §565 / задача 570 — запомнить выбранного члена группы ручного рода
  /// (`selector`). [groupTag] и [memberTag] — ФИНАЛЬНЫЕ теги собранного
  /// конфига; узлы ищутся обратной картой последней сборки. Группа папки —
  /// её `manualDefault` (как в редакторе группы); группа подписки —
  /// [SubscriptionServers.groupDefaults] рядом с записью источника.
  ///
  /// [live] — ядро уже переключено вживую (`selectOutbound`): конфиг на диске
  /// тогда не помечается устаревшим (плашка и автоперезапуск были бы
  /// шумом), но следующий старт VPN его пересоберёт
  /// ([groupDefaultsPending]). Без туннеля — обычная правка: конфиг
  /// устарел. `false` — группа не своя (Направление, свёртка) или член не
  /// из неё: выбор живёт только в ядре.
  Future<bool> rememberGroupMember(String groupTag, String memberTag,
      {required bool live}) async {
    final group = _lastTagMap[groupTag];
    final member = _lastTagMap[memberTag];
    if (group is! AutoSelectSpec || !group.isManual || member == null) {
      return false;
    }
    for (final e in _entries) {
      final list = e.list;
      ServerList? next;
      switch (list) {
        case SubscriptionServers():
          if (!list.nodes.contains(group) || !list.nodes.contains(member)) {
            continue;
          }
          if (list.groupDefaults[group.tag] == member.tag) return true;
          next = list.copyWith(
              groupDefaults: {...list.groupDefaults, group.tag: member.tag});
        case FolderServers():
          final i = list.members.indexWhere((m) => m.node == group);
          if (i < 0) continue;
          final raw = list.members.firstWhere((m) => m.node == member,
              orElse: () => FolderMember(raw: ''));
          if (raw.node == null) return false;
          final m = list.members[i];
          final members = [...list.members];
          final chosen = group.copyWith(manualDefault: raw.node!.tag);
          members[i] = FolderMember.auto(chosen,
              enabled: m.enabled, warnings: m.warnings);
          next = list.copyWith(members: members);
          // Узел группы сменился (равенство включает `manualDefault`):
          // карта сборки ведёт к новому, иначе следующий выбор до
          // пересборки его не нашёл бы.
          _lastTagMap = {..._lastTagMap, groupTag: chosen};
        case UserServer():
          continue;
      }
      e._replaceList(next);
      if (live) {
        _groupDefaultsPending = true;
        await _persist(keepDirtyFlag: true);
      } else {
        await _persist();
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Фича 478 / PARSING_PRINCIPLES §9.3 — выключить узел, названный ядром, и записать
  /// рядом вердикт. [tag] — ФИНАЛЬНЫЙ тег собранного конфига; узел ищется
  /// обратной картой последней сборки ([lastEmittedTagMap]), которую выдала
  /// та же сборка. Производные записи (хоп цепочки, узел папки, префикс
  /// подписки, WARP) ведут к своему ИСХОДНОМУ узлу.
  ///
  /// `false` — тегу не нашлось узла (служебная запись приложения) либо
  /// выключить его нечем: автоматики нет, цикл страховки прерывается.
  Future<CoreRejectNodeRef?> disableNodeByCoreTag(String tag, String reason) async {
    final node = _lastTagMap[tag];
    if (node == null) return null;
    for (var i = 0; i < _entries.length; i++) {
      final list = _entries[i].list;
      final ref = nodeRefFor(list, node);
      final applied = applyVerdict(list, node, reason);
      if (!applied.changed) continue;
      _entries[i]._replaceList(applied.list);
      _entries[i].nodeCount = _entries[i].list.nodes.length;
      // Список узлов и вкладка Notifications читают `NodeSpec.warnings`;
      // без штампа вердикт жил бы только в хранилище до следующего разбора.
      stampNodeWarnings(
          node, [StoredWarning.coreRejected(reason, ref: ref)]);
      await _persist();
      notifyListeners();
      return ref;
    }
    return null;
  }

  /// §503 — узел из листа страховки по идентичности вердикта, не по карте
  /// текущей сборки (выключенный узел из сборки исключён).
  CoreRejectNavigationTarget? resolveCoreRejectNavigation(DisabledNode disabled) =>
      resolveCoreRejectNode(
        [
          for (var i = 0; i < _entries.length; i++)
            (i, _entries[i].id, _entries[i].list),
        ],
        disabled,
        emittedTagMap: _lastTagMap,
      );

  /// Фича 478 — все вердикты, стоящие сейчас: тег-идентичность → причина.
  /// Отдаёт их Debug API и плашка.
  List<({String source, String tag, String reason})> get coreRejectedNodes {
    final out = <({String source, String tag, String reason})>[];
    for (final e in _entries) {
      final list = e.list;
      // §494 — displayName: у одиночного сервера list.name пуст (§243).
      final source = e.displayName;
      switch (list) {
        case SubscriptionServers():
          for (final w in list.nodeWarnings.entries) {
            for (final v in w.value) {
              if (v.isCoreRejected) {
                out.add((source: source, tag: w.key, reason: v.reason));
              }
            }
          }
        case FolderServers():
          for (final m in list.members) {
            for (final v in m.warnings) {
              if (v.isCoreRejected) {
                out.add((
                  source: source,
                  tag: m.node?.tag ?? m.nameHint,
                  reason: v.reason
                ));
              }
            }
          }
        case UserServer():
          for (final v in list.warnings) {
            if (v.isCoreRejected) {
              out.add((
                source: source,
                tag: list.nodes.isEmpty ? source : list.nodes.first.tag,
                reason: v.reason
              ));
            }
          }
      }
    }
    return out;
  }

  /// Фича 478 — ручное включение узла ПО ТЕГУ (Debug API, плашка «Show»):
  /// вердикт стирается, узел проверится заново. `false` — узла нет.
  ///
  /// [tag] — финальный тег ядра (с префиксом подписки) либо сырой тег
  /// идентичности: сначала [lastEmittedTagMap], как у [disableNodeByCoreTag].
  Future<bool> enableNodeByCoreTag(String tag) async {
    final mapped = _lastTagMap[tag];
    if (mapped != null) {
      for (var i = 0; i < _entries.length; i++) {
        final applied = revertVerdict(_entries[i].list, mapped);
        if (!applied.changed) continue;
        _entries[i]._replaceList(applied.list);
        _entries[i].nodeCount = _entries[i].list.nodes.length;
        unstampCoreRejected(mapped);
        await _persist();
        notifyListeners();
        return true;
      }
    }
    for (var i = 0; i < _entries.length; i++) {
      final list = _entries[i].list;
      switch (list) {
        case SubscriptionServers():
          if (!list.nodeWarnings.containsKey(tag) &&
              !list.disabledHashes.containsKey(tag)) {
            continue;
          }
          final disabled = Map<String, DateTime>.from(list.disabledHashes)
            ..remove(tag);
          _entries[i]._replaceList(clearSubscriptionVerdict(
              list.copyWith(disabledHashes: disabled), tag));
        case FolderServers():
          final at = list.members.indexWhere(
              (m) => (m.node?.tag ?? m.nameHint) == tag);
          if (at < 0) continue;
          final members = [...list.members];
          members[at] = members[at]
              .copyWith(enabled: true, warnings: dropVerdict(members[at].warnings));
          _entries[i]._replaceList(list.copyWith(members: members));
        case UserServer():
          final own = list.nodes.isEmpty ? list.name : list.nodes.first.tag;
          if (own != tag) continue;
          _entries[i]._replaceList(
              list.copyWith(enabled: true, warnings: dropVerdict(list.warnings)));
      }
      _entries[i].nodeCount = _entries[i].list.nodes.length;
      await _persist();
      notifyListeners();
      return true;
    }
    return false;
  }

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

  /// §435 — native `Context.filesDir` для `state_directory` узлов Tailscale.
  /// Кэшируется только успешный ответ (в юнит-тестах канала нет → пусто).
  static String? _filesDirCache;

  /// §445 — корень каталогов состояния Tailscale для тестов (без native-канала).
  @visibleForTesting
  static set debugTailscaleStateRoot(String? root) => _filesDirCache = root;

  /// §445 — ответ «ядро остановлено» для тестов; `null` — native-статус.
  @visibleForTesting
  static Future<bool> Function()? debugCoreStopped;

  /// §445 — ядро остановлено: native-статус `Stopped`. Ошибка канала —
  /// считается поднятым: каталоги состояния не удаляются.
  static Future<bool> _coreStopped() async {
    final override = debugCoreStopped;
    if (override != null) return override();
    try {
      final status = await BoxVpnClient().getVpnStatus();
      return status == TunnelStatus.disconnected ||
          status == TunnelStatus.revoked;
    } catch (_) {
      return false;
    }
  }

  /// §445 — индекс каталогов состояния Tailscale перед сборкой: имена
  /// каталогов узлов слота `current`, миграция, сироты. `null` — корня нет
  /// или индекс недоступен (имя по финальному тегу).
  Future<Map<NodeSpec, String>?> _prepareTailscaleState(
      String root, List<ServerList> lists) async {
    if (root.isEmpty) return null;
    try {
      final m = await WorkspaceStore.I.readManifest();
      return await TailscaleStateStore.I.prepareForBuild(
        root: root,
        slot: m.current,
        slotNames: m.names,
        lists: lists,
        coreStopped: _coreStopped,
      );
    } catch (e) {
      AppLog.I.warning('Tailscale state index unavailable: $e');
      return null;
    }
  }

  /// §445 — операция реестра над записями каталогов состояния Tailscale
  /// (переименование, перенос, удаление узла или источника).
  Future<void> _relinkTailscaleState(
    List<ServerList> before,
    List<ServerList> after,
    Map<NodeSpec, NodeSpec> renamed,
  ) async {
    if (!hasTailscaleNodes(before) && !hasTailscaleNodes(after)) return;
    final root = await _tailscaleStateRoot();
    if (root.isEmpty) return;
    try {
      final m = await WorkspaceStore.I.readManifest();
      await TailscaleStateStore.I.relink(
        root: root,
        slot: m.current,
        slotNames: m.names,
        before: before,
        after: after,
        renamed: renamed,
        coreStopped: _coreStopped,
      );
    } catch (e) {
      AppLog.I.warning('Tailscale state relink failed: $e');
    }
  }
  Future<String> _tailscaleStateRoot() async {
    final cached = _filesDirCache;
    if (cached != null) return cached;
    try {
      final native = await BoxVpnClient().getFilesDir();
      if (native != null && native.isNotEmpty) {
        _filesDirCache = native;
        return native;
      }
    } catch (_) {
      // Канал недоступен (тесты, ранний старт) — без корня.
    }
    return '';
  }

  /// §435 — секции одиночного узла (контракт ## 13): экран Routing пишет
  /// `enabled`/`num` записи, редактор узла — весь набор или очистку.
  /// `null` = снять поле.
  Future<void> setUserServerSections(int index, NodeSections? sections) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! UserServer) return;
    _entries[index]._replaceList(sections == null || sections.isEmpty
        ? list.copyWith(clearSections: true)
        : list.copyWith(sections: sections));
    await _persist();
    notifyListeners();
  }

  /// §435 — секции члена папки, симметрично [setUserServerSections].
  Future<UiMsg?> setMemberSections(
      int index, int memberIndex, NodeSections? sections) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final members = [...folder.members];
    members[memberIndex] = sections == null || sections.isEmpty
        ? members[memberIndex].copyWith(clearSections: true)
        : members[memberIndex].copyWith(sections: sections);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    return null;
  }

  Future<String> _generate() async {
    AppLog.I.info('Generating config...');
    _progressMessage = const SubStatusBuildingConfig();
    notifyListeners();

    // §565 / задача 570 — выбор члена групп ручного рода подписки
    // (`groupDefaults`) накладывается на копии узлов только для сборки.
    // Обратная карта сборки ниже возвращается к узлам-оригиналам: по ней
    // экраны и страховка ищут узел в `_entries` равенством.
    final originals = Map<NodeSpec, NodeSpec>.identity();
    final lists = <ServerList>[];
    for (final e in _entries) {
      final l = e.list;
      if (l is SubscriptionServers && l.groupDefaults.isNotEmpty) {
        final applied = l.withGroupDefaultsApplied();
        for (var k = 0; k < l.nodes.length; k++) {
          originals[applied.nodes[k]] = l.nodes[k];
        }
        lists.add(applied);
      } else {
        lists.add(l);
      }
    }
    // §435 — корень `state_directory` узлов Tailscale: native filesDir
    // (кэш на процесс, как у §316; без канала — пусто, поле не пишется).
    final tailscaleStateRoot = await _tailscaleStateRoot();

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
      wgBuildMax: await SettingsStorage.getWgBuildMax(), // §542
      wgLazyBuild: await SettingsStorage.getWgLazyBuild(), // §542
      passiveCheck: await SettingsStorage.getPassiveCheck(), // §272
      tailscaleStateRoot: tailscaleStateRoot,
      // §445 — имена каталогов из индекса (стабильны при переименовании).
      tailscaleStateDirs:
          await _prepareTailscaleState(tailscaleStateRoot, lists),
    );

    final result = await buildConfig(lists: lists, settings: settings);
    _lastTagMap = originals.isEmpty
        ? result.nodeByEmittedTag
        : {
            for (final e in result.nodeByEmittedTag.entries)
              e.key: originals[e.value] ?? e.value,
          };
    _groupDefaultsPending = false;
    _lastBuildWarningsByTag = result.nodeBuildWarningsByEmittedTag;

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
    _templateWarnings = result.templateWarnings;
    if (_templateWarnings.isNotEmpty) {
      _templateWarningsStamp++;
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
      // §515 — сетевые секунды это окно, в котором пользователь успевает
      // переключить пространство. Выходим до разбора результата: писать в
      // чужую сцену нечего (барьер в `_persist` поймал бы и так, но тогда
      // entry и статусы старого контроллера уехали бы в лог как «обновлено»).
      if (stale) {
        AppLog.I.warning(
            'workspaces: fetch result dropped — workspace switched: $shortUrl');
        return false;
      }
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

      // §400 (IDENTITY.md §5.1) — миграция legacy-ключей: отметки, записанные
      // до перехода на тег, опознаются по форме 64-hex и переезжают на
      // идентичность узла с тем же содержимым. Гоняем по ПОЛНОМУ свежему
      // списку (до GC и до фильтра выключенных: legacy-ключ опознаётся именно
      // по выключенному узлу) и ДО GC — иначе GC снёс бы ещё не переехавший
      // ключ как «не встреченный в теле».
      final migrated =
          migrateLegacyDisabledKeys(current.disabledHashes, result.nodes);

      // §283 — GC отметок disable ТОЛЬКО здесь (успешный сетевой fetch =
      // единственный сигнал «нода ушла из подписки»; failed fetch и
      // регидрация из кэша состав не проясняют, file:-подписки сюда не
      // доходят — guard выше). Хеш свежих нод считаем лишь когда есть что
      // чистить.
      final freshIdentities = sourceNodeIdentities(result.nodes).values.toSet();
      final baseDisabled = migrated.isEmpty && ruleMarks.disable.isEmpty
          ? migrated
          : gcDisabledHashes(
              migrated,
              freshIdentities,
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
      // Фича 478 / PARSING_PRINCIPLES §9.4 — вердикт привязан к ТЕЛУ узла: здесь старое и
      // новое тела доступны одновременно. Тело то же → вердикт держится;
      // тело изменилось ИЛИ старого тела нет (кэш пуст) → вердикт снимается
      // И узел включается обратно. Обновление ядра вердикты НЕ сбрасывает.
      final gcWarnings = gcNodeWarnings(
        current.nodeWarnings,
        nextDisabled,
        freshIdentities,
      );
      final verdicts = refreshSubscriptionVerdicts(
        disabled: nextDisabled,
        warnings: gcWarnings,
        oldBodies: bodiesByIdentity(current.nodes),
        newBodies: bodiesByIdentity(result.nodes),
      );
      // Фича 478 — уцелевшие вердикты дописываем на свежеразобранные узлы.
      stampStoredVerdicts(result.nodes, verdicts.warnings);

      final next = current.copyWith(
        name: nextName,
        meta: result.meta,
        lastUpdated: DateTime.now(),
        lastUpdateAttempt: attemptAt,
        lastUpdateStatus: UpdateStatus.ok,
        lastNodeCount: result.nodes.length,
        consecutiveFails: 0,
        updateIntervalHours: nextInterval,
        disabledHashes: verdicts.disabled,
        nodeWarnings: verdicts.warnings,
        dropped: summaryDropped(result.dropped),
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
          _compositionKey(result.nodes, verdicts.disabled.keys);
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

  /// §439 (D-113) — префикс одиночного сервера — часть его корневого адреса
  /// (`{tag: префикс + тег}`): смена [oldPrefix] на текущий переписывает
  /// ссылки на его узлы. У папки и подписки префикс адрес не меняет
  /// (NODE_LINK §6 п. 2) — no-op.
  Future<void> relinkServerTagPrefix(
      SubscriptionEntry entry, String oldPrefix) async {
    final list = entry.list;
    if (list is! UserServer || list.tagPrefix == oldPrefix) return;
    final index = _entries.indexOf(entry);
    if (index < 0) return;
    final before = _lists();
    before[index] = list.copyWith(tagPrefix: oldPrefix);
    if (await _relink(before) == null) return;
    await _persist();
    notifyListeners();
  }

  /// Обновляет inline-узлы `UserServer` из нового списка URI/JSON строк.
  /// §456 — [nameHint]: имя для INI-текста (тег из поля Tag редактора);
  /// ссылка и JSON несут имя сами, им hint не нужен.
  Future<void> updateConnectionAt(int index, List<String> connections,
      {String? nameHint}) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! UserServer) return;

    final nodes = <NodeSpec>[];
    for (final c in connections) {
      final decoded = decode(c);
      nodes.addAll(parseAll(decoded, nameHint: nameHint));
    }
    final before = _lists();
    // Фича 478 / PARSING_PRINCIPLES §9.4 п. 1 — человек правил тело ручного сервера:
    // вердикт ядра привязан к ТЕЛУ и на изменённом теле недействителен.
    // Запись стирается И узел включается обратно — тем же составом полей,
    // что у ручного включения (`enableNodeByCoreTag`). У `UserServer` узел
    // один, сравниваем первый: остальные — секции того же документа.
    final dropVerdictByEdit = verdictDroppedByEdit(
      warnings: list.warnings,
      before: list.nodes.isEmpty ? null : list.nodes.first,
      after: nodes.isEmpty ? null : nodes.first,
    );
    final next = list.copyWith(
      // §243 — displayName у UserServer name игнорирует (legacy v2.11.0 мог
      // записать туда имя файла); при пересохранении затираем совсем.
      name: '',
      rawBody: connections.join('\n'),
      nodes: nodes,
      enabled: dropVerdictByEdit ? true : null,
      warnings: dropVerdictByEdit ? dropVerdict(list.warnings) : null,
      // §435 — голое тело секции не трогает; документ с `sections` или с
      // `dns`/`route` замещает их целиком (NODE_SECTIONS.md §7).
      sections: nodes.isEmpty ? null : nodes.first.importedSections,
    );
    _entries[index]._replaceList(next);
    _entries[index].nodeCount = nodes.length;
    _entries[index].status = const SubStatusJsonOutbound();
    // §439 (D-113) — переименование корневого узла правкой тела переписывает
    // ссылки на него; узлы сопоставляются по месту в теле.
    await _relink(before, renamed: {
      for (var k = 0; k < list.nodes.length && k < nodes.length; k++)
        list.nodes[k]: nodes[k],
    });
    await _persist();
    notifyListeners();
  }

  /// §331 — отпечаток «состава» подписки: то и только то, от чего зависит
  /// собранный конфиг. Одинаковый отпечаток ⇒ пересборка дала бы тот же
  /// результат ⇒ поднимать `configDirty` не за что.
  ///
  /// Что входит:
  /// - контент-хеши узлов с тегом, **в порядке следования** — порядок значим:
  ///   от него зависят суффиксы `allocateTag` (`X` / `X-1`) и порядок внутри
  ///   пулов `urltest`/`selector`. Провайдер переставил узлы — это изменение;
  /// - набор disable-отметок (§283) — при том же списке узлов снятая или
  ///   поставленная отметка меняет, что билдер эмитит. Сортируем: порядок
  ///   ключей map'а сам по себе ничего не значит.
  ///
  /// Что НЕ входит и не должно: `last_updated`, `last_update_attempt`,
  /// `lastUpdateStatus`, `meta` (HTTP-заголовки, трафик, срок), `name`,
  /// `consecutiveFails`, `updateIntervalHours` — билдер их не читает.
  ///
  /// Хеши считаются от УЖЕ пропатченных §302-правилами узлов (метод зовётся
  /// после `_applyRulesToNodes`) — то есть от той формы, которую увидит
  /// билдер.
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
    // §400 — здесь нужен отпечаток СОДЕРЖИМОГО, а не идентичности: вопрос
    // «изменилось ли то, что уйдёт в конфиг». Идентичность-тег на смену
    // server/uuid под тем же именем не реагирует (в этом её смысл), поэтому
    // состав считаем контент-хешем — той же функцией, что до §400, плюс тег
    // отдельным полем (переименование узла билдер тоже эмитит иначе).
    final tags = lenPrefixed([
      for (final n in nodes) '${n.tag}\u0000${legacyNodeIdentityHash(n)}',
    ]);
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
      // §400 — тот же контент-отпечаток, что у §331: вопрос «изменилось ли
      // то, что уйдёт в конфиг», а не «тот ли это узел».
      final nodes = l.nodes.map(legacyNodeIdentityHash).join(',');
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
  ///
  /// §515 — первая строка: барьер поколения. Контроллер, переживший
  /// переключение пространства (или уже disposed'нутый), НЕ пишет: сцена на
  /// диске принадлежит другому слоту, а запись здесь заменяет весь набор
  /// контейнеров составом ЭТОГО контроллера. Один барьер в одной точке
  /// закрывает и летящий фетч, и `toggleAt`, и регидрацию кэша, и любую
  /// будущую мутацию. `configDirty` тоже не поднимаем — флаг глобальный, он
  /// заставил бы новый слот пересобирать конфиг из-за чужого хвоста.
  Future<void> _persist({bool keepDirtyFlag = false}) async {
    if (stale) {
      AppLog.I.warning('workspaces: persist skipped — controller from '
          'generation $_bornGeneration, current '
          '${WorkspaceController.I.generation}'
          '${_disposed ? ' (disposed)' : ''}');
      return;
    }
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

  /// §441 — ресинк `_entries` после storage-heal `body.detour` DNS-серверов
  /// секций узлов на выключенное или удалённое Направление [tag] (→ vpn-1),
  /// по той же причине, что [syncDetourDirectionRefsCleared]. Ядро общее —
  /// [retargetSectionsDnsDetours].
  void syncSectionsDnsDetourRefsHealed(String tag) {
    final retarget = directionRefRetarget(tag, 'vpn-1');
    var changed = false;
    for (final e in _entries) {
      final r = retargetSectionsDnsDetours(e.list, retarget);
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

/// §439 (D-114) — что удалено: подпись уведомления о погашенных ссылках.
final class NodeLinkSubject {
  const NodeLinkSubject._(this.kind, this.name, [this.count = 1]);

  /// Источник целиком: одиночный сервер, подписка или папка. [name] —
  /// подпись записи в списке (у подписки без имени — адрес).
  factory NodeLinkSubject.of(ServerList list, {String? name}) =>
      switch (list) {
        UserServer u => NodeLinkSubject._(
            NodeLinkSubjectKind.server,
            u.nodes.isNotEmpty
                ? containerFinalForm(u, u.nodes.first.tag)
                : (name ?? u.name),
          ),
        SubscriptionServers s => NodeLinkSubject._(
            NodeLinkSubjectKind.subscription, name ?? s.name),
        FolderServers f =>
          NodeLinkSubject._(NodeLinkSubjectKind.folder, f.name),
      };

  /// Член папки [folder].
  factory NodeLinkSubject.member(FolderServers folder, FolderMember m) =>
      NodeLinkSubject._(
        NodeLinkSubjectKind.server,
        m.node == null ? '' : containerFinalForm(folder, m.node!.tag),
      );

  /// Несколько серверов разом.
  factory NodeLinkSubject.servers(int count) =>
      NodeLinkSubject._(NodeLinkSubjectKind.servers, '', count);

  final NodeLinkSubjectKind kind;
  final String name;
  final int count;
}

enum NodeLinkSubjectKind { server, subscription, folder, servers }

/// §439 (D-114) — удаление погасило ссылки: кого удалили и кого задело.
final class NodeLinkNotice {
  const NodeLinkNotice({required this.subject, required this.change});

  final NodeLinkSubject subject;
  final NodeLinkChange change;
}
