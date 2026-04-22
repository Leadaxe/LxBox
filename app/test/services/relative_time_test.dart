import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/relative_time.dart';

void main() {
  final now = DateTime(2026, 4, 22, 12, 0, 0);
  group('relativeTime (night T6-1)', () {
    test('<60 sec → "just now"', () {
      expect(relativeTime(now, now.subtract(const Duration(seconds: 30))),
          'just now');
    });
    test('future → "just now" (не пугаем)', () {
      expect(relativeTime(now, now.add(const Duration(minutes: 5))),
          'just now');
    });
    test('5 min → "5 min ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(minutes: 5))),
          '5 min ago');
    });
    test('2 h → "2h ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(hours: 2))),
          '2h ago');
    });
    test('ровно 24ч → yesterday', () {
      expect(relativeTime(now, now.subtract(const Duration(days: 1))),
          'yesterday');
    });
    test('3 дня → "3d ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(days: 3))),
          '3d ago');
    });
    test('2 недели → "2w ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(days: 14))),
          '2w ago');
    });
    test('2 месяца → "2mo ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(days: 65))),
          '2mo ago');
    });
    test('2 года → "2y ago"', () {
      expect(relativeTime(now, now.subtract(const Duration(days: 800))),
          '2y ago');
    });
  });
}
