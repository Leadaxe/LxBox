import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 6, раздел 3 спеки — инварианты переезда naive на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/` и
/// `test/storage_migration/`.
const _contractRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/naive/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_contractRoot/corpus/uri/naive')
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

/// Коды узла: текст предупреждения живёт в реестре, и проверять тут нужно
/// код, а не класс.
List<String> _codes(NodeSpec n) => [for (final w in _registry(n)) w.code];

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 инвариант 4 — identity naive не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(17)),
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
    test('весь корпус naive переживает круг', () {
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
      // 15 разбираемых кейсов, включая QUIC.
      expect(checked, greaterThan(13));
    }, skip: skip);

    test('naive+quic переживает круг: написание схемы несёт QUIC', () {
      // ПОЧИНКА ПОТЕРИ, а не смена нормы. Рукописный `toUriNaive` ВСЕГДА
      // писал `naive+https://` (ветки QUIC у него не было вовсе), и узел
      // `naive+quic://` на круге ронял и `quic`, и congestion control —
      // человек получал по Copy link ссылку на ДРУГОЙ транспорт.
      //
      // Реестр это написание объявляет сам:
      // `emit.form_from: {quic: {true: "naive+quic", "*": "naive+https"}}`,
      // зеркально `scheme_sets`. Движок исполняет объявленное, и круг
      // сходится. Кейс корпуса — `quic_userpass`; снимок `emit_before480`
      // держит там СТАРУЮ ссылку (`naive+https://`), поэтому страж вида
      // ссылки на этот кейс не срабатывает: он кормится старой ссылкой, в
      // которой QUIC уже потерян.
      final a = parseUri('naive+quic://u:p@quic.example:443#q')!;
      expect(a.emit(TemplateVars.empty).map['quic'], isTrue);
      expect(a.toUri(), startsWith('naive+quic://'));
      final b = parseUri(a.toUri())!;
      expect(b.emit(TemplateVars.empty).map, a.emit(TemplateVars.empty).map,
          reason: 'написание схемы возвращает QUIC целиком');
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 naive-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'naive+https://user$i:pass$i@example-$i.com:443'
              '?extra-headers=X-Tag%3A%20v$i#node$i',
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
        reason: 'разбор $n naive-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — naive: перевод, который остаётся за маппером', () {
    test('§465 — одиночный userinfo это PASSWORD', () {
      final only = parseUri('naive+https://secret@h.example#n')!;
      final body = only.emit(TemplateVars.empty).map;
      expect(body['password'], 'secret');
      expect(body.containsKey('username'), isFalse);

      // `user:` — двоеточие есть, пароль пуст: это форма «только имя».
      final userOnly = parseUri('naive+https://alice:@h.example#n')!;
      final ub = userOnly.emit(TemplateVars.empty).map;
      expect(ub['username'], 'alice');
      expect(ub.containsKey('password'), isFalse);
      // И она возвращается в ссылку С двоеточием — иначе круг прочёл бы имя
      // как пароль (`toUriNaive`, §465).
      expect(userOnly.toUri(), contains('alice:@'));
    }, skip: skip);

    test('naive+quic даёт quic: true и bbr, naive+https — нет', () {
      final quic = parseUri('naive+quic://u:p@h.example:443#q')!;
      final qb = quic.emit(TemplateVars.empty).map;
      expect(qb['quic'], isTrue);
      expect(qb['quic_congestion_control'], 'bbr');

      final https = parseUri('naive+https://u:p@h.example:443#h')!;
      expect(https.emit(TemplateVars.empty).map.containsKey('quic'), isFalse);
    }, skip: skip);

    test('extra-headers: битая пара пропускается, остальные живут', () {
      // `broken_header_pair_skipped` — одна битая пара не стоит узлу
      // остальных заголовков. Код один на узел.
      final spec = parseUri('naive+https://u:p@h.example'
          '?extra-headers=X%20User%3Abad%0D%0AX-Good%3Aok#n')!;
      expect(spec.emit(TemplateVars.empty).map['extra_headers'],
          {'X-Good': 'ok'});
      expect(_codes(spec).where((c) => c == 'naive_extra_headers_invalid'),
          hasLength(1));
    }, skip: skip);

    test('padding отбрасывается с кодом маппера', () {
      // Эквивалента в sing-box нет; значения в теле не будет, поэтому код
      // ставит МАППЕР — санитайзеру сказать о нём нечего.
      final spec =
          parseUri('naive+https://u:p@h.example?padding=true#n')!;
      expect(_codes(spec), contains('naive_padding_ignored'));
      expect(spec.emit(TemplateVars.empty).map.containsKey('padding'), isFalse);
    }, skip: skip);

    test('TLS у naive всегда минимален: enabled + server_name', () {
      // Диалект ссылки naive TLS-параметров не знает вовсе (`uri.query`
      // реестра: только extra-headers и padding), поэтому писать в блок
      // нечего, и allowlist §454/§270 на этом входе не срабатывает.
      final spec = parseUri('naive+https://u:p@h.example:443#n')!;
      expect(spec.emit(TemplateVars.empty).map['tls'],
          {'enabled': true, 'server_name': 'h.example'});
      expect(_registry(spec).map((w) => w.code),
          isNot(contains('tls_field_unsupported_naive')));
    }, skip: skip);

    test('пустой host отбраковывается (§463)', () {
      // Ядро на пустом адресе валит ВЕСЬ конфиг, то есть один такой узел из
      // подписки оставлял человека без VPN.
      expect(parseUri('naive+https://'), isNull);
    }, skip: skip);

    test('§453 dial-поля доезжают до тела и не теряются', () {
      final spec =
          parseUri('naive+https://u:p@h.example?tcp_keep_alive=30s#n')!;
      expect(spec.emit(TemplateVars.empty).map['tcp_keep_alive'], '30s');
      expect(_registry(spec).map((w) => w.code), isNot(contains('unknown_key')));
    }, skip: skip);
  });

  group('§472 — дефект: QUIC терялся на входе тела', () {
    test('quic читается из тела обратно в модель', () {
      // `emitNaive` поле пишет, а `parseSingboxEntry` не читал вовсе: узел
      // `naive+quic://`, пересохранённый через JSON или отредактированный во
      // вкладке JSON, молча возвращался к HTTP/2 и соединения не поднимал.
      // Тот же класс, что `encryption` у vless и `plugin` у shadowsocks.
      final node = parseSingboxEntry({
        'type': 'naive',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'quic': true,
        'quic_congestion_control': 'bbr',
        'tls': {'enabled': true, 'server_name': 'h.example'},
      })!;
      expect((node as NaiveSpec).quic, isTrue);
      // Круг через тело сохраняет транспорт.
      final body = node.emit(TemplateVars.empty).map;
      expect(body['quic'], isTrue);
      expect(body['quic_congestion_control'], 'bbr');
    }, skip: skip);

    test('без ключа quic узел остаётся на HTTP/2', () {
      final node = parseSingboxEntry({
        'type': 'naive',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 443,
        'tls': {'enabled': true, 'server_name': 'h.example'},
      })!;
      expect((node as NaiveSpec).quic, isFalse);
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном naive ничего не добавляет',
        () {
      final spec = parseUri('naive+https://u:p@h.example:443'
          '?padding=true&extra-headers=X-A%3A%20b#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });
}
