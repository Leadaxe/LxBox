import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/warp_endpoint_picker.dart';

/// §136 — рандом WARP-endpoint из asset (формат ip:port, диапазоны, SNI-пул).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(WarpEndpointPicker.resetForTest);

  test('load: asset парсится, есть данные', () async {
    final p = await WarpEndpointPicker.load();
    expect(p.hasData, isTrue);
    expect(p.sniPool, isNotEmpty);
  });

  test('randomEndpoint: формат prefix+N:port, N∈1..10, известные блоки',
      () async {
    final p = await WarpEndpointPicker.load();
    final re = RegExp(r'^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3}):(\d{1,5})$');
    for (var i = 0; i < 200; i++) {
      final ep = p.randomEndpoint();
      expect(ep, isNotNull);
      final m = re.firstMatch(ep!);
      expect(m, isNotNull, reason: 'не ip:port: $ep');
      final last = int.parse(m!.group(2)!);
      final port = int.parse(m.group(3)!);
      expect(last, inInclusiveRange(1, 10), reason: 'last octet $last (ep=$ep)');
      expect(port, inInclusiveRange(1, 65535), reason: 'port $port');
    }
  });

  test('randomEndpoint: использует известные Cloudflare-префиксы', () async {
    final p = await WarpEndpointPicker.load();
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      final ep = p.randomEndpoint()!;
      // префикс = всё до последнего октета.
      final prefix = ep.substring(0, ep.lastIndexOf('.') + 1);
      seen.add(prefix);
    }
    // должны встретиться твёрдые блоки (162.159.*/188.114.*).
    expect(
        seen.any((p) => p.startsWith('162.159.') || p.startsWith('188.114.')),
        isTrue,
        reason: 'не видели твёрдых блоков: $seen');
  });

  test('randomSni: непустой из пула, варьируется', () async {
    final p = await WarpEndpointPicker.load();
    final seen = <String>{};
    for (var i = 0; i < 100; i++) {
      final s = p.randomSni();
      expect(s.isNotEmpty, isTrue);
      expect(p.sniPool.contains(s), isTrue);
      seen.add(s);
    }
    expect(seen.length, greaterThan(1), reason: 'SNI не варьируется');
  });

  test('sni_pool содержит РФ-сайты и международные', () async {
    final p = await WarpEndpointPicker.load();
    expect(p.sniPool, contains('gosuslugi.ru'));
    expect(p.sniPool, contains('www.google.com'));
  });
}
