import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart'
    show
        evaluateDnsDirectBlocked,
        DnsDirectStats,
        kDnsDirectFailThreshold,
        kDnsDirectFailFraction,
        kDnsHealthySuccessEarlyExit;
import 'package:lxbox/vpn/cc_channel.dart';

// §259 — юнит на вердикт детектора direct-DNS-глушения.
// Формула: fail_domains >= 3 && fail_domains/total_direct > 30%
// (знаменатель — только direct-домены; VPN-домены игнорируются).
// Белые списки: успехи (yandex) и провалы (заблокированное) вперемешку через
// один direct-сервер — «есть успех → молчим» НЕ применяется.

CcDnsQuery _q({
  required String domain,
  required String source,
  required int rcode,
  bool failed = false,
  String error = '',
  List<String> outbound = const [],
  int queryType = 1,
}) =>
    CcDnsQuery(
      domain: domain,
      queryType: queryType,
      rcode: rcode,
      source: source,
      failed: failed,
      error: error,
      outbound: outbound,
    );

// Мёртвый direct-запрос (глушилка): failed, rcode=-1, direct (пустой outbound).
CcDnsQuery _dead(String domain, {List<String> outbound = const []}) => _q(
      domain: domain,
      source: 'failed',
      rcode: -1,
      failed: true,
      error: 'context deadline exceeded',
      outbound: outbound,
    );

// Живой успех direct (пустой outbound = direct-дефолт).
CcDnsQuery _okDirect(String domain) =>
    _q(domain: domain, source: 'exchanged', rcode: 0);

