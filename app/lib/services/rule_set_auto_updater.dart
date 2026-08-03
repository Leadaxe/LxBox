import 'dart:async';

import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../models/preset_rule_set.dart';
import 'app_log.dart';
import 'rule_set_downloader.dart';
import 'settings_storage.dart';
import 'template_loader.dart';

/// Триггеры авто-обновления rule-set'ов (§366). Нужны для логов — решение
/// «пора?» одинаковое.
enum RuleSetUpdateTrigger {
  /// Через [RuleSetAutoUpdater.appStartDelay] после запуска приложения.
  appStart,

  /// Через [RuleSetAutoUpdater.postVpnConnectedDelay] после подъёма туннеля.
  vpnConnected,

  /// Повтор после неудачного прохода, через [RuleSetAutoUpdater.retryDelay].
  retry,
}

/// Один кандидат на обновление: `.srs`, чей кэш протух по своему TTL.
class _Candidate {
  const _Candidate({
    required this.cacheId,
    required this.url,
    required this.label,
    this.presetId,
    this.tag,
  });

  /// Ключ в дисковом кэше: `CustomRule.id` либо `preset__<presetId>__<tag>`.
  final String cacheId;
  final String url;

  /// Для логов.
  final String label;

  final String? presetId;
  final String? tag;
}

/// Авто-обновление кэшированных rule-set'ов по устареванию (§366, gh#39).
///
/// **Почему не таймер.** Постоянный фоновый таймер отвергнут: рулсеты живут
/// неделями, а будильник раз в час стоит батареи каждый день. Вместо него два
/// естественных момента, когда приложение и так проснулось и сеть заведомо
/// нужна: запуск приложения и подъём туннеля.
///
/// **Контракт:**
/// - `appStart` — через 30 с после старта (не сразу: старт и так занят
///   загрузкой конфига, подписками и подъёмом UI).
/// - `vpnConnected` — через 30 с после connected, даёт туннелю устояться.
/// - Неудача → ровно один повтор через 20 с. Дальше ждём следующего старта
///   VPN.
/// - **Успешный проход (или «обновлять нечего») усыпляет механику до
///   перезапуска процесса** — [_sessionDone]. Пользователь просил именно так:
///   раз в сессию проверили и больше не трогаем.
/// - Только на переднем плане: уход в фон отменяет запланированную попытку.
///   Ничего не делаем за спиной у свёрнутого приложения.
///
/// Само скачивание — условным GET (`If-None-Match`), так что типичная
/// еженедельная проверка стоит одного 304-ответа без тела.
///
/// Что НЕ делаем при неудаче: не удаляем старый `.srs` и не выключаем
/// правило — даже на 404. Устаревший рабочий список лучше выключенного.
class RuleSetAutoUpdater {
  RuleSetAutoUpdater();

  /// Задержка перед проходом на старте приложения.
  static const Duration appStartDelay = Duration(seconds: 30);

  /// Задержка перед проходом после подъёма туннеля.
  static const Duration postVpnConnectedDelay = Duration(seconds: 30);

  /// Повтор после неудачного прохода — один раз.
  static const Duration retryDelay = Duration(seconds: 20);

  /// Пауза между рулсетами внутри прохода, чтобы не бить в провайдера пачкой.
  static const Duration perRuleSetDelay = Duration(seconds: 2);

  Timer? _timer;
  bool _running = false;

  /// Проход завершился без единой неудачи → до перезапуска процесса больше
  /// не проверяем.
  bool _sessionDone = false;

  /// Приложение на переднем плане. Фон = попыток нет.
  bool _foreground = true;

  /// Реакция на реально изменившийся кэш: конфиг надо пересобрать. Ставит
  /// `home_screen` — по образцу `AutoUpdater.bindOnUpdateReaction` (§323).
  /// Не привязана (тесты, headless) — проход просто отработает молча, а
  /// новый `.srs` подхватится обычным путём при следующей сборке.
  Future<void> Function()? _onChanged;

  void bindOnChanged(Future<void> Function() fn) => _onChanged = fn;

  /// Виден ли снаружи как «уже отработал за эту сессию» (для тестов и логов).
  bool get sessionDone => _sessionDone;

  /// Старт приложения — планирует первую проверку.
  void start() => _schedule(RuleSetUpdateTrigger.appStart, appStartDelay);

  /// Туннель поднялся. Зовёт `HomeController` на transition → connected.
  void onVpnConnected() =>
      _schedule(RuleSetUpdateTrigger.vpnConnected, postVpnConnectedDelay);

  /// Приложение ушло в фон — отменяем запланированное.
  void onAppPaused() {
    _foreground = false;
    _timer?.cancel();
    _timer = null;
  }

