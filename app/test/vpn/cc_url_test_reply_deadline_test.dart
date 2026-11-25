import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/vpn/platform_channels.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §731 (4PDA #2001) — таймаут замера держит ядро; если его RPC не вернулся
/// вовсе, вызов обязан завершиться сам: иначе строка узла висит в «PING…», а
/// воркер mass ping навсегда занимает слот.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final grace = CcChannel.urlTestReplyGrace;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    CcChannel.urlTestReplyGrace = grace;
  });

  test('ядро не ответило → ошибка по дедлайну «таймаут + запас»', () async {
    final never = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) => never.future);
    CcChannel.urlTestReplyGrace = const Duration(milliseconds: 60);

    final sw = Stopwatch()..start();
    final r = await CcChannel.instance
        .urlTestOutbound('chain-warp', link: 'https://x.example', timeoutMs: 40);

    expect(r.ok, isFalse);
    expect(r.lastDelayValue, -1);
    expect(r.error, contains('no reply from core'));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(90),
        reason: 'раньше таймаута замера + запаса не обрываем');
    never.complete(null);
  });

  // §731 (дополнение 25.11, Telegram 12043) — замер probe-сессии с TLS
  // fragment ядро держит мимо таймаута; без дедлайна пул теста подписки
  // вставал, когда все слоты занимали такие узлы.
  test('probe: ядро не ответило → ошибка по дедлайну «таймаут + запас»',
      () async {
    final never = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) => never.future);
    CcChannel.urlTestReplyGrace = const Duration(milliseconds: 60);

    final sw = Stopwatch()..start();
    final r = await CcChannel.instance.probeUrlTest('frag-node',
        runId: 7, link: 'https://x.example', timeoutMs: 40);

    expect(r.ok, isFalse);
    expect(r.error, contains('no reply from core'));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(90),
        reason: 'раньше таймаута замера + запаса не обрываем');
    never.complete(null);
  });

  test('probe: ответ ядра в срок проходит как есть', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => {'delay': 42, 'error': ''});
    final r = await CcChannel.instance.probeUrlTest('n',
        runId: 7, link: 'https://x.example', timeoutMs: 5000);
    expect(r.ok, isTrue);
    expect(r.delay, 42);
  });

  test('ответ ядра в срок проходит как есть', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => {'delay': 42, 'error': ''});
    final r = await CcChannel.instance
        .urlTestOutbound('n', link: 'https://x.example', timeoutMs: 5000);
    expect(r.ok, isTrue);
    expect(r.delay, 42);
  });

  test('ошибка ядра (свой таймаут замера) проходит как есть', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => {'delay': 0, 'error': 'context deadline exceeded'});
    final r = await CcChannel.instance
        .urlTestOutbound('n', link: 'https://x.example', timeoutMs: 5000);
    expect(r.error, 'context deadline exceeded');
  });
}
