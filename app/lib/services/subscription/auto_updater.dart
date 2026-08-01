import 'dart:async';
import 'dart:math';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../app_log.dart';
import '../settings_storage.dart';

/// Триггеры, по которым зовётся `maybeUpdateAll`. Нужны только для
/// телеметрии/логов — логика решения «пора?» одинаковая.
enum UpdateTrigger {
  appStart,      // init app
  vpnConnected,  // +2 мин после VPN connected
  periodic,      // раз в час
  vpnStopped,    // сразу по VPN disconnected
  manual,        // юзер нажал ⟳ (force=true)
  resumed,       // §291 — app вернулся из фона (periodic мог спать в Doze)
}

/// Авто-обновление подписок по 6 триггерам (§027 спека):
/// appStart / vpnConnected / periodic / vpnStopped / manual / resumed.
///
/// §291 — `resumed`: `periodic` тикает только пока процесс жив; при свёрнутом
/// app с выключенным VPN Android со временем замораживает процесс и таймер
/// засыпает. Возврат из фона — бесплатный (по батарее) момент досмотреть, не
/// пора ли обновить. Не force: проходит `auto_update_subs` и весь
/// `shouldUpdatePure`-гейт. Полноценный background-fetch выгруженного app
/// (WorkManager) остаётся вне скопа.
///
/// Параметры фиксированы (в спеке документированы):
/// - `updateIntervalHours` берётся с каждой подписки (default 24, из
///   `profile-update-interval`).
/// - `minRetryInterval` = 15 мин — между повторами той же подписки.
/// - `maxFailsPerSession` = 5 — после 5 фейлов подряд подписка «парится»
///   до следующего app start.
/// - `perSubscriptionDelay` = 10 сек — между fetch'ами подписок внутри
///   одного прохода (чтобы не нагружать провайдеров).
class AutoUpdater {
  AutoUpdater(this._subController);
  final SubscriptionController _subController;

  /// §323 — реакция на успешное авто-обновление. Ставит `home_screen`
  /// (`bindOnUpdateReaction`), потому что AutoUpdater создаётся ДО
  /// `HomeController` и прямой ссылки на него иметь не может.
  ///
  /// `reload = true` → после пересборки дёрнуть in-place reload ядра.
  /// Контракт: реализация сама решает, поднят ли туннель, и сама молчит, если
  /// пересборка дала конфиг, идентичный работающему (гейт §323 в
  /// `saveParsedConfig`). Не задан (тесты, headless) — режимы деградируют до
  /// `none`: ноды обновлены, `configDirty` стоит, применится обычным путём.
  Future<void> Function({required bool reload})? _onUpdateReaction;

  void bindOnUpdateReaction(Future<void> Function({required bool reload}) fn) {
    _onUpdateReaction = fn;
  }

  static const Duration minRetryInterval = Duration(minutes: 15);
  static const int maxFailsPerSession = 5;
  static const Duration perSubscriptionDelay = Duration(seconds: 10);
  static const Duration postVpnConnectedDelay = Duration(minutes: 2);
  static const Duration periodicInterval = Duration(hours: 1);

  Timer? _periodicTimer;
  Timer? _postVpnTimer;
  bool _running = false;

  /// Счётчики фейлов только в памяти; сбрасываются при перезапуске app.
  final Map<String, int> _failCounts = {};

  /// Для dedup'а параллельных запусков одной и той же подписки.
  final Set<String> _inFlight = {};

  /// Вызвать один раз при init приложения (из `SubscriptionController.init`
  /// или `main.dart`). Запускает trigger #1 и взводит periodic-таймер.
  void start() {
    _periodicTimer ??= Timer.periodic(periodicInterval, (_) {
      unawaited(maybeUpdateAll(UpdateTrigger.periodic));
    });
    unawaited(maybeUpdateAll(UpdateTrigger.appStart));
  }

  /// Зовёт `HomeController` на transition → `connected`.
  /// Планирует попытку через 2 минуты (не сразу — даёт туннелю устояться).
  void onVpnConnected() {
    _postVpnTimer?.cancel();
    _postVpnTimer = Timer(postVpnConnectedDelay, () {
      unawaited(maybeUpdateAll(UpdateTrigger.vpnConnected));
    });
  }

