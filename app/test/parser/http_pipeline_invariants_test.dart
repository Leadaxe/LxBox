import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 6, раздел 3 спеки — инварианты переезда http(s)-прокси (§222) на
/// конвейер.
const _contractRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/http/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_contractRoot/corpus/uri/http')
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
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 инвариант 4 — identity http не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(9)),
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
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус http переживает круг', () {
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
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 http-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'proxy-https://user$i:pass$i@example-$i.com:443'
              '?sni=example-$i.com&alpn=h2&path=/p$i#node$i',
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
        reason: 'разбор $n http-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — коды http приходят из реестра, с путём и значением', () {
    test('insecure и мусорный fp судит реестр', () {
      final spec = parseUri('proxy-https://u:p@h.example:443'
          '?sni=a.example&fp=bogus&allowInsecure=1#n')!;
      expect(spec.warnings.whereType<InsecureTlsWarning>(), isEmpty);
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);

      final ins = _registry(spec).firstWhere((w) => w.code == 'tls_insecure');
      expect(ins.path, 'tls.insecure');
      expect(ins.value, 'true');

      final fp =
          _registry(spec).firstWhere((w) => w.code == 'utls_fp_unknown');
      expect(fp.path, 'tls.utls.fingerprint');
      expect(fp.value, 'bogus', reason: 'значение как написал автор');
      // Отпечаток сведён к chrome — правилом реестра, не разбором.
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
    }, skip: skip);
  });

  group('§472 — http: перевод, который остаётся за маппером', () {
    test('суффикс схемы — TLS-дискриминатор и порт по умолчанию', () {
      final plain = parseUri('proxy-http://u:p@h.example#n')!;
      final pb = plain.emit(TemplateVars.empty).map;
      expect(pb.containsKey('tls'), isFalse,
          reason: 'явный tls:{enabled:false} ронял ядра lx.5..lx.18');
      expect(pb['server_port'], 80);

      final secure = parseUri('proxy-https://u:p@h.example#n')!;
      final sb = secure.emit(TemplateVars.empty).map;
      expect((sb['tls'] as Map)['enabled'], isTrue);
      expect(sb['server_port'], 443);
    }, skip: skip);

    test('§268 — плюс-формы эквивалентны дефисным', () {
      final dash = parseUri('proxy-https://u@h.example:8443#n')!;
      final plus = parseUri('proxy+https://u@h.example:8443#n')!;
      expect(plus.emit(TemplateVars.empty).map,
          dash.emit(TemplateVars.empty).map);
    }, skip: skip);

    test('security=none гасит TLS даже на https-схеме', () {
      // `security_none_no_tls` — `applies_to` включает http.
      final spec =
          parseUri('proxy-https://u@h.example:443?security=none#n')!;
      expect(spec.emit(TemplateVars.empty).map.containsKey('tls'), isFalse);
    }, skip: skip);

    test('userinfo: user | user:pass | :pass', () {
      final userOnly = parseUri('proxy-http://alice@h.example#n')!
          .emit(TemplateVars.empty)
          .map;
      expect(userOnly['username'], 'alice');
      expect(userOnly.containsKey('password'), isFalse);

      final passOnly = parseUri('proxy-http://:secret@h.example#n')!
          .emit(TemplateVars.empty)
          .map;
      expect(passOnly.containsKey('username'), isFalse);
      expect(passOnly['password'], 'secret');
    }, skip: skip);

    test('headers: та же сериализация, что extra-headers у naive', () {
      final spec = parseUri(
          'proxy-http://u@h.example?headers=X-B%3A%20two%0D%0AX-A%3A%20one#n')!;
      // Ключи отсортированы — так эмитят оба проекта.
      expect(spec.emit(TemplateVars.empty).map['headers'],
          {'X-A': 'one', 'X-B': 'two'});
    }, skip: skip);

    test('§453 dial-поля доезжают до тела и не теряются', () {
      final spec =
          parseUri('proxy-http://u@h.example?tcp_keep_alive=30s#n')!;
      expect(spec.emit(TemplateVars.empty).map['tcp_keep_alive'], '30s');
      expect(_registry(spec).map((w) => w.code), isNot(contains('unknown_key')));
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном http ничего не добавляет',
        () {
      final spec = parseUri('proxy-https://u:p@h.example:443'
          '?sni=x.com&fp=firefox&allowInsecure=1#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });
}
