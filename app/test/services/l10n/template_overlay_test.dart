import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/l10n/template_overlay.dart';

/// §279 — TemplateOverlay: applier/extractor поверх декодированного
/// wizard_template.json (схема адресов §3.2 спеки 279).
void main() {
  Map<String, dynamic> loadRealTemplate() =>
      jsonDecode(File('assets/wizard_template.json').readAsStringSync())
          as Map<String, dynamic>;

  /// Минимальный синтетический шаблон, покрывающий все узлы схемы.
  Map<String, dynamic> syntheticTemplate() => {
        'parser_config': {'inner': 'machine'},
        'config': {
          'log': {'level': '@log_level'},
        },
        'sections': [
          {
            'id': 'general',
            'name': 'General',
            'description': 'General settings',
            'chapter': 'core',
            'vars': [
              {
                'name': 'log_level',
                'type': 'enum',
                'title': 'Log level',
                'tooltip': 'Verbosity',
                'default_value': 'warn',
                'options': ['warn', 'info'],
              },
              {
                'name': 'vpn_mode',
                'type': 'enum',
                'title': 'Mode',
                'options': [
                  {'title': 'VPN — system-wide', 'value': 'vpn'},
                ],
              },
              {'ref': 'resolve_enabled'},
            ],
          },
        ],
        'selectable_rules': [
          {
            'preset_id': 'ru-direct',
            'ui': {'label': 'RU Direct', 'description': 'Route RU directly'},
            'vars': [
              {'name': 'dns_server', 'title': 'DNS server', 'tooltip': 'T1'},
            ],
            'dns_servers': [
              {'tag': 'yandex_udp', 'description': 'Yandex UDP'},
            ],
            'rule': {'outbound': '@outbound'},
          },
          {
            'preset_id': 'fakeip',
            'ui': {'label': 'FakeIP', 'description': 'FakeIP mode'},
            'vars': [
              // Одноимённая var с ДРУГИМ текстом — скоупинг по preset_id
              // обязан развести адреса (P0 ревью §279).
              {'name': 'dns_server', 'title': 'FakeIP server', 'tooltip': 'T2'},
            ],
          },
        ],
        'group_templates': {
          'magic_nodes': {
            'direct': {'title': 'Direct', 'tag': 'direct-out'},
          },
        },
        'default_directions': [
          {'tag': 'vpn-1', 'label': 'VPN 1'},
        ],
        'dns_options': {
          'servers': [
            {
              'description': 'Google DNS',
              'server': {'type': 'udp', 'tag': 'google_udp'},
              'vars': [
                {
                  'name': 'dns_ip',
                  'title': 'Server IP',
                  'options': [
                    {'title': '8.8.8.8 · Primary v4', 'value': '8.8.8.8'},
                  ],
                },
              ],
            },
          ],
          'rules': [
            {'name': 'identity-name', 'rule': {}},
          ],
        },
        'ping_options': {
          'presets': [
            {'id': 'google-204', 'name': 'Google 204', 'url': 'https://x'},
          ],
        },
        'speed_test_options': {
          'servers': [
            {'id': 'cloudflare', 'name': 'Cloudflare', 'download_url': 'u'},
          ],
        },
      };

  group('extract', () {
    test('deterministic over real template', () {
      final a = TemplateOverlay.extract(loadRealTemplate());
      final b = TemplateOverlay.extract(loadRealTemplate());
      expect(a, isNotEmpty);
      expect(a, equals(b));
      expect(a.keys.toList(), equals(b.keys.toList()));
    });

    test('english → english mirror per §3.2 schema', () {
      final m = TemplateOverlay.extract(syntheticTemplate());
      // Ключ = само display-значение; map — english→english зеркало.
      expect(m['General'], 'General');
      expect(m['General settings'], 'General settings');
      expect(m['Log level'], 'Log level');
      expect(m['Verbosity'], 'Verbosity');
      expect(m['VPN — system-wide'], 'VPN — system-wide');
      // Одноимённые vars разных пресетов несут РАЗНЫЙ текст → оба ключа есть.
      expect(m['DNS server'], 'DNS server');
      expect(m['FakeIP server'], 'FakeIP server');
      expect(m['RU Direct'], 'RU Direct');
      expect(m['Yandex UDP'], 'Yandex UDP');
      expect(m['Direct'], 'Direct');
      expect(m['VPN 1'], 'VPN 1');
      expect(m['Google DNS'], 'Google DNS');
      expect(m['8.8.8.8 · Primary v4'], '8.8.8.8 · Primary v4');
      expect(m['Google 204'], 'Google 204');
      expect(m['Cloudflare'], 'Cloudflare');
      // Machine-значения не извлекаются.
      expect(m.containsKey('machine'), isFalse);
      expect(m.containsKey('identity-name'), isFalse);
      // Bare-string enum-опции (wire-значения) не извлекаются.
      expect(m.containsKey('warn'), isFalse);
      expect(m.containsKey('info'), isFalse);
    });

    test('repeated english text collapses to one key (not a conflict)', () {
      final t = syntheticTemplate();
      // Второй section с ТЕМ ЖЕ english name — схлопывается в один ключ.
      (t['sections'] as List).add({
        'id': 'general-2',
        'name': 'General', // тот же текст, что и у первой секции
        'vars': <dynamic>[],
      });
      final m = TemplateOverlay.extract(t);
      expect(m['General'], 'General');
    });
  });

  group('apply', () {
    test('localizes display fields, leaves machine subtrees byte-identical',
        () {
      final t = syntheticTemplate();
      final configBefore = jsonEncode(t['config']);
      final parserBefore = jsonEncode(t['parser_config']);
      TemplateOverlay.apply(t, {
        'General': 'Общие',
        'DNS server': 'DNS-сервер',
        'VPN — system-wide': 'VPN — весь трафик',
        'Google DNS': 'Google DNS (напрямую)',
      });
      final sections = t['sections'] as List;
      expect((sections.first as Map)['name'], 'Общие');
      final rules = t['selectable_rules'] as List;
      final ruVar =
          (((rules.first as Map)['vars'] as List).first as Map);
      expect(ruVar['title'], 'DNS-сервер');
      // fakeip несёт ДРУГОЙ english ('FakeIP server') → не тронута overlay'ем
      // для 'DNS server'; english-ключ разводит их так же, как раньше адрес.
      final fakeVar =
          (((rules[1] as Map)['vars'] as List).first as Map);
      expect(fakeVar['title'], 'FakeIP server');
      final opt = ((((sections.first as Map)['vars'] as List)[1]
          as Map)['options'] as List)
          .first as Map;
      expect(opt['title'], 'VPN — весь трафик');
      expect(opt['value'], 'vpn'); // machine-значение не тронуто
      // Whitelist: config/parser_config byte-identical.
      expect(jsonEncode(t['config']), configBefore);
      expect(jsonEncode(t['parser_config']), parserBefore);
    });

    test('skips values starting with @ or containing {', () {
      final t = syntheticTemplate();
      TemplateOverlay.apply(t, {
        'General': '@log_level',
        'General settings': 'bad {placeholder}',
      });
      final s = (t['sections'] as List).first as Map;
      expect(s['name'], 'General');
      expect(s['description'], 'General settings');
    });

    test('unknown english keys are a silent no-op', () {
      final t = syntheticTemplate();
      final before = jsonEncode(t);
      TemplateOverlay.apply(t, {'Not in template': 'X'});
      expect(jsonEncode(t), before);
    });
  });

  // §578 — dns_servers[] тела пресета: плоский сервер, условная обёртка
  // `#if/#value/#else`, тег-`#tpl` (пресет с `for_each`).
  group('preset dns_servers', () {
    Map<String, dynamic> presetWith(List<dynamic> servers) => {
          'selectable_rules': [
            {
              'preset_id': 'p',
              'ui': {'label': 'P'},
              'dns_servers': servers,
            },
          ],
        };

    Map<String, dynamic> serversOf(Map<String, dynamic> t, int i) =>
        (((t['selectable_rules'] as List).first as Map)['dns_servers']
            as List)[i] as Map<String, dynamic>;

    test('flat server: extracted and localized as before', () {
      final t = presetWith([
        {'type': 'udp', 'tag': 'flat', 'description': 'Flat server'},
      ]);
      expect(TemplateOverlay.extract(t), containsPair('Flat server', 'Flat server'));
      TemplateOverlay.apply(t, {'Flat server': 'Плоский'});
      expect(serversOf(t, 0)['description'], 'Плоский');
    });

    test('server inside #if: #value and #else branches', () {
      final t = presetWith([
        {
          '#if': {
            '#and': ['@dns_enable'],
            '#value': {'tag': 'a', 'description': 'On branch'},
            '#else': {'tag': 'b', 'description': 'Off branch'},
          },
        },
      ]);
      final m = TemplateOverlay.extract(t);
      expect(m.keys, containsAll(['On branch', 'Off branch']));
      TemplateOverlay.apply(t, {'On branch': 'Вкл', 'Off branch': 'Выкл'});
      final cond = serversOf(t, 0)['#if'] as Map;
      expect((cond['#value'] as Map)['description'], 'Вкл');
      expect((cond['#else'] as Map)['description'], 'Выкл');
      expect(cond['#and'], ['@dns_enable']); // условие не тронуто
    });

    test('server with #tpl tag: localized, tag object untouched', () {
      final t = presetWith([
        {
          '#if': {
            '#and': ['@dns_enable'],
            '#value': {
              'type': 'tailscale',
              'tag': {'#tpl': '@{node}-dns'},
              'description': 'MagicDNS of the tailnet',
            },
          },
        },
      ]);
      expect(TemplateOverlay.extract(t).keys, contains('MagicDNS of the tailnet'));
      TemplateOverlay.apply(t, {'MagicDNS of the tailnet': 'MagicDNS сети'});
      final body = (serversOf(t, 0)['#if'] as Map)['#value'] as Map;
      expect(body['description'], 'MagicDNS сети');
      expect(body['tag'], {'#tpl': '@{node}-dns'});
    });
  });

  group('parseLocaleFile', () {
    test('accepts {value} object entries and flat strings', () {
      final m = TemplateOverlay.parseLocaleFile({
        'a': {'value': 'A-текст'},
        'b': 'B-текст',
        'c': {'no_value': true},
        'd': 42,
      });
      expect(m, {'a': 'A-текст', 'b': 'B-текст'});
    });
  });
}