  /// Зовёт `HomeController` на transition → `disconnected`.
  void onVpnStopped() {
    _postVpnTimer?.cancel();
    unawaited(maybeUpdateAll(UpdateTrigger.vpnStopped));
  }

  void dispose() {
    _periodicTimer?.cancel();
    _postVpnTimer?.cancel();
    _periodicTimer = null;
    _postVpnTimer = null;
  }

  /// Manual force refresh одной подписки — сбрасывает `failCount`,
  /// пропускает min-retry cap. Зовётся из `SubscriptionController.updateAt`.
  void resetFailCount(String url) => _failCounts.remove(url);

  /// Manual force refresh всех подписок (кнопка ⟳ на Servers).
  void resetAllFailCounts() => _failCounts.clear();

  /// Пройтись по всем подпискам и обновить те, которым пора.
  /// Последовательно, с задержкой 10с между подписками.
  Future<void> maybeUpdateAll(UpdateTrigger trigger,
      {bool force = false}) async {
    if (_running) {
      AppLog.I.debug('AutoUpdater: skip ${trigger.name} — already running');
      return;
    }
    // Global toggle: `auto_update_subs` в App Settings → Subscriptions.
    // Manual refresh (юзер нажал ⟳) и любой force обходят флаг — юзер
    // явно запросил, не наше дело блокировать.
    if (trigger != UpdateTrigger.manual && !force) {
      final enabled = await SettingsStorage.getAutoUpdateSubs();
      if (!enabled) {
        AppLog.I.debug('AutoUpdater: skip ${trigger.name} — auto-update disabled');
        return;
      }
    }
    // §337 — глобальная галка «обновлять выключенные подписки». Читаем один
    // раз за проход и передаём в pure-гейт параметром.
    final updateDisabled = await SettingsStorage.getAutoUpdateDisabledSubs();
    _running = true;
    AppLog.I.info('AutoUpdater: trigger=${trigger.name}${force ? ' force' : ''}');

    try {
      final candidates = <SubscriptionEntry>[];
      for (final entry in _subController.entries) {
        if (!_shouldUpdate(entry, force: force, updateDisabled: updateDisabled)) {
          continue;
        }
        candidates.add(entry);
      }
      if (candidates.isEmpty) {
        AppLog.I.debug('AutoUpdater: no candidates');
        return;
      }
      AppLog.I.info('AutoUpdater: ${candidates.length} to refresh');

      // §323 — реакции копим за весь проход и применяем ОДИН раз в конце.
      // Иначе три обновившиеся подписки дали бы три пересборки (и до трёх
      // reload'ов) подряд, каждый со своим 3-секундным разрывом туннеля.
      // `reload` побеждает `rebuild`: если хотя бы одна подписка просит
      // применить немедленно, применяем — она всё равно уже в общем конфиге.
      var needRebuild = false;
      var needReload = false;

      for (var i = 0; i < candidates.length; i++) {
        final entry = candidates[i];
        final url = (entry.list as SubscriptionServers).url;
        if (_inFlight.contains(url)) continue;
        _inFlight.add(url);
        try {
          final compositionChanged =
              await _subController.refreshEntry(entry, trigger: trigger);
          final fresh = entry.list;
          if (fresh is SubscriptionServers &&
              fresh.lastUpdateStatus == UpdateStatus.ok) {
            _failCounts.remove(url);
            // §331 (ревью) — реакция ТОЛЬКО при изменившемся составе, как на
            // ручном пути. Без гейта подписка, отдающая тот же список раз в
            // час, гоняла бы пересборку (а в режиме reload — и reload-попытку)
            // на каждом тике впустую.
            // §337 — реакцию берём только с ВКЛЮЧЁННЫХ подписок. Выключенная
            // в конфиг не попадает: её новый состав итоговый конфиг не меняет,
            // пересобирать и (в режиме reload) рвать туннель незачем.
            if (compositionChanged && fresh.enabled) {
              switch (fresh.onUpdateAction) {
                case SubscriptionOnUpdateAction.reload:
                  needReload = true;
                  needRebuild = true;
                case SubscriptionOnUpdateAction.rebuild:
                  needRebuild = true;
                case SubscriptionOnUpdateAction.none:
                  break;
              }
            }
          } else {
            _failCounts[url] = (_failCounts[url] ?? 0) + 1;
          }
        } catch (e) {
          _failCounts[url] = (_failCounts[url] ?? 0) + 1;
          AppLog.I.warning('AutoUpdater: ${entry.displayName} fail: $e');
        } finally {
          _inFlight.remove(url);
        }

        if (i < candidates.length - 1) {
          // 10с ± джиттер ±2с — чтобы два app'а не стучали в одну миллисекунду.
          final jitter = Random().nextInt(4000) - 2000;
          await Future<void>.delayed(
              perSubscriptionDelay + Duration(milliseconds: jitter));
        }
      }

      // §331 — ручной ⟳ больше НЕ исключён. Прежняя логика («юзер сам на
      // экране, сам применит») на практике читалась как сломанная настройка:
      // выбрал «пересобрать и перезагрузить», нажал ⟳ — ничего. Настройка
      // называется «При обновлении», а не «При автообновлении».
      if (needRebuild) await applyReaction(reload: needReload);
    } finally {
      _running = false;
    }
  }

