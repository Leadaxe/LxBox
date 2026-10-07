// §612 (контракт 1.1.110, PARSING_PRINCIPLES §6.3) — `required_unless`:
// условная обязательность отсутствующего поля, общий примитив санитайзера.
// Живой случай реестра — пир WireGuard: `peers[].address` не нужен при
// `listen_port` (код `wg_peer_incoming`), `peers[].port` — без `address`.
import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/services/contract/body_edit.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/parse_all.dart';

const _key = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=';

Map<String, dynamic> _wg({
  int? listenPort,
  Map<String, dynamic> peer = const {},
}) =>
    {
      'type': 'wireguard',
      'tag': 'wg',
      'address': ['10.99.2.1/32'],
      'listen_port': ?listenPort,
      'private_key': _key,
      'peers': [
        {
          'allowed_ips': ['0.0.0.0/0'],
          'public_key': _key,
          ...peer,
        },
      ],
    };

SanitizeResult _san(Map<String, dynamic> body) => RegistrySanitizer.sanitize(
    body,
    scheme: 'wireguard',
    coreVersion: '0.0.0',
    applyCoreGates: false);

List<String> _codes(SanitizeResult r) =>
    [for (final w in r.warnings) '${w.code}@${w.path ?? ''}'];

void main() {
  setUpAll(() async {
    await loadTestRegistry();
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('required_unless', () {
    test('set: listen_port снимает обязательность адреса, код на пути поля', () {
      final r = _san(_wg(listenPort: 51822));
      expect(r.body, isNotNull);
      expect(_codes(r), ['wg_peer_incoming@peers[0].address']);
      final peer = (r.body!['peers'] as List).single as Map;
      expect(peer.containsKey('address'), isFalse, reason: 'тело не меняется');
    });

    test('absent: без адреса порт не обязателен и молчит (кода нет)', () {
      final r = _san(_wg(listenPort: 51822));
      expect(_codes(r).where((c) => c.contains('port')), isEmpty);
    });

    test('не снято: нет ни адреса, ни listen_port — field_missing, узел снят',
        () {
      final r = _san(_wg());
      expect(r.body, isNull);
      expect(r.explicitDropNode, isTrue,
          reason: 'пир без обязательного поля снимает узел явно');
      expect(_codes(r), ['field_missing@peers[0].address']);
    });

    test('сосед из absent задан — порт обязателен', () {
      final r = _san(_wg(peer: {'address': 'example.com'}));
      expect(r.body, isNull);
      expect(_codes(r), ['field_missing@peers[0].port']);
    });

    test('адрес задан — кода о входящем пире нет', () {
      final r = _san(
          _wg(listenPort: 51822, peer: {'address': 'example.com', 'port': 51820}));
      expect(r.body, isNotNull);
      expect(_codes(r), isEmpty);
    });
  });

  group('авторское тело (§6.3)', () {
    test('info-код без правки — без applied:false', () {
      final raw = _wg(listenPort: 51822);
      final res = settleSanitized('wireguard', raw, _san(_wg(listenPort: 51822)),
          authored: true);
      expect(res.body, isNotNull);
      final w = res.warnings.single;
      expect(w.code, 'wg_peer_incoming');
      expect(w.applied, isTrue);
    });

    test('мёртвый пир — узел остаётся, field_missing с applied:false', () {
      final res = settleSanitized('wireguard', _wg(), _san(_wg()),
          authored: true);
      expect(res.body, isNotNull);
      final w = res.warnings.single;
      expect(w.code, 'field_missing');
      expect(w.applied, isFalse);
    });
  });

  test('ссылка из входящего узла не строится с пустым хостом', () {
    const text = '{"type":"wireguard","tag":"wg-in","address":["10.99.2.1/32"],'
        '"listen_port":51822,"private_key":"$_key","peers":[{"allowed_ips":'
        '["0.0.0.0/0"],"public_key":"$_key"}]}';
    final nodes = parseAll(decode(text), own: true);
    expect(nodes, hasLength(1));
    expect(nodes.single.toUri(), isEmpty);
  });
}
