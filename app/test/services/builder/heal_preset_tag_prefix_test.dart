import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';

// §103 C7 — миграция ссылок на теги пресетов.
//
// Состояние пользователя, записанное до неймспейса, ссылается на локальный
// тег. Ядро такой конфиг ПРОПУСКАЕТ на старте и падает лениво — «DNS server
// not found» на каждом сматчившемся соединении. Пользователь увидит не
// «обновление сломало настройку», а «часть сайтов не работает».

Map<String, dynamic> _config({
  List<Map<String, dynamic>> dnsServers = const [],
  List<Map<String, dynamic>> dnsRules = const [],
  List<Map<String, dynamic>> ruleSets = const [],
  List<Map<String, dynamic>> routeRules = const [],
  String? dnsFinal,
}) =>
    {
      'dns': {
        'servers': dnsServers,
        'rules': dnsRules,
        if (dnsFinal != null) 'final': dnsFinal,
      },
      'route': {'rule_set': ruleSets, 'rules': routeRules},
    };

void main() {
  test('старая ссылка на DNS-сервер пресета переезжает на новый тег', () {
    final config = _config(
      dnsServers: [
        {'tag': 'ru-direct:yandex_doh', 'type': 'https'},
      ],
      dnsRules: [
        {'domain_suffix': ['ya.ru'], 'server': 'yandex_doh'},
      ],
    );

    final healed = healPresetTagPrefix(config);

    expect(healed, hasLength(1));
    expect(healed.single.from, 'yandex_doh');
    expect(healed.single.to, 'ru-direct:yandex_doh');
    expect((config['dns']!['rules'] as List).single['server'],
        'ru-direct:yandex_doh');
  });

  test('ссылка на rule_set переезжает, в том числе в списке', () {
    final config = _config(
      ruleSets: [
        {'tag': 'ru-direct:ru-domains', 'type': 'local'},
        {'tag': 'ru-direct:geoip-ru', 'type': 'local'},
      ],
      routeRules: [
        {'rule_set': ['ru-domains', 'geoip-ru'], 'outbound': 'direct-out'},
      ],
    );

    healPresetTagPrefix(config);

    expect((config['route']!['rules'] as List).single['rule_set'],
        ['ru-direct:ru-domains', 'ru-direct:geoip-ru']);
  });

  test('server у route-правила с action:resolve тоже чинится', () {
    final config = _config(
      dnsServers: [
        {'tag': 'ru-direct:dns_ru', 'type': 'group'},
      ],
      routeRules: [
        {'action': 'resolve', 'server': 'dns_ru'},
      ],
    );

    healPresetTagPrefix(config);

    expect((config['route']!['rules'] as List).single['server'],
        'ru-direct:dns_ru');
  });

  test('dns.final тоже переезжает', () {
    final config = _config(
      dnsServers: [
        {'tag': 'ru-direct:yandex_doh', 'type': 'https'},
      ],
      dnsFinal: 'yandex_doh',
    );

    healPresetTagPrefix(config);

    expect(config['dns']!['final'], 'ru-direct:yandex_doh');
  });

  // Неоднозначность не чиним: угадывать, какой из двух пресетов имел в виду
  // пользователь, — значит молча выбрать не тот.
  test('одинаковый локальный тег у двух пресетов — ссылка не трогается', () {
    final config = _config(
      dnsServers: [
        {'tag': 'preset-a:dns', 'type': 'https'},
        {'tag': 'preset-b:dns', 'type': 'https'},
      ],
      dnsRules: [
        {'domain_suffix': ['x.com'], 'server': 'dns'},
      ],
    );

    final healed = healPresetTagPrefix(config);

    expect(healed, isEmpty);
    expect((config['dns']!['rules'] as List).single['server'], 'dns');
  });

  // Ссылка на живой тег не трогается, даже если совпала с чьим-то локальным
  // именем: пользователь выбрал именно этот сервер.
  test('существующий тег имеет приоритет над миграцией', () {
    final config = _config(
      dnsServers: [
        {'tag': 'dns_ru', 'type': 'udp'},
        {'tag': 'ru-direct:dns_ru', 'type': 'group'},
      ],
      dnsRules: [
        {'domain_suffix': ['x.com'], 'server': 'dns_ru'},
      ],
    );

    final healed = healPresetTagPrefix(config);

    expect(healed, isEmpty);
    expect((config['dns']!['rules'] as List).single['server'], 'dns_ru');
  });

  test('конфиг без префиксованных тегов не трогается', () {
    final config = _config(
      dnsServers: [
        {'tag': 'google', 'type': 'udp'},
      ],
      dnsRules: [
        {'domain_suffix': ['x.com'], 'server': 'google'},
      ],
    );

    expect(healPresetTagPrefix(config), isEmpty);
    expect((config['dns']!['rules'] as List).single['server'], 'google');
  });

  test('ссылка в никуда остаётся нетронутой — её снимет деградация', () {
    final config = _config(
      dnsServers: [
        {'tag': 'ru-direct:yandex_doh', 'type': 'https'},
      ],
      dnsRules: [
        {'domain_suffix': ['x.com'], 'server': 'ghost'},
      ],
    );

    expect(healPresetTagPrefix(config), isEmpty);
    expect((config['dns']!['rules'] as List).single['server'], 'ghost');
  });
}
