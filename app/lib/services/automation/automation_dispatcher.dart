import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import '../debug/context.dart';
import '../debug/contract/errors.dart';
import '../debug/debug_registry.dart';
import 'event_emitter.dart';
import 'handlers.dart' as handlers;

/// §047 — incoming-роутер automation-интентов. Native (`LxBoxIntentReceiver`)
/// форвардит intent-action + extras сюда через [BoxVpnClient.
/// registerAutomationActionHandler]. Мы собираем [DebugContext] из
/// [DebugRegistry] (контроллеры биндятся в `HomeScreen.initState`) и зовём
/// shared [handlers].
///
/// **Symmetric request-response (§047):** если handler бросает — логируем и
/// эмитим outgoing `VPN_ERROR` (code/message), чтобы Tasker, ждущий ответ на
/// свой `SWITCH_NODE`, узнал о провале. Успех наблюдается через профильные
/// события (`ACTIVE_NODE_CHANGED` и т.п.), которые эмитятся из контроллеров.
///
/// Init: [registerAutomationBridge] в `main()` после bootstrap'а.
void registerAutomationBridge() {
  BoxVpnClient.I.registerAutomationActionHandler(_dispatch);
}

void _dispatch(String name, Map<String, dynamic> args) {
  // Контекст без HTTP-обвязки: registry + заглушки полей, которые
  // action-handlers не читают (appStartedAt). Контроллеры берутся из
  // DebugRegistry.I — те же, что у Debug API.
  final ctx = DebugContext(
    registry: DebugRegistry.I,
    appStartedAt: DateTime.now(),
  );

  // Async-обёртка: handlers возвращают Future. Ошибки ловим тут, наружу не
  // пробрасываем (native onReceive синхронный, ответа не ждёт).
  Future<void> run() async {
    switch (name) {
      case 'switch-node':
        await handlers.actionSwitchNode(_str(args, 'tag'), ctx);
      case 'set-group':
        await handlers.actionSetGroup(_str(args, 'group'), ctx);
      case 'rebuild-config':
        await handlers.actionRebuildConfig(ctx);
      case 'refresh-subs':
        await handlers.actionRefreshSubs(_bool(args, 'force'), ctx);
      case 'reset-network':
        await handlers.actionResetNetwork(ctx);
      case 'urltest-group':
        await handlers.actionUrltestGroup(_str(args, 'group'), ctx);
      default:
        AppLog.I.warning('[automation] unknown action "$name"');
        return;
    }
  }

  run().then((_) {
    AppLog.I.info('[automation] action $name → ok');
  }).catchError((Object e) {
    final code = e is DebugError ? e.code : 'error';
    // §290 — наружу (открытый broadcast) отдаём только контролируемые
    // DebugError-сообщения. Произвольное исключение (generateConfig/
    // saveParsedConfig и т.п.) может нести путь файла, URL подписки, фрагмент
    // конфига — как Debug API прячет его в generic InternalError, так и здесь
    // шлём generic-текст; детали — в AppLog.
    final message = e is DebugError ? e.message : 'internal error';
    // Полный текст пишем только в лог (не в broadcast).
    AppLog.I.warning('[automation] action $name → ERROR $code: $e');
    // Symmetric: дать ждущему Tasker'у понять что запрос провалился.
    AutomationEventEmitter.I.emitVpnError(code, message);
  });
}

String _str(Map<String, dynamic> args, String key) =>
    args[key]?.toString() ?? '';

bool _bool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is bool) return v;
  // §290 — тот же набор литералов, что Debug API `qBool` (true/1/yes), чтобы
  // строковый bool парсился одинаково на обоих транспортах. Native обычно шлёт
  // настоящий Boolean (getBooleanExtra), но контракт парсеров держим единым.
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }
  return false;
}
