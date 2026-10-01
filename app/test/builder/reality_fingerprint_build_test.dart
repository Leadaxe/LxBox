import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/subscription/sources.dart';

// §169 — валидный X25519 public key (43 символа base64url = 32 байта).
const _pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';

/// §444 — отпечаток REALITY-узла на полном пути «тело подписки → парсер →
/// buildConfig». Отпечаток узла из подписки уходит в конфиг как есть;
/// `chrome` пишется только там, где выбора не было (пустой fp, дефолт
/// `random`), и вместо мусора вне словаря ядра (§281).
///
/// §472 шаг 3 — vless разбирается конвейером, и оба кода (`reality_fp_not_chrome`,
/// `utls_fp_unknown`) ставит РЕЕСТР, а не рукописные классы. Сверка идёт по
/// коду, а не по типу класса: так тест переживёт и шаг 9, когда рукописные
/// классы уйдут у остальных схем. Реестр обязан быть загружен — без него
/// санитайзер молчит и тест проверял бы не то поведение, которое видит
/// приложение. `app/contract/` вендорится локально и в репозиторий не
/// коммитится (§460), поэтому на CI его нет и тесты пропускаются — ровно как
/// весь `test/contract`.
void main() {

  setUpAll(loadTestRegistry);


  /// Коды предупреждений узла — рукописные и реестровые одинаково.
  List<String> codes(NodeSpec n) =>
      n.warnings.map(warningCodeOf).whereType<String>().toList();

  /// Значение, названное кодом (у реестрового — `value`, у рукописного — своё
  /// поле: здесь совпадает с отпечатком).
  String? valueOf(NodeSpec n, String code) => n.warnings
      .whereType<RegistryWarning>()
      .where((w) => w.code == code)
      .map((w) => w.value)
      .firstOrNull;

  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    groupTemplates: GroupTemplates(),
    vars: const [],
    varSections: const [],
    config: {
      'outbounds': [
        {'tag': 'direct-out', 'type': 'direct'},
      ],
      'route': {'rules': []},
    },
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  Future<({Map utls, NodeSpec node})> build(List<NodeSpec> nodes) async {
    final list = UserServer(
      id: 'fp-444',
      name: 'FP',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      nodes: nodes,
    );
    final result = await buildConfig(
      lists: [list],
      template: template,
      settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
    );
    expect(result.validation.isOk, true,
        reason: result.validation.issues.join('\n'));
    final node = nodes.single;
    final out = (result.config['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['tag'] == node.tag);
    return (utls: (out['tls'] as Map)['utls'] as Map, node: node);
  }

  Future<({Map utls, NodeSpec node})> buildUri(String uri) async {
    final r = await parseFromSource(InlineSource('$uri\n'));
    expect(r.nodes, hasLength(1), reason: uri);
    return build(r.nodes);
  }

  String reality(String fpQuery) =>
      'vless://11111111-1111-1111-1111-111111111111@example-1.com:443'
      '?type=tcp&security=reality$fpQuery&sni=www.example-3.com'
      '&pbk=$_pbk&sid=ab#R';

  // §451 / ядро SPEC 086+087 (libbox ≥ v1.14.1-lx.3) — форк utls несёт
  // Firefox 148 и Safari 26.3 с гибридным key share: узел живой, повода
  // предупреждать нет.
  test('REALITY + fp=firefox/safari → в конфиге как есть, без предупреждения',
      () async {
    for (final fp in ['firefox', 'safari']) {
      final b = await buildUri(reality('&fp=$fp'));
      expect(b.utls['fingerprint'], fp, reason: fp);
      expect(codes(b.node), isNot(contains('reality_fp_not_chrome')),
          reason: fp);
    }
  });

  test('REALITY + fp=edge/ios/android/360/qq → предупреждение на узле',
      () async {
    for (final fp in ['edge', 'ios', 'android', '360', 'qq']) {
      final b = await buildUri(reality('&fp=$fp'));
      expect(b.utls['fingerprint'], fp, reason: '§444: подмены нет, $fp');
      expect(codes(b.node), contains('reality_fp_not_chrome'), reason: fp);
      expect(valueOf(b.node, 'reality_fp_not_chrome'), fp, reason: fp);
    }
  });

  test('REALITY + пустой fp (sing-box JSON) → uTLS без отпечатка', () async {
    final node = parseSingboxEntry({
      'type': 'vless',
      'tag': 'empty-fp',
      'server': 'example-1.com',
      'server_port': 443,
      'uuid': '11111111-1111-1111-1111-111111111111',
      'tls': {
        'enabled': true,
        'server_name': 'www.example-3.com',
        'utls': {'enabled': true, 'fingerprint': ''},
        'reality': {'enabled': true, 'public_key': _pbk, 'short_id': 'ab'},
      },
    })!;
    final b = await build([node]);
    // Контракт 1.1.61: пустой отпечаток под REALITY остаётся пустым (ядро =
    // chrome), uTLS включён.
    expect(b.utls['enabled'], true);
    expect(b.utls.containsKey('fingerprint'), isFalse);
    expect(codes(b.node), isNot(contains('reality_fp_not_chrome')));
  });

  test('vless REALITY без fp и с fp= → chrome с кодом (контракт 1.1.61)',
      () async {
    for (final q in ['', '&fp=']) {
      final b = await buildUri(reality(q));
      // Контракт 1.1.61: неявный random (D-009) под REALITY правило
      // `coerce_when` меняет на chrome уже в теле узла, с кодом.
      expect((b.node as VlessSpec).tls.fingerprint, 'chrome',
          reason: 'q="$q"');
      expect(b.utls['fingerprint'], 'chrome', reason: 'q="$q"');
      expect(codes(b.node), contains('reality_fp_random_pinned'));
      expect(codes(b.node), isNot(contains('reality_fp_not_chrome')));
    }
  });

  test('REALITY + явный fp=random → chrome (в модели неотличим от дефолта)',
      () async {
    final b = await buildUri(reality('&fp=random'));
    expect(b.utls['fingerprint'], 'chrome');
    expect(codes(b.node), isNot(contains('reality_fp_not_chrome')));
  });

  test('REALITY + fp=randomized → как есть, с предупреждением', () async {
    final b = await buildUri(reality('&fp=randomized'));
    expect(b.utls['fingerprint'], 'randomized');
    expect(codes(b.node), contains('reality_fp_not_chrome'));
    expect(valueOf(b.node, 'reality_fp_not_chrome'), 'randomized');
  });

  test('TLS без REALITY + fp=firefox → firefox, без предупреждения', () async {
    final b = await buildUri(
        'vless://11111111-1111-1111-1111-111111111111@example-1.com:443'
        '?type=tcp&security=tls&fp=firefox&sni=example-1.com#T');
    expect(b.utls['fingerprint'], 'firefox');
    expect(codes(b.node), isNot(contains('reality_fp_not_chrome')));
  });

  test('§281: мусор → chrome + utls_fp_unknown (TLS и REALITY)', () async {
    final tls = await buildUri(
        'vless://11111111-1111-1111-1111-111111111111@example-1.com:443'
        '?type=tcp&security=tls&fp=garbage&sni=example-1.com#T');
    expect(tls.utls['fingerprint'], 'chrome');
    expect(codes(tls.node), contains('utls_fp_unknown'));
    // §472 шаг 3 — у кода реестра есть адрес и СЫРОЕ значение ссылки, чего у
    // рукописного класса не было.
    expect(valueOf(tls.node, 'utls_fp_unknown'), 'garbage');

    final r = await buildUri(reality('&fp=garbage'));
    expect(r.utls['fingerprint'], 'chrome');
    expect(codes(r.node), contains('utls_fp_unknown'));
    expect(codes(r.node), isNot(contains('reality_fp_not_chrome')),
        reason: 'chrome после канонизации — не повод для REALITY-предупреждения');
  });
}
