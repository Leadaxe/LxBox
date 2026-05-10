import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/custom_rule_edit/normalizers.dart';

/// §053 Stage 1 — unit tests для extracted normalizers.
void main() {
  group('splitRaw', () {
    test('splits by newline + comma + trims', () {
      expect(splitRaw('a\nb,c'), ['a', 'b', 'c']);
    });
    test('drops empty', () {
      expect(splitRaw('a\n\n\nb,,c,'), ['a', 'b', 'c']);
    });
    test('trims whitespace', () {
      expect(splitRaw('  a  ,  b  ,  c  '), ['a', 'b', 'c']);
    });
    test('empty input', () {
      expect(splitRaw(''), isEmpty);
      expect(splitRaw('  '), isEmpty);
      expect(splitRaw(',,,'), isEmpty);
    });
  });

  group('normalizedDomains', () {
    test('lower-case', () {
      expect(normalizedDomains('Example.COM'), ['example.com']);
    });
    test('strips http(s):// + trailing /', () {
      expect(normalizedDomains('https://Example.com/'),
          ['example.com']);
      expect(normalizedDomains('http://api.x.io'), ['api.x.io']);
    });
    test('strip leading dot when requested (for suffix)', () {
      expect(
        normalizedDomains('.ru', stripLeadingDot: true),
        ['ru'],
      );
      expect(
        normalizedDomains('.example.com', stripLeadingDot: true),
        ['example.com'],
      );
    });
    test('keeps leading dot by default', () {
      expect(normalizedDomains('.ru'), ['.ru']);
    });
    test('multi-input split', () {
      expect(
        normalizedDomains('Example.com,FOO.io\nbar.RU'),
        ['example.com', 'foo.io', 'bar.ru'],
      );
    });
    test('drops empty after normalize', () {
      expect(normalizedDomains('https:///'), isEmpty);
    });
  });

  group('normalizedKeywords', () {
    test('lower-case + split', () {
      expect(
        normalizedKeywords('Tracker,ANALYTICS\nads'),
        ['tracker', 'analytics', 'ads'],
      );
    });
  });

  group('normalizedCidrs', () {
    test('adds /32 for bare IPv4', () {
      expect(normalizedCidrs('1.2.3.4'), ['1.2.3.4/32']);
    });
    test('adds /128 for bare IPv6', () {
      expect(normalizedCidrs('::1'), ['::1/128']);
      expect(normalizedCidrs('fe80::1'), ['fe80::1/128']);
    });
    test('keeps explicit mask', () {
      expect(normalizedCidrs('10.0.0.0/8'), ['10.0.0.0/8']);
      expect(normalizedCidrs('::1/128'), ['::1/128']);
    });
    test('mixed input', () {
      expect(
        normalizedCidrs('192.168.1.1,10.0.0.0/8\n::1'),
        ['192.168.1.1/32', '10.0.0.0/8', '::1/128'],
      );
    });
  });

  group('normalizedPorts / normalizedPortRanges', () {
    test('passthrough split', () {
      expect(normalizedPorts('80,443\n22'), ['80', '443', '22']);
      expect(normalizedPortRanges('8000:9000,:3000'),
          ['8000:9000', ':3000']);
    });
  });
}
