// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/probe/chain_layer_probe.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §394 — послойная проба цепочки: нарезка слоёв 0..k, схема тегов ядра,
/// накопительные значения и дельты, обрыв слоя k помечает k+1.. not reached.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  /// Мок native: журнал вызовов + ответы `ccUrlTestOutbound` по тегу.
  ///
  /// [vpnStatus] — WIRE-литерал native ('Started'/'Stopped'): `fromNative`
  /// мапит только их.
  List<MethodCall> installHandler({
    required String vpnStatus,
    Map<String, Map<String, dynamic>> byTag = const {},
  }) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getVpnStatus':
          return vpnStatus;
        case 'ccUrlTestOutbound':
          final tag = (call.arguments as Map)['tag'] as String;
          return byTag[tag] ?? {'delay': 0, 'error': 'outbound not found'};
        default:
          return null;
      }
    });
    return calls;
  }

  Map<String, dynamic> ok(int ms) => {'delay': ms, 'error': ''};
  Map<String, dynamic> fail(String e) => {'delay': 0, 'error': e};

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chain_layer_probe_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.savePingOptions({
      'url': 'https://probe.example/generate_204',
      'timeout_ms': 4000,
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('схема тегов = лаунчерной', () {
    // Литералы сверены с `config.ChainLayerTag` лаунчера
    // (`core/config/chain_validate.go:100`) и первоисточником — `Chain.hopTag`
    // ядра (`protocol/chain/chain.go:135`).
    test('<chain>#<pos>, позиции с нуля', () {
      expect(chainLayerTag('chain-1', 0), 'chain-1#0');
      expect(chainLayerTag('chain-1', 1), 'chain-1#1');
      expect(chainLayerTag('chain-1', 7), 'chain-1#7');
    });

    test('тег с пробелом и решёткой в имени не меняет схему', () {
      // «Germany #1» — обычное имя из публичной подписки; служебный тег
      // цепочки от него отличается отсутствием пробела перед `#`
      // (`ChainInternalTag` лаунчера).
      expect(chainLayerTag('Germany #1', 2), 'Germany #1#2');
    });
  });

  group('нарезка слоёв', () {
    test('N позиций → N слоёв 0..N-1, каждый своим служебным тегом', () async {
      final calls = installHandler(vpnStatus: 'Started', byTag: {
        'chain-1#0': ok(127),
        'chain-1#1': ok(316),
        'chain-1#2': ok(675),
      });
      final report = await ChainLayerProbe().run(
        'chain-1',
        hops: ['warp', 'al-france', 'masque'],
      );

      expect(report.layers.length, 3);
      expect([for (final l in report.layers) l.probeTag],
          ['chain-1#0', 'chain-1#1', 'chain-1#2']);
      expect([for (final l in report.layers) l.tag],
          ['warp', 'al-france', 'masque']);
      expect([for (final l in report.layers) l.pos], [0, 1, 2]);
      // Пробится ровно по одному разу на слой и ровно этими тегами.
      final probed = [
        for (final c in calls)
          if (c.method == 'ccUrlTestOutbound')
            (c.arguments as Map)['tag'] as String,
      ];
      expect(probed, ['chain-1#0', 'chain-1#1', 'chain-1#2']);
    });

    test('накопительные значения — как вернуло ядро, дельта = разность',
        () async {
      installHandler(vpnStatus: 'Started', byTag: {
        'chain-1#0': ok(127),
        'chain-1#1': ok(316),
        'chain-1#2': ok(675),
      });
      final report = await ChainLayerProbe()
          .run('chain-1', hops: ['a', 'b', 'c']);

      expect([for (final l in report.layers) l.cumulativeMs],
          [127, 316, 675]);
      // Первый слой опорной точки не имеет — цены нет.
      expect(report.deltaAt(0), isNull);
      expect(report.deltaAt(1), 316 - 127);
      expect(report.deltaAt(2), 675 - 316);
    });

    test('отрицательная дельта (шум сети) сводится к нулю, не к минусу',
        () async {
      installHandler(vpnStatus: 'Started', byTag: {
        'chain-1#0': ok(300),
        'chain-1#1': ok(250),
      });
      final report =
          await ChainLayerProbe().run('chain-1', hops: ['a', 'b']);
      expect(report.deltaAt(1), 0);
    });

    test('бюджет и URL — из ping_options, не из хардкода', () async {
      final calls = installHandler(
          vpnStatus: 'Started', byTag: {'chain-1#0': ok(10), 'chain-1#1': ok(20)});
      final report =
          await ChainLayerProbe().run('chain-1', hops: ['a', 'b']);

      expect(report.url, 'https://probe.example/generate_204');
      expect(report.timeoutMs, 4000);
      final args =
          calls.firstWhere((c) => c.method == 'ccUrlTestOutbound').arguments
              as Map;
      expect(args['link'], 'https://probe.example/generate_204');
      expect(args['timeoutMs'], 4000);
    });
  });

  group('обрыв слоя', () {
    test('слой k с ошибкой → k+1.. помечены not reached и НЕ пробятся',
        () async {
      final calls = installHandler(vpnStatus: 'Started', byTag: {
        'chain-1#0': ok(127),
        'chain-1#1': fail('position 1 (al-france): dial: i/o timeout'),
        'chain-1#2': ok(675),
      });
      final report = await ChainLayerProbe()
          .run('chain-1', hops: ['warp', 'al-france', 'masque']);

      expect(report.layers[0].ok, isTrue);
      expect(report.layers[1].error,
          'position 1 (al-france): dial: i/o timeout');
      expect(report.layers[1].notReached, isFalse);
      // Третий слой недостижим ПО ПОСТРОЕНИЮ — своей ошибки у него нет.
      expect(report.layers[2].notReached, isTrue);
      expect(report.layers[2].error, isEmpty);
      expect(report.layers[2].ok, isFalse);

      final probed = [
        for (final c in calls)
          if (c.method == 'ccUrlTestOutbound')
            (c.arguments as Map)['tag'] as String,
      ];
      // Ядро о третьем слое не спрашивали вовсе: бюджет не тратится на
      // заведомо мёртвый путь.
      expect(probed, ['chain-1#0', 'chain-1#1']);
    });

    test('цены нет ни у сломанного слоя, ни у следующего за ним', () async {
      installHandler(vpnStatus: 'Started', byTag: {
        'chain-1#0': ok(127),
        'chain-1#1': fail('dial: i/o timeout'),
      });
      final report =
          await ChainLayerProbe().run('chain-1', hops: ['a', 'b', 'c']);
      expect(report.deltaAt(1), isNull);
      expect(report.deltaAt(2), isNull);
    });

    test('первый слой сломан → все остальные not reached', () async {
      installHandler(vpnStatus: 'Started',
          byTag: {'chain-1#0': fail('outbound not found: chain-1#0')});
      final report =
          await ChainLayerProbe().run('chain-1', hops: ['a', 'b', 'c']);
      expect(report.layers[0].error, isNotEmpty);
      expect([for (final l in report.layers.skip(1)) l.notReached],
          [true, true]);
    });
  });

  group('предусловия', () {
    test('VPN выключен → vpn_down, ядро не трогаем', () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      await expectLater(
        ChainLayerProbe().run('chain-1', hops: ['a', 'b']),
        throwsA(isA<ChainProbeUnavailable>()
            .having((e) => e.isVpnDown, 'isVpnDown', isTrue)),
      );
      expect(calls.map((c) => c.method), isNot(contains('ccUrlTestOutbound')));
    });

    test('нет позиций → no_positions, статус VPN даже не спрашиваем', () async {
      final calls = installHandler(vpnStatus: 'Started');
      await expectLater(
        ChainLayerProbe().run('chain-1', hops: const []),
        throwsA(isA<ChainProbeUnavailable>()
            .having((e) => e.reason, 'reason', 'no_positions')),
      );
      expect(calls, isEmpty);
    });
  });

  group('chainHopsFromConfig', () {
    test('узел type:chain → его outbounds в порядке пакета', () {
      expect(
        chainHopsFromConfig({
          'tag': 'chain-1',
          'type': 'chain',
          'outbounds': ['a', 'b', 'c'],
        }),
        ['a', 'b', 'c'],
      );
    });

    test('не цепочка / нет узла → null (блок не показывается)', () {
      expect(chainHopsFromConfig(null), isNull);
      expect(chainHopsFromConfig({'tag': 'x', 'type': 'vless'}), isNull);
    });

    test('мусор в outbounds отсеивается, список остаётся', () {
      expect(
        chainHopsFromConfig({
          'type': 'chain',
          'outbounds': ['a', 42, null, 'b'],
        }),
        ['a', 'b'],
      );
    });
  });
}
