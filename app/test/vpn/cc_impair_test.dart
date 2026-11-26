import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/vpn/platform_channels.dart';

/// §762 (ядро SPEC 164) — `CcChannel` для outbound `impair`: имена методов и
/// аргументы, `null` = клиент недоступен, статус — разобранный JSON ядра,
/// отказ ядра — `PlatformException` наружу.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final cc = CcChannel.instance;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('getImpairStatus: статус разобран, поля как у ядра', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'ccGetImpairStatus');
      expect(call.arguments, {'tag': 'node-a'});
      return '{"tag":"node-a","schedule":{"round":1},"sublinks":[]}';
    });
    final r = await cc.getImpairStatus('node-a');
    expect(r, {
      'tag': 'node-a',
      'schedule': {'round': 1},
      'sublinks': <Object?>[],
    });
  });

  test('null от натива → null (клиент недоступен)', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await cc.getImpairStatus('node-a'), isNull);
    expect(await cc.setImpair('node-a', '{"sublinks":false}'), isNull);
    expect(await cc.scheduleImpair('node-a', const []), isNull);
  });

  test('без плагина → null', () async {
    expect(await cc.getImpairStatus('node-a'), isNull);
  });

  test('setImpair и scheduleImpair: аргументы', () async {
    final seen = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen.add(call);
      return '{"tag":"node-a"}';
    });
    await cc.setImpair('node-a', '{"link_params":{"loss":"2%"}}');
    await cc.scheduleImpair(
      'node-a',
      [
        {'at': '0s', 'link_params': {'outage': true, 'reset': true}},
      ],
      start: 'first_use',
      repeat: '60s',
    );
    await cc.scheduleImpair('node-a', const []);
    expect(seen[0].method, 'ccSetImpair');
    expect(seen[0].arguments,
        {'tag': 'node-a', 'entry': '{"link_params":{"loss":"2%"}}'});
    expect(seen[1].method, 'ccScheduleImpair');
    final a = seen[1].arguments as Map;
    expect(jsonDecode(a['entries'] as String), [
      {'at': '0s', 'link_params': {'outage': true, 'reset': true}},
    ]);
    expect(a['start'], 'first_use');
    expect(a['repeat'], '60s');
    expect(seen[2].arguments,
        {'tag': 'node-a', 'entries': '[]', 'start': '', 'repeat': ''});
  });

  test('отказ ядра — PlatformException с кодом', () async {
    messenger.setMockMethodCallHandler(channel, (_) async =>
        throw PlatformException(code: CcStatusError.notFound, message: 'x'));
    await expectLater(cc.getImpairStatus('nope'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', CcStatusError.notFound)));
  });

  test('статус не объект — FormatException', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => '[]');
    await expectLater(
        cc.getImpairStatus('node-a'), throwsA(isA<FormatException>()));
  });
}
