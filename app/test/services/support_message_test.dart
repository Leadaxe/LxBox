// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/support/active_time_tracker.dart';
import 'package:lxbox/services/support/support_message.dart';
import 'package:lxbox/services/support/support_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
}

/// §105 — support message: decide-логика, fetch/кэш, snooze/dismiss,
/// ActiveTimeTracker.
void main() {
  late Directory tempDir;

  SupportMessage msg({
    String id = 'c1',
    int minHours = 3,
    int minSessionMin = 5,
    int snoozeHours = 10,
  }) =>
      SupportMessage(
        id: id,
        minActiveHours: minHours,
        minSessionMinutes: minSessionMin,
        snoozeActiveHours: snoozeHours,
        title: 't',
        message: 'm',
        links: const [('⭐ Repo', 'https://example.com')],
      );

  // Текущая сессия заведомо выше порога — для кейсов, проверяющих другие оси.
  const liveSession = 99999;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('support_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SupportState.I.resetCacheForTesting();
    ActiveTimeTracker.I.resetForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // AppLog async write race — см. settings_storage_test.
    }
  });

  group('decide (pure)', () {
    test('порог: 2ч59м → false, ровно 3ч → true', () {
      expect(
        SupportMessageService.decide(
            m: msg(),
            totalActiveSeconds: 3 * 3600 - 60,
            currentSessionSeconds: liveSession,
            dismissedId: '',
            snoozeAfterSeconds: 0),
        false,
      );
      expect(
        SupportMessageService.decide(
            m: msg(),
            totalActiveSeconds: 3 * 3600,
            currentSessionSeconds: liveSession,
            dismissedId: '',
            snoozeAfterSeconds: 0),
        true,
      );
    });

    test('dismiss по id кампании; новая кампания показывается', () {
      expect(
        SupportMessageService.decide(
            m: msg(id: 'c1'),
            totalActiveSeconds: 99999,
            currentSessionSeconds: liveSession,
            dismissedId: 'c1',
            snoozeAfterSeconds: 0),
        false,
      );
      expect(
        SupportMessageService.decide(
            m: msg(id: 'c2'),
            totalActiveSeconds: 99999,
            currentSessionSeconds: liveSession,
            dismissedId: 'c1',
            snoozeAfterSeconds: 0),
        true,
      );
    });

    test('session-gate: VPN не активен / <5мин → false даже при 100ч total', () {
      // Накопил уйму суммарного, но прямо сейчас туннель выключен.
      expect(
        SupportMessageService.decide(
            m: msg(),
            totalActiveSeconds: 100 * 3600,
            currentSessionSeconds: 0,
            dismissedId: '',
            snoozeAfterSeconds: 0),
        false,
        reason: 'не пользуется сейчас',
      );
      // Только что подключился (4 мин) — рано.
      expect(
        SupportMessageService.decide(
            m: msg(minSessionMin: 5),
            totalActiveSeconds: 100 * 3600,
            currentSessionSeconds: 4 * 60,
            dismissedId: '',
            snoozeAfterSeconds: 0),
        false,
      );
      // Сессия 5 мин ровно — порог пройден.
      expect(
        SupportMessageService.decide(
            m: msg(minSessionMin: 5),
            totalActiveSeconds: 100 * 3600,
            currentSessionSeconds: 5 * 60,
            dismissedId: '',
            snoozeAfterSeconds: 0),
        true,
      );
    });

    test('snooze: false до порога, true после', () {
      // «Позже» на 3ч → snooze_after = 13ч.
      const snoozeAfter = 13 * 3600;
      expect(
        SupportMessageService.decide(
            m: msg(),
            totalActiveSeconds: 12 * 3600,
            currentSessionSeconds: liveSession,
            dismissedId: '',
            snoozeAfterSeconds: snoozeAfter),
        false,
      );
      expect(
        SupportMessageService.decide(
            m: msg(),
            totalActiveSeconds: 13 * 3600,
            currentSessionSeconds: liveSession,
            dismissedId: '',
            snoozeAfterSeconds: snoozeAfter),
        true,
      );
    });
  });

  group('SupportMessage.fromJson', () {
    test('полный JSON парсится', () {
      final m = SupportMessage.fromJson({
        'id': 'support-2026-06',
        'min_active_hours': 3,
        'snooze_active_hours': 10,
        'title': 'Привет!',
        'message': 'Текст',
        'links': [
          {'label': '⭐ A', 'url': 'https://a'},
          {'label': '💰 B', 'url': 'https://b'},
        ],
      })!;
      expect(m.id, 'support-2026-06');
      expect(m.minActiveHours, 3);
      expect(m.links, hasLength(2));
      expect(m.links.first, ('⭐ A', 'https://a'));
    });

    test('malformed → null, не падает', () {
      expect(SupportMessage.fromJson('garbage'), isNull);
      expect(SupportMessage.fromJson({'no_id': true}), isNull);
      expect(SupportMessage.fromJson(null), isNull);
    });

    test('битые links скипаются, дефолты порогов', () {
      final m = SupportMessage.fromJson({
        'id': 'x',
        'links': [
          {'label': 'ok', 'url': 'https://ok'},
          {'label': '', 'url': 'https://no-label'},
          'garbage',
        ],
      })!;
      expect(m.links, hasLength(1));
      expect(m.minActiveHours, 3);
      expect(m.snoozeActiveHours, 10);
    });
  });

  group('fetchOrCached', () {
    final body = jsonEncode({
      'id': 'net-1',
      'title': 't',
      'message': 'm',
      'links': [
        {'label': 'l', 'url': 'https://u'}
      ],
    });

    test('200 → парс + кэш; следующий офлайн-фейл читает кэш', () async {
      final svc = SupportMessageService.I;
      svc.httpClientForTesting =
          MockClient((req) async => http.Response(body, 200));
      final m1 = await svc.fetchOrCached();
      expect(m1!.id, 'net-1');

      // Сеть умерла → из кэша.
      svc.httpClientForTesting =
          MockClient((req) async => throw const SocketException('down'));
      final m2 = await svc.fetchOrCached();
      expect(m2!.id, 'net-1');
    });

    test('ни сети, ни кэша → null', () async {
      final svc = SupportMessageService.I;
      svc.httpClientForTesting =
          MockClient((req) async => http.Response('err', 500));
      expect(await svc.fetchOrCached(), isNull);
    });
  });

  group('snooze / dismiss персист', () {
    test('snooze поднимает порог от текущего total', () async {
      final svc = SupportMessageService.I;
      await SupportState.I.set('active_seconds', 3 * 3600);
      expect(await svc.shouldShow(msg(), currentSessionSeconds: liveSession), true);
      await svc.snooze(msg());
      expect(await svc.shouldShow(msg(), currentSessionSeconds: liveSession), false);
      // Доработал ещё 10ч активного времени → снова показ.
      await SupportState.I.set('active_seconds', 13 * 3600);
      expect(await svc.shouldShow(msg(), currentSessionSeconds: liveSession), true);
    });

    test('dismissForever гасит кампанию навсегда', () async {
      final svc = SupportMessageService.I;
      await SupportState.I.set('active_seconds', 99 * 3600);
      await svc.dismissForever(msg(id: 'c1'));
      expect(await svc.shouldShow(msg(id: 'c1'), currentSessionSeconds: liveSession), false);
      expect(await svc.shouldShow(msg(id: 'c2'), currentSessionSeconds: liveSession), true);
    });
  });

  group('ActiveTimeTracker', () {
    test('totalSeconds = persisted + live-хвост; disconnect доливает',
        () async {
      await SupportState.I.set('active_seconds', 100);
      final t = ActiveTimeTracker.I;
      expect(await t.totalSeconds(), 100);

      await t.onTunnelChanged(true);
      // live-хвост ≥ 0 — total не уменьшается.
      expect(await t.totalSeconds(), greaterThanOrEqualTo(100));

      await t.onTunnelChanged(false);
      // После disconnect persisted ≥ 100 (delta могла быть 0 секунд).
      expect(await SupportState.I.getInt('active_seconds'),
          greaterThanOrEqualTo(100));
      // Сессия закрыта — повторный disconnect no-op.
      await t.onTunnelChanged(false);
    });
  });
}
