import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/format_utils.dart';

/// §084 H4 — tests for unified byte/duration/time formatters.
void main() {
  group('formatBytes — compact (spaced=false)', () {
    test('bytes', () => expect(formatBytes(500), '500B'));
    test('KB', () => expect(formatBytes(1536), '1.5KB'));
    test('MB', () => expect(formatBytes(5 * 1024 * 1024), '5.0MB'));
    test('GB', () => expect(formatBytes(3 * 1024 * 1024 * 1024), '3.00GB'));
    test('zero', () => expect(formatBytes(0), '0B'));
  });

  group('formatBytes — spaced (stats)', () {
    test('bytes', () => expect(formatBytes(500, spaced: true), '500 B'));
    test('KB', () => expect(formatBytes(1536, spaced: true), '1.5 KB'));
    test('MB',
        () => expect(formatBytes(5 * 1024 * 1024, spaced: true), '5.0 MB'));
    test('zero → "0 B"', () => expect(formatBytes(0, spaced: true), '0 B'));
    test('negative → "0 B"',
        () => expect(formatBytes(-5, spaced: true), '0 B'));
  });

  group('formatDuration', () {
    test('seconds', () =>
        expect(formatDuration(const Duration(seconds: 42)), '42s'));
    test('minutes+seconds', () => expect(
        formatDuration(const Duration(minutes: 5, seconds: 30)), '5m 30s'));
    test('hours+minutes', () => expect(
        formatDuration(const Duration(hours: 2, minutes: 5)), '2h 5m'));
    test('zero', () => expect(formatDuration(Duration.zero), '0s'));
  });

  group('formatTime', () {
    test('HH:mm:ss padded', () =>
        expect(formatTime(DateTime(2026, 1, 1, 9, 5, 3)), '09:05:03'));
    test('midday', () =>
        expect(formatTime(DateTime(2026, 1, 1, 23, 59, 59)), '23:59:59'));
  });
}
