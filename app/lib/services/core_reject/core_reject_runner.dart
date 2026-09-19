/// Фича 478 — прогон страховки на одно нажатие Start, без экрана.
///
/// Раньше вся связка (состояние прогона, хост, пересборка, отмена) жила в
/// `home_screen.dart` приватным методом, и вызвать её мог только экран. Но
/// проверять фичу надо и снаружи: `POST /action/start-vpn-headless?guard=true`
/// поднимает VPN тем же автоматом на устройстве, где на экран смотреть некому.
/// Поэтому связка переехала сюда, а экран зовёт ровно её же — поведение
/// экрана не меняется, вопрос человеку и плашка по-прежнему его.
///
/// Что осталось у экрана: диалог предела кругов ([askPrompt]) и тихая
/// пересборка со снэкбарами ([rebuildAndSave]). Обе приходят параметром — без
/// них (Debug API, автозапуск, сторож) предел остаётся пределом, а пересборка
/// идёт молча через контроллер подписок.
library;

import 'dart:async';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../app_log.dart';
import 'core_reject_guard.dart';
import 'core_reject_host.dart';
import 'core_reject_state.dart';

Completer<CoreRejectRun>? _activeGuardRun;

/// Тихая пересборка конфига без экрана: то же, что делает `_rebuildConfig`
/// экрана в `silent`-режиме, но без снэкбаров и `mounted`-проверок.
///
/// `null` — пересобрать нечем (lock §037, fatal-валидация) либо конфиг не
/// записался: автомату этого достаточно, чтобы прервать цикл.
Future<String?> rebuildConfigSilently(
  HomeController home,
  SubscriptionController sub,
) async {
  final config = await sub.generateConfig();
  if (config == null) return null;
  final ok = await home.saveParsedConfig(config);
  if (!ok) {
    sub.configDirty = true;
    return null;
  }
  return home.state.configRaw;
}

/// Один прогон страховки. Возвращает итог автомата — его же кладёт в
/// [CoreRejectState] (плашка, фаза для Debug API, ответ на вопрос предела).
///
/// [rebuildAndSave] — пересборка круга; `null` означает «через контроллеры,
/// молча» ([rebuildConfigSilently]). Экран передаёт свою, чтобы `silent`-режим
/// и его `mounted`-проверки остались как были.
///
/// [askPrompt] — вопрос человеку после предела кругов; `null` — пути без UI
/// (Debug API): тогда ждём [CoreRejectState.askPrompt] (в т.ч. заранее
/// поставленный `answer=keep`).
Future<CoreRejectRun> runCoreRejectGuard({
  required HomeController home,
  required SubscriptionController sub,
  Future<String?> Function()? rebuildAndSave,
  Future<CoreRejectPrompt> Function(int limit)? askPrompt,
}) async {
  final active = _activeGuardRun;
  if (active != null && !active.isCompleted) return active.future;

  final runCompleter = Completer<CoreRejectRun>();
  _activeGuardRun = runCompleter;

  CoreRejectState.I.beginRun();
  final host = AppCoreRejectHost(
    home: home,
    sub: sub,
    rebuildAndSave:
        rebuildAndSave ?? () => rebuildConfigSilently(home, sub),
    askPrompt: askPrompt,
  );
  final guard = CoreRejectGuard(host);
  // Отмена доступна всегда (спека раздел 3): кнопка Start в фазе тихого цикла
  // и `POST /core_reject/cancel` дотягиваются до автомата только отсюда — сам
  // он живёт ровно этот прогон.
  CoreRejectState.I.bindCancel(guard.cancel);
  try {
    final run = await guard.run();
    CoreRejectState.I.finish(run);
    if (run.outcome == CoreRejectOutcome.failed && run.error.isNotEmpty) {
      // Ошибка показывается обычным путём (экран слушает контроллер): автомат её
      // не перехватывает, а лишь довёл до неё быстрее.
      AppLog.I.warning('core reject guard: ${run.error}');
    }
    runCompleter.complete(run);
    return run;
  } catch (e, st) {
    runCompleter.completeError(e, st);
    rethrow;
  } finally {
    if (_activeGuardRun == runCompleter) _activeGuardRun = null;
  }
}
