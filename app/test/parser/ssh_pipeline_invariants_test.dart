import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 6, раздел 3 спеки — инварианты переезда ssh на конвейер.

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/ssh/pipeline_identity_before.json';

/// Многострочный PEM — тот случай, ради которого §466 держит ключ в query.
const _pem = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAA\n'
    'AAAAline3+/=\n'
    '-----END OPENSSH PRIVATE KEY-----';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$kVendorRoot/corpus/uri/ssh')
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (!f.path.endsWith('.uri')) continue;
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      out.add(t);
    }
  }
  return out;
}

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

void main() {
  final corpusSkip = corpusTestSkip('test/parser/ssh_pipeline_invariants_test.dart');

  setUpAll(() async {
    await loadTestRegistry();
  });

  group('§472 инвариант 4 — identity ssh не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(10)),
          reason: 'фикстура похудела — проверьте, не срезан ли корпус');
      for (final e in before.entries) {
        final uri = e.value['uri'] as String;
        final want = e.value['identity'] as String?;
        final spec = parseUri(uri);
        if (want == null) {
          expect(spec, isNull, reason: 'кейс ${e.key} стал разбираться');
          continue;
        }
        expect(spec, isNotNull, reason: 'кейс ${e.key} перестал разбираться');
        expect(
          legacyNodeIdentityHash(spec!),
          want,
          reason: 'identity кейса ${e.key} изменилась: у пользователей слетят '
              'выбор узла, отключения и цепочки',
        );
      }
    });
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус ssh переживает круг', () {
      var checked = 0;
      for (final u in _corpusUris()) {
        final a = parseUri(u);
        if (a == null) continue;
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'круг потерял узел: $u');
        expect(
          b!.emit(TemplateVars.empty).map,
          a.emit(TemplateVars.empty).map,
          reason: 'круг изменил тело: $u',
        );
        expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
            reason: 'круг изменил identity: $u');
        checked++;
      }
      // Круг проходят ВСЕ разбираемые кейсы, без исключений.
      expect(checked, greaterThan(8));
    }, skip: corpusSkip);

    test('§466 — многострочный приватный ключ переживает круг побайтно', () {
      // Ключ едет в QUERY (форма хранения, §466), и в нём законно встречается
      // и `\n`, и `+` внутри base64. `Uri.queryParameters` декодирует значение
      // РОВНО ОДИН РАЗ — этого достаточно и больше делать нельзя: раскрутка до
      // стабильной точки испортила бы ключ с `%` внутри.
      final uri = 'ssh://u@h.example:2222'
          '?private_key=${Uri.encodeComponent(_pem)}'
          '&private_key_passphrase=pp#k';
      final a = parseUri(uri)! as SshSpec;
      expect(a.privateKey, _pem, reason: 'ключ дочитан побайтно');
      expect(a.privateKeyPassphrase, 'pp');

      final b = parseUri(a.toUri())! as SshSpec;
      expect(b.privateKey, _pem, reason: 'круг сохранил ключ');
      expect(b.emit(TemplateVars.empty).map, a.emit(TemplateVars.empty).map);
      expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a));
    });
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 ssh-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'ssh://user$i:pass$i@example-$i.com:22'
              '?host_key_algorithms=ssh-ed25519,ssh-rsa#node$i',
      ];

      for (var i = 0; i < 200; i++) {
        parseUri(uris[i]);
      }

      final nodes = <NodeSpec>[];
      var best = 1 << 30;
      for (var rep = 0; rep < 3; rep++) {
        nodes.clear();
        final sw = Stopwatch()..start();
        for (final u in uris) {
          final s = parseUri(u);
          if (s != null) nodes.add(s);
        }
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      expect(nodes, hasLength(n));
      expect(
        best,
        lessThan(3000),
        reason: 'разбор $n ssh-узлов конвейером: $best мс (лучший из трёх)',
      );
    });
  });

  group('§472 — ssh: перевод, который остаётся за маппером', () {
    test('userinfo обязателен: без user узла нет', () {
      expect(parseUri('ssh://h.example:22#n'), isNull);
      expect(parseUri('ssh://@h.example:22#n'), isNull);
      expect(parseUri('ssh://u@h.example:22#n'), isNotNull);
    });

    test('пароль — всё после первого двоеточия', () {
      final spec = parseUri('ssh://u:p%3A1%3A2@h.example:22#n')!;
      expect(spec.emit(TemplateVars.empty).map['password'], 'p:1:2');
    });

    test('host_key и host_key_algorithms — списки через запятую', () {
      // Пустые элементы отбрасываются (`uri.query.host_key.impl`).
      final spec = parseUri('ssh://u@h.example:22'
          '?host_key=aaa,,bbb&host_key_algorithms=ssh-rsa,,ssh-ed25519#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['host_key'], ['aaa', 'bbb']);
      expect(body['host_key_algorithms'], ['ssh-rsa', 'ssh-ed25519']);
    });

    test('порт по умолчанию 22', () {
      final spec = parseUri('ssh://u@h.example#n')!;
      expect(spec.emit(TemplateVars.empty).map['server_port'], 22);
    });

    test('§453 dial-поля доезжают до тела и не теряются', () {
      final spec = parseUri('ssh://u:p@h.example:22?tcp_keep_alive=30s#n')!;
      expect(spec.emit(TemplateVars.empty).map['tcp_keep_alive'], '30s');
      expect(_registry(spec).map((w) => w.code), isNot(contains('unknown_key')));
    });
  });

  // БЕЗ ГЕЙТА: тесты идут через `parseSingboxEntry` напрямую, реестр им не
  // нужен, а дефект они стерегут на любом прогоне. Гейт здесь оставил бы
  // регрессию неприкрытой ровно там, где `app/contract` нет, — на CI.
  group('§472 — дефект: host_key_algorithms терялся на входе тела', () {
    test('host_key_algorithms читается из тела обратно в модель', () {
      // `emitSsh` поле пишет, а `parseSingboxEntry` не читал вовсе: узел,
      // пересохранённый через JSON или отредактированный во вкладке JSON,
      // терял список алгоритмов молча. Тот же класс, что `encryption` у vless
      // (шаг 3), `plugin` у shadowsocks (шаг 4) и `quic` у naive.
      final node = parseSingboxEntry({
        'type': 'ssh',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 22,
        'user': 'u',
        'host_key': ['aaa'],
        'host_key_algorithms': ['ssh-rsa', 'ssh-ed25519'],
      })! as SshSpec;
      expect(node.hostKeyAlgorithms, ['ssh-rsa', 'ssh-ed25519']);
      expect(node.emit(TemplateVars.empty).map['host_key_algorithms'],
          ['ssh-rsa', 'ssh-ed25519']);
    });

    test('одиночная строка — законная форма listable_string', () {
      final node = parseSingboxEntry({
        'type': 'ssh',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 22,
        'user': 'u',
        'host_key_algorithms': 'ssh-rsa',
      })! as SshSpec;
      expect(node.hostKeyAlgorithms, ['ssh-rsa']);
    });

    test('без ключа список пуст и в тело не пишется', () {
      final node = parseSingboxEntry({
        'type': 'ssh',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 22,
        'user': 'u',
      })! as SshSpec;
      expect(node.hostKeyAlgorithms, isEmpty);
      expect(
          node.emit(TemplateVars.empty).map.containsKey('host_key_algorithms'),
          isFalse);
    });
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном ssh ничего не добавляет', () {
      final spec = parseUri('ssh://u:p@h.example:22?host_key=aaa#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    });
  });
}