void main() {
  group('§259 константы', () {
    test('порог=3, доля=30%, health-exit=20', () {
      expect(kDnsDirectFailThreshold, 3);
      expect(kDnsDirectFailFraction, 0.30);
      expect(kDnsHealthySuccessEarlyExit, 20);
    });
  });

  group('§259 evaluateDnsDirectBlocked — базовые', () {
    test('пустой поток → false', () {
      expect(evaluateDnsDirectBlocked(const []), isFalse);
    });

    test('3 мёртвых direct из 3 (100% > 30%) → true', () {
      expect(
        evaluateDnsDirectBlocked([_dead('a'), _dead('b'), _dead('c')]),
        isTrue,
      );
    });

    test('2 мёртвых (< порога 3) → false, даже если 100%', () {
      expect(evaluateDnsDirectBlocked([_dead('a'), _dead('b')]), isFalse);
    });

    test('direct-тег в outbound (не пусто) тоже direct → true', () {
      expect(
        evaluateDnsDirectBlocked([
          _dead('a', outbound: ['direct-out']),
          _dead('b', outbound: ['direct']),
          _dead('c', outbound: ['direct-out']),
        ]),
        isTrue,
      );
    });
  });

  group('§259 порог + доля', () {
    test('3 мёртвых из 10 direct (30%, НЕ >30%) → false', () {
      final qs = <CcDnsQuery>[
        for (var i = 0; i < 3; i++) _dead('dead$i'),
        for (var i = 0; i < 7; i++) _okDirect('ok$i'),
      ];
      // 3/10 = 0.30, строго не > 0.30 → false
      expect(evaluateDnsDirectBlocked(qs), isFalse);
    });

    test('4 мёртвых из 10 direct (40% > 30%) → true', () {
      final qs = <CcDnsQuery>[
        for (var i = 0; i < 4; i++) _dead('dead$i'),
        for (var i = 0; i < 6; i++) _okDirect('ok$i'),
      ];
      expect(evaluateDnsDirectBlocked(qs), isTrue);
    });

    test('4 мёртвых из 100 direct (4%) → false (доля спасает)', () {
      final qs = <CcDnsQuery>[
        for (var i = 0; i < 4; i++) _dead('dead$i'),
        for (var i = 0; i < 96; i++) _okDirect('ok$i'),
      ];
      expect(evaluateDnsDirectBlocked(qs), isFalse);
    });
  });

  group('§259 белые списки (успехи+провалы вперемешку)', () {
    test('5 мёртвых заблокированных + 3 живых (yandex) direct → true', () {
      // 5/8 = 62.5% > 30%, fails=5>=3 → срабатывает НЕСМОТРЯ на успехи.
      final qs = <CcDnsQuery>[
        _dead('google.com'),
        _dead('youtube.com'),
        _dead('instagram.com'),
        _dead('twitter.com'),
        _dead('facebook.com'),
        _okDirect('yandex.ru'),
        _okDirect('mail.ru'),
        _okDirect('vk.com'),
      ];
      expect(evaluateDnsDirectBlocked(qs), isTrue,
          reason: 'ключевой кейс: успехи не гасят вердикт на белых списках');
    });
  });

  group('§259 знаменатель = только direct', () {
    test('VPN-домены НЕ в знаменателе: 3 мёртвых direct + 50 VPN → true', () {
      final qs = <CcDnsQuery>[
        _dead('a'), _dead('b'), _dead('c'), // 3 direct мёртвых
        // 50 живых через VPN — НЕ должны размывать долю
        for (var i = 0; i < 50; i++)
          _q(
              domain: 'vpn$i',
              source: 'exchanged',
              rcode: 0,
              outbound: ['vpn-1']),
      ];
      // total_direct = 3 (только мёртвые direct), 3/3=100% → true
      expect(evaluateDnsDirectBlocked(qs), isTrue,
          reason: 'VPN-успехи не входят в знаменатель direct-доли');
    });

    test('мёртвые через VPN не считаются (не direct) → false', () {
      expect(
        evaluateDnsDirectBlocked([
          _dead('a', outbound: ['vpn-1']),
          _dead('b', outbound: ['vpn-1']),
          _dead('c', outbound: ['vpn-1']),
        ]),
        isFalse,
      );
    });
  });

  group('§259 фильтры провалов', () {
    test('дедуп A+AAAA одного домена = 1 (порог не взят на 1 домене)', () {
      expect(
        evaluateDnsDirectBlocked([
          _dead('a'), // A
          _q(
              domain: 'a', // AAAA — тот же домен
              source: 'failed',
              rcode: -1,
              failed: true,
              error: 'context deadline exceeded',
              queryType: 28),
        ]),
        isFalse,
      );
    });

    test('loopback исключён (локальный, не глушение)', () {
      expect(
        evaluateDnsDirectBlocked([
          for (var i = 0; i < 3; i++)
            _q(
                domain: 'a$i',
                source: 'failed',
                rcode: -1,
                failed: true,
                error: 'loopback'),
        ]),
        isFalse,
      );
    });

    test('rejected исключён (наш reject, не глушение)', () {
      expect(
        evaluateDnsDirectBlocked([
          for (var i = 0; i < 3; i++)
            _q(
                domain: 'a$i',
                source: 'failed',
                rcode: -1,
                failed: true,
                error: 'rejected (cached)'),
        ]),
        isFalse,
      );
    });

    test('rcode != -1 (SERVFAIL с ответом) не глушение', () {
      expect(
        evaluateDnsDirectBlocked([
          for (var i = 0; i < 3; i++)
            _q(
                domain: 'a$i',
                source: 'failed',
                rcode: 2,
                failed: true,
                error: 'servfail'),
        ]),
        isFalse,
      );
    });

    test('deadline exceeded / connection refused ловятся (негативный фильтр)',
        () {
      expect(
        evaluateDnsDirectBlocked([
          _q(
              domain: 'a',
              source: 'failed',
              rcode: -1,
              failed: true,
              error: 'context deadline exceeded'),
          _q(
              domain: 'b',
              source: 'failed',
              rcode: -1,
              failed: true,
              error: 'connection refused'),
          _q(
              domain: 'c',
              source: 'failed',
              rcode: -1,
              failed: true,
              error: 'network is unreachable'),
        ]),
        isTrue,
      );
    });

    test('cached-провал (source != failed) не учитывается', () {
      // rcode==-1 всегда failed по ядру, но подстрахуемся: source=cached
      // не должен считаться провалом.
      expect(
        evaluateDnsDirectBlocked([
          _q(
              domain: 'a',
              source: 'cached',
              rcode: -1,
              failed: true,
              error: 'x'),
          _q(
              domain: 'b',
              source: 'cached',
              rcode: -1,
              failed: true,
              error: 'x'),
          _q(
              domain: 'c',
              source: 'cached',
              rcode: -1,
              failed: true,
              error: 'x'),
        ]),
        isFalse,
      );
    });
  });

  group('§259 DnsDirectStats — ранний выход', () {
    test('healthyEarlyExit: 20 успехов, 0 провалов → true', () {
      final s = DnsDirectStats();
      for (var i = 0; i < 20; i++) {
        s.ingest(_okDirect('ok$i'));
      }
      expect(s.healthyEarlyExit, isTrue);
      expect(s.blocked, isFalse);
    });

    test('healthyEarlyExit: 20 успехов, но есть провал → false', () {
      final s = DnsDirectStats();
      for (var i = 0; i < 20; i++) {
        s.ingest(_okDirect('ok$i'));
      }
      s.ingest(_dead('bad'));
      expect(s.healthyEarlyExit, isFalse,
          reason: 'провал есть → рано не выходим');
    });

    test('healthyEarlyExit: 19 успехов (< порога) → false', () {
      final s = DnsDirectStats();
      for (var i = 0; i < 19; i++) {
        s.ingest(_okDirect('ok$i'));
      }
      expect(s.healthyEarlyExit, isFalse);
    });

    test('refreshed засчитывается как живой успех', () {
      final s = DnsDirectStats();
      for (var i = 0; i < 20; i++) {
        s.ingest(_q(domain: 'r$i', source: 'refreshed', rcode: 0));
      }
      expect(s.healthyEarlyExit, isTrue);
    });

    test('optimistic НЕ живой успех (кэш)', () {
      final s = DnsDirectStats();
      for (var i = 0; i < 20; i++) {
        s.ingest(_q(domain: 'o$i', source: 'optimistic', rcode: 0));
      }
      expect(s.healthyEarlyExit, isFalse,
          reason: 'optimistic = отдача кэша, не живой запрос');
    });

    test('totalDirectDomains = мёртвые ∪ живые direct (без VPN)', () {
      final s = DnsDirectStats();
      s.ingest(_dead('a'));
      s.ingest(_okDirect('b'));
      s.ingest(_q(domain: 'c', source: 'exchanged', rcode: 0, outbound: ['vpn-1']));
      expect(s.totalDirectDomains, 2, reason: 'a(dead)+b(ok direct), vpn c — нет');
    });
  });
}
