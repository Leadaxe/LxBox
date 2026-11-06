import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/screens/dns_settings_screen/dns_server_copy.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// §682 — копия шаблонного/пресетного DNS-сервера.
void main() {
  group('dnsCopyTag', () {
    test('свободный <тег>_copy', () {
      expect(dnsCopyTag('google_doh', {'google_doh'}), 'google_doh_copy');
    });
    test('занятый → _copy2, _copy3', () {
      expect(
          dnsCopyTag('google_doh', {'google_doh_copy', 'google_doh_copy2'}),
          'google_doh_copy3');
    });
    test('пространство пресета снимается', () {
      expect(dnsCopyTag('ru-direct:yandex_dot', {}), 'yandex_dot_copy');
    });
  });

  test('dnsServerCopy: detour direct-out снят, ref-поля сняты, тело — копия',
      () {
    final src = <String, dynamic>{
      'type': 'tls',
      'tag': 'x',
      'server': '1.1.1.1',
      'tls': {'enabled': true},
      'detour': 'direct-out',
      '_preset_label': 'P',
    };
    final c = dnsServerCopy(
        body: src, tag: 'x_copy', enabled: true, description: 'X (copy)');
    expect(c.tag, 'x_copy');
    expect(c.description, 'X (copy)');
    expect(c.body, {
      'type': 'tls',
      'server': '1.1.1.1',
      'tls': {'enabled': true},
    });
    (c.body['tls'] as Map)['enabled'] = false;
    expect((src['tls'] as Map)['enabled'], true);
  });

  group('Save as copy у шаблонной записи', () {
    const wrapper = <String, dynamic>{
      'description': 'Quad9 DoH',
      'vars': [
        {'name': 'outbound', 'type': 'outbound', 'default_value': 'vpn-1'},
        {'name': 'dns_ip', 'type': 'enum', 'default_value': '9.9.9.9'},
      ],
      'server': {
        'type': 'https',
        'tag': 'quad9_doh',
        'server': '@dns_ip',
        'detour': '@outbound',
      },
    };
    const ref = DnsServerTemplate(
        enabled: true, tag: 'quad9_doh', varValues: {'dns_ip': '2620:fe::9'});
    DnsServerEditController make() => DnsServerEditController(
          initialRef: ref,
          resolved: const ResolvedServer(
            kind: ServerKind.template,
            tag: 'quad9_doh',
            description: 'Quad9 DoH',
            enabled: true,
            body: {'type': 'https', 'tag': 'quad9_doh'},
          ),
          templateWrapper: wrapper,
          canonicalDescription: 'Quad9 DoH',
        );

    test('тег не менялся — обычный Save, не dirty', () {
      final c = make();
      expect(c.savesAsCopy, isFalse);
      expect(c.isDirty(), isFalse);
      c.dispose();
    });

    test('сменённый тег → копия с текущими vars, оригинал в snapshot цел', () {
      final c = make();
      c.tagCtrl.text = 'my_quad9';
      expect(c.savesAsCopy, isTrue);
      expect(c.isDirty(), isTrue);
      final copy = c.copySnapshot('my_quad9');
      expect(copy.tag, 'my_quad9');
      expect(copy.description, 'Quad9 DoH');
      expect(copy.body, {
        'type': 'https',
        'server': '2620:fe::9',
        'detour': 'vpn-1',
      });
      expect(c.snapshot(), ref);
      c.tagCtrl.text = 'quad9_doh';
      expect(c.savesAsCopy, isFalse);
      c.dispose();
    });
  });
}
