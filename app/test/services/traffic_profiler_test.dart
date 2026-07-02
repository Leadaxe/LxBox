// §044 — TrafficProfiler unit tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TrafficProfiler.I.resetForTesting();
  });

  group('TrafficProfiler — session lifecycle', () {
    test('start sets active', () async {
      final s = await TrafficProfiler.I.start('ru.tinkoff.investing');
      expect(s.targetPackage, 'ru.tinkoff.investing');
      expect(TrafficProfiler.I.isRecording, true);
      expect(TrafficProfiler.I.active!.id, s.id);
    });

    test('stop moves to completed', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      final s = await TrafficProfiler.I.stop();
      expect(s, isNotNull);
      expect(TrafficProfiler.I.isRecording, false);
      expect(TrafficProfiler.I.completed.length, 1);
      expect(TrafficProfiler.I.completed.first.id, s!.id);
    });

    test('start while active finalizes previous', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      await TrafficProfiler.I.start('org.telegram.messenger');
      expect(TrafficProfiler.I.completed.length, 1);
      expect(TrafficProfiler.I.completed.first.targetPackage,
          'ru.tinkoff.investing');
      expect(TrafficProfiler.I.active!.targetPackage, 'org.telegram.messenger');
    });

    test('completed ring-buffer cap = 5', () async {
      for (var i = 0; i < 7; i++) {
        await TrafficProfiler.I.start('app.$i');
        await TrafficProfiler.I.stop();
      }
      expect(TrafficProfiler.I.completed.length, 5);
      // Oldest (app.0, app.1) сброшены.
      final pkgs = TrafficProfiler.I.completed.map((s) => s.targetPackage);
      expect(pkgs.contains('app.0'), false);
      expect(pkgs.contains('app.6'), true);
    });

    test('delete removes from completed', () async {
      await TrafficProfiler.I.start('a');
      final s = await TrafficProfiler.I.stop();
      expect(TrafficProfiler.I.delete(s!.id), true);
      expect(TrafficProfiler.I.completed, isEmpty);
    });

    test('clearAll wipes completed', () async {
      for (var i = 0; i < 3; i++) {
        await TrafficProfiler.I.start('a$i');
        await TrafficProfiler.I.stop();
      }
      expect(TrafficProfiler.I.clearAll(), 3);
      expect(TrafficProfiler.I.completed, isEmpty);
    });
  });

  group('TrafficProfiler — log parsing', () {
    test('DNS chain attribution: CNAME-hops в answers, ip = финальный A',
        () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      // §180 — CNAME-цепочка приходит целиком в answers (type==5 hops + A),
      // packageName атрибутируется ИЗ ЯДРА (не connId-сшивка).
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'cdn.t-bank-app.ru',
          queryType: 1, // A
          rcode: 0,
          packageName: 'ru.tinkoff.investing',
          answers: [
            CcDnsAnswer(
                name: 'cdn.t-bank-app.ru',
                type: 5,
                rdata: 'cl-ead2c819.edgecdn.ru'),
            CcDnsAnswer(
                name: 'cl-ead2c819.edgecdn.ru', type: 1, rdata: '193.17.93.194'),
          ],
        ),
      ]);
      final session = TrafficProfiler.I.active!;
      // 1 dnsResolve event for the A record.
      final resolves = session.events
          .where((e) => e.kind == TrafficEventKind.dnsResolve)
          .toList();
      expect(resolves, hasLength(1));
      // event.domain атрибутируется на **исходный** запрошенный домен
      // (q.domain), не на финальный CNAME-target. CNAME hops собраны в
      // cnameChain (answers с type==5).
      expect(resolves.first.domain, 'cdn.t-bank-app.ru');
      expect(resolves.first.ip, '193.17.93.194');
      expect(resolves.first.cnameChain, ['cl-ead2c819.edgecdn.ru']);
      expect(resolves.first.process, 'ru.tinkoff.investing');
      // Aggregates: ключ — исходный domain.
      expect(session.byDomain.containsKey('cdn.t-bank-app.ru'), true);
    });

    test('§180-fix — ядро шлёт rdata ПОЛНОЙ RR-строкой → берём значение', () async {
      // device dev.72: DnsAnswer.rdata = "name TTL IN TYPE value" (НЕ голое
      // значение). ip = последнее поле A-записи; cname target — без trailing dot.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'google.com',
          queryType: 1,
          rcode: 0,
          packageName: 'ru.tinkoff.investing',
          answers: [
            CcDnsAnswer(
                name: 'yt3.ggpht.com',
                type: 5,
                rdata: 'yt3.ggpht.com. 204 IN CNAME wide-youtube.l.google.com.'),
            CcDnsAnswer(
                name: 'google.com',
                type: 1,
                rdata: 'google.com. 29 IN A 64.233.165.139'),
          ],
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.ip, '64.233.165.139', reason: 'A: последнее поле, не вся строка');
      expect(ev.cnameChain, ['wide-youtube.l.google.com'],
          reason: 'CNAME: target без trailing dot');
    });

    test('non-target package events are ignored', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      // §180 — packageName приходит ИЗ ЯДРА прямо в CcDnsQuery; чужой пакет
      // (verified non-target) дропается из session (_resolveForSession).
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'telegram.org',
          queryType: 1,
          rcode: 0,
          packageName: 'org.telegram.messenger',
          answers: [
            CcDnsAnswer(name: 'telegram.org', type: 1, rdata: '1.2.3.4'),
          ],
        ),
      ]);
      expect(TrafficProfiler.I.active!.events, isEmpty);
    });

    test('DNS fail produces dnsTimeout issue', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      // §180 — провал приходит как failed:true / rcode:-1 (нет ответа).
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'some.host',
          queryType: 1,
          rcode: -1,
          failed: true,
          error: 'context deadline exceeded',
          packageName: 'ru.tinkoff.investing',
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events.last;
      expect(ev.kind, TrafficEventKind.dnsFail);
      expect(ev.issues.first.kind, ConnectionIssueKind.dnsTimeout);
    });

    test('rc.10 — dnsServer/dnsServerType/outbound пробрасываются', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'github.com',
          queryType: 1,
          rcode: 0,
          packageName: 'ru.tinkoff.investing',
          dnsServer: 'https://1.1.1.1/dns-query',
          dnsServerType: 'https',
          outbound: ['🇫🇮Финляндия (vpn-1)'],
          answers: [
            CcDnsAnswer(name: 'github.com', type: 1, rdata: '140.82.121.3'),
          ],
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      // outbound → outboundChain (для routingLine «через какой сервер»).
      expect(ev.outboundChain, ['🇫🇮Финляндия (vpn-1)']);
      // dnsServer/тип → extra (для detail-sheet).
      expect(ev.extra?['dns_server'], 'https://1.1.1.1/dns-query');
      expect(ev.extra?['dns_server_type'], 'https');
    });

    test('rc.10 — cached (пустой outbound) → outboundChain пуст', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'cached.example',
          queryType: 1,
          rcode: 0,
          source: 'cached',
          packageName: 'ru.tinkoff.investing',
          // outbound пуст на cache-hit (нет сетевого пути).
          answers: [
            CcDnsAnswer(name: 'cached.example', type: 1, rdata: '1.2.3.4'),
          ],
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.outboundChain, isEmpty);
    });
  });

  group('TrafficProfiler — connection ingest (§168 CommandClient)', () {
    test('new tcp conn for target → tcpOpen event (no issue on open)',
        () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c1',
          network: 'tcp',
          domain: 'certs.t-bank-app.ru',
          destination: '81.222.127.186:443',
          rule: 'default',
          uplink: 0,
          downlink: 0,
          outbound: '🇫🇮Финляндия (vpn-1)',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      expect(s.events.length, 1);
      final ev = s.events.first;
      expect(ev.kind, TrafficEventKind.tcpOpen);
      expect(ev.domain, 'certs.t-bank-app.ru');
      expect(ev.ip, '81.222.127.186');
      expect(ev.port, 443);
      // На open issues не вычисляем — оба текущих типа (dnsTimeout,
      // tcpReset) релевантны close/dns-fail event'ам.
      expect(ev.issues, isEmpty);
    });

    test('non-target connection ignored', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c2',
          network: 'tcp',
          domain: 'tg.example',
          destination: '5.5.5.5:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct',
          packageName: 'org.telegram.messenger',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      expect(TrafficProfiler.I.active!.events, isEmpty);
    });

    test('non-target connection close also ignored (§160 — open/close '
        'attribution symmetry)', () async {
      // Регрессия: close чужого conn'а раньше писался в session безусловно
      // (open отбрасывался _resolveForSession, а close — нет) → в сессии
      // Telegram появлялись verified-tcpClose от youtube/imo и т.п.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'foreign1',
          network: 'tcp',
          domain: 'rr3.googlevideo.com',
          destination: '74.125.108.232:443',
          rule: '',
          uplink: 10,
          downlink: 20,
          outbound: 'direct',
          packageName: 'com.google.android.youtube',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      // open чужого — в сессию не попал.
      expect(TrafficProfiler.I.active!.events, isEmpty);
      // Закрываем его (пустой снапшот = conn пропал).
      TrafficProfiler.I.ingestForTest([]);
      // close тоже НЕ должен попасть (наследует inSession=false).
      expect(TrafficProfiler.I.active!.events, isEmpty,
          reason: 'close чужого conn не должен писаться в session');
    });

    test('closed connection emits tcpClose with duration', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c3',
          network: 'tcp',
          domain: 'cdn.t-bank-app.ru',
          destination: '193.17.93.194:443',
          rule: '',
          uplink: 100,
          downlink: 200,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      // Now drop it.
      TrafficProfiler.I.ingestForTest([]);
      final s = TrafficProfiler.I.active!;
      expect(s.events.length, 2);
      expect(s.events.last.kind, TrafficEventKind.tcpClose);
      expect(s.events.last.duration, isNotNull);
    });

    test('closed connection via closedAt>0 emits tcpClose (§168)', () async {
      // CC может прислать тот же conn с closedAt>0 (вместо пропадания) —
      // ingest трактует isClosed как «пропал» → закрываем.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c4',
          network: 'tcp',
          domain: 'api.t-bank-app.ru',
          destination: '193.17.93.195:443',
          rule: '',
          uplink: 100,
          downlink: 200,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      // Тот же conn, но closedAt>0 → ingest НЕ кладёт в seenIds → close.
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c4',
          network: 'tcp',
          domain: 'api.t-bank-app.ru',
          destination: '193.17.93.195:443',
          rule: '',
          uplink: 100,
          downlink: 200,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 1,
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      expect(s.events.last.kind, TrafficEventKind.tcpClose);
    });

    test('§176 — короткий conn сразу closedAt>0 → обе фазы (open+close)',
        () async {
      // FilterState(All): коротко-живущий conn может прийти СРАЗУ закрытым
      // (open проскочил между тиками). Раньше (`if isClosed continue`) терялся
      // целиком. Теперь профайлер видит и tcpOpen, и tcpClose.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'short1',
          network: 'tcp',
          domain: 'short.example',
          destination: '5.6.7.8:443',
          rule: '',
          uplink: 50,
          downlink: 80,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 1, // пришёл сразу закрытым
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final kinds = s.events.map((e) => e.kind).toList();
      expect(kinds, contains(TrafficEventKind.tcpOpen),
          reason: 'open не потерян');
      expect(kinds, contains(TrafficEventKind.tcpClose),
          reason: 'close эмитнут');
    });

    test('§176 — тот же closed conn 2 тика → ОДИН close (анти-дубль)', () async {
      // Ядро держит closed в FilterState(All) до 5 мин → приходит каждый тик.
      // Guard _closedHandled обрабатывает РОВНО раз.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      const closedConn = CcConnection(
        id: 'dup1',
        network: 'tcp',
        domain: 'dup.example',
        destination: '9.9.9.9:443',
        rule: '',
        uplink: 10,
        downlink: 20,
        outbound: 'direct-out',
        packageName: 'ru.tinkoff.investing',
        createdAt: 0,
        closedAt: 1,
      );
      TrafficProfiler.I.ingestForTest([closedConn]);
      TrafficProfiler.I.ingestForTest([closedConn]); // повтор (ядро держит 5мин)
      TrafficProfiler.I.ingestForTest([closedConn]); // ещё раз
      final s = TrafficProfiler.I.active!;
      final closes =
          s.events.where((e) => e.kind == TrafficEventKind.tcpClose).length;
      expect(closes, 1, reason: 'closed обработан ровно раз, не дублируется');
    });

    test('TCP RST early flagged on close (closed <1s, 0 bytes)', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'rst',
          network: 'tcp',
          domain: 'blocked.example',
          destination: '1.2.3.4:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      // Close immediately (within 1s, 0 bytes).
      TrafficProfiler.I.ingestForTest([]);
      final s = TrafficProfiler.I.active!;
      final closeEvent = s.events.last;
      expect(closeEvent.kind, TrafficEventKind.tcpClose);
      expect(
          closeEvent.issues.any((a) => a.kind == ConnectionIssueKind.tcpReset), true);
    });
  });

  group('TrafficProfiler — aggregates', () {
    test('byDomain sums bytes and counts connections', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'api.tinkoff.ru',
          queryType: 1,
          rcode: 0,
          packageName: 'ru.tinkoff.investing',
          answers: [
            CcDnsAnswer(name: 'api.tinkoff.ru', type: 1, rdata: '1.1.1.1'),
          ],
        ),
      ]);
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c5',
          network: 'tcp',
          domain: 'api.tinkoff.ru',
          destination: '1.1.1.1:443',
          rule: '',
          uplink: 1000,
          downlink: 5000,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final d = s.byDomain['api.tinkoff.ru']!;
      expect(d.connections, 1);
      expect(d.upBytes, 1000);
      expect(d.downBytes, 5000);
      expect(d.ips.contains('1.1.1.1'), true);
    });
  });

  group('TrafficProfiler — meta JSON', () {
    test('toMetaJson exposes counts', () async {
      final s = await TrafficProfiler.I.start('ru.tinkoff.investing');
      final j = s.toMetaJson();
      expect(j['target_package'], 'ru.tinkoff.investing');
      expect(j['session_id'], s.id);
      expect(j['events_count'], 0);
      expect(j['verbose'], false);
      expect(j['secondary_packages'], <String>[]);
      expect(j['unattributed_count'], 0);
    });
  });

  // ───── §048 regression: defensive parsing ─────────────────────────────

  group('TrafficProfiler — §048 DNS record-type semantics', () {
    test('HTTPS record DNS resolve is parsed with record_type=HTTPS', () async {
      await TrafficProfiler.I.start('com.android.chrome');
      // HTTPS record (HTTP/3 alt-svc discovery). queryType 65 → 'HTTPS'.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'example.com',
          queryType: 65, // HTTPS
          rcode: 0,
          packageName: 'com.android.chrome',
          answers: [
            CcDnsAnswer(
                name: 'example.com', type: 65, rdata: '1 . alpn=h2,h3'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      // Парсится с record_type=HTTPS.
      final dnsEvents =
          s.events.where((e) => e.kind == TrafficEventKind.dnsResolve).toList();
      expect(dnsEvents, hasLength(1));
      expect(dnsEvents.first.dnsRecordType, 'HTTPS');
      expect(dnsEvents.first.confidence, ConfidenceLevel.verified);
    });

    test('SVCB record DNS resolve is parsed', () async {
      await TrafficProfiler.I.start('com.android.chrome');
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: '_dns.example.com',
          queryType: 64, // SVCB
          rcode: 0,
          packageName: 'com.android.chrome',
          answers: [
            CcDnsAnswer(
                name: '_dns.example.com', type: 64, rdata: '1 . alpn=h2'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final ev = s.events.firstWhere(
          (e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.dnsRecordType, 'SVCB');
    });

    test('SOA record (NXDOMAIN) is parsed without IP', () async {
      await TrafficProfiler.I.start('com.android.chrome');
      // SOA-ответ (NXDOMAIN): queryType 6 → 'SOA', rcode 3, answer не A/AAAA.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'missing.example',
          queryType: 6, // SOA
          rcode: 3, // NXDOMAIN
          source: 'cached',
          packageName: 'com.android.chrome',
          answers: [
            CcDnsAnswer(
                name: 'missing.example', type: 6, rdata: 'ns1.example.com.'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final ev = s.events.firstWhere(
          (e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.dnsRecordType, 'SOA');
      // SOA не несёт IP — поле должно быть null.
      expect(ev.ip, isNull);
    });

    test('DNS fail with HTTPS record type — unattributed if no owner', () async {
      await TrafficProfiler.I.start('com.android.chrome');
      // packageName пуст → unattributed (нет атрибуции из ядра).
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: '2ip.io',
          queryType: 65, // HTTPS
          rcode: -1,
          failed: true,
          error: 'context deadline exceeded',
          // packageName: '' → unattributed
        ),
      ]);
      // Должно попасть в global unattributed events ring (не в session).
      expect(TrafficProfiler.I.globalUnattributedEvents, isNotEmpty);
      final ev = TrafficProfiler.I.globalUnattributedEvents.first;
      expect(ev.kind, TrafficEventKind.dnsFail);
      expect(ev.confidence, ConfidenceLevel.unattributed);
      expect(ev.dnsRecordType, 'HTTPS');
      expect(ev.domain, '2ip.io');
      expect(ev.shownBecause, isNotNull);
    });

    test('DNS fail in session (attributed) → verified dnsFail with record type',
        () async {
      await TrafficProfiler.I.start('com.android.chrome');
      // packageName из ядра → verified; queryType 1 → 'A'.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'example.com',
          queryType: 1, // A
          rcode: -1,
          failed: true,
          error: 'context deadline exceeded',
          packageName: 'com.android.chrome',
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final fail = s.events.firstWhere(
          (e) => e.kind == TrafficEventKind.dnsFail);
      expect(fail.confidence, ConfidenceLevel.verified);
      expect(fail.domain, 'example.com');
      expect(fail.dnsRecordType, 'A');
    });
  });

  // ───── §048 regression: multi-package UID + secondary packages ───────

  group('TrafficProfiler — §048 multi-package & secondary', () {
    test('multi-package UID `com.x.y, com.x.z` matches if ANY == target',
        () async {
      await TrafficProfiler.I.start('com.google.android.gms');
      // §180 — ядро может отдать несколько пакетов одного UID через запятую
      // прямо в packageName; _splitPackageNames матчит если ЛЮБОЙ == target.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'play.google.com',
          queryType: 1,
          rcode: 0,
          packageName: 'com.google.android.gms, com.google.android.gsf',
          answers: [
            CcDnsAnswer(name: 'play.google.com', type: 1, rdata: '1.2.3.4'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final dns = s.events.firstWhere(
          (e) => e.kind == TrafficEventKind.dnsResolve);
      expect(dns.confidence, ConfidenceLevel.verified);
      expect(dns.domain, 'play.google.com');
    });

    test('WebView subprocess matched via secondaryPackages', () async {
      await TrafficProfiler.I.start(
        'ru.tinkoff.investing',
        secondaryPackages: {'com.google.android.webview'},
      );
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'cdn.t-bank-app.ru',
          queryType: 1,
          rcode: 0,
          packageName: 'com.google.android.webview',
          answers: [
            CcDnsAnswer(name: 'cdn.t-bank-app.ru', type: 1, rdata: '5.6.7.8'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final dns = s.events.firstWhere(
          (e) => e.kind == TrafficEventKind.dnsResolve);
      expect(dns.confidence, ConfidenceLevel.secondary);
      expect(dns.matchedVia, 'secondary_packages');
    });

    test('UID-suffixed package name (com.x (10999)) matches target', () async {
      await TrafficProfiler.I.start('com.android.chrome');
      // CcConnection.packageName может нести UID в скобках (getProcessInfo).
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'c1',
          network: 'tcp',
          domain: 'www.google.com',
          destination: '1.2.3.4:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct',
          packageName: 'com.android.chrome (10999)',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      expect(s.events, isNotEmpty);
      expect(s.events.first.kind, TrafficEventKind.tcpOpen);
      expect(s.events.first.confidence, ConfidenceLevel.verified);
    });

    test('non-target, non-secondary process events are dropped from session',
        () async {
      await TrafficProfiler.I.start(
        'ru.tinkoff.investing',
        secondaryPackages: {'com.google.android.webview'},
      );
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'telegram.org',
          queryType: 1,
          rcode: 0,
          packageName: 'org.telegram.messenger',
          answers: [
            CcDnsAnswer(name: 'telegram.org', type: 1, rdata: '7.7.7.7'),
          ],
        ),
      ]);
      // session.events empty (Telegram не target и не secondary).
      expect(TrafficProfiler.I.active!.events, isEmpty);
      // Но в global rolling buffer'е — есть.
      expect(TrafficProfiler.I.globalRollingBuffer, isNotEmpty);
    });

    test('updateSecondaryPackages mutates active session', () async {
      final s = await TrafficProfiler.I.start('ru.tinkoff.investing');
      expect(s.secondaryPackages, isEmpty);
      final changed =
          TrafficProfiler.I.updateSecondaryPackages({'com.google.android.webview'});
      expect(changed, true);
      expect(s.secondaryPackages, {'com.google.android.webview'});
    });
  });

  // ───── §048 regression: pre-session backfill ──────────────────────────

  group('TrafficProfiler — §048 pre-session backfill', () {
    test('events 30s before start are backfilled into new session', () async {
      // Сначала эмулируем events системы БЕЗ active session — они должны
      // попасть в global rolling buffer. §180 — DNS-стрим обрабатывается
      // только при active session ИЛИ global recording; включаем последнее.
      final sub = TrafficProfiler.I.globalLiveStream().listen((_) {});
      TrafficProfiler.I.startGlobalRecording();

      // §180 — DNS приходит структурным событием; атрибуция packageName ИЗ ЯДРА.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'api.tinkoff.ru',
          queryType: 1,
          rcode: 0,
          packageName: 'ru.tinkoff.investing',
          answers: [
            CcDnsAnswer(name: 'api.tinkoff.ru', type: 1, rdata: '1.1.1.1'),
          ],
        ),
      ]);

      // Теперь стартуем session — backfill должен подобрать прошлый event.
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      final s = TrafficProfiler.I.active!;
      final backfilled = s.events.where((e) => e.backfilled).toList();
      expect(backfilled, isNotEmpty);
      expect(backfilled.first.domain, 'api.tinkoff.ru');
      expect(backfilled.first.confidence, ConfidenceLevel.verified);

      TrafficProfiler.I.stopGlobalRecording();
      await sub.cancel();
    });
  });

  // ───── §048 regression: confidence levels in JSON ────────────────────

  group('TrafficProfiler — §048 confidence in JSON output', () {
    test('TrafficEvent.toJson includes confidence + matched_via', () async {
      await TrafficProfiler.I.start(
        'ru.tinkoff.investing',
        secondaryPackages: {'com.google.android.webview'},
      );
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'cdn.example.com',
          queryType: 1,
          rcode: 0,
          packageName: 'com.google.android.webview',
          answers: [
            CcDnsAnswer(name: 'cdn.example.com', type: 1, rdata: '9.9.9.9'),
          ],
        ),
      ]);
      final s = TrafficProfiler.I.active!;
      final ev = s.events
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      final j = ev.toJson();
      expect(j['confidence'], 'secondary');
      expect(j['matched_via'], 'secondary_packages');
    });

    test('unattributed event has shown_because explanation', () async {
      // §180 — DNS-стрим обрабатывается при global recording (нет session).
      final sub = TrafficProfiler.I.globalLiveStream().listen((_) {});
      TrafficProfiler.I.startGlobalRecording();
      // packageName пуст → unattributed; failed → dnsFail.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'orphan.example',
          queryType: 65, // HTTPS
          rcode: -1,
          failed: true,
          error: 'timeout',
        ),
      ]);
      final ev = TrafficProfiler.I.globalUnattributedEvents.first;
      final j = ev.toJson();
      expect(j['confidence'], 'unattributed');
      expect(j['shown_because'], isNotNull);
      TrafficProfiler.I.stopGlobalRecording();
      await sub.cancel();
    });
  });

  // ───── §048 regression: global rolling buffer + Live tab ─────────────

  group('TrafficProfiler — §048 Live system-wide buffer', () {
    test('globalSnapshot returns events for all apps', () async {
      final sub = TrafficProfiler.I.globalLiveStream().listen((_) {});
      TrafficProfiler.I.startGlobalRecording();
      // §180 — атрибуция packageName ИЗ ЯДРА прямо в CcDnsQuery.
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'a.example',
          queryType: 1,
          rcode: 0,
          packageName: 'com.app.a',
          answers: [CcDnsAnswer(name: 'a.example', type: 1, rdata: '1.1.1.1')],
        ),
        const CcDnsQuery(
          domain: 'b.example',
          queryType: 1,
          rcode: 0,
          packageName: 'com.app.b',
          answers: [CcDnsAnswer(name: 'b.example', type: 1, rdata: '2.2.2.2')],
        ),
      ]);
      final snap = TrafficProfiler.I.globalSnapshot();
      // Хотя бы по одному event на app в global buffer'е.
      final apps = snap
          .map((e) => e.process)
          .where((p) => p != null)
          .toSet();
      expect(apps.contains('com.app.a'), true);
      expect(apps.contains('com.app.b'), true);
      TrafficProfiler.I.stopGlobalRecording();
      await sub.cancel();
    });

    test('unattributedBannerActive flips when many unattributed events arrive',
        () async {
      final sub = TrafficProfiler.I.globalLiveStream().listen((_) {});
      TrafficProfiler.I.startGlobalRecording();
      // Эмулируем 10 unattributed DNS fail'ов за короткое время
      // (packageName пуст → unattributed, failed → dnsFail = признак сбоя).
      TrafficProfiler.I.ingestDnsForTest([
        for (var i = 0; i < 10; i++)
          CcDnsQuery(
            domain: 'x$i.test',
            queryType: 1,
            rcode: -1,
            failed: true,
            error: 'timeout',
          ),
      ]);
      expect(TrafficProfiler.I.recentUnattributedCount, greaterThanOrEqualTo(6));
      expect(TrafficProfiler.I.unattributedBannerActive, true);
      TrafficProfiler.I.stopGlobalRecording();
      await sub.cancel();
    });

    test('§177-A successful unattributed DNS resolves do NOT light the banner',
        () async {
      final sub = TrafficProfiler.I.globalLiveStream().listen((_) {});
      TrafficProfiler.I.startGlobalRecording();
      // 12 УСПЕШНЫХ резолвов без владельца (packageName пуст) — это норма,
      // НЕ сбой. Баннер не должен гореть (§177-A: считаем только признаки сбоя).
      TrafficProfiler.I.ingestDnsForTest([
        for (var i = 0; i < 12; i++)
          CcDnsQuery(
            domain: 'x$i.test',
            queryType: 1,
            rcode: 0,
            answers: [CcDnsAnswer(name: 'x$i.test', type: 1, rdata: '1.2.3.4')],
          ),
      ]);
      expect(TrafficProfiler.I.recentUnattributedCount, 0,
          reason: 'успешные dnsResolve без владельца — не признак сбоя');
      expect(TrafficProfiler.I.unattributedBannerActive, false);
      TrafficProfiler.I.stopGlobalRecording();
      await sub.cancel();
    });
  });

  // §044/§180 — тест «gc cleans stale conn-id entries» удалён вместе с
  // лог-питателем (§180); GC rolling-buffer'ов покрыт другими тестами.

  // ───── §181: оси РАЗДЕЛЬНО (outboundChain=маршрут, detourChain=транспорт) ──

  group('TrafficProfiler — §181 routing axes + routingLine', () {
    test('chains и detours несутся РАЗДЕЛЬНО (не склеены как §178)', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'd181a',
          network: 'tcp',
          domain: 'www.google.com',
          destination: '1.2.3.4:443',
          rule: 'final',
          uplink: 10,
          downlink: 20,
          outbound: 'BL: [BL]-3',
          chains: ['BL: [BL]-3', 'vpn-1'], // [node, selector] из ядра
          detours: ['WARP'], // detour-ось — ОТДЕЛЬНО
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events.first;
      expect(ev.outboundChain, ['BL: [BL]-3', 'vpn-1'],
          reason: '§181 — outboundChain = только маршрут (БЕЗ detour)');
      expect(ev.detourChain, ['WARP'],
          reason: '§181 — detour в своей оси');
    });

    test('routingLine: полная трассировка [net] proc ⇒ rule ⇒ группа : node → detour → domain',
        () async {
      await TrafficProfiler.I.start('com.android.vending');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'd181b',
          network: 'tcp',
          domain: 'play-fe.googleapis.com',
          destination: '74.125.131.102:443',
          rule: '', // пусто → "final"
          uplink: 10,
          downlink: 0,
          outbound: 'Венгрия',
          // [node, под-группа, верхняя-группа] — auto между vpn-1 и нодой
          chains: ['🇭🇺Венгрия', '✨auto', 'vpn-1'],
          detours: ['WARP'],
          packageName: 'com.android.vending',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events.first;
      // [tcp] proc ⇒ final ⇒ vpn-1 ⇒ ✨auto : 🇭🇺Венгрия → WARP → domain
      expect(
        ev.routingLine,
        '[tcp] com.android.vending ⇒ final ⇒ vpn-1 ⇒ ✨auto : 🇭🇺Венгрия → WARP → play-fe.googleapis.com',
      );
      // compact (live-список): без префикса [net] process ⇒ (он дублирует
      // строку процесса + бейдж типа). Начинается с rule.
      expect(
        ev.routingLineOf(compact: true),
        'final ⇒ vpn-1 ⇒ ✨auto : 🇭🇺Венгрия → WARP → play-fe.googleapis.com',
      );
    });

    test('routingLine: с явным rule (не final)', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'd181c',
          network: 'tcp',
          domain: 'site.ru',
          destination: '5.6.7.8:443',
          rule: 'rule_set=ru-domains',
          uplink: 1,
          downlink: 1,
          outbound: 'direct-out',
          chains: ['direct-out'], // прямой, без групп
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events.first;
      // нет групп (chains длины 1), нет detour: proc ⇒ rule : node → domain
      expect(
        ev.routingLine,
        '[tcp] ru.tinkoff.investing ⇒ rule_set=ru-domains : direct-out → site.ru',
      );
    });

    test('прямой conn (chains пуст) → fallback [outbound], detour пуст', () async {
      await TrafficProfiler.I.start('ru.tinkoff.investing');
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'd181d',
          network: 'tcp',
          domain: 'direct.example',
          destination: '9.9.9.9:443',
          rule: '',
          uplink: 5,
          downlink: 5,
          outbound: 'direct-out',
          // chains/detours пусты
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final ev = TrafficProfiler.I.active!.events.first;
      expect(ev.outboundChain, ['direct-out'],
          reason: 'fallback на [outbound]');
      expect(ev.detourChain, isEmpty);
    });
  });
}
