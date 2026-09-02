// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/chains.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/probe/chain_layer_probe.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => tempRoot;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
}

/// Прогон-заглушка: отдаёт заранее заданный отчёт (или бросает), запоминая,
/// с какими позициями и бюджетом её позвали. Ядро в юнит-тесте недоступно, а
/// проверять надо ЛОГИКУ хендлера, не транспорт.
class _StubProbe extends ChainLayerProbe {
  _StubProbe({this.report, this.error});

  final ChainProbeReport? report;
  final ChainProbeUnavailable? error;

  String? seenTag;
  List<String>? seenHops;
  String? seenUrl;
  int? seenTimeout;

  @override
  Future<ChainProbeReport> run(
    String chainTag, {
    required List<String> hops,
    String? url,
    int? timeoutMs,
  }) async {
    seenTag = chainTag;
    seenHops = hops;
    seenUrl = url;
    seenTimeout = timeoutMs;
    if (error != null) throw error!;
    return report!;
  }
}

/// §394 — `GET /chains/{tag}/probe`: маршрутизация под-ресурса, предусловия
/// (нет цепочки / нет в собранном конфиге / VPN выключен) и форма ответа.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  DebugContext ctx() =>
      DebugContext(registry: DebugRegistry.I, appStartedAt: DateTime.utc(2026));

  DebugRequest get(String path, {String qs = ''}) => DebugRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:9269$path$qs'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      );

  Map<String, Object?> asMap(DebugResponse r) =>
      (r as JsonResponse).body as Map<String, Object?>;

  /// Конфиг с узлом цепочки [tag] и позициями [hops].
  String cfgWithChain(String tag, List<String> hops) => jsonEncode({
        'outbounds': [
          for (final h in hops) {'tag': h, 'type': 'vless'},
          {'tag': tag, 'type': 'chain', 'outbounds': hops},
        ],
      });

  ChainProbeReport reportOf(String tag, List<ChainLayerResult> layers) =>
      ChainProbeReport(
        chainTag: tag,
        layers: layers,
        url: 'https://probe.example/generate_204',
        timeoutMs: 4000,
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chains_probe_handler_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async {
        // saveParsedConfig отдаёт false, если native не подтвердил запись, —
        // тогда configModel не обновится и все тесты уйдут в «нет в конфиге».
        if (call.method == 'saveConfig') return true;
        return null;
      });
    }
    controller = HomeController();
    DebugRegistry.I.home = controller;
    await SettingsStorage.setChains([
      const SourceChain(tag: 'chain-1', hops: ['warp', 'al']),
    ]);
  });

  tearDown(() async {
    chainProbeFactory = ChainLayerProbe.new;
    DebugRegistry.I.home = null;
    controller.dispose();
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('маршрутизация под-ресурса', () {
    test('неизвестная цепочка → 404', () async {
      await expectLater(
        chainsHandler(get('/chains/nope/probe'), ctx()),
        throwsA(isA<NotFound>()),
      );
    });

    test('не-GET на /probe → BadRequest', () async {
      final req = DebugRequest(
        method: 'POST',
        uri: Uri.parse('http://127.0.0.1:9269/chains/chain-1/probe'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      );
      await expectLater(
          chainsHandler(req, ctx()), throwsA(isA<BadRequest>()));
    });

    test('под-ресурс не съедает обычный GET /chains/{tag}', () async {
      final r = asMap(await chainsHandler(get('/chains/chain-1'), ctx()));
      expect(r['tag'], 'chain-1');
      expect(r['hops'], ['warp', 'al']);
    });
  });

  group('предусловия', () {
    test('цепочки нет в собранном конфиге → 409, ядро не зовём', () async {
      // configModel пуст: конфиг ни разу не собирался.
      final stub = _StubProbe(report: reportOf('chain-1', const []));
      chainProbeFactory = () => stub;
      await expectLater(
        chainsHandler(get('/chains/chain-1/probe'), ctx()),
        throwsA(isA<Conflict>()),
      );
      expect(stub.seenTag, isNull);
    });

    test('VPN выключен → 409 с внятным текстом, не сырым vpn_down', () async {
      await controller.saveParsedConfig(cfgWithChain('chain-1', ['warp', 'al']));
      chainProbeFactory =
          () => _StubProbe(error: const ChainProbeUnavailable('vpn_down'));
      await expectLater(
        chainsHandler(get('/chains/chain-1/probe'), ctx()),
        throwsA(isA<Conflict>().having((e) => e.message, 'message',
            contains('VPN is down'))),
      );
    });

    test('timeout_ms ≤ 0 → BadRequest', () async {
      await controller.saveParsedConfig(cfgWithChain('chain-1', ['warp', 'al']));
      await expectLater(
        chainsHandler(get('/chains/chain-1/probe', qs: '?timeout_ms=0'), ctx()),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('позиции и параметры', () {
    test('позиции берутся из СОБРАННОГО конфига, не из storage', () async {
      // В storage — два хопа; в собранном конфиге — три (конфиг ушёл вперёд).
      await controller
          .saveParsedConfig(cfgWithChain('chain-1', ['warp', 'al', 'exit']));
      final stub = _StubProbe(
          report: reportOf('chain-1', const [
        ChainLayerResult(
            pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 10),
      ]));
      chainProbeFactory = () => stub;
      await chainsHandler(get('/chains/chain-1/probe'), ctx());
      expect(stub.seenHops, ['warp', 'al', 'exit']);
    });

    test('url/timeout_ms из query доезжают до прогона', () async {
      await controller.saveParsedConfig(cfgWithChain('chain-1', ['warp', 'al']));
      final stub = _StubProbe(report: reportOf('chain-1', const []));
      chainProbeFactory = () => stub;
      await chainsHandler(
          get('/chains/chain-1/probe',
              qs: '?url=https://x.example/204&timeout_ms=1500'),
          ctx());
      expect(stub.seenUrl, 'https://x.example/204');
      expect(stub.seenTimeout, 1500);
    });

    test('без query — прогон сам подставит ping_options (null наверх)',
        () async {
      await controller.saveParsedConfig(cfgWithChain('chain-1', ['warp', 'al']));
      final stub = _StubProbe(report: reportOf('chain-1', const []));
      chainProbeFactory = () => stub;
      await chainsHandler(get('/chains/chain-1/probe'), ctx());
      expect(stub.seenUrl, isNull);
      expect(stub.seenTimeout, isNull);
    });
  });

  group('форма ответа', () {
    test('успешные слои: cumulative_ms + delta_ms со второго', () async {
      await controller.saveParsedConfig(
          cfgWithChain('chain-1', ['warp', 'al', 'exit']));
      chainProbeFactory = () => _StubProbe(
              report: reportOf('chain-1', const [
            ChainLayerResult(
                pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 127),
            ChainLayerResult(
                pos: 1, tag: 'al', probeTag: 'chain-1#1', cumulativeMs: 316),
            ChainLayerResult(
                pos: 2, tag: 'exit', probeTag: 'chain-1#2', cumulativeMs: 675),
          ]));
      final r = asMap(await chainsHandler(get('/chains/chain-1/probe'), ctx()));

      expect(r['ok'], isTrue);
      expect(r['action'], 'chain-probe');
      expect(r['tag'], 'chain-1');
      expect(r['url'], 'https://probe.example/generate_204');
      expect(r['timeout_ms'], 4000);
      final layers = (r['layers'] as List).cast<Map<String, Object?>>();
      expect(layers.length, 3);
      expect(layers[0]['probe_tag'], 'chain-1#0');
      expect(layers[0]['cumulative_ms'], 127);
      // Первый слой цены не несёт — вычитать не из чего.
      expect(layers[0].containsKey('delta_ms'), isFalse);
      expect(layers[1]['delta_ms'], 189);
      expect(layers[2]['delta_ms'], 359);
    });

    test('слой с ошибкой несёт error, следующие — not_reached без цифр',
        () async {
      await controller.saveParsedConfig(
          cfgWithChain('chain-1', ['warp', 'al', 'exit']));
      chainProbeFactory = () => _StubProbe(
              report: reportOf('chain-1', const [
            ChainLayerResult(
                pos: 0, tag: 'warp', probeTag: 'chain-1#0', cumulativeMs: 127),
            ChainLayerResult(
                pos: 1,
                tag: 'al',
                probeTag: 'chain-1#1',
                error: 'dial: i/o timeout'),
            ChainLayerResult(
                pos: 2, tag: 'exit', probeTag: 'chain-1#2', notReached: true),
          ]));
      final layers = ((asMap(
                  await chainsHandler(get('/chains/chain-1/probe'), ctx()))[
              'layers'] as List))
          .cast<Map<String, Object?>>();

      expect(layers[1]['error'], 'dial: i/o timeout');
      // Ноль миллисекунд читался бы как «хоп бесплатный» — ключа нет вовсе.
      expect(layers[1].containsKey('cumulative_ms'), isFalse);
      expect(layers[1].containsKey('delta_ms'), isFalse);
      expect(layers[2]['not_reached'], isTrue);
      expect(layers[2].containsKey('cumulative_ms'), isFalse);
      expect(layers[2].containsKey('error'), isFalse);
    });
  });
}
