import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/diagnostics/node_diagnostics_runner.dart';
import 'package:lxbox/services/platform_channels.dart';

/// §392 — раннер диагностики узла: выбор ветки probe/live по состоянию VPN,
/// probe-сессия поднимается и ГАСИТСЯ, узел-группа отсекается до вызова ядра.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformChannels.methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const uri = 'vless://u1@h1.example:443?type=ws&security=tls#Alpha';

  /// Парс URI в ноду тем же путём, что и продовый код (FolderMember).
  NodeSpec nodeOf(String raw) => FolderMember(raw: raw).node!;

  /// Мок native-стороны: ведёт журнал вызовов, отвечает по методу.
  ///
  /// [vpnStatus] — WIRE-литерал native ('Started'/'Stopped'), а не имя
  /// TunnelStatus: `fromNative` мапит только их, всё прочее → `unknown`,
  /// и ветка молча ушла бы в live.
  List<MethodCall> installHandler({
    required String vpnStatus,
    Map<String, dynamic>? getUrlReply,
    String probeStartError = '',
  }) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getVpnStatus':
          return vpnStatus;
        case 'probeStart':
          return probeStartError;
        case 'probeStop':
          return null;
        case 'probeGetUrl':
        case 'ccGetUrlViaOutbound':
          return getUrlReply ??
              {'status': 200, 'content': 'warp=on', 'error': ''};
        default:
          return null;
      }
    });
    return calls;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('§392 — выбор ветки по состоянию VPN', () {
    test('VPN выключен → probe-сессия, и она ГАСИТСЯ после ответа', () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      final outcome = await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://1.1.1.1/cdn-cgi/trace',
        liveTag: 'pr: Alpha',
      );

      expect(outcome.source, DiagnosticSource.probe);
      expect(outcome.result.content, 'warp=on');
      final methods = calls.map((c) => c.method).toList();
      expect(methods, containsAllInOrder(
          ['probeStart', 'probeGetUrl', 'probeStop']));
      // Боевой клиент в этой ветке не трогаем вовсе.
      expect(methods, isNot(contains('ccGetUrlViaOutbound')));
    });

    test('VPN включён → боевое ядро, probe-сессия НЕ поднимается', () async {
      final calls = installHandler(vpnStatus: 'Started');
      final outcome = await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://1.1.1.1/cdn-cgi/trace',
        liveTag: 'pr: Alpha',
      );

      expect(outcome.source, DiagnosticSource.live);
      final methods = calls.map((c) => c.method).toList();
      expect(methods, contains('ccGetUrlViaOutbound'));
      expect(methods, isNot(contains('probeStart')));
    });

    test('боевая ветка адресует узел ОТОБРАЖАЕМЫМ тегом (с префиксом)',
        () async {
      final calls = installHandler(vpnStatus: 'Started');
      await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://example.org',
        liveTag: 'pr: Alpha',
      );
      final call =
          calls.firstWhere((c) => c.method == 'ccGetUrlViaOutbound');
      // В живом конфиге узлы подписки живут под display-тегом; bare там
      // не резолвится — ядро вернуло бы «outbound not found».
      expect((call.arguments as Map)['tag'], 'pr: Alpha');
    });

    test('probe-ветка адресует узел тегом ИЗ probe-конфига (bare)', () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://example.org',
        liveTag: 'pr: Alpha',
      );
      final call = calls.firstWhere((c) => c.method == 'probeGetUrl');
      expect((call.arguments as Map)['tag'], 'Alpha');
    });
  });

  group('§392 — параметры вызова', () {
    test('таймаут и кламп тела прокидываются в ядро', () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://example.org',
        liveTag: 'pr: Alpha',
      );
      final args =
          calls.firstWhere((c) => c.method == 'probeGetUrl').arguments as Map;
      expect(args['timeoutMs'], NodeDiagnosticsRunner.kTimeoutMs);
      expect(args['maxBytes'], NodeDiagnosticsRunner.kMaxBytes);
    });
  });

  group('§392 — прогон невозможен', () {
    test('узел-группа (§322) → DiagnosticUnavailable.isGroup, ядро не зовётся',
        () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      final group = AutoSelectSpec(id: 'g-1', tag: 'Auto', label: 'Auto');
      expect(group.isGroup, isTrue);

      // Группа — не соединение: своего outbound'а у неё нет, а её заготовка
      // urltest с пустым outbounds роняет ВЕСЬ probe-конфиг («missing tags»).
      // Поэтому отсекаем до старта сессии.
      await expectLater(
        NodeDiagnosticsRunner()
            .run(group, url: 'https://example.org', liveTag: 'pr: Auto'),
        throwsA(isA<DiagnosticUnavailable>()
            .having((e) => e.isGroup, 'isGroup', isTrue)),
      );
      expect(calls.map((c) => c.method), isNot(contains('probeStart')));
      expect(calls.map((c) => c.method), isNot(contains('probeGetUrl')));
    });

    test('node == null + VPN выключен → no_node, ядро не зовётся', () async {
      final calls = installHandler(vpnStatus: 'Stopped');
      // Экран просмотра outbound'а знает узел только по тегу собранного
      // конфига — probe-конфиг собирать не из чего.
      await expectLater(
        NodeDiagnosticsRunner()
            .run(null, url: 'https://example.org', liveTag: 'pr: Alpha'),
        throwsA(isA<DiagnosticUnavailable>()
            .having((e) => e.reason, 'reason', 'no_node')),
      );
      expect(calls.map((c) => c.method), isNot(contains('probeStart')));
    });

    test('node == null + VPN включён → боевая ветка работает', () async {
      final calls = installHandler(vpnStatus: 'Started');
      final outcome = await NodeDiagnosticsRunner()
          .run(null, url: 'https://example.org', liveTag: 'pr: Alpha');
      expect(outcome.source, DiagnosticSource.live);
      expect(calls.map((c) => c.method), contains('ccGetUrlViaOutbound'));
    });

    test('probeStart вернул ошибку → DiagnosticUnavailable, probeGetUrl не зван',
        () async {
      final calls = installHandler(
        vpnStatus: 'Stopped',
        probeStartError: 'VPN is running — test uses the live tunnel instead',
      );
      await expectLater(
        NodeDiagnosticsRunner().run(
          nodeOf(uri),
          url: 'https://example.org',
          liveTag: 'pr: Alpha',
        ),
        throwsA(isA<DiagnosticUnavailable>()),
      );
      expect(calls.map((c) => c.method), isNot(contains('probeGetUrl')));
    });

    test('несостоявшийся обмен — это РЕЗУЛЬТАТ с error, а не бросок', () async {
      installHandler(
        vpnStatus: 'Started',
        getUrlReply: {'error': 'dial tcp: i/o timeout'},
      );
      final outcome = await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://example.org',
        liveTag: 'pr: Alpha',
      );
      // Раннер бросает только когда прогон невозможен в принципе; отказ
      // соединения — обычный итог, который UI показывает текстом ошибки.
      expect(outcome.ok, false);
      expect(outcome.result.error, contains('timeout'));
    });

    test('не-2xx доезжает как результат (429 не делает узел нерабочим)',
        () async {
      installHandler(
        vpnStatus: 'Started',
        getUrlReply: {
          'status': 429,
          'content': '{"error":"rate limit"}',
          'error': '',
        },
      );
      final outcome = await NodeDiagnosticsRunner().run(
        nodeOf(uri),
        url: 'https://api.ip2location.io/',
        liveTag: 'pr: Alpha',
      );
      expect(outcome.ok, true);
      expect(outcome.result.status, 429);
    });
  });
}
