// ignore_for_file: depend_on_referenced_packages

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/profiler.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §048 P17 (028) — `/profiler/live*` читают и управляют ТЕМ ЖЕ синглтоном
/// `TrafficProfiler.I`, что и Live tab: тот же лог, тот же start/stop,
/// JSON события несёт сервер (outbound_chain), источник (process) и трассу
/// группы (извлекается из outbound_chain при наличии группы).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TrafficProfiler.I.resetForTesting();
  });

  DebugContext ctx() =>
      DebugContext(registry: DebugRegistry.I, appStartedAt: DateTime.utc(2026));

  DebugRequest req(String method, String pathAndQuery) => DebugRequest(
    method: method,
    uri: Uri.parse('http://127.0.0.1:9269$pathAndQuery'),
    headers: const {},
    body: Uint8List(0),
    receivedAt: DateTime.utc(2026),
  );

  test(
    '/profiler/live/start and /stop drive the same singleton as the screen',
    () async {
      expect(TrafficProfiler.I.isGlobalRecording, false);

      final startResp = await profilerHandler(
        req('POST', '/profiler/live/start'),
        ctx(),
      );
      final startBody = (startResp as JsonResponse).body as Map;
      expect(startBody['recording'], true);
      expect(
        TrafficProfiler.I.isGlobalRecording,
        true,
        reason: 'хендлер зовёт тот же startGlobalRecording, что и экран',
      );

      final stopResp = await profilerHandler(
        req('POST', '/profiler/live/stop'),
        ctx(),
      );
      final stopBody = (stopResp as JsonResponse).body as Map;
      expect(stopBody['recording'], false);
      expect(
        TrafficProfiler.I.isGlobalRecording,
        false,
        reason: 'хендлер зовёт тот же stopGlobalRecording, что и экран',
      );
    },
  );

  test('/profiler/live reads the same log the screen shows, with server, '
      'source and group trace in the event JSON', () async {
    TrafficProfiler.I.startGlobalRecording();
    TrafficProfiler.I.ingestForTest([
      const CcConnection(
        id: 'p17-a',
        network: 'tcp',
        domain: 'site.example',
        destination: '9.9.9.9:443',
        rule: 'rule_set=ru-domains',
        uplink: 10,
        downlink: 20,
        outbound: 'vpn-1',
        chains: ['[BL]-3', '✨auto', 'vpn-1'], // группы: трасса решения
        packageName: 'ru.tinkoff.investing', // источник (app)
        createdAt: 0,
        closedAt: 0,
      ),
    ]);

    // То, что видит экран — напрямую из синглтона.
    final screenBuf = TrafficProfiler.I.globalRollingBuffer;
    expect(screenBuf.length, 1);

    final resp = await profilerHandler(req('GET', '/profiler/live'), ctx());
    final body = (resp as JsonResponse).body as Map;
    final events = body['events'] as List;
    expect(
      events.length,
      screenBuf.length,
      reason: 'Debug API видит тот же буфер, что и экран',
    );

    final ev = events.single as Map;
    // Сервер + трасса группы — outbound_chain целиком (узел + группы).
    expect(ev['outbound_chain'], ['[BL]-3', '✨auto', 'vpn-1']);
    // Источник — package name приложения.
    expect(ev['process'], 'ru.tinkoff.investing');

    TrafficProfiler.I.stopGlobalRecording();
  });

  test(
    '/profiler/live/state mirrors the screen recording state and count',
    () async {
      TrafficProfiler.I.startGlobalRecording();
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'p17-b',
          network: 'tcp',
          domain: 'b.example',
          destination: '1.1.1.1:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct',
          packageName: 'com.app.b',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);

      final resp = await profilerHandler(
        req('GET', '/profiler/live/state'),
        ctx(),
      );
      final body = (resp as JsonResponse).body as Map;
      expect(body['recording'], TrafficProfiler.I.isGlobalRecording);
      expect(
        body['buffer_count'],
        TrafficProfiler.I.globalRollingBuffer.length,
      );

      TrafficProfiler.I.stopGlobalRecording();
    },
  );
}
