import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 5, раздел 3 спеки — инварианты переезда tuic на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/` и
/// `test/storage_migration/`. Здесь то, что специфично для переезда
/// протокола: identity, round-trip, цена и коды из реестра.
/// §480 W4 — РЕЕСТР берётся из ЗЕРКАЛА (`assets/contract`), а не из
/// вендоренной копии: копии на CI нет вовсе (она в `.gitignore`), и под её
/// гейтом весь файл молча пропускался бы именно там, где нужен. Зеркало лежит
/// в git и едет в APK.
///
/// КОРПУС остаётся за вендоренной копией — в зеркале его нет, оно несёт
/// только `registry/`. Поэтому гейта два: тесты по фикстурам идут всегда,
/// тесты по корпусу — только локально после синка.

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/tuic/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Все tuic-ссылки корпуса, в порядке файлов.
List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$kVendorRoot/corpus/uri/tuic')
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
  // Корпус живёт только в вендоренной копии — на CI его нет.
  final corpusSkip = corpusTestSkip('test/parser/tuic_pipeline_invariants_test.dart');

  setUpAll(() async {
    await loadTestRegistry();
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§472 инвариант 4 — identity tuic не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(12)),
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

    test('узел с `uuid` не в форме UUID теперь отбраковывается', () {
      // ЕДИНСТВЕННОЕ изменение поведения этого переезда, и оно намеренное.
      // Реестр объявляет у поля `format: uuid` + `on_invalid: drop`, а само
      // поле `required`: ядро отвечает на мусорный uuid «invalid uuid» —
      // фаталом на ВЕСЬ конфиг, то есть такой узел уносил с собой и все
      // остальные. Прежде он строился и уезжал в ядро как есть.
      //
      // Корпус эту границу провёл сам (SPEC 131 W2c): заглушки `u` в его
      // кейсах заменены настоящими UUID с пометкой «кейс нормировал тело,
      // которое не запускается». Ни одного корпусного кейса с мусорным uuid
      // сегодня нет, и identity выше это подтверждает.
      expect(parseUri('tuic://u:p@h.example:443?alpn=h3#n'), isNull);
      expect(parseUri('tuic://aaaa-bbbb:secret@srv:443#n'), isNull);
      // Настоящий UUID проходит.
      expect(
          parseUri('tuic://11111111-1111-1111-1111-111111111111:p@h:443#n'),
          isNotNull);
    });
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус tuic переживает круг', () {
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
      // У tuic круг проходят ВСЕ разбираемые кейсы, без исключений.
      expect(checked, greaterThan(11));
    }, skip: corpusSkip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 tuic-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          // Настоящий UUID: реестр проверяет форму (`format: uuid`), и
          // заглушка отбраковала бы все 2000 узлов вместо замера.
          'tuic://11111111-1111-1111-1111-${'$i'.padLeft(12, '0')}'
              ':pass$i@example-$i.com:443?congestion_control=bbr&alpn=h3'
              '&udp_relay_mode=native&sni=example-$i.com#node$i',
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
        reason: 'разбор $n tuic-узлов конвейером: $best мс (лучший из трёх)',
      );
    });
  });

  group('§472 — коды tuic приходят из реестра, с путём и значением', () {
    const uuid = '11111111-1111-1111-1111-111111111111';

    test('запрещённый на QUIC блок utls судит САНИТАЙЗЕР', () {
      // Прежде блок срезал ЭМИТТЕР (`toSingboxForQuic`), то есть раньше
      // судьи, и код ставил рукописный проход `forbiddenTlsBlockWarnings`
      // (§469) — причём `fp` у tuic до 1.1.4 не читался вовсе.
      final spec = parseUri('tuic://$uuid:pass123@tuic.example-1.com:443/'
          '?congestion_control=bbr&fp=firefox&sni=tuic.example-1.com#n')!;
      final w = _registry(spec)
          .where((w) => w.code == 'tls_not_applicable_quic')
          .toList();
      expect(w, hasLength(1), reason: 'один код на блок');
      expect(w.single.path, 'tls.utls');
      expect(w.single.value, 'map[enabled:true fingerprint:firefox]');
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('utls'), isFalse, reason: 'тело прежнее');
    });

    test('ссылка и тело дают РАВНЫЕ коды (парный кейс корпуса)', () {
      final fromUri = parseUri('tuic://$uuid:pass123@tuic.example-1.com:443/'
          '?congestion_control=bbr&fp=firefox&sni=tuic.example-1.com#n')!;
      final fromBody = parseSingboxEntry({
        'type': 'tuic',
        'tag': 'n',
        'server': 'tuic.example-1.com',
        'server_port': 443,
        'uuid': uuid,
        'password': 'pass123',
        'congestion_control': 'bbr',
        'tls': {
          'enabled': true,
          'server_name': 'tuic.example-1.com',
          'utls': {'enabled': true, 'fingerprint': 'firefox'},
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
    });

    test('congestion_control и udp_relay_mode судит реестр', () {
      final cc = parseUri('tuic://$uuid:p@h:443?congestion_control=bogus#n')!;
      final w = _registry(cc)
          .firstWhere((w) => w.code == 'tuic_congestion_invalid');
      expect(w.path, 'congestion_control');
      expect(w.value, 'bogus', reason: 'значение как написал автор');
      expect(cc.emit(TemplateVars.empty).map.containsKey('congestion_control'),
          isFalse, reason: 'ядро подставит свой дефолт');

      // §463 — мусор в udp_relay_mode СНИМАЕТСЯ, а не подменяется на native.
      final urm = parseUri('tuic://$uuid:p@h:443?udp_relay_mode=quiс#n')!;
      final u = _registry(urm)
          .firstWhere((w) => w.code == 'tuic_udp_relay_mode_invalid');
      expect(u.path, 'udp_relay_mode');
      expect(u.value, 'quiс', reason: 'кириллическая «с» — та самая опечатка');
      expect(urm.emit(TemplateVars.empty).map.containsKey('udp_relay_mode'),
          isFalse);
    });

    test('три написания 0-RTT читаются одинаково', () {
      // `uri.query.reduce_rtt.aliases` — целевой набор контракта это
      // объединение обоих проектов; `zero_rtt_handshake` у Dart прежде не
      // читался вовсе.
      for (final key in ['reduce_rtt', 'zero_rtt', 'zero_rtt_handshake']) {
        final spec = parseUri('tuic://$uuid:p@h:443?$key=1#n')!;
        expect(spec.emit(TemplateVars.empty).map['zero_rtt_handshake'], isTrue,
            reason: 'написание $key');
      }
      // Без параметра поля в теле нет вовсе (дефолт ставит ядро).
      final off = parseUri('tuic://$uuid:p@h:443#n')!;
      expect(off.emit(TemplateVars.empty).map.containsKey('zero_rtt_handshake'),
          isFalse);
    });

    test('disable_sni=1 убирает имя сервера из тела', () {
      final on = parseUri('tuic://$uuid:p@h.example:443?sni=a.b'
          '&disable_sni=1#n')!;
      final tls = on.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('server_name'), isFalse);
      // `disable_sni=0` — не просили: имя на месте (кейс корпуса v5_zero_rtt).
      final off = parseUri('tuic://$uuid:p@h.example:443?sni=a.b'
          '&disable_sni=0#n')!;
      expect((off.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'a.b');
    });

    test('пароль с двоеточием внутри не теряется', () {
      // userinfo у tuic это `uuid:password`, но пароль — всё ПОСЛЕ первого
      // двоеточия: у hysteria2 двоеточие часть пароля целиком, здесь —
      // разделитель ровно один раз.
      final spec = parseUri('tuic://$uuid:p%3A1%3A2@h:443#n')!;
      expect(spec.emit(TemplateVars.empty).map['password'], 'p:1:2');
    });
  });

  // РЕШЕНИЕ ВЛАДЕЛЬЦА 19.09.2026 — пустой пароль это УЗЕЛ С ПРЕДУПРЕЖДЕНИЕМ,
  // а не отбраковка. Снимает расхождение строгости, которое лаунчер держал
  // открытым вопросом (TASKS_LXBOX §32.3, Q133-67). Соединение возможно по
  // устройству протокола: токен TUIC v5 — TLS-экспортёр, пароль идёт
  // КОНТЕКСТОМ, и пустой контекст экспортёр не отвергает.
  group('пустой пароль — узел с кодом, не отбраковка', () {
    const uuid = '11111111-1111-1111-1111-111111111111';
    const empty = 'tuic://$uuid:@example-1.com:443#n';
    const absent = 'tuic://$uuid@example-1.com:443#n';

    test('оба написания дают УЗЕЛ и код password_empty', () {
      // Написаний отсутствия два — пустой хвост и хвоста нет вовсе, — а
      // событие одно: значения нет. Для тела они неразличимы, поэтому и
      // судятся одинаково.
      for (final u in [empty, absent]) {
        final spec = parseUri(u);
        expect(spec, isNotNull, reason: 'узел отбракован: $u');
        final w = _registry(spec!).where((w) => w.code == 'password_empty');
        expect(w, hasLength(1), reason: 'один код на узел: $u');
        expect(w.single.path, 'password');
      }
    });

    test('тело у обоих написаний ОДНО и то же', () {
      final a = parseUri(empty)!.emit(TemplateVars.empty).map;
      final b = parseUri(absent)!.emit(TemplateVars.empty).map;
      expect(b, a, reason: 'написание входа в тело не просачивается');
      // Корпус 1.1.43+ (Q133-67): пустой пароль — предупреждение, ключ в теле
      // не материализуется (omitempty у ядра; оба написания отсутствия
      // неразличимы для тела).
      expect(a.containsKey('password'), isFalse);
      expect(b.containsKey('password'), isFalse);
    });

    test('круг parse(emit) сходится вместе с кодом', () {
      for (final u in [empty, absent]) {
        final a = parseUri(u)!;
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'круг потерял узел: $u');
        expect(b!.emit(TemplateVars.empty).map, a.emit(TemplateVars.empty).map,
            reason: 'круг изменил тело: $u');
        expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
            reason: 'круг изменил identity: $u');
        // Код обязан пережить круг: исходящая ссылка пароля не несёт, и
        // второй разбор видит ровно то же отсутствие.
        expect(
          _registry(b).where((w) => w.code == 'password_empty'),
          hasLength(1),
          reason: 'круг потерял код: $u',
        );
      }
    });

    test('узел С паролем кода не получает', () {
      final spec = parseUri('tuic://$uuid:pass123@example-1.com:443#n')!;
      expect(_registry(spec).where((w) => w.code == 'password_empty'), isEmpty);
      expect(spec.emit(TemplateVars.empty).map['password'], 'pass123');
    });

    test('синк 1.1.37 — у кода есть ТЕКСТЫ, карточка не пустая', () {
      // До синка 1.1.37 код ставился нашим оверлеем, а в `warnings.json` его
      // не было вовсе: severity бралась умолчанием, заголовком вставал сам
      // идентификатор, карточка оставалась пустой. Реестр привёз код ОБЩИМ
      // (не под схему) вместе с текстами — проверяем именно это, иначе
      // регрессия реестра прошла бы молча: поведение-то осталось бы верным.
      final t = ContractRegistry.I.textFor('password_empty');
      expect(t, isNotNull, reason: 'кода нет в registry/warnings.json');
      expect(t!.severity, 'warning');
      expect(t.params, contains('path'));
      for (final s in [t.titleEn, t.titleRu, t.textEn, t.textRu]) {
        expect(s, isNotEmpty);
        expect(s, isNot('password_empty'),
            reason: 'заголовком встал идентификатор — текста нет');
      }
      // Подстановка `{path}` обязана быть названа значением, а не остаться
      // в тексте дословно: путь кода у этой записи — `password`.
      expect(t.textEn, contains('{path}'));
      expect(t.fixEn, isNotEmpty);
      expect(t.fixRu, isNotEmpty);
    });
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном tuic ничего не добавляет', () {
      final spec = parseUri(
          'tuic://11111111-1111-1111-1111-111111111111:p@h:443'
          '?sni=x.com&fp=firefox&allow_insecure=1#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    });
  });
}
