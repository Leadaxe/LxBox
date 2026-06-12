import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// §117 задача 4 — `DnsServerEditController`: snapshot/isDirty по kind,
/// inline-detour (`body['detour']`, locked decision №10), JSON-валидация
/// со strip'ом ref-level полей (бывший server_editor_sheet).
void main() {
  group('inline (new-режим)', () {
    DnsServerEditController makeNew() => DnsServerEditController(
          initialRef: {
            'enabled': true,
            'kind': 'inline',
            'tag': 'dns_new',
            'description': 'My DNS',
            'body': {'type': 'udp', 'server': '1.1.1.1', 'server_port': 53},
          },
        );

    test('snapshot: tag/description из контроллеров, body без detour', () {
      final c = makeNew();
      c.tagCtrl.text = 'my_dns';
      final snap = c.snapshot();
      expect(snap['kind'], 'inline');
      expect(snap['tag'], 'my_dns');
      expect(snap['description'], 'My DNS');
      expect(snap['body'], {
        'type': 'udp',
        'server': '1.1.1.1',
        'server_port': 53,
      });
      expect((snap['body'] as Map).containsKey('detour'), false,
          reason: 'дефолт — отсутствие ключа (решение №2)');
      c.dispose();
    });

    test('inline-detour: выбор канала пишет body.detour, direct-out стирает',
        () {
      final c = makeNew();
      expect(c.inlineDetour, 'direct-out'); // ключа нет → direct
      c.setInlineDetour('vpn-1');
      expect(c.snapshot()['body']['detour'], 'vpn-1');
      expect(c.inlineDetour, 'vpn-1');
      // JSON-вкладка синхронизирована
      expect(c.bodyCtrl.text, contains('"detour": "vpn-1"'));
      c.setInlineDetour('direct-out');
      expect((c.snapshot()['body'] as Map).containsKey('detour'), false);
      c.dispose();
    });

    test('JSON edit: валидный объект становится body, ref-поля strip', () {
      final c = makeNew();
      c.onBodyTextChanged(
          '{"type":"tls","server":"9.9.9.9","server_port":853,'
          '"tag":"x","description":"y","enabled":false,"_origin":"z"}');
      expect(c.jsonError, null);
      expect(c.snapshot()['body'], {
        'type': 'tls',
        'server': '9.9.9.9',
        'server_port': 853,
      });
      c.dispose();
    });

    test('JSON edit: невалидный → jsonError, последний валидный body жив', () {
      final c = makeNew();
      c.onBodyTextChanged('{"type":"udp"');
      expect(c.jsonError, isNotNull);
      expect(c.snapshot()['body']['server'], '1.1.1.1');
      c.onBodyTextChanged('[1,2]');
      expect(c.jsonError, isNotNull);
      c.onBodyTextChanged('{"type":"udp","server":"8.8.8.8"}');
      expect(c.jsonError, null);
      expect(c.snapshot()['body']['server'], '8.8.8.8');
      c.dispose();
    });

    test('isDirty: false до правок (new — заготовка), true после', () {
      final c = makeNew();
      expect(c.isDirty(), false);
      c.setInlineDetour('vpn-1');
      expect(c.isDirty(), true);
      c.setInlineDetour('direct-out');
      expect(c.isDirty(), false);
      c.dispose();
    });
  });

  group('template (edit existing)', () {
    ResolvedServer resolvedTemplate() => const ResolvedServer(
          kind: ServerKind.template,
          tag: 'google_udp',
          description: 'Google DNS (direct)',
          enabled: true,
          body: {'type': 'udp', 'tag': 'google_udp', 'server': '8.8.8.8'},
        );

    DnsServerEditController makeTpl({Map<String, dynamic>? ref}) =>
        DnsServerEditController(
          initialRef:
              ref ?? {'enabled': true, 'kind': 'template', 'tag': 'google_udp'},
          resolved: resolvedTemplate(),
          canonicalDescription: 'Google DNS (direct)',
        );

    test('не dirty при открытии; description == canonical не пишется в ref',
        () {
      final c = makeTpl();
      expect(c.isDirty(), false);
      final snap = c.snapshot();
      expect(snap.containsKey('description'), false);
      expect(snap.containsKey('varValues'), false);
      c.dispose();
    });

    test('setVarValue → varValues в snapshot, dirty', () {
      final c = makeTpl();
      c.setVarValue('outbound', 'vpn-1');
      expect(c.isDirty(), true);
      expect(c.snapshot()['varValues'], {'outbound': 'vpn-1'});
      c.dispose();
    });

    test('существующие varValues сохраняются и дополняются', () {
      final c = makeTpl(ref: {
        'enabled': true,
        'kind': 'template',
        'tag': 'google_udp',
        'varValues': {'dns_ip': '8.8.4.4'},
      });
      expect(c.isDirty(), false);
      c.setVarValue('outbound', 'vpn-1');
      expect(c.snapshot()['varValues'],
          {'dns_ip': '8.8.4.4', 'outbound': 'vpn-1'});
      c.dispose();
    });

    test('description-override пишется только при отличии от canonical', () {
      final c = makeTpl();
      c.descCtrl.text = 'Мой Google';
      expect(c.snapshot()['description'], 'Мой Google');
      c.descCtrl.text = 'Google DNS (direct)'; // вернули canonical
      expect(c.snapshot().containsKey('description'), false);
      c.dispose();
    });
  });

  group('lifecycle / kinds', () {
    test('locked (used by preset): editor видит lock и label', () {
      final c = DnsServerEditController(
        initialRef: {'enabled': true, 'kind': 'preset', 'tag': 'yandex_udp'},
        resolved: const ResolvedServer(
          kind: ServerKind.preset,
          tag: 'yandex_udp',
          description: 'Yandex',
          enabled: true,
          body: {'type': 'udp', 'tag': 'yandex_udp'},
          presetLabel: 'ru-direct',
        ),
        canonicalDescription: 'Yandex',
      );
      expect(c.locked, true);
      expect(c.lockedByLabel, 'ru-direct');
      expect(c.isUserOnly, false);
      c.dispose();
    });

    test('inline-override: overrides доступен (Reset-action в AppBar)', () {
      final c = DnsServerEditController(
        initialRef: {
          'enabled': true,
          'kind': 'inline',
          'tag': 'google_udp',
          'body': {'type': 'udp', 'server': '8.8.4.4'},
        },
        resolved: const ResolvedServer(
          kind: ServerKind.inline,
          tag: 'google_udp',
          description: 'Google DNS (direct)',
          enabled: true,
          body: {'type': 'udp', 'tag': 'google_udp', 'server': '8.8.4.4'},
          overrides: ServerKind.template,
        ),
      );
      expect(c.overrides, ServerKind.template);
      expect(c.isUserOnly, false);
      // body инициализирован из resolved.body без синтезированного tag'а
      expect(c.snapshot()['body'], {'type': 'udp', 'server': '8.8.4.4'});
      c.dispose();
    });
  });
}
