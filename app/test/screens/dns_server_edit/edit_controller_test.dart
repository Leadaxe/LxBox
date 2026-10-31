import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// §117 задача 4 — `DnsServerEditController`: snapshot/isDirty по kind,
/// inline-detour (`body['detour']`, locked decision №10), JSON-валидация
/// со strip'ом ref-level полей (бывший server_editor_sheet).
/// Тело inline-сервера снимка контроллера (модель, не форма хранения).
Map<String, dynamic> bodyOf(DnsServerEditController c) =>
    (c.snapshot() as DnsServerInline).body;

void main() {
  group('inline (new-режим)', () {
    DnsServerEditController makeNew() => DnsServerEditController(
          initialRef: const DnsServerInline(
            enabled: true,
            tag: 'dns_new',
            description: 'My DNS',
            body: {'type': 'udp', 'server': '1.1.1.1', 'server_port': 53},
          ),
        );

    test('snapshot: tag/description из контроллеров, body без detour', () {
      final c = makeNew();
      c.tagCtrl.text = 'my_dns';
      final snap = c.snapshot() as DnsServerInline;
      expect(snap.tag, 'my_dns');
      expect(snap.description, 'My DNS');
      expect(snap.body, {
        'type': 'udp',
        'server': '1.1.1.1',
        'server_port': 53,
      });
      expect(snap.body.containsKey('detour'), false,
          reason: 'дефолт — отсутствие ключа (решение №2)');
      c.dispose();
    });

    test('inline-detour: выбор Направления пишет body.detour, direct-out стирает',
        () {
      final c = makeNew();
      expect(c.inlineDetour, 'direct-out'); // ключа нет → direct
      c.setInlineDetour('vpn-1');
      expect(bodyOf(c)['detour'], 'vpn-1');
      expect(c.inlineDetour, 'vpn-1');
      // JSON-вкладка синхронизирована
      expect(c.bodyCtrl.text, contains('"detour": "vpn-1"'));
      c.setInlineDetour('direct-out');
      expect(bodyOf(c).containsKey('detour'), false);
      c.dispose();
    });

    test('JSON edit: валидный объект становится body, ref-поля strip', () {
      final c = makeNew();
      c.onBodyTextChanged(
          '{"type":"tls","server":"9.9.9.9","server_port":853,'
          '"tag":"x","description":"y","enabled":false,"_origin":"z"}');
      expect(c.jsonError, null);
      expect(bodyOf(c), {
        'type': 'tls',
        'server': '9.9.9.9',
        'server_port': 853,
      });
      // tag — часть sing-box-тела: в new-режиме синхронизируется в поле Tag.
      expect(c.tagCtrl.text, 'x');
      expect(c.snapshot().tag, 'x');
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
      expect(bodyOf(c)['server'], '1.1.1.1');
      c.onBodyTextChanged('[1,2]');
      expect(c.jsonError, isNotNull);
      c.onBodyTextChanged('{"type":"udp","server":"8.8.8.8"}');
      expect(c.jsonError, null);
      expect(bodyOf(c)['server'], '8.8.8.8');
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
          initialRef: const DnsServerInline(
            enabled: true,
            tag: 'dns_new',
            body: {'type': 'udp'},
          ),
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
      expect(bodyOf(c),
          {'type': 'udp', 'server': '9.9.9.9', 'server_port': 5353});
      c.onPortChanged('');
      expect(
          bodyOf(c).containsKey('server_port'), false);
      c.dispose();
    });

    test('переключение режима: стандартный порт снимается, кастомный живёт',
        () {
      final c = makeNew();
      c.onAddressChanged('9.9.9.9');
      c.onPortChanged('53'); // дефолт udp
      c.setServerMode('tls');
      final body = bodyOf(c);
      expect(body['type'], 'tls');
      expect(body.containsKey('server_port'), false,
          reason: 'дефолтный порт старого режима → дефолт нового');
      c.onPortChanged('8853'); // кастомный
      c.setServerMode('https');
      expect(bodyOf(c)['server_port'], 8853);
      c.dispose();
    });

    test('DoH: path/SNI; уход с https чистит path, udp чистит tls', () {
      final c = makeNew();
      c.setServerMode('https');
      c.onAddressChanged('8.8.8.8');
      c.onPathChanged('dns-query'); // без слэша — нормализуется
      c.onSniChanged('dns.google');
      expect(bodyOf(c), {
        'type': 'https',
        'server': '8.8.8.8',
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'dns.google'},
      });
      c.setServerMode('tls');
      var body = bodyOf(c);
      expect(body.containsKey('path'), false);
      expect(body.containsKey('tls'), true, reason: 'SNI валиден для DoT');
      c.setServerMode('udp');
      body = bodyOf(c);
      expect(body.containsKey('tls'), false);
      c.dispose();
    });

    test('§604: правка SNI не трогает прочие поля tls', () {
      final c = makeNew();
      c.onBodyTextChanged(
          '{"type":"tls","server":"9.9.9.9","tls":{"enabled":true,'
          '"server_name":"old.example","insecure":true,"alpn":["dot"]}}');
      c.onSniChanged('dns.example');
      expect(bodyOf(c)['tls'], {
        'enabled': true,
        'server_name': 'dns.example',
        'insecure': true,
        'alpn': ['dot'],
      });
      c.onSniChanged('');
      expect(bodyOf(c)['tls'], {
        'enabled': true,
        'insecure': true,
        'alpn': ['dot'],
      });
      c.onBodyTextChanged('{"type":"tls","server":"9.9.9.9",'
          '"tls":{"enabled":true,"server_name":"x.example"}}');
      c.onSniChanged('');
      expect(bodyOf(c).containsKey('tls'), false,
          reason: 'кроме enabled ничего — блок уходит целиком');
      // tls не объект — прежняя замена, без исключения; видимый JSON в синхроне.
      c.onBodyTextChanged(
          '{"type":"tls","server":"9.9.9.9","tls":true}');
      c.onSniChanged('z.example');
      expect(bodyOf(c)['tls'], {'enabled': true, 'server_name': 'z.example'});
      c.onBodyTextChanged('{"type":"tls","server":"9.9.9.9",'
          '"tls":{"enabled":false,"alpn":["dot"]}}');
      c.onSniChanged('w.example');
      expect(c.bodyCtrl.text, contains('"alpn"'));
      expect(bodyOf(c)['tls']['enabled'], true);
      c.dispose();
    });

    test('DoH URL-вставка: https://host/path → server+path+режим', () {
      final c = makeNew(tags: ['google_udp', 'cloudflare_udp']);
      c.onAddressChanged('https://dns.quad9.net/dns-query');
      final body = bodyOf(c);
      expect(body['type'], 'https');
      expect(body['server'], 'dns.quad9.net');
      expect(body['path'], '/dns-query');
      expect(c.addressCtrl.text, 'dns.quad9.net');
      c.dispose();
    });

    // §411 — DoQ (quic, 853, как DoT) и DoH3 (h3, 443 + path, как DoH).
    test('DoQ/DoH3: режимы формы и порты по умолчанию (§411)', () {
      expect(kDnsServerModes, containsAll(['quic', 'h3']));
      expect(defaultDnsPort('quic'), 853);
      expect(defaultDnsPort('h3'), 443);
      final c = makeNew();
      c.onBodyTextChanged('{"type":"quic","server":"dns.adguard-dns.com"}');
      expect(c.serverMode, 'quic', reason: 'раньше → null (JSON-only)');
      c.onBodyTextChanged('{"type":"h3","server":"dns.google"}');
      expect(c.serverMode, 'h3');
      c.dispose();
    });

    test('DoH3: path/SNI живут; уход в DoQ чистит path, tls остаётся (§411)',
        () {
      final c = makeNew();
      c.setServerMode('h3');
      c.onAddressChanged('8.8.8.8');
      c.onPathChanged('dns-query');
      c.onSniChanged('dns.google');
      expect(bodyOf(c), {
        'type': 'h3',
        'server': '8.8.8.8',
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'dns.google'},
      });
      c.setServerMode('quic');
      final body = bodyOf(c);
      expect(body['type'], 'quic');
      expect(body.containsKey('path'), false);
      expect(body.containsKey('tls'), true, reason: 'SNI валиден для DoQ');
      expect(body.containsKey('server_port'), false,
          reason: 'дефолтный порт → дефолт нового режима');
      c.dispose();
    });

    test('DoH3 → DoH: стандартный 443 общий, ключ порта не появляется (§411)',
        () {
      final c = makeNew();
      c.setServerMode('h3');
      c.onAddressChanged('1.1.1.1');
      c.onPortChanged('443');
      c.setServerMode('https');
      expect(bodyOf(c).containsKey('server_port'), false);
      c.dispose();
    });

    test('URL-вставка в режиме DoH3 не сбивает режим на DoH (§411)', () {
      final c = makeNew(tags: ['google_udp']);
      c.setServerMode('h3');
      c.onAddressChanged('https://dns.quad9.net/dns-query');
      final body = bodyOf(c);
      expect(body['type'], 'h3');
      expect(body['server'], 'dns.quad9.net');
      expect(body['path'], '/dns-query');
      c.dispose();
    });

    test('hostname-адрес → авто domain_resolver (google_udp), IP → снимается',
        () {
      final c = makeNew(tags: ['google_udp', 'cloudflare_udp']);
      c.onAddressChanged('dns.adguard-dns.com');
      expect(bodyOf(c)['domain_resolver'], 'google_udp');
      c.setDomainResolver('cloudflare_udp');
      expect(bodyOf(c)['domain_resolver'], 'cloudflare_udp');
      c.onAddressChanged('94.140.14.14');
      expect(bodyOf(c).containsKey('domain_resolver'),
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

    DnsServerEditController makeTpl({DnsServerRef? ref}) =>
        DnsServerEditController(
          initialRef: ref ??
              const DnsServerTemplate(enabled: true, tag: 'google_udp'),
          resolved: resolvedTemplate(),
          canonicalDescription: 'Google DNS (direct)',
        );

    test('не dirty при открытии; description == canonical не пишется в ref',
        () {
      final c = makeTpl();
      expect(c.isDirty(), false);
      final snap = c.snapshot() as DnsServerTemplate;
      expect(snap.description, isNull);
      expect(snap.varValues, isEmpty);
      c.dispose();
    });

    test('setVarValue → varValues в snapshot, dirty', () {
      final c = makeTpl();
      c.setVarValue('outbound', 'vpn-1');
      expect(c.isDirty(), true);
      expect((c.snapshot() as DnsServerTemplate).varValues,
          {'outbound': 'vpn-1'});
      c.dispose();
    });

    test('существующие varValues сохраняются и дополняются', () {
      final c = makeTpl(
        ref: const DnsServerTemplate(
          enabled: true,
          tag: 'google_udp',
          varValues: {'dns_ip': '8.8.4.4'},
        ),
      );
      expect(c.isDirty(), false);
      c.setVarValue('outbound', 'vpn-1');
      expect((c.snapshot() as DnsServerTemplate).varValues,
          {'dns_ip': '8.8.4.4', 'outbound': 'vpn-1'});
      c.dispose();
    });

    test('description-override пишется только при отличии от canonical', () {
      final c = makeTpl();
      c.descCtrl.text = 'Мой Google';
      expect(c.snapshot().description, 'Мой Google');
      c.descCtrl.text = 'Google DNS (direct)'; // вернули canonical
      expect(c.snapshot().description, isNull);
      c.dispose();
    });
  });

  group('lifecycle / kinds', () {
    test('locked (used by preset): editor видит lock и label', () {
      final c = DnsServerEditController(
        initialRef: const DnsServerPreset(enabled: true, tag: 'yandex_udp'),
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
        initialRef: const DnsServerInline(
          enabled: true,
          tag: 'my-dns',
          body: {'type': 'udp', 'server': '192.168.1.1'},
        ),
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
      expect(c.snapshot().tag, 'other');
      c.dispose();
    });

    test('inline-override: overrides доступен (Reset-action в AppBar)', () {
      final c = DnsServerEditController(
        initialRef: const DnsServerInline(
          enabled: true,
          tag: 'google_udp',
          body: {'type': 'udp', 'server': '8.8.4.4'},
        ),
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
      expect(bodyOf(c), {'type': 'udp', 'server': '8.8.4.4'});
      c.dispose();
    });
  });

  // §695 правило 1 — шаблонные записи редактируемы: правка тела формой
  // сохраняется override'ом (inline с тем же тегом), Reset to template
  // возвращает шаблонную запись.
  group('template → override (§695)', () {
    const shieldWrapper = <String, dynamic>{
      'description': 'Shield DNS',
      'enabled': true,
      'server': {
        'type': 'group',
        'tag': 'dns_shield',
        'servers': ['google_doh', 'cloudflare_dot', 'quad9_doh'],
        'mode': 'fastest',
      },
    };
    const udpWrapper = <String, dynamic>{
      'description': 'Google DNS',
      'enabled': true,
      'vars': [
        {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
        {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
      ],
      'server': {
        'type': 'udp',
        'tag': 'google_udp',
        'server_port': 53,
        'server': '@dns_ip',
        'detour': '@outbound',
      },
    };

    DnsServerEditController make(String tag, Map<String, dynamic> wrapper,
            Map<String, dynamic> body,
            {bool enabled = true}) =>
        DnsServerEditController(
          initialRef: DnsServerTemplate(enabled: enabled, tag: tag),
          resolved: ResolvedServer(
            kind: ServerKind.template,
            tag: tag,
            description: wrapper['description'] as String,
            enabled: enabled,
            body: {...body, 'tag': tag},
          ),
          templateWrapper: wrapper,
          canonicalDescription: wrapper['description'] as String,
        );

    test('снятый член группы → inline с тем же тегом, enabled сохранён', () {
      final c = make('dns_shield', shieldWrapper, {
        'type': 'group',
        'servers': ['google_doh', 'cloudflare_dot', 'quad9_doh'],
        'mode': 'fastest',
      }, enabled: false);
      expect(c.isGroup, isTrue);
      expect(c.groupMembers, ['google_doh', 'cloudflare_dot', 'quad9_doh']);
      expect(c.templateBodyEdited, isFalse);
      expect(c.snapshot(), isA<DnsServerTemplate>());
      c.toggleGroupMember('cloudflare_dot', false);
      expect(c.templateBodyEdited, isTrue);
      expect(c.isDirty(), isTrue);
      final snap = c.snapshot() as DnsServerInline;
      expect(snap.tag, 'dns_shield');
      expect(snap.enabled, isFalse);
      expect(snap.description, isNull);
      expect(snap.body, {
        'type': 'group',
        'servers': ['google_doh', 'quad9_doh'],
        'mode': 'fastest',
      });
      // Пустой состав — Save не проходит (гейт экрана).
      expect(c.groupHasNoMembers, isFalse);
      c.toggleGroupMember('google_doh', false);
      c.toggleGroupMember('quad9_doh', false);
      expect(c.groupHasNoMembers, isTrue);
      c.toggleGroupMember('google_doh', true);
      expect(c.groupHasNoMembers, isFalse);
      // Вернули состав как в шаблоне — снова шаблонная запись.
      c.toggleGroupMember('quad9_doh', false);
      c.toggleGroupMember('cloudflare_dot', true);
      c.toggleGroupMember('quad9_doh', true);
      expect(c.templateBodyEdited, isFalse);
      c.dispose();
    });

    test('тело override = тело шаблона после vars + правка; var после '
        'правки меняет только свои ключи', () {
      final c = make('google_udp', udpWrapper,
          {'type': 'udp', 'server_port': 53, 'server': '8.8.8.8'});
      expect(c.addressCtrl.text, '8.8.8.8');
      c.onPortChanged('5353');
      c.setVarValue('dns_ip', '8.8.4.4');
      expect(c.addressCtrl.text, '8.8.4.4');
      final snap = c.snapshot() as DnsServerInline;
      expect(snap.body, {
        'type': 'udp',
        'server_port': 5353,
        'server': '8.8.4.4',
      });
      c.dispose();
    });

    test('смена var без правки тела — шаблонная запись с varValues', () {
      final c = make('google_udp', udpWrapper,
          {'type': 'udp', 'server_port': 53, 'server': '8.8.8.8'});
      c.setVarValue('dns_ip', '8.8.4.4');
      final snap = c.snapshot() as DnsServerTemplate;
      expect(snap.varValues, {'dns_ip': '8.8.4.4'});
      c.dispose();
    });

    test('Reset to template: тег, enabled и description те же, vars — '
        'дефолты', () {
      final c = DnsServerEditController(
        initialRef: const DnsServerInline(
          enabled: false,
          tag: 'dns_shield',
          description: 'My shield',
          body: {'type': 'group', 'servers': ['google_doh']},
        ),
        resolved: const ResolvedServer(
          kind: ServerKind.inline,
          tag: 'dns_shield',
          description: 'My shield',
          enabled: false,
          body: {'type': 'group', 'tag': 'dns_shield',
            'servers': ['google_doh']},
          overrides: ServerKind.template,
        ),
        canonicalDescription: 'Shield DNS',
      );
      expect(c.canResetToTemplate, isTrue);
      expect(c.resetToTemplateSnapshot(),
          const DnsServerTemplate(
              enabled: false, tag: 'dns_shield', description: 'My shield'));
      c.descCtrl.text = 'Shield DNS';
      expect(c.resetToTemplateSnapshot().description, isNull);
      c.dispose();
    });

    test('Reset to template только у override шаблона', () {
      final user = DnsServerEditController(
        initialRef: const DnsServerInline(
            enabled: true, tag: 'mine', body: {'type': 'udp'}),
        resolved: const ResolvedServer(
          kind: ServerKind.inline,
          tag: 'mine',
          description: '',
          enabled: true,
          body: {'type': 'udp', 'tag': 'mine'},
        ),
      );
      expect(user.canResetToTemplate, isFalse);
      user.dispose();
    });
  });

  group('§699 сервер hosts', () {
    DnsServerEditController make(Map<String, dynamic> body,
            {List<DnsMemberOption> hostsOptions = const []}) =>
        DnsServerEditController(
          initialRef: DnsServerInline(enabled: true, tag: 'grp', body: body),
          dnsHostsOptions: hostsOptions,
        );

    test('hosts — безадресный режим формы', () {
      expect(kDnsServerModes, contains('hosts'));
      expect(kDnsAddresslessModes, contains('hosts'));
    });

    test('вход в hosts снимает транспорт и ставит predefined: {}', () {
      final c = make({
        'type': 'https',
        'server': 'dns.example',
        'server_port': 8443,
        'path': '/q',
        'tls': {'enabled': true, 'server_name': 'x'},
        'domain_resolver': 'google_udp',
        'detour': 'vpn-1',
      });
      c.setServerMode('hosts');
      expect(c.isHosts, isTrue);
      expect(bodyOf(c), {'type': 'hosts', 'predefined': <String, dynamic>{}});
      expect(c.hostsHasNoEntries, isTrue);
      c.dispose();
    });

    test('выход из hosts снимает predefined и path', () {
      final c = make({
        'type': 'hosts',
        'predefined': {
          'wg.home': ['203.0.113.10'],
        },
        'path': ['/data/hosts'],
      });
      c.setServerMode('udp');
      expect(bodyOf(c), {'type': 'udp'});
      c.dispose();
    });

    test('записи: строка и список читаются, путь — «Also reads»', () {
      final c = make({
        'type': 'hosts',
        'predefined': {
          'wg.home': '203.0.113.10',
          'warp.lan': ['162.159.192.1', '2606:4700:d0::a29f:c001'],
        },
        'path': '/data/hosts',
      });
      expect([for (final e in c.hostsEntries) [e.name, e.addresses]], [
        ['wg.home', ['203.0.113.10']],
        ['warp.lan', ['162.159.192.1', '2606:4700:d0::a29f:c001']],
      ]);
      expect(c.hostsPaths, ['/data/hosts']);
      c.dispose();
    });

    test('только path — Save не блокируется', () {
      final c = make({
        'type': 'hosts',
        'predefined': <String, dynamic>{},
        'path': ['/data/hosts'],
      });
      expect(c.hostsHasNoEntries, isFalse);
      c.dispose();
    });

    test('запись: имя в нижнем регистре, адреса списком; правка — на месте',
        () {
      final c = make({'type': 'hosts', 'predefined': <String, dynamic>{}});
      c.putHostsEntry(' WG.Home ', ['203.0.113.10', '2001:db8::10']);
      c.putHostsEntry('warp.lan', ['162.159.192.1']);
      expect(bodyOf(c)['predefined'], {
        'wg.home': ['203.0.113.10', '2001:db8::10'],
        'warp.lan': ['162.159.192.1'],
      });
      expect(c.hostsHasNoEntries, isFalse);
      // Смена имени у первой записи — позиция та же.
      c.putHostsEntry('router.home', ['192.168.1.1'], replacing: 'wg.home');
      expect((bodyOf(c)['predefined'] as Map).keys,
          ['router.home', 'warp.lan']);
      c.removeHostsEntry('router.home');
      expect(bodyOf(c)['predefined'], {
        'warp.lan': ['162.159.192.1'],
      });
      c.removeHostsEntry('warp.lan');
      expect(bodyOf(c)['predefined'], <String, dynamic>{});
      expect(c.hostsHasNoEntries, isTrue);
      c.dispose();
    });

    test('проверки диалога: имя и адреса', () {
      final c = make({
        'type': 'hosts',
        'predefined': {
          'wg.home': ['203.0.113.10'],
        },
      });
      expect(c.hostsNameError(''), isNotNull);
      expect(c.hostsNameError('wg home'), isNotNull);
      expect(c.hostsNameError('https://wg.home'), isNotNull);
      expect(c.hostsNameError('wg.home/x'), isNotNull);
      expect(c.hostsNameError('wg.home:53'), isNotNull);
      expect(c.hostsNameError('WG.HOME'), isNotNull, reason: 'дубль');
      expect(c.hostsNameError('WG.HOME', editing: 'wg.home'), isNull,
          reason: 'своё имя при правке — не дубль');
      expect(c.hostsNameError('warp.lan'), isNull);

      expect(DnsServerEditController.hostsAddressesError(''), isNotNull);
      expect(DnsServerEditController.hostsAddressesError('1.2.3.4\nnope'),
          isNotNull);
      expect(
          DnsServerEditController.hostsAddressesError(
              '203.0.113.10\n\n 2001:db8::10 '),
          isNull);
      expect(
          DnsServerEditController.hostsAddressLines(
              '203.0.113.10\n\n 2001:db8::10 '),
          ['203.0.113.10', '2001:db8::10']);
      c.dispose();
    });

    test('hosts группы — в порядке списка, не кликов; пусто — ключа нет', () {
      const opts = [
        DnsMemberOption(tag: 'h1', type: 'hosts', enabled: true),
        DnsMemberOption(tag: 'h2', type: 'hosts', enabled: true),
        DnsMemberOption(tag: 'h3', type: 'hosts', enabled: true),
      ];
      final c = make({
        'type': 'group',
        'servers': ['a'],
      }, hostsOptions: opts);
      c.toggleGroupHosts('h3', true);
      c.toggleGroupHosts('h1', true);
      expect(bodyOf(c)['hosts'], ['h1', 'h3']);
      c.toggleGroupHosts('h2', true);
      expect(c.groupHosts, ['h1', 'h2', 'h3']);
      c.toggleGroupHosts('grp', true); // сама группа — нет
      expect(c.groupHosts, ['h1', 'h2', 'h3']);
      for (final t in ['h1', 'h2', 'h3']) {
        c.toggleGroupHosts(t, false);
      }
      expect(bodyOf(c).containsKey('hosts'), isFalse);
      expect(bodyOf(c)['servers'], ['a'], reason: 'Members не трогаются');
      c.dispose();
    });

    test('тег вне опций (JSON-вкладка) — после известных; выход из group '
        'снимает hosts', () {
      final c = make({
        'type': 'group',
        'servers': ['a'],
        'hosts': 'ghost',
      }, hostsOptions: const [
        DnsMemberOption(tag: 'h1', type: 'hosts', enabled: true),
      ]);
      expect(c.groupHosts, ['ghost']);
      c.toggleGroupHosts('h1', true);
      expect(bodyOf(c)['hosts'], ['h1', 'ghost']);
      c.setServerMode('hosts');
      expect(bodyOf(c), {'type': 'hosts', 'predefined': <String, dynamic>{}});
      c.dispose();
    });
  });
}
