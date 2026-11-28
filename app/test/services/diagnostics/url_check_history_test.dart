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

  test('повтор адреса не плодит дубль, а поднимает его наверх со свежим итогом',
      () {
    final h = UrlCheckHistory();
    h.add(rec('https://a.com', summary: 'old'));
    h.add(rec('https://b.com'));
    h.add(rec('https://c.com'));
    h.add(rec('https://a.com', summary: 'new'));
    expect(h.items.map((e) => e.link),
        ['https://a.com', 'https://c.com', 'https://b.com']);
    expect(h.items.first.summary, 'new');
  });

  test('повтор при полной истории не вытесняет чужой адрес', () {
    final h = UrlCheckHistory();
    for (var i = 0; i < 20; i++) {
      h.add(rec('https://s$i.com'));
    }
    h.add(rec('https://s0.com'));
    expect(h.items, hasLength(20));
    expect(h.items.first.link, 'https://s0.com');
    expect(h.items.last.link, 'https://s1.com');
  });

  test('items не даёт править историю снаружи', () {
    final h = UrlCheckHistory()..add(rec('https://a.com'));
    expect(() => h.items.clear(), throwsUnsupportedError);
  });
}
