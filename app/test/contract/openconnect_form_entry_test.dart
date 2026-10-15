// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry_form.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

/// §654 B — форма «Add server → OpenConnect» поверх модели формы реестра:
/// тело, которое собирает экран (`withFormValue`/`applyFormOption`/
/// `formInputValue`/`formListInput`), и путь сохранения — тот же, что у
/// вставки sing-box JSON (`addFromInput`).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

// Эталон из «Фактов» спеки §654 (адрес и учётка — заглушки).
const _reference =
    '{"type":"openconnect","tag":"forti",'
    '"server":"https://fw.example.com:42319","flavor":"fortinet",'
    '"username":"user","password":"secret","tls":{"insecure":true}}';

void main() {
  late Directory tempDir;
  late FormLayout layout;

  setUpAll(loadEngineSections);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('oc_form_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    layout = formLayoutFor('openconnect')!;
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Файлы кэша могут быть ещё открыты — не мешает тесту.
    }
  });

  /// Ввод в поле экрана: текст → значение → тело.
  Map<String, dynamic> type(
    Map<String, dynamic> body,
    String path,
    String text,
  ) => withFormValue(body, path, formInputValue(layout.field(path)!, text));

  Map<String, dynamic> formBody() {
    var body = <String, dynamic>{'flavor': 'fortinet'};
    body = type(body, 'server', 'https://fw.example.com:42319');
    body = type(body, 'username', 'user');
    body = type(body, 'password', 'secret');
    body = type(body, 'user_agent', '   ');
    body = type(body, 'mtu', '');
    final cert = layout.choice('server_cert_check')!;
    return applyFormOption(body, cert, 'insecure');
  }

  test('форма собирает эталон; пустые поля ключей не пишут', () {
    final body = formBody();
    final want = Map<String, dynamic>.from(jsonDecode(_reference) as Map)
      ..remove('type')
      ..remove('tag');
    expect(body, want);
    expect(body.containsKey('user_agent'), isFalse);
    expect(body.containsKey('mtu'), isFalse);
    expect(body.containsKey('server_port'), isFalse);
    expect(layout.stateOf(body).canSave, isTrue);
  });

  test('ввод: int — число, секрет не обрезается, отпечатки через запятую', () {
    expect(formInputValue(layout.field('mtu')!, ' 1400 '), 1400);
    expect(formInputValue(layout.field('mtu')!, ''), isNull);
    expect(formInputValue(layout.field('password')!, ' p w '), ' p w ');
    expect(formInputValue(layout.field('password')!, '  '), isNull);
    expect(formInputValue(layout.field('dpd_interval')!, ' 30s '), '30s');
    expect(formListInput('sha256:aa, bb ,, '), ['sha256:aa', 'bb']);
    expect(formListInput(' , '), isEmpty);
    final st = layout.stateOf(type(formBody(), 'mtu', '9000'));
    expect(st.outOfRangeAt('mtu'), isNotNull);
    expect(st.canSave, isFalse);
  });

  test('видимость по flavor: Group / Realm и Hostcheck', () {
    final forti = layout.stateOf(formBody());
    expect(forti.isVisible('auth_group'), isFalse);
    expect(forti.isVisible('fortinet_host_check.hostcheck'), isTrue);
    final ac = layout.stateOf(
      withFormValue(formBody(), 'flavor', 'anyconnect'),
    );
    expect(ac.isVisible('auth_group'), isTrue);
    expect(ac.isVisible('fortinet_host_check.hostcheck'), isFalse);
  });

  test('сертификат: insecure → pinned → system', () {
    final cert = layout.choice('server_cert_check')!;
    var body = formBody();
    expect(activeFormOption(cert, body), 'insecure');
    body = applyFormOption(body, cert, 'pinned');
    expect(body.containsKey('tls'), isFalse);
    body = withFormValue(
      body,
      'tls.peer_fingerprint',
      formListInput('sha256:${'ab' * 32}, ${'cd' * 20}'),
    );
    expect(activeFormOption(cert, body), 'pinned');
    expect((body['tls'] as Map)['peer_fingerprint'], hasLength(2));
    expect((body['tls'] as Map).containsKey('insecure'), isFalse);
    body = applyFormOption(body, cert, 'system');
    expect(body.containsKey('tls'), isFalse);
    expect(activeFormOption(cert, body), 'system');
  });

  test('правка полей формы не теряет ключи вне формы', () {
    var body = <String, dynamic>{
      'server': 'vpn.example.com',
      'flavor': 'anyconnect',
      'username': 'user',
      'auth_group': 'staff',
      'token': {'mode': 'totp', 'secret': 'base32secret'},
      'cookie': 'webvpn=x',
      'detour': 'warp',
      'system': false,
      'tls': {'client_certificate_path': '/c.pem', 'client_key_path': '/k.pem'},
    };
    final cert = layout.choice('server_cert_check')!;
    body = type(body, 'username', '');
    body = withFormValue(body, 'flavor', 'fortinet');
    body = applyFormOption(body, cert, 'insecure');
    body = applyFormOption(body, cert, 'system');
    expect(body['token'], {'mode': 'totp', 'secret': 'base32secret'});
    expect(body['cookie'], 'webvpn=x');
    expect(body['detour'], 'warp');
    expect(body['system'], false);
    expect(body['tls'], {
      'client_certificate_path': '/c.pem',
      'client_key_path': '/k.pem',
    });
    // Скрытое при fortinet поле из тела не снимается.
    expect(body['auth_group'], 'staff');
    expect(body.containsKey('username'), isFalse);
    // Username не обязателен при клиентском сертификате.
    expect(layout.stateOf(body).isMissing('username'), isFalse);
  });

  test(
    'сохранение формой = вставка эталона JSON-ом: endpoint, тело то же',
    () async {
      final c = SubscriptionController();
      Future<NodeSpec> add(String text, UserSource origin) async {
        await c.addFromInput(text, origin: origin);
        expect(c.lastError, isNull);
        return (c.entries.last.list as UserServer).nodes.single;
      }

      final entry = {'type': 'openconnect', 'tag': 'forti', ...formBody()};
      final byForm = await add(
        jsonEncode(formBodyForSave('openconnect', entry)),
        UserSource.manual,
      );
      final byPaste = await add(_reference, UserSource.paste);
      expect(c.entries, hasLength(2));
      expect(byForm, isA<UnknownTypeSpec>());
      final formEmit = byForm.emitRaw(TemplateVars.empty);
      final pasteEmit = byPaste.emitRaw(TemplateVars.empty);
      expect(formEmit, isA<Endpoint>());
      expect(pasteEmit, isA<Endpoint>());
      final a = Map<String, dynamic>.from(formEmit.map)..remove('tag');
      final b = Map<String, dynamic>.from(pasteEmit.map)..remove('tag');
      expect(a, b);
      expect(a.containsKey('server_port'), isFalse);
      expect(a['server'], 'https://fw.example.com:42319');
    },
  );
}
