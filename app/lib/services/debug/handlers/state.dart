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
    _ => throw NotFound('state path: ${req.path}'),
  };
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
  final results = await Future.wait([
    vpn.getAutoStart(),
    vpn.getKeepOnExit(),
    vpn.isIgnoringBatteryOptimizations(),
  ]);
  return JsonResponse({
    'auto_start': results[0],
    'keep_on_exit': results[1],
    'is_ignoring_battery_optimizations': results[2],
  });
}
