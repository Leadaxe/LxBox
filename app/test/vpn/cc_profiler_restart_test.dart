import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §605 — profilerClient переподнимается на `connected`, если его держат:
/// native `shutdownAll` рвёт клиента на каждой остановке туннеля.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('держатель есть — restartProfiler зовёт ccConnectProfiler', () async {
    final cc = CcChannel.instance;
    await cc.acquireProfiler();
    calls.clear();

    await cc.restartProfiler();
    expect(calls, ['ccConnectProfiler']);

    await cc.releaseProfiler();
  });

  test('держателей нет — restartProfiler ничего не шлёт', () async {
    await CcChannel.instance.restartProfiler();
    expect(calls, isEmpty);
  });
}
