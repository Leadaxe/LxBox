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
        'default_channels': [
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

    test('committed en.json equals fresh extraction', () {
      final committed = jsonDecode(
              File('assets/l10n/template/en.json').readAsStringSync())
          as Map<String, dynamic>;
      final fresh = TemplateOverlay.extract(loadRealTemplate());
      expect(Map<String, String>.from(committed), equals(fresh));
    });

    test('scoped addresses per §3.2 schema', () {
      final m = TemplateOverlay.extract(syntheticTemplate());
      expect(m['section.general.name'], 'General');
      expect(m['section.general.description'], 'General settings');
      expect(m['var.log_level.title'], 'Log level');
      expect(m['var.log_level.tooltip'], 'Verbosity');
      expect(m['var.vpn_mode.option.vpn'], 'VPN — system-wide');
      // Rule-локальные vars скоупятся preset_id — одноимённые не схлопнуты.
      expect(m['preset.ru-direct.var.dns_server.title'], 'DNS server');
      expect(m['preset.fakeip.var.dns_server.title'], 'FakeIP server');
      expect(m['preset.ru-direct.label'], 'RU Direct');
      expect(m['preset.ru-direct.dns_server.yandex_udp.description'],
          'Yandex UDP');
      expect(m['magic.direct.title'], 'Direct');
      expect(m['channel.vpn-1.label'], 'VPN 1');
      expect(m['dns_server.google_udp.description'], 'Google DNS');
      expect(m['dns_server.google_udp.var.dns_ip.option.8.8.8.8'],
          '8.8.8.8 · Primary v4');
      expect(m['ping.google-204.name'], 'Google 204');
      expect(m['speed.cloudflare.name'], 'Cloudflare');
      // Machine-поля не адресуются.
      expect(m.keys.where((k) => k.contains('identity-name')), isEmpty);
      expect(m.values.where((v) => v == 'machine'), isEmpty);
      // Bare-string enum-опции не адресуются.
      expect(m.keys.where((k) => k.startsWith('var.log_level.option')),
          isEmpty);
    });

    test('hard-fails on duplicate address with conflicting values', () {
      final t = syntheticTemplate();
      (t['sections'] as List).add({
        'id': 'general', // дубль id с другим name
        'name': 'Different',
        'vars': <dynamic>[],
      });
      expect(() => TemplateOverlay.extract(t), throwsStateError);
    });

    test('duplicate address with identical value is allowed', () {
      final t = syntheticTemplate();
      (t['sections'] as List).add({
        'id': 'general',
        'name': 'General', // same value → не конфликт
        'vars': <dynamic>[],
      });
      expect(TemplateOverlay.extract(t)['section.general.name'], 'General');
    });
  });

  group('apply', () {
    test('localizes display fields, leaves machine subtrees byte-identical',
        () {
      final t = syntheticTemplate();
      final configBefore = jsonEncode(t['config']);
      final parserBefore = jsonEncode(t['parser_config']);
      TemplateOverlay.apply(t, {
        'section.general.name': 'Общие',
        'preset.ru-direct.var.dns_server.title': 'DNS-сервер',
        'var.vpn_mode.option.vpn': 'VPN — весь трафик',
        'dns_server.google_udp.description': 'Google DNS (напрямую)',
      });
      final sections = t['sections'] as List;
      expect((sections.first as Map)['name'], 'Общие');
      final rules = t['selectable_rules'] as List;
      final ruVar =
          (((rules.first as Map)['vars'] as List).first as Map);
      expect(ruVar['title'], 'DNS-сервер');
      // fakeip (одноимённая var) не тронута — скоупинг работает.
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
        'section.general.name': '@log_level',
        'section.general.description': 'bad {placeholder}',
      });
      final s = (t['sections'] as List).first as Map;
      expect(s['name'], 'General');
      expect(s['description'], 'General settings');
    });

    test('unknown addresses are a silent no-op', () {
      final t = syntheticTemplate();
      final before = jsonEncode(t);
      TemplateOverlay.apply(t, {'section.nonexistent.name': 'X'});
      expect(jsonEncode(t), before);
    });
  });

  group('parseLocaleFile', () {
    test('accepts object entries and flat strings, ignores src', () {
      final m = TemplateOverlay.parseLocaleFile({
        'a': {'text': 'A-текст', 'src': 'deadbeef'},
        'b': 'B-текст',
        'c': {'no_text': true},
        'd': 42,
      });
      expect(m, {'a': 'A-текст', 'b': 'B-текст'});
    });
  });
}
