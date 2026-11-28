import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/diagnostics/connection_test.dart';
import 'package:lxbox/services/diagnostics/url_check_history.dart';

UrlCheckRecord rec(String link, {String summary = 'HTTP 200 · 10 ms'}) =>
    UrlCheckRecord(
      link: link,
      depth: ConnectionTestDepth.http,
      outcome: UrlCheckOutcome.success,
      summary: summary,
      at: DateTime(2026, 11, 28, 12),
    );

void main() {
  test('новые записи первыми', () {
    final h = UrlCheckHistory();
    h.add(rec('https://a.com'));
    h.add(rec('https://b.com'));
    expect(h.items.map((e) => e.link), ['https://b.com', 'https://a.com']);
  });

  test('не больше 20: самая старая вытесняется', () {
    final h = UrlCheckHistory();
    expect(h.limit, 20);
    for (var i = 0; i < 21; i++) {
      h.add(rec('https://s$i.com'));
    }
    expect(h.items, hasLength(20));
    expect(h.items.first.link, 'https://s20.com');
    expect(h.items.last.link, 'https://s1.com');
    expect(h.items.any((e) => e.link == 'https://s0.com'), isFalse);
  });

  test('повтор адреса — новая запись, старая остаётся', () {
    final h = UrlCheckHistory();
    h.add(rec('https://a.com', summary: 'old'));
    h.add(rec('https://b.com'));
    h.add(rec('https://a.com', summary: 'new'));
    expect(h.items.map((e) => e.link),
        ['https://a.com', 'https://b.com', 'https://a.com']);
    expect(h.items.map((e) => e.summary).toList()..removeAt(1), ['new', 'old']);
  });

  test('links: адреса без повторов, по последней проверке', () {
    final h = UrlCheckHistory();
    h.add(rec('https://a.com'));
    h.add(rec('https://b.com'));
    h.add(rec('https://a.com'));
    expect(h.links, ['https://a.com', 'https://b.com']);
  });

  test('повторы тоже занимают место в лимите', () {
    final h = UrlCheckHistory();
    h.add(rec('https://old.com'));
    for (var i = 0; i < 20; i++) {
      h.add(rec('https://a.com'));
    }
    expect(h.items, hasLength(20));
    expect(h.links, ['https://a.com']);
  });

  test('items не даёт править историю снаружи', () {
    final h = UrlCheckHistory()..add(rec('https://a.com'));
    expect(() => h.items.clear(), throwsUnsupportedError);
  });

  test('запись держит параметры и дерево прогона для показа без запроса', () {
    final t = ConnectionTestTrace();
    final h = UrlCheckHistory()
      ..add(UrlCheckRecord(
        link: 'https://a.com',
        depth: ConnectionTestDepth.dns,
        outcome: UrlCheckOutcome.error,
        summary: 'x',
        at: DateTime(2026, 11, 28, 15, 16),
        packageName: 'org.example',
        fresh: true,
        trace: t,
      ));
    final r = h.items.single;
    expect(identical(r.trace, t), isTrue);
    expect(r.packageName, 'org.example');
    expect(r.fresh, isTrue);
    expect(r.depth, ConnectionTestDepth.dns);
  });
}
