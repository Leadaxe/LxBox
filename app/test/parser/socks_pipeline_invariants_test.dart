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

/// §472 шаг 6, раздел 3 спеки — инварианты переезда socks на конвейер.
const _contractRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/socks/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_contractRoot/corpus/uri/socks')
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

  group('§472 инвариант 4 — identity socks не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(8)),
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
    test('весь корпус socks переживает круг', () {
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
      expect(checked, greaterThan(7));
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 socks-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'socks5://user$i:pass$i@example-$i.com:1080#node$i',
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
        reason: 'разбор $n socks-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — socks: перевод, который остаётся за маппером', () {
    test('socks:// и socks5:// дают одно тело', () {
      // `aliases: ["socks5"]` — алиас НАПИСАНИЯ, тело у обеих форм одно.
      final bare = parseUri('socks://u:p@h.example:1080#n')!;
      final five = parseUri('socks5://u:p@h.example:1080#n')!;
      expect(five.emit(TemplateVars.empty).map,
          bare.emit(TemplateVars.empty).map);
    }, skip: skip);

    test('version в теле всегда "5" и в ссылку не пишется', () {
      // Поле ставит ЭМИТТЕР из модели (дефолт `5`), маппер его не кладёт:
      // положи он — тело поехало бы и из ссылки, чего прежний путь не делал.
      final spec = parseUri('socks5://u:p@h.example:1080#n')!;
      expect(spec.emit(TemplateVars.empty).map['version'], '5');
      expect(spec.toUri(), isNot(contains('version=')));
    }, skip: skip);

    test('порт по умолчанию 1080', () {
      final spec = parseUri('socks5://h.example#n')!;
      expect(spec.emit(TemplateVars.empty).map['server_port'], 1080);
    }, skip: skip);

    test('userinfo: оба пусто | user | user:pass | :pass', () {
      final none =
          parseUri('socks5://h.example:1080#n')!.emit(TemplateVars.empty).map;
      expect(none.containsKey('username'), isFalse);
      expect(none.containsKey('password'), isFalse);

      final passOnly = parseUri('socks5://:pw@h.example:1080#n')!
          .emit(TemplateVars.empty)
          .map;
      expect(passOnly.containsKey('username'), isFalse);
      expect(passOnly['password'], 'pw');
      // §463 — пустой username больше не снимает userinfo целиком, иначе
      // пароль пропадал на первом же пересохранении узла.
      expect(parseUri('socks5://:pw@h.example:1080#n')!.toUri(),
          contains(':pw@'));
    }, skip: skip);

    test('§453 dial-поля доезжают до тела и не теряются', () {
      final spec =
          parseUri('socks5://u@h.example:1080?tcp_keep_alive=30s#n')!;
      expect(spec.emit(TemplateVars.empty).map['tcp_keep_alive'], '30s');
      expect(_registry(spec).map((w) => w.code), isNot(contains('unknown_key')));
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном socks ничего не добавляет',
        () {
      final spec = parseUri('socks5://u:p@h.example:1080#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });
}
