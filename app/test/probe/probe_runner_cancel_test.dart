import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/probe/probe_runner.dart';

import '../parser/engine_test_setup.dart';
import 'probe_session_fake.dart';

/// §669 — Test servers при выключенном VPN: Stop обрывает начатые замеры,
/// старый прогон не закрывает сессию нового (runId-владелец).
NodeSpec _vless(String tag) => VlessSpec(
      id: tag,
      tag: tag,
      label: tag,
      server: '$tag.example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

Future<void> _until(bool Function() cond, {String what = ''}) async {
  for (var i = 0; i < 500 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(cond(), isTrue, reason: 'не дождались: $what');
}

void main() {
  setUpAll(loadEngineSections);
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.leadaxe.lxbox/methods');
  late FakeProbeSession fake;
  final nodes = [for (var i = 1; i <= 8; i++) _vless('n$i')];

  setUp(() {
    fake = FakeProbeSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fake.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('cancel() во время прогона рвёт начатые замеры и закрывает свою сессию',
      () async {
    final results = <int, ProbeResult>{};
    final runner = ProbeRunner();
    final done = runner.run(nodes,
        url: 'https://example.com/gen204',
        timeoutMs: 5000,
        onResult: (i, r) => results[i] = r);

    // Шесть параллельных dial'ов висят — без обрыва они ждали бы таймаута.
    await _until(() => fake.pendingCount == 6, what: '6 замеров в полёте');
    runner.cancel();

    final err = await done.timeout(const Duration(seconds: 2));
    expect(err, '');
    expect(fake.runIdsOf('probeCancel'), [1]);
    expect(fake.runIdsOf('probeStop'), [1]);
    expect(fake.live, isNull, reason: 'сессия закрыта');
    // Оборванные замеры вердиктом не стали, оставшиеся не начинались.
    expect(results, isEmpty);
    expect(fake.callsOf('probeUrlTest'), 6);
  });

  test('cancel() до старта сессии: замеров нет, сессия закрыта', () async {
    final runner = ProbeRunner();
    final done = runner.run(nodes,
        url: '', timeoutMs: 0, onResult: (_, _) {});
    runner.cancel();
    expect(await done, '');
    expect(fake.callsOf('probeUrlTest'), 0);
    expect(fake.live, isNull);
  });

  test('probeStop старого прогона не закрывает сессию нового', () async {
    final oldResults = <int, ProbeResult>{};
    final newResults = <int, ProbeResult>{};
    final oldRunner = ProbeRunner();
    final oldDone = oldRunner.run(nodes,
        url: '', timeoutMs: 0, onResult: (i, r) => oldResults[i] = r);
    await _until(() => fake.pendingCount == 6, what: 'старый прогон в полёте');

    // Новый прогон поднимает свою сессию поверх старой (рестарт).
    final newRunner = ProbeRunner();
    final newDone = newRunner.run(nodes,
        url: '', timeoutMs: 0, onResult: (i, r) => newResults[i] = r);

    // Старый доходит до finally: его probeStop(1) — no-op для сессии 2.
    expect(await oldDone.timeout(const Duration(seconds: 2)), '');
    expect(fake.runIdsOf('probeStop'), contains(1));
    expect(fake.live, 2, reason: 'сессия нового прогона жива');
    expect(oldResults.values.map((r) => r.message),
        isNot(contains('stale run')));

    // Новый прогон меряет до конца в своей сессии.
    await _until(() => fake.pendingCount == 6, what: 'новый прогон в полёте');
    fake.holdUrlTests = false;
    fake.releaseOk();
    expect(await newDone.timeout(const Duration(seconds: 2)), '');
    expect(newResults.length, 8);
    expect(newResults.values.every((r) => r.status == ProbeStatus.ok), isTrue);
    expect(fake.runIdsOf('probeStop').last, 2);
    expect(fake.live, isNull);
  });
}
