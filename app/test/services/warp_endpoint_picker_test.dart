import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/warp_client.dart' show WarpApi;
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

  test('§386 endpointsPreset: непуст, recommended — явный ключ и есть в списке',
      () async {
    final p = await WarpEndpointPicker.load();
    expect(p.endpointsPreset, isNotEmpty);
    expect(p.recommendedEndpoint, 'engage.cloudflareclient.com:2408');
    expect(p.endpointsPreset, contains(p.recommendedEndpoint));
    // Каждый пункт — host:port (порт числовой).
    for (final e in p.endpointsPreset) {
      final i = e.lastIndexOf(':');
      expect(i, greaterThan(0), reason: e);
      expect(int.tryParse(e.substring(i + 1)), isNotNull, reason: e);
    }
  });

  test('§386 masqueHostsPreset: recommended — явный ключ (домен), без масок',
      () async {
    final p = await WarpEndpointPicker.load();
    expect(p.masqueHostsPreset, isNotEmpty);
    expect(
        p.recommendedMasqueHost, 'consumer-masque.cloudflareclient.com');
    expect(p.masqueHostsPreset, contains(p.recommendedMasqueHost));
    for (final h in p.masqueHostsPreset) {
      expect(h.contains('/'), isFalse, reason: h);
    }
  });

  test('§305 randomEndpoint: host:port, порт валиден, v4/v6-хост', () async {
    final p = await WarpEndpointPicker.load();
    // v4: a.b.c.d:port; v6: [....]:port (полный рандом по CIDR, не только .1-.10).
    final v4 = RegExp(r'^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{1,5})$');
    final v6 = RegExp(r'^\[[0-9a-f:]+\]:(\d{1,5})$');
    for (var i = 0; i < 200; i++) {
      final ep = p.randomEndpoint();
      expect(ep, isNotNull);
      final port = int.parse(ep!.substring(ep.lastIndexOf(':') + 1));
      expect(port, inInclusiveRange(1, 65535), reason: 'port $port (ep=$ep)');
      expect(v4.hasMatch(ep) || v6.hasMatch(ep), isTrue,
          reason: 'не host:port: $ep');
    }
  });

  test('§305 randomEndpoint: v4-хосты в известных Cloudflare-блоках', () async {
    final p = await WarpEndpointPicker.load();
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      final ep = p.randomEndpoint()!;
      if (ep.startsWith('[')) continue; // v6 — пропускаем для этой проверки
      final prefix = ep.substring(0, ep.lastIndexOf('.') + 1);
      seen.add(prefix);
    }
    // твёрдые v4-блоки (162.159.*/188.114.*).
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

  test('§136 WG sni_pool НЕ содержит cloudflare-доменов (device-smoke: режутся)',
      () async {
    final p = await WarpEndpointPicker.load();
    // Iliya 2026-06-16: cloudflare-quic.com → нет соединения (DPI читает SNI
    // внутри junk-приманки §136 → cloudflare-* палевно). ТОЛЬКО для WG-пула.
    for (final s in p.sniPool) {
      expect(s.contains('cloudflare'), isFalse,
          reason: 'cloudflare-SNI палевен в WG-masquerade: $s');
    }
  });

  test('§130 masque_sni_pool отдельный, СОДЕРЖИТ cloudflare (реальный TLS SNI)',
      () async {
    final p = await WarpEndpointPicker.load();
    expect(p.masqueSniPool, isNotEmpty);
    // У MASQUE это реальный SNI QUIC-сессии к Cloudflare — cloudflare-домен тут
    // естественен (в отличие от WG-junk §136), пул специально отдельный.
    expect(p.masqueSniPool, contains('www.cloudflare.com'));
    expect(p.masqueSniPool, contains('cdn.jsdelivr.net'));
    expect(p.masqueSniPool, contains('aws.amazon.com'));
    // randomMasqueSni отдаёт непустой домен из пула.
    final s = p.randomMasqueSni();
    expect(s, isNotEmpty);
    expect(p.masqueSniPool, contains(s));
  });

  test('masque recommended_sni: родной домен первым в пуле и помечен', () async {
    final p = await WarpEndpointPicker.load();
    // DPI умеет резать по НЕсовпадению SNI с IP-блоком (§143), поэтому родной
    // домен — полноправный кандидат перебора (в т.ч. для кубика), а не «палево».
    // Он же дефолт ядра при пустом поле SNI.
    expect(p.recommendedMasqueSni, 'consumer-masque.cloudflareclient.com');
    expect(p.masqueSniPool.first, p.recommendedMasqueSni);
  });

  test('WG-пул recommended_sni НЕ имеет (cloudflare-домены там режутся)',
      () async {
    final p = await WarpEndpointPicker.load();
    // Асимметрия с MASQUE намеренна: §136 — SNI внутри junk-приманки, не TLS.
    expect(p.sniPool, isNot(contains('engage.cloudflareclient.com')));
  });

  test('§130 новые чистые домены в обоих пулах (jsdelivr/aws — не cloudflare)',
      () async {
    final p = await WarpEndpointPicker.load();
    expect(p.sniPool, contains('cdn.jsdelivr.net'));
    expect(p.sniPool, contains('aws.amazon.com'));
  });

  // §305 — asset несёт device-verified MASQUE-данные боевого теста.
  test('§305 masque-блоки asset = только живые .198/.199', () async {
    final p = await WarpEndpointPicker.load();
    expect(p.masqueV4Cidr, ['162.159.198.0/24', '162.159.199.0/24']);
    // §305 — h3 живёт только на 4 хостах (device-verified), не по всему блоку.
    expect(p.scan!.masqueH3V4Cidr, [
      '162.159.198.1/32',
      '162.159.198.2/32',
      '162.159.199.1/32',
      '162.159.199.2/32',
    ]);
  });

  test('§305 masque-порты: все 7 рабочих у ОБОИХ транспортов', () async {
    final p = await WarpEndpointPicker.load();
    // Наборы заданы раздельными ключами (ports_h3/ports_h2), но device-verified
    // рабочие порты одинаковы — важно, что это не сузилось случайно.
    expect(p.masquePortsFor('h3'), [443, 500, 1701, 4500, 4443, 8443, 8095]);
    expect(p.masquePortsFor('h2'), [443, 500, 1701, 4500, 4443, 8443, 8095]);
  });

  test('§305 randomMasqueIp: h3 — ТОЛЬКО 4 живых хоста, h2 — весь блок',
      () async {
    final p = await WarpEndpointPicker.load();
    const h3hosts = {
      '162.159.198.1',
      '162.159.198.2',
      '162.159.199.1',
      '162.159.199.2',
    };
    final h2seen = <String>{};
    for (var i = 0; i < 100; i++) {
      // h3 — рандом по узкому списку: любой результат обязан быть живым хостом.
      final ipH3 = p.randomMasqueIp(network: 'h3');
      expect(h3hosts, contains(ipH3), reason: 'h3 IP $ipH3 вне живых хостов');
      // h2 — по всему блоку.
      final ipH2 = p.randomMasqueIp(network: 'h2');
      expect(ipH2, isNotNull);
      expect(ipH2!.startsWith('162.159.198.') ||
          ipH2.startsWith('162.159.199.'), isTrue,
          reason: 'h2 IP $ipH2 вне masque-блоков');
      h2seen.add(ipH2);
    }
    // h2 действительно варьируется по блоку, а не сидит на 4 адресах.
    expect(h2seen.length, greaterThan(h3hosts.length),
        reason: 'h2 должен разбрасываться шире, чем h3-список');
    const allPorts = [443, 500, 1701, 4500, 4443, 8443, 8095];
    expect(allPorts, contains(p.randomMasquePortFor('h3')));
    expect(allPorts, contains(p.randomMasquePortFor('h2')));
  });

  test('§418 api.hosts из asset: devices первым, legacy запасным; '
      'зашитый fallback клиента совпадает с asset', () async {
    final p = await WarpEndpointPicker.load();
    expect(p.apiHosts, [
      'https://api.devices.cloudflare.com',
      'https://api.cloudflareclient.com',
    ]);
    // Один список в двух местах намеренно (asset — боевой, const — на случай
    // битого asset); расхождение = кто-то поправил одно и забыл другое.
    expect(p.apiHosts, WarpApi.fallbackHosts);
  });
}
