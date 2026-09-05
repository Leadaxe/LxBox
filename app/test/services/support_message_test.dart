// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/settings_storage.dart';
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

/// §356 — support-лента: pick-логика (очередь/since_version/baseline),
/// fromJson (i18n), fetch/кэш, markRead/snooze, ActiveTimeTracker (native
/// uptime + legacy).
void main() {
  late Directory tempDir;

  const en = SupportContent(title: 't-en', message: 'm-en', links: []);

  SupportMessage msg({
    String id = 'a',
    String since = '1.0.0',
    bool skip = false,
    int minHours = 3,
    int minSessionMin = 5,
    Map<String, SupportContent>? i18n,
  }) =>
      SupportMessage(
        id: id,
        sinceVersion: since,
        skip: skip,
        minActiveHours: minHours,
        minSessionMinutes: minSessionMin,
        i18n: i18n ?? const {'en': en},
      );

  SupportFeed feed(List<SupportMessage> messages, {int snoozeHours = 10}) =>
      SupportFeed(snoozeActiveHours: snoozeHours, messages: messages);

  // Текущая сессия заведомо выше порога — для кейсов про другие оси.
  const liveSession = 99999;

  SupportMessage? pick(
    SupportFeed f, {
    String appVersion = '2.20.0',
    Map<String, String> read = const {},
    int total = 1000 * 3600,
    int baseline = 0,
    int session = liveSession,
    int snoozeAfter = 0,
  }) =>
      SupportMessageService.pick(
        feed: f,
        appVersion: appVersion,
        read: read,
        totalActiveSeconds: total,
        baselineSeconds: baseline,
        currentSessionSeconds: session,
        snoozeAfterSeconds: snoozeAfter,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('support_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SupportState.I.resetCacheForTesting();
    ActiveTimeTracker.I.resetForTesting();
    SupportMessageService.I.appVersionForTesting = '2.20.0';
    SupportMessageService.I.httpClientForTesting = null;
    // §422 — сеть за лентой открыта только с согласия на проверку обновлений;
    // сетевые кейсы ниже считают, что оно дано.
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.setAutoCheckUpdates(true);
  });

  tearDown(() async {
    SupportMessageService.I.appVersionForTesting = null;
    SupportMessageService.I.httpClientForTesting = null;
    ActiveTimeTracker.I.resetForTesting();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // AppLog async write race — см. settings_storage_test.
    }
  });

  group('pick (pure)', () {
    test('порядок ленты: первое непрочитанное; прочитанные перешагиваются', () {
      final f = feed([msg(id: 'a'), msg(id: 'b'), msg(id: 'c')]);
      expect(pick(f)!.id, 'a');
      expect(pick(f, read: {'a': '2.20.0'})!.id, 'b');
      expect(pick(f, read: {'a': '2.20.0', 'b': '2.20.0'})!.id, 'c');
      expect(pick(f, read: {'a': '2.20.0', 'b': '2.20.0', 'c': '2.20.0'}),
          isNull);
    });

    test('очередь строгая: гейт первого непрочитанного блокирует всю ленту',
        () {
      // a требует 100ч от baseline, b — 1ч. Наработано 50ч → a не готово,
      // b НЕ показывается (вперёд не перескакиваем).
      final f = feed([msg(id: 'a', minHours: 100), msg(id: 'b', minHours: 1)]);
      expect(pick(f, total: 50 * 3600), isNull);
    });

    test('baseline: порог считается от точки отсчёта, не от нуля', () {
      final f = feed([msg(id: 'a', minHours: 3)]);
      // total огромный, но baseline рядом → не готово.
      expect(pick(f, total: 500 * 3600, baseline: 498 * 3600), isNull);
      // Ровно 3ч от baseline → показ.
      expect(pick(f, total: 501 * 3600, baseline: 498 * 3600)!.id, 'a');
    });

    test('since_version: версии старше не видят (перешагиваем к следующему)',
        () {
      final f = feed([msg(id: 'new', since: '2.21.0'), msg(id: 'old')]);
      expect(pick(f, appVersion: '2.20.0')!.id, 'old');
      expect(pick(f, appVersion: '2.21.0')!.id, 'new');
    });

    test('бамп since_version выше прочитанной версии → повторный показ', () {
      // Прочитано на 2.20.0; автор поднял since до 2.21.0.
      final f = feed([msg(id: 'a', since: '2.21.0')]);
      // Юзер ещё на 2.20.0 → сообщение невидимо.
      expect(pick(f, appVersion: '2.20.0', read: {'a': '2.20.0'}), isNull);
      // Обновился до 2.21.0 → непрочитанное заново.
      expect(pick(f, appVersion: '2.21.0', read: {'a': '2.20.0'})!.id, 'a');
      // Прочитал на 2.21.0 → снова тишина (и после следующих обновлений).
      expect(pick(f, appVersion: '2.21.0', read: {'a': '2.21.0'}), isNull);
      expect(pick(f, appVersion: '2.22.0', read: {'a': '2.21.0'}), isNull);
    });

    test('обновление приложения САМО не распрочитывает', () {
      final f = feed([msg(id: 'a', since: '2.0.0')]);
      expect(pick(f, appVersion: '2.25.0', read: {'a': '2.20.0'}), isNull);
    });

    test('skip выводит из ротации', () {
      final f = feed([msg(id: 'a', skip: true), msg(id: 'b')]);
      expect(pick(f)!.id, 'b');
    });

    test('session-gate: VPN не активен / короткая сессия → null', () {
      final f = feed([msg(id: 'a', minSessionMin: 5)]);
      expect(pick(f, session: 0), isNull, reason: 'не пользуется сейчас');
      expect(pick(f, session: 4 * 60), isNull);
      expect(pick(f, session: 5 * 60)!.id, 'a');
    });

    test('глобальный снуз глушит всю ленту', () {
      final f = feed([msg(id: 'a'), msg(id: 'b')]);
      expect(pick(f, total: 12 * 3600, snoozeAfter: 13 * 3600), isNull);
      expect(pick(f, total: 13 * 3600, snoozeAfter: 13 * 3600)!.id, 'a');
    });
  });

  group('fromJson', () {
    Map<String, dynamic> msgJson(String id, {Map<String, dynamic>? extra}) => {
          'id': id,
          'i18n': {
            'en': {'title': 't', 'message': 'm'},
          },
          ...?extra,
        };

    test('feed парсится, дефолты порогов/снуза', () {
      final f = SupportFeed.fromJson({
        'messages': [msgJson('a')],
      })!;
      expect(f.snoozeActiveHours, 10);
      expect(f.messages, hasLength(1));
      final m = f.messages.first;
      expect(m.sinceVersion, '0.0.0');
      expect(m.skip, false);
      expect(m.minActiveHours, 3);
      expect(m.minSessionMinutes, 5);
    });

    test('сообщение без en-блока отбрасывается целиком', () {
      final f = SupportFeed.fromJson({
        'messages': [
          {
            'id': 'ru-only',
            'i18n': {
              'ru': {'title': 'т', 'message': 'м'},
            },
          },
          msgJson('ok'),
        ],
      })!;
      expect(f.messages.map((m) => m.id), ['ok']);
    });

    test('contentFor: локаль → блок, нет блока → фолбэк en', () {
      final f = SupportFeed.fromJson({
        'messages': [
          {
            'id': 'a',
            'i18n': {
              'en': {'title': 't-en', 'message': 'm-en'},
              'ru': {
                'title': 'т-ру',
                'message': 'м-ру',
                'links': [
                  {'label': 'кнопка', 'url': 'https://ru'},
                ],
              },
            },
          },
        ],
      })!;
      final m = f.messages.first;
      expect(m.contentFor('ru').title, 'т-ру');
      final link = m.contentFor('ru').links.single;
      expect((link.label, link.url), ('кнопка', 'https://ru'));
      expect(link.markRead, true, reason: 'дефолт mark_read');
      expect(m.contentFor('en').title, 't-en');
      expect(m.contentFor('de').title, 't-en', reason: 'фолбэк en');
    });

    test('§357: mark_read и read_delay_seconds парсятся, дефолты живут', () {
      final f = SupportFeed.fromJson({
        'messages': [
          {
            'id': 'a',
            'read_delay_seconds': 3,
            'i18n': {
              'en': {
                'title': 't',
                'message': 'm',
                'links': [
                  {'label': 'nav', 'url': 'lxbox://route:dns', 'mark_read': false},
                  {'label': 'ext', 'url': 'https://x'},
                ],
              },
            },
          },
          {
            'id': 'b',
            'i18n': {
              'en': {'title': 't', 'message': 'm'},
            },
          },
        ],
      })!;
      final a = f.messages.first;
      expect(a.readDelaySeconds, 3);
      expect(a.i18n['en']!.links[0].markRead, false);
      expect(a.i18n['en']!.links[1].markRead, true);
      expect(f.messages[1].readDelaySeconds, 10, reason: 'дефолт таймера');
    });

    test('битые links скипаются; malformed → null, не падает', () {
      final f = SupportFeed.fromJson({
        'messages': [
          {
            'id': 'a',
            'i18n': {
              'en': {
                'title': 't',
                'message': 'm',
                'links': [
                  {'label': 'ok', 'url': 'https://ok'},
                  {'label': '', 'url': 'https://no-label'},
                  'garbage',
                ],
              },
            },
          },
        ],
      })!;
      expect(f.messages.first.i18n['en']!.links, hasLength(1));

      expect(SupportFeed.fromJson('garbage'), isNull);
      expect(SupportFeed.fromJson({'no_messages': true}), isNull);
      expect(SupportFeed.fromJson(null), isNull);
    });
  });

  group('fetchOrCached', () {
    final body = jsonEncode({
      'snooze_active_hours': 7,
      'messages': [
        {
          'id': 'net-1',
          'i18n': {
            'en': {'title': 't', 'message': 'm'},
          },
        },
      ],
    });

    test('200 → парс + кэш; следующий офлайн-фейл читает кэш', () async {
      final svc = SupportMessageService.I;
      svc.httpClientForTesting =
          MockClient((req) async => http.Response(body, 200));
      final f1 = await svc.fetchOrCached();
      expect(f1!.messages.single.id, 'net-1');
      expect(f1.snoozeActiveHours, 7);

      // Сеть умерла → из кэша.
      svc.httpClientForTesting =
          MockClient((req) async => throw const SocketException('down'));
      final f2 = await svc.fetchOrCached();
      expect(f2!.messages.single.id, 'net-1');
    });

    test('ни сети, ни кэша → bundled-копия docs/support.json (§422)', () async {
      final svc = SupportMessageService.I;
      svc.httpClientForTesting =
          MockClient((req) async => http.Response('err', 500));
      final f = await svc.fetchOrCached();
      expect(f, isNotNull);
      expect(f!.messages, isNotEmpty);
      expect(f.messages.first.id, '001-welcome-guide');
    });

    test('§422: без согласия на обновления — ни одного запроса, читаем кэш',
        () async {
      final svc = SupportMessageService.I;
      // Сначала с согласием — кладём кэш.
      svc.httpClientForTesting =
          MockClient((req) async => http.Response(body, 200));
      expect((await svc.fetchOrCached())!.messages.single.id, 'net-1');

      await SettingsStorage.setAutoCheckUpdates(false);
      var calls = 0;
      svc.httpClientForTesting = MockClient((req) async {
        calls++;
        return http.Response(body, 200);
      });
      final f = await svc.fetchOrCached();
      expect(calls, 0, reason: 'сеть закрыта — клиент не должен вызываться');
      expect(f!.messages.single.id, 'net-1', reason: 'кэш, не asset');
    });

    test('§422: без согласия и без кэша — bundled-копия, сеть не трогается',
        () async {
      final svc = SupportMessageService.I;
      await SettingsStorage.setAutoCheckUpdates(false);
      var calls = 0;
      svc.httpClientForTesting = MockClient((req) async {
        calls++;
        return http.Response(body, 200);
      });
      final f = await svc.fetchOrCached();
      expect(calls, 0);
      expect(f!.messages.first.id, '001-welcome-guide');
      // asset не пишется в кэш — при появлении согласия придёт свежая лента.
      expect(await SupportState.I.getString('cache_json'), isEmpty);
    });
  });

  group('nextToShow: baseline-персист', () {
    test('смена версии приложения сдвигает baseline (анти-спам обновления)',
        () async {
      final svc = SupportMessageService.I;
      final f = feed([msg(id: 'a', minHours: 3)]);
      // Наработано 500ч на версии 2.20.0, baseline с первого вызова.
      await SupportState.I.set('active_seconds', 500 * 3600);
      expect(await svc.nextToShow(f, currentSessionSeconds: liveSession),
          isNull, reason: 'первый вызов ставит baseline=500ч — не готово');
      // Доработал 3ч на той же версии → показ.
      await SupportState.I.set('active_seconds', 503 * 3600);
      expect(
          (await svc.nextToShow(f, currentSessionSeconds: liveSession))!.id,
          'a');
      // «Обновился» → baseline сдвинулся → снова ждать 3ч.
      svc.appVersionForTesting = '2.21.0';
      expect(await svc.nextToShow(f, currentSessionSeconds: liveSession),
          isNull);
      await SupportState.I.set('active_seconds', 506 * 3600);
      expect(
          (await svc.nextToShow(f, currentSessionSeconds: liveSession))!.id,
          'a');
    });

    test('markRead: версия в read + сдвиг baseline → следующее ждёт своё',
        () async {
      final svc = SupportMessageService.I;
      final f = feed([msg(id: 'a', minHours: 0), msg(id: 'b', minHours: 3)]);
      await SupportState.I.set('active_seconds', 100 * 3600);
      final first =
          await svc.nextToShow(f, currentSessionSeconds: liveSession);
      expect(first!.id, 'a');
      await svc.markRead(first);
      expect(await SupportState.I.getStringMap('read'), {'a': '2.20.0'});
      // b ждёт 3ч от момента прочтения a.
      expect(await svc.nextToShow(f, currentSessionSeconds: liveSession),
          isNull);
      await SupportState.I.set('active_seconds', 103 * 3600);
      expect(
          (await svc.nextToShow(f, currentSessionSeconds: liveSession))!.id,
          'b');
    });

    test('snooze поднимает порог от текущего total; baseline не трогает',
        () async {
      final svc = SupportMessageService.I;
      final f = feed([msg(id: 'a', minHours: 0)], snoozeHours: 10);
      await SupportState.I.set('active_seconds', 3 * 3600);
      expect((await svc.nextToShow(f, currentSessionSeconds: liveSession))!.id,
          'a');
      await svc.snooze(f);
      expect(await svc.nextToShow(f, currentSessionSeconds: liveSession),
          isNull);
      // Доработал 10ч активного времени → снова показ (baseline не двигался).
      await SupportState.I.set('active_seconds', 13 * 3600);
      expect((await svc.nextToShow(f, currentSessionSeconds: liveSession))!.id,
          'a');
    });
  });

  group('ActiveTimeTracker — native uptime (§356)', () {
    test('доливка delta по нативному аптайму (переживает мёртвый UI)',
        () async {
      final t = ActiveTimeTracker.I;
      var uptimeMs = 30 * 60 * 1000; // 30 мин
      t.uptimeMsProvider = () async => uptimeMs;

      expect(await t.totalSeconds(), 30 * 60);
      // «Смахнул, VPN отработал ещё 5ч, открыл приложение».
      uptimeMs += 5 * 3600 * 1000;
      expect(await t.totalSeconds(), 30 * 60 + 5 * 3600);
      // Повторный вызов без роста аптайма не задваивает.
      expect(await t.totalSeconds(), 30 * 60 + 5 * 3600);
    });

    test('рестарт туннеля: uptime < credited → новая сессия с нуля', () async {
      final t = ActiveTimeTracker.I;
      var uptimeMs = 2 * 3600 * 1000;
      t.uptimeMsProvider = () async => uptimeMs;
      expect(await t.totalSeconds(), 2 * 3600);

      // Туннель перезапустился, новая сессия 10 мин.
      uptimeMs = 10 * 60 * 1000;
      expect(await t.totalSeconds(), 2 * 3600 + 10 * 60);
    });

    test('disconnect сбрасывает счётчик сессии', () async {
      final t = ActiveTimeTracker.I;
      var uptimeMs = 3600 * 1000;
      t.uptimeMsProvider = () async => uptimeMs;
      expect(await t.totalSeconds(), 3600);

      await t.onTunnelChanged(false);
      expect(await SupportState.I.getInt('session_credited'), 0);
      // Новая сессия зачисляется с нуля.
      uptimeMs = 5 * 60 * 1000;
      await t.onTunnelChanged(true);
      expect(await SupportState.I.getInt('active_seconds'), 3600 + 5 * 60);
    });

    test('провайдер бросает → тихо пропускаем, доливка при следующем вызове',
        () async {
      final t = ActiveTimeTracker.I;
      var fail = true;
      t.uptimeMsProvider = () async {
        if (fail) throw Exception('direction down');
        return 3600 * 1000;
      };
      expect(await t.totalSeconds(), 0);
      fail = false;
      expect(await t.totalSeconds(), 3600);
    });
  });

  group('ActiveTimeTracker — legacy wall-clock (без провайдера)', () {
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
