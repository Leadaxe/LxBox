import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/sources.dart';

void main() {
  group('parseFromSource — offline sources', () {
    test('InlineSource with URI list → nodes parsed', () async {
      const body = 'vless://u1@h1.com:443#A\ntrojan://p@h2.com:443#B\n';
      final r = await parseFromSource(const InlineSource(body));
      expect(r.nodes, hasLength(2));
      expect(r.meta, isNull);
    });

    test('ClipboardSource empty body → empty nodes, no throw', () async {
      final r = await parseFromSource(const ClipboardSource(''));
      expect(r.nodes, isEmpty);
    });

    test('QrSource with single URI → one node', () async {
      final r = await parseFromSource(
        const QrSource('vless://u@h.com:443?type=ws#X'),
      );
      expect(r.nodes, hasLength(1));
    });

    test('InlineSource with base64-wrapped list → nodes parsed', () async {
      const raw =
          'dmxlc3M6Ly91QGguY29tOjQ0MyN4CnRyb2phbjovL3BAaC5jb206NDQzI3kK';
      final r = await parseFromSource(const InlineSource(raw));
      expect(r.nodes, hasLength(2));
    });
  });
}
