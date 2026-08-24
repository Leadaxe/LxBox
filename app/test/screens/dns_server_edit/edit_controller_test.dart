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

    test('inline-detour: выбор Направления пишет body.detour, direct-out стирает',
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
      // tag — часть sing-box-тела: в new-режиме синхронизируется в поле Tag.
      expect(c.tagCtrl.text, 'x');
      expect(c.snapshot()['tag'], 'x');
      c.dispose();
    });

    test('JSON показывает tag; правка Tag в Params пересинхронизирует JSON',
        () {
      final c = makeNew();
      expect(c.bodyCtrl.text, contains('"tag": "dns_new"'));
      c.tagCtrl.text = 'my_dns';
      expect(c.bodyCtrl.text, contains('"tag": "my_dns"'));
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

  group('форма inline-сервера — UDP/DoT/DoH (§117 задача 4b)', () {
    DnsServerEditController makeNew({List<String> tags = const []}) =>
        DnsServerEditController(
          initialRef: {
            'enabled': true,
            'kind': 'inline',
            'tag': 'dns_new',
            'body': {'type': 'udp'},
          },
          dnsServerTags: tags,
        );

    test('режим по body.type; неизвестный type → null (JSON-only)', () {
      final c = makeNew();
      expect(c.serverMode, 'udp');
      c.onBodyTextChanged('{"type":"local"}');
      expect(c.serverMode, null);
      expect(c.rawServerType, 'local');
      c.dispose();
    });

    test('адрес/порт пишутся в body; пустой порт → ключа нет (дефолт)', () {
      final c = makeNew();
      c.onAddressChanged('9.9.9.9');
      c.onPortChanged('5353');
      expect(c.snapshot()['body'],
          {'type': 'udp', 'server': '9.9.9.9', 'server_port': 5353});
      c.onPortChanged('');
      expect(
          (c.snapshot()['body'] as Map).containsKey('server_port'), false);
      c.dispose();
    });

    test('переключение режима: стандартный порт снимается, кастомный живёт',
        () {
      final c = makeNew();
      c.onAddressChanged('9.9.9.9');
      c.onPortChanged('53'); // дефолт udp
      c.setServerMode('tls');
      final body = c.snapshot()['body'] as Map;
      expect(body['type'], 'tls');
      expect(body.containsKey('server_port'), false,
          reason: 'дефолтный порт старого режима → дефолт нового');
      c.onPortChanged('8853'); // кастомный
      c.setServerMode('https');
      expect(c.snapshot()['body']['server_port'], 8853);
      c.dispose();
    });

    test('DoH: path/SNI; уход с https чистит path, udp чистит tls', () {
      final c = makeNew();
      c.setServerMode('https');
      c.onAddressChanged('8.8.8.8');
      c.onPathChanged('dns-query'); // без слэша — нормализуется
      c.onSniChanged('dns.google');
      expect(c.snapshot()['body'], {
        'type': 'https',
        'server': '8.8.8.8',
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'dns.google'},
      });
      c.setServerMode('tls');
      var body = c.snapshot()['body'] as Map;
      expect(body.containsKey('path'), false);
      expect(body.containsKey('tls'), true, reason: 'SNI валиден для DoT');
      c.setServerMode('udp');
      body = c.snapshot()['body'] as Map;
      expect(body.containsKey('tls'), false);
      c.dispose();
    });

    test('DoH URL-вставка: https://host/path → server+path+режим', () {
      final c = makeNew(tags: ['google_udp', 'cloudflare_udp']);
      c.onAddressChanged('https://dns.quad9.net/dns-query');
      final body = c.snapshot()['body'] as Map;
      expect(body['type'], 'https');
      expect(body['server'], 'dns.quad9.net');
      expect(body['path'], '/dns-query');
      expect(c.addressCtrl.text, 'dns.quad9.net');
      c.dispose();
    });

    test('hostname-адрес → авто domain_resolver (google_udp), IP → снимается',
        () {
      final c = makeNew(tags: ['google_udp', 'cloudflare_udp']);
      c.onAddressChanged('dns.adguard-dns.com');
      expect(c.snapshot()['body']['domain_resolver'], 'google_udp');
      c.setDomainResolver('cloudflare_udp');
      expect(c.snapshot()['body']['domain_resolver'], 'cloudflare_udp');
      c.onAddressChanged('94.140.14.14');
      expect((c.snapshot()['body'] as Map).containsKey('domain_resolver'),
          false);
      c.dispose();
    });

    test('JSON-edit подтягивает поля формы (двусторонняя синхронизация)', () {
      final c = makeNew();
      c.onBodyTextChanged(
          '{"type":"tls","server":"1.1.1.1","server_port":853,'
          '"tls":{"enabled":true,"server_name":"one.one.one.one"}}');
      expect(c.serverMode, 'tls');
      expect(c.addressCtrl.text, '1.1.1.1');
      expect(c.portCtrl.text, '853');
      expect(c.sniCtrl.text, 'one.one.one.one');
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

    test('edit existing: смена tag в JSON = rename (синхронизирует поле Tag)',
        () {
      final c = DnsServerEditController(
        initialRef: {
          'enabled': true,
          'kind': 'inline',
          'tag': 'my-dns',
          'body': {'type': 'udp', 'server': '192.168.1.1'},
        },
        resolved: const ResolvedServer(
          kind: ServerKind.inline,
          tag: 'my-dns',
          description: '',
          enabled: true,
          body: {'type': 'udp', 'tag': 'my-dns', 'server': '192.168.1.1'},
        ),
      );
      expect(c.bodyCtrl.text, contains('"tag": "my-dns"'));
      c.onBodyTextChanged(
          '{"tag":"other","type":"udp","server":"192.168.1.1"}');
      // §117 задача 4b: rename разрешён — каскад по ссылкам на save.
      expect(c.jsonError, null);
      expect(c.tagCtrl.text, 'other');
      expect(c.snapshot()['tag'], 'other');
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
