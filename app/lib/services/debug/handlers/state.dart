import '../../../config/clash_endpoint.dart';
import '../../../vpn/box_vpn_client.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../serializers/home_state.dart';
import '../serializers/rules.dart';
import '../serializers/storage.dart';
import '../serializers/subs.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// Диспатчер `/state/*`. Подмаршруты читают разные части домена —
/// home controller, subs, rules (из storage), storage cache, native VPN.
Future<DebugResponse> stateHandler(DebugRequest req, DebugContext ctx) async {
  return switch (req.path) {
    '/state' => _root(req, ctx),
    '/state/clash' => _clash(req, ctx),
    '/state/subs' => _subs(req, ctx),
    '/state/rules' => _rules(req, ctx),
    '/state/storage' => _storage(req, ctx),
    '/state/vpn' => _vpn(req, ctx),
    '/state/config_locked' => _configLocked(req, ctx),
    _ => throw NotFound('state path: ${req.path}'),
  };
}

/// §037: Текущее состояние lock'а auto-rebuild. Когда `locked: true` —
/// `SubscriptionController.generateConfig()` возвращает null silently,
/// pinned config через `PUT /config` не перетирается UI-действиями.
Future<DebugResponse> _configLocked(DebugRequest req, DebugContext ctx) async {
  final locked = await SettingsStorage.getConfigLockedForDebug();
  return JsonResponse({'locked': locked});
}

Future<DebugResponse> _root(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  return JsonResponse(serializeHomeState(home.state));
}

Future<DebugResponse> _clash(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final reveal = req.qBool('reveal');
  final endpoint = ClashEndpoint.fromConfigJson(home.state.configRaw);
  var apiOk = false;
  if (home.clashClient != null) {
    try {
      await home.clashClient!.pingVersion();
      apiOk = true;
    } catch (_) {
      apiOk = false;
    }
  }
  return JsonResponse({
    'available': endpoint != null,
    'base_uri': endpoint?.baseUri.toString(),
    'secret': endpoint == null
        ? null
        : (reveal ? endpoint.secret : (endpoint.secret.isEmpty ? '' : '***')),
    'api_ok': apiOk,
  });
}

Future<DebugResponse> _subs(DebugRequest req, DebugContext ctx) async {
  final sub = ctx.requireSub();
  final reveal = req.qBool('reveal');
  final entries = sub.entries
      .map((e) => serializeSubEntry(e, reveal: reveal))
      .toList();
  return JsonResponse(entries);
}

Future<DebugResponse> _rules(DebugRequest req, DebugContext ctx) async {
  final rules = await SettingsStorage.getCustomRules();
  final serialized = await Future.wait(rules.map(serializeCustomRule));
  return JsonResponse(serialized);
}

Future<DebugResponse> _storage(DebugRequest req, DebugContext ctx) async {
  final cache = await SettingsStorage.dumpCache();
  return JsonResponse(serializeStorageCache(cache));
}

Future<DebugResponse> _vpn(DebugRequest req, DebugContext ctx) async {
  final vpn = BoxVpnClient();
  final autoStart = await vpn.getAutoStart();
  final keepOnExit = await vpn.getKeepOnExit();
  final allowBypass = await vpn.getAllowBypass();
  // §069 — runtime applied value, может отличаться от persisted allowBypass
  // если юзер поменял toggle но не reload'нул VPN.
  final currentSessionAllowBypass = await vpn.getCurrentSessionAllowBypass();
  final backgroundMode = await vpn.getBackgroundMode();
  final battery = await vpn.isIgnoringBatteryOptimizations();
  return JsonResponse({
    'auto_start': autoStart,
    'keep_on_exit': keepOnExit,
    'allow_bypass': allowBypass,
    'current_session_allow_bypass': currentSessionAllowBypass,
    'background_mode': backgroundMode.wireValue,
    'is_ignoring_battery_optimizations': battery,
  });
}
