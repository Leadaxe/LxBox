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
    expect(formLayoutFor('vless'), isNull);
    expect(formStateFor('vless', const {}), isNull);
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
}
