// §044 / §288 — TrafficProfiler unit tests (system-wide only).

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/vpn/cc_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TrafficProfiler.I.resetForTesting();
  });

  // ───── DNS parsing into the global rolling buffer (§180 structural stream) ──

  group('TrafficProfiler — DNS parsing (global buffer)', () {
    test('DNS chain attribution: CNAME-hops в answers, ip = финальный A',
        () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final resolves = TrafficProfiler.I.globalRollingBuffer
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
      expect(resolves.first.confidence, ConfidenceLevel.verified);
    });

    test('§180-fix — ядро шлёт rdata ПОЛНОЙ RR-строкой → берём значение',
        () async {
      // device dev.72: DnsAnswer.rdata = "name TTL IN TYPE value" (НЕ голое
      // значение). ip = последнее поле A-записи; cname target — без trailing dot.
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.ip, '64.233.165.139', reason: 'A: последнее поле, не вся строка');
      expect(ev.cnameChain, ['wide-youtube.l.google.com'],
          reason: 'CNAME: target без trailing dot');
    });

    test('DNS fail produces dnsTimeout issue', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer.last;
      expect(ev.kind, TrafficEventKind.dnsFail);
      expect(ev.issues.first.kind, ConnectionIssueKind.dnsTimeout);
    });

    test('rc.10 — dnsServer/dnsServerType/outbound пробрасываются', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      // outbound → outboundChain (для routingLine «через какой сервер»).
      expect(ev.outboundChain, ['🇫🇮Финляндия (vpn-1)']);
      // dnsServer/тип → extra (для detail-sheet).
      expect(ev.extra?['dns_server'], 'https://1.1.1.1/dns-query');
      expect(ev.extra?['dns_server_type'], 'https');
    });

    test('rc.10 — cached (пустой outbound) → outboundChain пуст', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.outboundChain, isEmpty);
    });

    test('multi-package UID `com.x.y, com.x.z` → verified (process известен)',
        () async {
      TrafficProfiler.I.startGlobalRecording();
      // §180 — ядро может отдать несколько пакетов одного UID через запятую
      // прямо в packageName; process непуст → verified.
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
      final dns = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(dns.confidence, ConfidenceLevel.verified);
      expect(dns.domain, 'play.google.com');
    });
  });

  // ───── §048 DNS record-type semantics (global buffer) ─────────────────

  group('TrafficProfiler — §048 DNS record-type semantics', () {
    test('HTTPS record DNS resolve is parsed with record_type=HTTPS', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final dnsEvents = TrafficProfiler.I.globalRollingBuffer
          .where((e) => e.kind == TrafficEventKind.dnsResolve)
          .toList();
      expect(dnsEvents, hasLength(1));
      expect(dnsEvents.first.dnsRecordType, 'HTTPS');
      expect(dnsEvents.first.confidence, ConfidenceLevel.verified);
    });

    test('SVCB record DNS resolve is parsed', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.dnsRecordType, 'SVCB');
    });

    test('SOA record (NXDOMAIN) is parsed without IP', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsResolve);
      expect(ev.dnsRecordType, 'SOA');
      // SOA не несёт IP — поле должно быть null.
      expect(ev.ip, isNull);
    });

    test('DNS fail with HTTPS record type — unattributed if no owner', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      // Должно попасть в global unattributed events ring.
      expect(TrafficProfiler.I.globalUnattributedEvents, isNotEmpty);
      final ev = TrafficProfiler.I.globalUnattributedEvents.first;
      expect(ev.kind, TrafficEventKind.dnsFail);
      expect(ev.confidence, ConfidenceLevel.unattributed);
      expect(ev.dnsRecordType, 'HTTPS');
      expect(ev.domain, '2ip.io');
      expect(ev.shownBecause, isNotNull);
    });

    test('DNS fail (attributed) → verified dnsFail with record type', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final fail = TrafficProfiler.I.globalRollingBuffer
          .firstWhere((e) => e.kind == TrafficEventKind.dnsFail);
      expect(fail.confidence, ConfidenceLevel.verified);
      expect(fail.domain, 'example.com');
      expect(fail.dnsRecordType, 'A');
    });
  });

  // ───── Connection ingest into the global buffer (§168 CommandClient) ──

  group('TrafficProfiler — connection ingest (§168 CommandClient)', () {
    test('new tcp conn → tcpOpen event (no issue on open)', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final buf = TrafficProfiler.I.globalRollingBuffer;
      expect(buf.length, 1);
      final ev = buf.first;
      expect(ev.kind, TrafficEventKind.tcpOpen);
      expect(ev.domain, 'certs.t-bank-app.ru');
      expect(ev.ip, '81.222.127.186');
      expect(ev.port, 443);
      expect(ev.process, 'ru.tinkoff.investing');
      expect(ev.confidence, ConfidenceLevel.verified);
      // На open issues не вычисляем — оба текущих типа (dnsTimeout,
      // tcpReset) релевантны close/dns-fail event'ам.
      expect(ev.issues, isEmpty);
    });

    test('tcp conn without owner → unattributed', () async {
      TrafficProfiler.I.startGlobalRecording();
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'noown',
          network: 'tcp',
          domain: 'noowner.example',
          destination: '5.5.5.5:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct',
          // packageName / processPath пусты → unattributed
          createdAt: 0,
          closedAt: 0,
        ),
      ]);
      final ev = TrafficProfiler.I.globalRollingBuffer.first;
      expect(ev.confidence, ConfidenceLevel.unattributed);
      expect(ev.process, isNull);
    });

    test('closed connection emits tcpClose with duration', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final buf = TrafficProfiler.I.globalRollingBuffer;
      expect(buf.length, 2);
      expect(buf.last.kind, TrafficEventKind.tcpClose);
      expect(buf.last.duration, isNotNull);
    });

    test('closed connection via closedAt>0 emits tcpClose (§168)', () async {
      // CC может прислать тот же conn с closedAt>0 (вместо пропадания) —
      // ingest трактует isClosed как «пропал» → закрываем.
      TrafficProfiler.I.startGlobalRecording();
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
      expect(TrafficProfiler.I.globalRollingBuffer.last.kind,
          TrafficEventKind.tcpClose);
    });

    test('§176 — короткий conn сразу closedAt>0 → обе фазы (open+close)',
        () async {
      // FilterState(All): коротко-живущий conn может прийти СРАЗУ закрытым
      // (open проскочил между тиками). Раньше (`if isClosed continue`) терялся
      // целиком. Теперь профайлер видит и tcpOpen, и tcpClose.
      TrafficProfiler.I.startGlobalRecording();
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
      final kinds =
          TrafficProfiler.I.globalRollingBuffer.map((e) => e.kind).toList();
      expect(kinds, contains(TrafficEventKind.tcpOpen),
          reason: 'open не потерян');
      expect(kinds, contains(TrafficEventKind.tcpClose),
          reason: 'close эмитнут');
    });

    test('§353 — kernel-метки: duration от createdAt/closedAt, не от тиков',
        () async {
      // Conn открылся и закрылся МЕЖДУ тиками: приходит сразу закрытым с
      // реальными epoch-ms метками ядра. Раньше startedAt=now → duration 0 и
      // ложный tcpReset («<1с и 0 байт») для conn'а, жившего 4.2с.
      TrafficProfiler.I.startGlobalRecording();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      TrafficProfiler.I.ingestForTest([
        CcConnection(
          id: 'k1',
          network: 'tcp',
          domain: 'slowclose.example',
          destination: '9.9.9.9:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: nowMs - 5000,
          closedAt: nowMs - 800,
        ),
      ]);
      final close = TrafficProfiler.I.globalRollingBuffer
          .lastWhere((e) => e.kind == TrafficEventKind.tcpClose);
      expect(close.duration, const Duration(milliseconds: 4200),
          reason: 'длительность по часам ядра, детерминированная');
      expect(close.issues, isEmpty,
          reason: '4.2с с 0 байт — НЕ tcpReset (порог 1с)');
    });

    test('§353 — честный быстрый close с kernel-метками даёт tcpReset',
        () async {
      TrafficProfiler.I.startGlobalRecording();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      TrafficProfiler.I.ingestForTest([
        CcConnection(
          id: 'k2',
          network: 'tcp',
          domain: 'fastclose.example',
          destination: '9.9.9.10:443',
          rule: '',
          uplink: 0,
          downlink: 0,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: nowMs - 500,
          closedAt: nowMs - 100,
        ),
      ]);
      final close = TrafficProfiler.I.globalRollingBuffer
          .lastWhere((e) => e.kind == TrafficEventKind.tcpClose);
      expect(close.duration, const Duration(milliseconds: 400));
      expect(close.issues, isNotEmpty,
          reason: '400мс с 0 байт — вероятный RST, эвристика остаётся');
    });

    test('§353 — сентинел closedAt=1 не превращается в 1970 год', () async {
      // Тестовый/легаси сентинел «закрыт» (isClosed достаточно closedAt>0) —
      // порог _kernelTime отбрасывает его, close идёт app-временем.
      TrafficProfiler.I.startGlobalRecording();
      TrafficProfiler.I.ingestForTest([
        const CcConnection(
          id: 'k3',
          network: 'tcp',
          domain: 'sentinel.example',
          destination: '9.9.9.11:443',
          rule: '',
          uplink: 10,
          downlink: 10,
          outbound: 'direct-out',
          packageName: 'ru.tinkoff.investing',
          createdAt: 0,
          closedAt: 1,
        ),
      ]);
      final close = TrafficProfiler.I.globalRollingBuffer
          .lastWhere((e) => e.kind == TrafficEventKind.tcpClose);
      expect(close.ts.year, greaterThan(2000));
      expect(close.duration, isNotNull);
      expect(close.duration!.isNegative, isFalse);
    });

    test('§176 — тот же closed conn 2 тика → ОДИН close (анти-дубль)', () async {
      // Ядро держит closed в FilterState(All) до 5 мин → приходит каждый тик.
      // Guard _closedHandled обрабатывает РОВНО раз.
      TrafficProfiler.I.startGlobalRecording();
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
      final closes = TrafficProfiler.I.globalRollingBuffer
          .where((e) => e.kind == TrafficEventKind.tcpClose)
          .length;
      expect(closes, 1, reason: 'closed обработан ровно раз, не дублируется');
    });

    test('TCP RST early flagged on close (closed <1s, 0 bytes)', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final closeEvent = TrafficProfiler.I.globalRollingBuffer.last;
      expect(closeEvent.kind, TrafficEventKind.tcpClose);
      expect(
          closeEvent.issues.any((a) => a.kind == ConnectionIssueKind.tcpReset),
          true);
    });

    test('UID-suffixed package name (com.x (10999)) → verified', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final buf = TrafficProfiler.I.globalRollingBuffer;
      expect(buf, isNotEmpty);
      expect(buf.first.kind, TrafficEventKind.tcpOpen);
      expect(buf.first.confidence, ConfidenceLevel.verified);
    });
  });

  // ───── §048 Live system-wide buffer ────────────────────────────────────

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

    test('recording off → events ignored', () async {
      // Без startGlobalRecording ingest — no-op (listener detached).
      TrafficProfiler.I.ingestDnsForTest([
        const CcDnsQuery(
          domain: 'ignored.example',
          queryType: 1,
          rcode: 0,
          packageName: 'com.app.a',
          answers: [
            CcDnsAnswer(name: 'ignored.example', type: 1, rdata: '1.1.1.1'),
          ],
        ),
      ]);
      expect(TrafficProfiler.I.globalRollingBuffer, isEmpty);
    });
  });

  // ───── §181: оси РАЗДЕЛЬНО (outboundChain=маршрут, detourChain=транспорт) ──

  group('TrafficProfiler — §181 routing axes + routingLine', () {
    test('chains и detours несутся РАЗДЕЛЬНО (не склеены как §178)', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer.first;
      expect(ev.outboundChain, ['BL: [BL]-3', 'vpn-1'],
          reason: '§181 — outboundChain = только маршрут (БЕЗ detour)');
      expect(ev.detourChain, ['WARP'],
          reason: '§181 — detour в своей оси');
    });

    test(
        'routingLine: полная трассировка [net] proc ⇒ rule ⇒ группа : node → detour → domain',
        () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer.first;
      // §252: proc ⇒ [tcp] final ⇒ vpn-1 ⇒ ✨auto : WARP → vpn-1 (✨auto (🇭🇺Венгрия)) → domain
      expect(
        ev.routingLine,
        'com.android.vending ⇒ [tcp] final ⇒ vpn-1 ⇒ ✨auto : WARP → vpn-1 (✨auto (🇭🇺Венгрия)) → play-fe.googleapis.com',
      );
      // compact (live-список): без префикса [net] process ⇒ (он дублирует
      // строку процесса + бейдж типа). Начинается с rule.
      expect(
        ev.routingLineOf(compact: true),
        'final ⇒ vpn-1 ⇒ ✨auto : WARP → vpn-1 (✨auto (🇭🇺Венгрия)) → play-fe.googleapis.com',
      );
    });

    test('routingLine: с явным rule (не final)', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer.first;
      // нет групп (chains длины 1), нет detour: proc ⇒ rule : node → domain
      expect(
        ev.routingLine,
        'ru.tinkoff.investing ⇒ [tcp] rule_set=ru-domains : direct-out → site.ru',
      );
    });

    test('прямой conn (chains пуст) → fallback [outbound], detour пуст', () async {
      TrafficProfiler.I.startGlobalRecording();
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
      final ev = TrafficProfiler.I.globalRollingBuffer.first;
      expect(ev.outboundChain, ['direct-out'],
          reason: 'fallback на [outbound]');
      expect(ev.detourChain, isEmpty);
    });
  });
}
