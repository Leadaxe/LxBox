/// Фича 478 — связка автомата страховки с живым приложением.
///
/// Автомат (`core_reject_guard.dart`) знает только этот интерфейс; всё, что
/// про туннель, сборку и хранение, живёт здесь. Так автомат остаётся
/// проверяемым юнитами, а связка — тонкой.
///
/// Лежал под `screens/home/`, хотя виджетов не знает вовсе: ни одного импорта
/// Flutter. Переехал в сервисы, когда прогон понадобился Debug API
/// (`core_reject_runner.dart`) — сервису нельзя зависеть от экрана.
library;

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import 'core_reject_guard.dart';
import 'core_reject_state.dart';

/// Реализация [CoreRejectHost] поверх контроллеров.
///
/// [askPrompt] приходит снаружи: на пути с UI это показ диалога, на старте
/// без UI — [CoreRejectState.askPrompt] (очередь `answer=keep` с Debug API).
class AppCoreRejectHost implements CoreRejectHost {
  AppCoreRejectHost({
    required this.home,
    required this.sub,
    required this.rebuildAndSave,
    this.askPrompt,
    BoxVpnClient? vpn,
  }) : _vpn = vpn ?? BoxVpnClient.I;

  final HomeController home;
  final SubscriptionController sub;
  final BoxVpnClient _vpn;

  /// Пересобрать конфиг и записать его на диск. Возвращает текст конфига или
  /// `null`, если пересобрать нечем (lock §037, fatal-валидация).
  final Future<String?> Function() rebuildAndSave;

  /// Показ вопроса человеку; `null` — пути без UI.
  final Future<CoreRejectPrompt> Function(int limit)? askPrompt;

  @override
  Future<CoreAttempt> realStart() async {
    final error = await home.startAndAwaitVerdict();
    if (error == null) return const CoreAttempt.accepted();
    if (error.isEmpty) return const CoreAttempt.unavailable();
    return CoreAttempt.rejected(error);
  }

  @override
  Future<RebuiltConfig?> rebuild() async {
    final json = await rebuildAndSave();
    if (json == null || json.isEmpty) return null;
    // Теги — из обратной карты той же сборки (CANON §9.3): против них
    // проверяются кандидаты разбора строки ошибки.
    return RebuiltConfig(
      configJson: json,
      tags: sub.lastEmittedTagMap.keys.toSet(),
    );
  }

  @override
  Future<CoreAttempt> check(String configJson) async {
    final r = await _vpn.checkConfig(configJson);
    // Моста нет (юнит, старый native, таймаут) — проверять нечем.
    if (r == null) return const CoreAttempt.unavailable();
    return r.ok ? const CoreAttempt.accepted() : CoreAttempt.rejected(r.error);
  }

  @override
  Future<bool> disableNode(String tag, String reason) async {
    final ok = await sub.disableNodeByCoreTag(tag, reason);
    AppLog.I.warning(ok
        ? 'core rejected node "$tag", disabled: $reason'
        : 'core rejected tag "$tag" with no matching node, no automation');
    return ok;
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int disabledCount) async {
    final ask = askPrompt;
    if (ask != null) return ask(disabledCount);
    // Debug API и прочие пути без экрана ждут ответ через CoreRejectState
    // (`GET/POST /core_reject/prompt`, в т.ч. заранее `answer=keep`).
    return CoreRejectState.I.askPrompt(disabledCount);
  }

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) =>
      CoreRejectState.I
          .onProgress(phase, round, disabledNodes: disabledNodes);
}
