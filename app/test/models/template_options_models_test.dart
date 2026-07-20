import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';

/// §279 Phase 2 (§3.3 hardening) — typed-модели трёх raw-секций шаблона
/// (dns_options.servers / ping_options.presets / speed_test_options.servers)
/// парсятся из уже-оверлеенного JSON; display-поля читаются только через них.
void main() {
  final template = WizardTemplate.fromJson({
    'dns_options': {
      'servers': [
        {
          'description': 'System DNS',
          'enabled': true,
          'server': {'type': 'local', 'tag': 'local_dns_resolver'},
        },
        {
          'description': 'Google DNS (direct)',
          'server': {'type': 'udp', 'tag': 'google_udp'},
          'vars': [
            {
              'name': 'dns_ip',
              'type': 'enum',
              'default_value': '8.8.8.8',
              'title': 'Address',
            },
          ],
        },
        // malformed: без server.tag — пропускается.
        {'description': 'Broken'},
      ],
      'rules': [
        {'name': 'identity-key', 'enabled': true},
      ],
    },
    'ping_options': {
      'url': 'https://www.gstatic.com/generate_204',
      'timeout_ms': 5000,
      'presets': [
        {'id': 'google-204', 'name': 'Google 204', 'url': 'https://g/204'},
        {'id': 'yandex', 'name': 'Yandex', 'url': 'https://ya.ru/'},
      ],
    },
    'speed_test_options': {
      'servers': [
        {
          'id': 'cloudflare',
          'name': 'Cloudflare',
          'download_url': 'https://cf/down',
          'upload_url': 'https://cf/up',
          'upload_method': 'POST',
          'ping_url': 'https://cf/ping',
        },
        {
          'id': 'selectel-ru',
          'name': 'Selectel (RU)',
          'download_url': 'https://sel/10MB',
        },
      ],
      'stream_options': [1, 4, 10],
      'default_streams': 4,
    },
  });

  test('DnsOptionsModel: tag из вложенного server, malformed пропущен', () {
    final m = template.dnsOptionsModel;
    expect(m.servers.map((s) => s.tag), ['local_dns_resolver', 'google_udp']);
    expect(m.servers.first.description, 'System DNS');
    expect(m.servers.first.enabled, isTrue);
    expect(m.servers[1].vars.single.title, 'Address');
    // Обёртка сохранена для machine-уровня (резолвер body / редактор).
    expect(m.wrappersByTag['google_udp']?['server'],
        containsPair('type', 'udp'));
  });

  test('PingOptionsModel: дефолты + пресеты по id', () {
    final m = template.pingOptionsModel;
    expect(m.defaultUrl, 'https://www.gstatic.com/generate_204');
    expect(m.defaultTimeoutMs, 5000);
    expect(m.presets.map((p) => p.id), ['google-204', 'yandex']);
    expect(m.presets.first.name, 'Google 204');
    expect(m.presets.first.url, 'https://g/204');
  });

  test('SpeedTestOptionsModel: серверы + потоки', () {
    final m = template.speedTestOptionsModel;
    expect(m.servers.map((s) => s.id), ['cloudflare', 'selectel-ru']);
    expect(m.servers.first.uploadMethod, 'POST');
    expect(m.servers.first.uploadUrl, 'https://cf/up');
    expect(m.servers.first.pingUrl, 'https://cf/ping');
    // Отсутствующие поля — дефолты (fallback-цепочки экрана).
    expect(m.servers[1].uploadUrl, isNull);
    expect(m.servers[1].uploadMethod, 'PUT');
    expect(m.servers[1].pingUrl, isEmpty);
    expect(m.streamOptions, [1, 4, 10]);
    expect(m.defaultStreams, 4);
  });

  test('пустые секции — пустые модели (без throw)', () {
    final empty = WizardTemplate.fromJson(const {});
    expect(empty.dnsOptionsModel.servers, isEmpty);
    expect(empty.pingOptionsModel.presets, isEmpty);
    expect(empty.pingOptionsModel.defaultTimeoutMs, 0);
    expect(empty.speedTestOptionsModel.servers, isEmpty);
    expect(empty.speedTestOptionsModel.defaultStreams, isNull);
  });
}
