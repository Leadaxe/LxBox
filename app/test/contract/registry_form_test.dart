import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry_form.dart';

import '../contract_paths.dart';

// §654 A — модель формы по реестру (контракт 1.1.122, атрибут `form`):
// раскладка, варианты, запись значения. Сверка вычисления состояния с
// лаунчером — корпус `corpus/form` (`form_corpus_test.dart`).
void main() {
  setUpAll(loadTestRegistry);

  late FormLayout layout;
  setUp(() => layout = formLayoutFor('openconnect')!);

  test('схема без формы — null', () {
    expect(formLayoutFor('vmess'), isNull);
    expect(formStateFor('vmess', const {}), isNull);
  });

  test('раскладка: блоки, поля блока в порядке order, группа выбора', () {
    expect(layout.blocks, ['connection', 'security', 'advanced']);
    expect(
      [for (final f in layout.fieldsIn('connection')) f.path],
      ['server', 'flavor', 'username', 'password'],
    );
    expect(
      layout.fieldsIn('advanced').map((f) => f.path),
      containsAllInOrder([
        'user_agent',
        'fortinet_host_check',
        'fortinet_host_check.hostcheck',
        'mtu',
      ]),
    );
    final c = layout.choicesIn('security').single;
    expect(c.id, 'server_cert_check');
    expect([for (final o in c.options) o.id], ['system', 'pinned', 'insecure']);
    expect(c.paths, {'tls.peer_fingerprint', 'tls.insecure'});
    // Поля группы выбора блока не имеют — их рисует группа.
    expect(layout.field('tls.insecure')!.block, isNull);
    final flavor = layout.field('flavor')!;
    expect(flavor.values, contains('fortinet'));
    expect(flavor.defaultValue, 'anyconnect');
    expect(layout.field('password')!.secret, isTrue);
    expect(layout.field('mtu')!.min, 576);
    expect(layout.field('mtu')!.max, 1500);
  });

  test('видимость по flavor: auth_group скрыт у fortinet, hostcheck — '
      'только у fortinet', () {
    final forti = layout.stateOf({'flavor': 'fortinet'});
    expect(forti.isVisible('auth_group'), isFalse);
    expect(forti.isVisible('fortinet_host_check.hostcheck'), isTrue);
    final gp = layout.stateOf({'flavor': 'gp'});
    expect(gp.isVisible('auth_group'), isTrue);
    expect(gp.isVisible('fortinet_host_check.hostcheck'), isFalse);
    expect(gp.canSave, isFalse);
    expect(gp.missing, ['server', 'username']);
  });

  test('смена варианта: чистит пути прочих и пишет set выбранного', () {
    final c = layout.choice('server_cert_check')!;
    final body = <String, dynamic>{
      'server': 'fw.example.com',
      'token': {'mode': 'totp', 'secret': 's'},
      'tls': {
        'peer_fingerprint': ['sha256:0123'],
        'server_name': 'fw',
      },
    };
    expect(activeFormOption(c, body), 'pinned');

    final insecure = applyFormOption(body, c, 'insecure');
    expect(insecure['tls'], {'server_name': 'fw', 'insecure': true});
    expect(activeFormOption(c, insecure), 'insecure');
    // Исходное тело не тронуто, прочие ключи на месте.
    expect((body['tls'] as Map).containsKey('insecure'), isFalse);
    expect(insecure['token'], body['token']);

    final system = applyFormOption(
      withFormValue(insecure, 'tls.server_name', ''),
      c,
      'system',
    );
    expect(system.containsKey('tls'), isFalse);
    expect(activeFormOption(c, system), 'system');
  });

  test('запись значения: пустое ключ не пишет, вложенный путь создаётся', () {
    final body = <String, dynamic>{'server': 'a', 'cookie': 'c'};
    final withHost = withFormValue(body, 'fortinet_host_check.hostcheck', 'h');
    expect(withHost['fortinet_host_check'], {'hostcheck': 'h'});
    expect(withHost['cookie'], 'c');
    final cleared = withFormValue(
      withHost,
      'fortinet_host_check.hostcheck',
      '',
    );
    expect(cleared.containsKey('fortinet_host_check'), isFalse);
    expect(withFormValue(body, 'server', null).containsKey('server'), isFalse);
    expect(formPathSet({'a': ''}, 'a'), isFalse);
    expect(
      formValueAt({
        'a': {'b': 1},
      }, 'a.b'),
      1,
    );
  });

  test('advisory поля: коды при значении из values', () {
    final crypto = layout.field('allow_insecure_crypto')!;
    expect(formAdvisoryCodes(crypto, true, const {}), [
      'openconnect_insecure_crypto',
    ]);
    expect(formAdvisoryCodes(crypto, false, const {}), isEmpty);
    final insecure = layout.field('tls.insecure')!;
    expect(formAdvisoryCodes(insecure, true, const {}), ['tls_insecure']);
  });

  test('диапазон формы: пустое не судится, вне — out_of_range', () {
    expect(layout.stateOf({'mtu': 1400}).outOfRange, isEmpty);
    final st = layout.stateOf({'mtu': 1600});
    expect(st.outOfRangeAt('mtu')?.value, 1600);
    expect(st.canSave, isFalse);
  });

  // §654 A2 — контракт 1.1.123 (TASKS_LXBOX §120).
  group('контракт 1.1.123', () {
    test('общая секция: блок ref-поля, поля группы выбора блок не имеют', () {
      final vless = formLayoutFor('vless')!;
      expect(vless.field('server')!.block, 'connection');
      expect(vless.field('tls.server_name')!.block, 'tls');
      expect(vless.field('tls.enabled')!.block, isNull);
      expect(vless.field('tls.enabled')!.choiceId, 'security');
      expect(
        [for (final f in vless.fieldsIn('transport')) f.path],
        containsAllInOrder(['transport', 'transport.type', 'transport.path']),
      );
      final disc = vless.field('transport.type')!;
      expect(disc.discriminator, isTrue);
      expect(disc.values, isNot(contains('quic')));
      expect(disc.values!.first, '');
      // У http reality/utls/alpn сняты exclude_fields.
      final http = formLayoutFor('http')!;
      expect(http.field('tls.alpn'), isNull);
      expect(http.field('tls.reality.enabled'), isNull);
      expect(http.field('tls.server_name'), isNotNull);
      // hysteria2: reality запрещён схеме (forbidden_for) — с поддеревом.
      expect(formLayoutFor('hysteria2')!.field('tls.reality.enabled'), isNull);
    });

    test('fixed: не рисуется, пишется при сохранении', () {
      final trojan = formLayoutFor('trojan')!;
      expect(trojan.fixed, {'tls.enabled': true});
      expect(trojan.field('tls.enabled'), isNull);
      expect(trojan.stateOf(const {}).isVisible('tls.server_name'), isTrue);
      final saved = formBodyForSave('trojan', {
        'type': 'trojan',
        'tag': 't',
        'server': 't.example.com',
        'server_port': 443,
        'password': 'p',
      });
      expect(saved['tls'], {'enabled': true});
    });

    test('смена варианта security у VLESS: reality → tls → none', () {
      final vless = formLayoutFor('vless')!;
      final c = vless.choice('security')!;
      final reality = applyFormOption(const {}, c, 'reality');
      expect(reality['tls'], {
        'enabled': true,
        'reality': {'enabled': true},
      });
      expect(activeFormOption(c, reality), 'reality');
      final tls = applyFormOption(reality, c, 'tls');
      expect(tls['tls'], {'enabled': true});
      expect(activeFormOption(c, tls), 'tls');
      expect(applyFormOption(tls, c, 'none').containsKey('tls'), isFalse);
    });

    test('массив: элемент [0] создаётся, второй не трогается, пустой '
        'единственный снимается', () {
      final one = withFormValue(const {}, 'peers.0.address', 'w.example.com');
      expect(one['peers'], [
        {'address': 'w.example.com'},
      ]);
      expect(formValueAt(one, 'peers.0.address'), 'w.example.com');
      expect(formPathSet(one, 'peers.1.address'), isFalse);
      expect(withFormValue(one, 'peers.0.address', null), isEmpty);
      final two = <String, dynamic>{
        'peers': [
          {'address': 'a'},
          {'address': 'b'},
        ],
      };
      expect(withFormValue(two, 'peers.0.address', null)['peers'], [
        <String, dynamic>{},
        {'address': 'b'},
      ]);
    });

    test('implies: отпечаток пишет utls.enabled, очистка снимает', () {
      final trojan = formLayoutFor('trojan')!;
      final on = trojan.write(const {}, 'tls.utls.fingerprint', 'firefox');
      expect(on['tls'], {
        'utls': {'enabled': true, 'fingerprint': 'firefox'},
      });
      expect(trojan.write(on, 'tls.utls.fingerprint', ''), isEmpty);
    });

    test('тело формы — через санитайзер (п. 11): WireGuard получает '
        'allowed_ips пира', () {
      final saved = formBodyForSave('wireguard', {
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['10.0.0.2/32'],
        'private_key': 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=',
        'peers': [
          {
            'address': 'w.example.com',
            'port': 51820,
            'public_key': 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=',
          },
        ],
      });
      expect(saved['type'], 'wireguard');
      expect(saved['tag'], 'wg');
      expect((saved['peers'] as List).single['allowed_ips'], isNotEmpty);
    });
  });
}