  /// §331 — применить реакцию подписки (см. [SubscriptionOnUpdateAction]).
  /// Публичный: ручной ⟳ идёт через `SubscriptionController.updateAt` →
  /// `_fetchEntryByRef`, минуя `maybeUpdateAll`, и зовёт этот метод напрямую.
  ///
  /// No-throw: реакция не должна ронять ни проход апдейтера (он в `unawaited`),
  /// ни UI-обработчик кнопки. Не привязана (тесты, headless) — режимы
  /// деградируют до `none`: ноды на диске свежие, обычный путь догонит.
  Future<void> applyReaction({required bool reload}) async {
    final react = _onUpdateReaction;
    if (react == null) {
      AppLog.I.debug('AutoUpdater: no reaction bound — skip (acts as none)');
      return;
    }
    AppLog.I.info('AutoUpdater: reaction rebuild${reload ? ' + reload' : ''}');
    try {
      await react(reload: reload);
    } catch (e) {
      AppLog.I.warning('AutoUpdater: reaction failed: $e');
    }
  }

  bool _shouldUpdate(SubscriptionEntry entry,
      {required bool force, bool updateDisabled = false}) {
    final list = entry.list;
    if (list is! SubscriptionServers) return false;
    return shouldUpdatePure(
      list: list,
      force: force,
      fails: _failCounts[list.url] ?? 0,
      now: DateTime.now(),
      updateDisabled: updateDisabled,
    );
  }

  /// Pure-function вариант `_shouldUpdate` — testable без SubscriptionController
  /// и системного времени (night T4-1). Та же логика §027: fail-cap,
  /// min-retry, updateIntervalHours. Принимает `now` и `fails` явно.
  static bool shouldUpdatePure({
    required SubscriptionServers list,
    required bool force,
    required int fails,
    required DateTime now,
    bool updateDisabled = false,
  }) {
    // §337 — выключенная подписка обновляется только при снятой галке
    // «Update disabled subscriptions». Гейт стоит ВЫШЕ `force` намеренно:
    // restore-backup и «обновить все» не должны размораживать выключенные,
    // если юзер галку не ставил.
    if (!list.enabled && !updateDisabled) return false;

    // Fail-cap: после 5 фейлов подписка замораживается до следующего app start.
    if (!force && fails >= maxFailsPerSession) return false;

    if (force) return true;

    // §129 — updateIntervalHours == 0 = «не обновлять автоматически». Ручной
    // Update (force) выше уже вернул true; авто-триггеры сюда доходят и должны
    // пропустить подписку. Файловые подписки ставятся в 0 при создании.
    if (list.updateIntervalHours <= 0) return false;

    // Min-retry: не пытаться чаще 15 мин, даже если `updateIntervalHours`
    // прошёл. Защищает от fail-шторма на каждом триггере.
    final lastTry = list.lastUpdateAttempt;
    if (lastTry != null && now.difference(lastTry) < minRetryInterval) {
      return false;
    }

    // Основное: пора по успешному времени?
    final lastOk = list.lastUpdated;
    if (lastOk == null) return true;
    final interval = Duration(hours: list.updateIntervalHours);
    return now.difference(lastOk) >= interval;
  }
}