  void onAppResumed() => _foreground = true;

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(RuleSetUpdateTrigger trigger, Duration delay) {
    if (_sessionDone || _running || !_foreground) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_run(trigger)));
  }

  /// Один проход. No-throw: зовётся из таймера через `unawaited`.
  Future<void> _run(RuleSetUpdateTrigger trigger) async {
    if (_sessionDone || _running) return;
    // Момент срабатывания — последняя точка, где фон ещё можно поймать:
    // между планированием и выстрелом приложение могли свернуть.
    if (!_foreground) return;
    _running = true;
    try {
      final candidates = await _collectCandidates();
      if (candidates.isEmpty) {
        // «Обновлять нечего» — тоже успех: спим до перезапуска.
        _sessionDone = true;
        AppLog.I.debug('RuleSetAutoUpdater: ${trigger.name} — nothing stale');
        return;
      }
      AppLog.I.info(
          'RuleSetAutoUpdater: ${trigger.name} — ${candidates.length} stale');

      var failed = 0;
      var changed = false;
      for (var i = 0; i < candidates.length; i++) {
        // Свернули посреди прохода — останавливаемся, недокачанное догоним
        // на следующем триггере (проход не помечаем успешным).
        if (!_foreground) {
          failed++;
          break;
        }
        final c = candidates[i];
        final res = await RuleSetDownloader.fetch(c.cacheId, c.url,
            conditional: true);
        switch (res.outcome) {
          case DownloadOutcome.downloaded:
            changed = true;
            AppLog.I.info('RuleSetAutoUpdater: updated ${c.label}');
          case DownloadOutcome.notModified:
            AppLog.I.debug('RuleSetAutoUpdater: ${c.label} up to date (304)');
          case DownloadOutcome.failed:
            failed++;
            AppLog.I.warning('RuleSetAutoUpdater: ${c.label} failed');
        }
        if (i < candidates.length - 1) {
          await Future<void>.delayed(perRuleSetDelay);
        }
      }

      if (changed) await _notifyChanged();

      if (failed == 0) {
        _sessionDone = true;
        AppLog.I.info('RuleSetAutoUpdater: pass complete — sleeping until restart');
      } else if (trigger != RuleSetUpdateTrigger.retry) {
        // Один повтор за триггер. После него — только следующий старт VPN.
        AppLog.I.info('RuleSetAutoUpdater: $failed failed — retry in 20s');
        _running = false; // иначе `_schedule` отобьёт собственный повтор
        _schedule(RuleSetUpdateTrigger.retry, retryDelay);
        return;
      }
    } catch (e) {
      AppLog.I.warning('RuleSetAutoUpdater: pass error: $e');
    } finally {
      _running = false;
    }
  }

  /// No-throw: реакция не должна ронять проход.
  Future<void> _notifyChanged() async {
    final fn = _onChanged;
    if (fn == null) {
      AppLog.I.debug('RuleSetAutoUpdater: no reaction bound — skip rebuild');
      return;
    }
    try {
      await fn();
    } catch (e) {
      AppLog.I.warning('RuleSetAutoUpdater: reaction failed: $e');
    }
  }

  /// Собрать протухшие рулсеты: свои `CustomRuleSrs` + remote-рулсеты
  /// пресетов. Выключенные правила пропускаем — их `.srs` в конфиг не идёт,
  /// качать его незачем.
  Future<List<_Candidate>> _collectCandidates() async {
    final rules = await SettingsStorage.getCustomRules();
    final now = DateTime.now();
    final out = <_Candidate>[];

    WizardTemplate? template;
    for (final r in rules) {
      if (!r.enabled) continue;

      if (r is CustomRuleSrs) {
        final url = r.srsUrl.trim();
        if (url.isEmpty) continue;
        final meta = await RuleSetDownloader.readMeta(r.id);
        if (!shouldUpdatePure(
            meta: meta, intervalHours: r.updateIntervalHours, now: now)) {
          continue;
        }
        out.add(_Candidate(cacheId: r.id, url: url, label: r.name));
        continue;
      }

      if (r is CustomRulePreset) {
        // Шаблон грузим лениво — у юзера может не быть ни одного пресета
        // с remote-рулсетами.
        template ??= await TemplateLoader.load();
        SelectableRule? preset;
        for (final sr in template.selectableRules) {
          if (sr.presetId == r.presetId) {
            preset = sr;
            break;
          }
        }
        if (preset == null) continue; // пресета нет в шаблоне
        // С `rule` — уважаем §045-гейтинг: выключенный var'ом rule_set в
        // конфиг не попадает.
        for (final rs in remoteRuleSetsOfPreset(preset, r)) {
          final meta =
              await RuleSetDownloader.readMetaForPreset(r.presetId, rs.tag);
          if (!shouldUpdatePure(
              meta: meta,
              intervalHours: rs.updateIntervalHours,
              now: now)) {
            continue;
          }
          out.add(_Candidate(
            cacheId: RuleSetDownloader.presetCacheId(r.presetId, rs.tag),
            url: rs.url,
            label: '${r.name}/${rs.tag}',
            presetId: r.presetId,
            tag: rs.tag,
          ));
        }
      }
    }
    return out;
  }

  /// Пора ли обновлять — pure, тестируется без файловой системы и часов.
  ///
  /// - `intervalHours <= 0` — «никогда» (юзер выбрал Never): не обновляем.
  /// - Нет `lastUpdated` — кэш скачан до §366 (метаданных не было) либо
  ///   вообще не скачан: считаем протухшим, первая же проверка заведёт
  ///   метаданные.
  /// - Иначе — по возрасту.
  ///
  /// Отдельного min-retry (как у подписок) нет: попыток за сессию и так
  /// максимум две, шторм невозможен.
  static bool shouldUpdatePure({
    required RuleSetMeta meta,
    required int intervalHours,
    required DateTime now,
  }) {
    if (intervalHours <= 0) return false;
    final last = meta.lastUpdated;
    if (last == null) return true;
    return now.difference(last) >= Duration(hours: intervalHours);
  }
}
