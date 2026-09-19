import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 5, раздел 3 спеки — инварианты переезда hysteria2 на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/` и
/// `test/storage_migration/`. Здесь то, что специфично для переезда
/// протокола: identity, round-trip, цена и коды из реестра.
/// §480 W4 — РЕЕСТР из ЗЕРКАЛА (`assets/contract`): вендоренной копии на CI
/// нет вовсе, и под её гейтом файл молча пропускался бы целиком. КОРПУС
/// остаётся за копией — в зеркале его нет.
const _contractRoot = 'assets/contract';
const _corpusRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/hysteria2/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Все hysteria2-ссылки корпуса, в порядке файлов.
List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_corpusRoot/corpus/uri/hysteria2')
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
  final skip = synced ? null : 'зеркало реестра не найдено';
  final hasCorpus = Directory('$_corpusRoot/corpus/uri/hysteria2').existsSync();
  final skipCorpus = hasCorpus ? skip : 'корпус не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§472 инвариант 4 — identity hysteria2 не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(20)),
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

    test('узел без пароля обфускации ЖИВЁТ — снят только блок obfs', () {
      // Граница вложенного `required` (§472 шаг 5). Реестр пишет её прямо у
      // `obfs.password`: «отсутствие пароля снимает блок obfs целиком (узел
      // живёт без обфускации)». До этого шага правило читалось корневым, и
      // такой узел исчезал бы целиком — с ним и живой сервер.
      final spec = parseUri(
          'hysteria2://pass123@example-2.com:443?obfs=gecko&sni=example-2.com'
          '#hy2-nopass');
      expect(spec, isNotNull);
      final body = spec!.emit(TemplateVars.empty).map;
      expect(body.containsKey('obfs'), isFalse);
      final w = _registry(spec)
          .firstWhere((w) => w.code == 'obfs_password_missing');
      expect(w.path, 'obfs.password', reason: 'ожидание корпуса');
      expect(w.params['type'], 'gecko');
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    // Исключения — два свойства ОБЩЕЙ hysteria2-эмиссии, не тронутой этим
    // шагом. Оба проверены на СТАРОМ пути напрямую: в снятом до правки
    // эталоне круг у этих кейсов расходился ровно так же.
    //
    // 1. **Port hopping** (шесть кейсов): `toUriHysteria2` не пишет обратно
    //    `server_ports` — ключа `mport=` в нём нет вовсе, и ссылка собирается
    //    на ОДНОМ порту, том, что стоит в `server_port`.
    // 2. **Пиннинг сертификата** (один кейс): `pinSHA256=` читается на входе
    //    (D-078), но в ссылку не возвращается — эмиттер этого ключа не знает.
    //
    // Отбор по СВОЙСТВУ тела, а не списком тегов: корпус растёт, и список
    // пришлось бы дописывать на каждый новый кейс, пряча за ним настоящие
    // расхождения. Тот же приём, что у vless с явным `path=/`.
    bool outsideCanonicalUri(NodeSpec s) {
      final body = s.emit(TemplateVars.empty).map;
      if (body['server_ports'] != null) return true;
      final tls = body['tls'];
      return tls is Map && tls['certificate_public_key_sha256'] != null;
    }

    test('весь корпус hysteria2 переживает круг', () {
      var checked = 0;
      for (final u in _corpusUris()) {
        final a = parseUri(u);
        if (a == null) continue;
        if (outsideCanonicalUri(a)) continue;
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
      // Страж от «исключения съели корпус»: из 23 кейсов круг проходят 16,
      // семь исключены по свойству выше.
      expect(checked, greaterThan(14));
    }, skip: skipCorpus);

    test('оба исключения — свойство ЭМИТТЕРА, тело своё несёт', () {
      // Проверено напрямую, в обход конвейера: значения теряет обратная
      // запись ссылки, а не маппер. Тела оба свойства несут.
      final hop = parseUri('hysteria2://pass123@example-1.com:20000-50000/'
          '?sni=example-1.com#r')!;
      expect(hop.emit(TemplateVars.empty).map['server_ports'], ['20000:50000']);
      expect(hop.toUri(), isNot(contains('mport')));
      expect(hop.toUri(), contains(':20000?'), reason: 'ссылка на одном порту');

      final pin = parseUri('hysteria2://pass123@203.0.113.1:443'
          '?sni=hy.example-1.com&pinSHA256=YWJjZGVmZ2g=#h')!;
      expect(
          ((pin.emit(TemplateVars.empty).map['tls'] as Map)
              ['certificate_public_key_sha256']),
          ['YWJjZGVmZ2g=']);
      expect(pin.toUri(), isNot(contains('pinSHA256')));
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 hysteria2-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'hysteria2://pass$i@example-$i.com:443?sni=example-$i.com'
              '&obfs=salamander&obfs-password=op$i&upmbps=100&downmbps=200'
              '&alpn=h3&insecure=1#node$i',
      ];

      // Прогрев кэша схем и JIT.
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
        reason: 'разбор $n hysteria2-узлов конвейером: $best мс '
            '(лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — коды hysteria2 приходят из реестра, с путём и значением', () {
    test('запрещённые на QUIC блоки судит САНИТАЙЗЕР, по одному коду на блок',
        () {
      // Главное отличие шага 5. Прежде блоки срезал ЭМИТТЕР
      // (`toSingboxForQuic`), то есть раньше судьи, и код ставил рукописный
      // проход `forbiddenTlsBlockWarnings` (§469). На конвейере блоки
      // доезжают до санитайзера в сырой карте, и правило
      // `forbidden_for`/`forbidden_codes` реестра снимает их само.
      final spec = parseUri(
          'hysteria2://pass123@example-1.com:443?sni=x.example.com&fp=chrome'
          '&pbk=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&sid=ab'
          '#hy2-quic-pair')!;
      expect(
        _registry(spec)
            .where((w) => w.code == 'tls_not_applicable_quic')
            .map((w) => '${w.path}|${w.value}')
            .toList(),
        [
          'tls.utls|map[enabled:true fingerprint:chrome]',
          'tls.reality|map[enabled:true public_key:'
              'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5…',
        ],
        reason: 'по одному коду на блок, значение по CANON §6',
      );
      // Тело от переезда не изменилось: блоков в нём не было и раньше.
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('utls'), isFalse);
      expect(tls.containsKey('reality'), isFalse);
      expect(tls['server_name'], 'x.example.com');
    }, skip: skip);

    test('ссылка и тело дают РАВНЫЕ коды (парный кейс корпуса)', () {
      // §469 требовал равенства пары uri↔body, и раньше его держали ДВА
      // рукописных производителя (в URI-парсере и в ветке json_parsers).
      // Теперь код у обоих входов один и тот же — санитайзер по сырой карте.
      final fromUri = parseUri(
          'hysteria2://pass123@example-1.com:443?sni=x.example.com&fp=chrome'
          '#n')!;
      final fromBody = parseSingboxEntry({
        'type': 'hysteria2',
        'tag': 'n',
        'server': 'example-1.com',
        'server_port': 443,
        'password': 'pass123',
        'tls': {
          'enabled': true,
          'server_name': 'x.example.com',
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
        },
      })!;
      annotateAllFromRawBody([fromBody]);
      String codes(NodeSpec n) => _registry(n)
          .where((w) => w.code == 'tls_not_applicable_quic')
          .map((w) => '${w.code}|${w.path}|${w.value}')
          .join(';');
      expect(codes(fromBody), codes(fromUri));
      expect(fromBody.emit(TemplateVars.empty).map['tls'],
          fromUri.emit(TemplateVars.empty).map['tls']);
    }, skip: skip);

    test('obfs: тип и размеры пакетов судит реестр', () {
      final unknown = parseUri('hysteria2://p@h:443?obfs=xyz&obfs-password=op'
          '&sni=h#H')!;
      final w = _registry(unknown).firstWhere((w) => w.code == 'obfs_unknown');
      expect(w.path, 'obfs.type');
      expect(w.value, 'xyz', reason: 'значение как написал автор');

      // `requires` с `equals: gecko` — размеры осмыслены только у gecko.
      final salamander = parseUri(
          'hysteria2://p@h:443?obfs=salamander&obfs-password=op'
          '&obfs-min-packet-size=100&sni=h#H')!;
      final r =
          _registry(salamander).firstWhere((w) => w.code == 'field_requires');
      expect(r.path, 'obfs.min_packet_size');
      expect(r.params['requires'], 'obfs.type');
      final obfs = salamander.emit(TemplateVars.empty).map['obfs'] as Map;
      expect(obfs.containsKey('min_packet_size'), isFalse);
      expect(obfs['type'], 'salamander', reason: 'сама обфускация цела');
    }, skip: skip);

    test('§453 dial-полей у QUIC-схемы нет — и это не потеря', () {
      // У trojan/vless/ss маппер отдаёт keep-alive в тело (`extensionFields`),
      // здесь — нет. TCP keep-alive поверх QUIC смысла не имеет: транспорт
      // UDP, `Hysteria2Spec` такого поля не знает, и прежний парсер его не
      // читал. Проверяем, что мы не завели его молча: параметр остаётся
      // параметром ссылки и в тело не течёт.
      final spec = parseUri('hysteria2://p@h:443?sni=h&tcp_keep_alive=30s#H')!;
      expect(spec.tcpKeepAlive, isNull);
      final body = spec.emit(TemplateVars.empty).map;
      expect(body.containsKey('tcp_keep_alive'), isFalse);
      expect(spec.warnings.map(warningCodeOf), isNot(contains('unknown_key')));
    }, skip: skip);

    test('pinSHA256 доезжает до тела (на QUIC он валиден)', () {
      final spec = parseUri('hysteria2://p@h:443?sni=x.com'
          '&pinSHA256=YWJjZGVmZ2g=#H')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls['certificate_public_key_sha256'], ['YWJjZGVmZ2g=']);
    }, skip: skip);

    test('эвристика SNI сохранена байт в байт', () {
      // `sni_heuristic_falls_back_to_server` — у hysteria2 она ЕСТЬ на обоих
      // проектах, в отличие от trojan и vless.
      for (final bad in ['localhost', '🔒', '']) {
        final q = bad.isEmpty ? '' : '&sni=${Uri.encodeComponent(bad)}';
        final spec = parseUri('hysteria2://p@h.example:443?alpn=h3$q#H')!;
        final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
        expect(tls['server_name'], 'h.example',
            reason: 'sni=$bad должен уступать адресу сервера');
      }
      // Имя с точкой эвристику переживает.
      final ok = parseUri('hysteria2://p@h.example:443?sni=a.b#H')!;
      expect((ok.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'a.b');
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном hysteria2 ничего не добавляет',
        () {
      final spec = parseUri(
          'hysteria2://p@h:443?sni=x.com&fp=bogus&insecure=1#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });
}
