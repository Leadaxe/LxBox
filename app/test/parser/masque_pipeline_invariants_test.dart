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
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/warp/masque_account.dart';

/// §472 шаг 7, раздел 3 спеки — инварианты переезда masque на конвейер.
/// §480 W4 — РЕЕСТР из ЗЕРКАЛА: вендоренной копии на CI нет, и под её гейтом
/// файл пропускался бы целиком. КОРПУС остаётся за копией — в зеркале его нет.
const _contractRoot = 'assets/contract';
const _corpusRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026). В нём и
/// корпус, и ссылки `app/test`, и узлы, которые строит фабрика WARP
/// (`MasqueAccount.toMasqueUri`) — именно они у пользователей самые массовые.
const _identityFixture = 'test/fixtures/masque/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_corpusRoot/corpus/uri/masque')
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

/// Узел WARP-фабрики: та самая ссылка, которую строит визард MASQUE.
MasqueAccount _warpAccount() => MasqueAccount(
      privKeyDer: 'MHcCAQEEIB5oxGzgOdLvTY2aAbRsyJslxnlvPpOzLR076h3cgsnc'
          'oAoGCCqGSM49AwEHoUQDQgAEDQBTbtpEikpJDklVHdnMhgIR8YatYDJLUILDQWGd'
          'wBbqaLiKKiuawVQz6MIaHr0I/4mNM/TfUUnoENKv9qZEWw==',
      serverPubDer: 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDQBTbtpEikpJDklVHd'
          'nMhgIR8YatYDJLUILDQWGdwBbqaLiKKiuawVQz6MIaHr0I/4mNM/TfUUnoENKv9q'
          'ZEWw==',
      clientV4: '172.16.0.2/32',
      clientV6: '2606:4700:110:8a1b:c0de:cafe:babe:1234/128',
      server: '162.159.198.1',
      port: 443,
      deviceId: 'dev',
      token: 'tok',
      createdAt: '2026-01-01T00:00:00Z',
      sni: 'masque.example.com',
      idleTimeout: '5m',
      keepAlive: '30s',
    );

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'зеркало реестра не найдено';
  final hasCorpus = Directory('$_corpusRoot/corpus/uri/masque').existsSync();
  final skipCorpus = hasCorpus ? skip : 'корпус не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§472 инвариант 4 — identity masque не меняется', () {
    test('каждый кейс снимка даёт прежние хеш, тег и тело', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(12)),
          reason: 'снимок похудел — проверьте, не срезан ли корпус');
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
        expect(spec.tag, e.value['tag'], reason: 'тег кейса ${e.key}');
        expect(jsonEncode(spec.emit(TemplateVars.empty).map),
            jsonEncode(e.value['body']),
            reason: 'тело кейса ${e.key}');
      }
    }, skip: skip);

    test('узел фабрики WARP не сдвинулся ни на одной версии HTTP', () {
      // MASQUE-узлы WARP у пользователей самые массовые, и строит их ссылка
      // `MasqueAccount.toMasqueUri` — тот же вход, что у ручной вставки.
      final before = _identityBefore();
      for (final vhttp in const ['h3', 'h2', 'auto']) {
        final spec = parseMasqueUri(_warpAccount().toMasqueUri(vhttp: vhttp))!;
        expect(legacyNodeIdentityHash(spec), before['warp:$vhttp']!['identity'],
            reason: 'identity WARP-узла vhttp=$vhttp');
        expect(spec.emit(TemplateVars.empty).map['vhttp'], vhttp);
      }
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус masque переживает круг', () {
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
      expect(checked, 6);
    }, skip: skipCorpus);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 masque-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'masque://PRIVDER%3D%3D@192.0.2.$i:443?publickey=PUBDER%3D%3D'
              '&address=172.16.0.2%2F32%2C2001%3Adb8%3A%3A2'
              '&vhttp=h3&sni=a$i.example&mtu=1280&idle_timeout=5m#node$i',
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
        reason: 'разбор $n masque-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — masque: перевод, который остаётся за маппером', () {
    const bare = 'masque://PRIVDER%3D%3D@192.0.2.44:443'
        '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32#n';

    test('приватный ключ: userinfo, фолбэк из query, оба написания', () {
      for (final key in const ['private_key', 'privatekey']) {
        final spec = parseUri('masque://192.0.2.44:443?publickey=PUBDER%3D%3D'
            '&address=172.16.0.2%2F32&$key=PRIVDER%3D%3D#n')!;
        expect(spec.emit(TemplateVars.empty).map['private_key'], 'PRIVDER==',
            reason: 'фолбэк $key');
      }
      // §106 — сырой `/` в base64(DER) userinfo не теряет ключ.
      final slash = parseUri('masque://PR/IV@192.0.2.44:443'
          '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32#n')!;
      expect(slash.emit(TemplateVars.empty).map['private_key'], 'PR/IV');
    }, skip: skip);

    test('без publickey или без address узла нет', () {
      expect(
          parseUri('masque://PRIVDER%3D%3D@192.0.2.44:443'
              '?address=172.16.0.2%2F32#n'),
          isNull);
      expect(
          parseUri('masque://PRIVDER%3D%3D@192.0.2.44:443'
              '?publickey=PUBDER%3D%3D#n'),
          isNull);
    }, skip: skip);

    test('порт по умолчанию 443', () {
      final spec = parseUri('masque://PRIVDER%3D%3D@192.0.2.44'
          '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32#n')!;
      expect(spec.emit(TemplateVars.empty).map['server_port'], 443);
    }, skip: skip);

    test('keep_alive ссылки → keep_alive_period тела', () {
      final spec = parseUri(bare.replaceAll('#n', '&keep_alive=45s#n'))!;
      expect(spec.emit(TemplateVars.empty).map['keep_alive_period'], '45s');
    }, skip: skip);

    test('profile и mtu — дефолты ССЫЛКИ, пишутся явно', () {
      // Реестр объявляет их `default`, но `default` по CANON §2.4 в тело не
      // материализуется; корпус их присутствия ждёт, и на них стоит identity.
      final body = parseUri(bare)!.emit(TemplateVars.empty).map;
      expect(body['profile'], 'cloudflare');
      expect(body['mtu'], 1280);
    }, skip: skip);
  });

  group('§472 — masque: судит реестр', () {
    const bare = 'masque://PRIVDER%3D%3D@192.0.2.44:443'
        '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32#n';

    test('vhttp вне тройки → coerce h3 с кодом реестра', () {
      final spec = parseUri(bare.replaceAll('#n', '&vhttp=tcp#n'))!;
      expect(spec.emit(TemplateVars.empty).map['vhttp'], 'h3');
      final w = _registry(spec)
          .firstWhere((w) => w.code == 'masque_vhttp_invalid',
              orElse: () => fail('нет кода: ${spec.warnings}'));
      expect(w.path, 'vhttp');
      expect(w.value, 'tcp',
          reason: 'значение в коде — то, что написал автор ссылки');
      // Рукописного класса на пути ссылки больше нет: производитель один.
      // §472 шаг 9 — `MasqueVhttpInvalidWarning` снят совсем, и проверять его
      // отсутствие больше нечем: он не компилируется.
    }, skip: skip);

    test('profile вне набора снимается реестром, узел живёт на дефолте', () {
      // Санитайзер снимает негодное значение (`on_invalid: drop`), и дальше
      // `parseSingboxEntry` читает отсутствующее поле как дефолт МОДЕЛИ
      // (`cloudflare`), а `emitMasque` пишет его всегда. То есть узел уезжает
      // на рабочем профиле, и человек видит, ЧТО именно было снято.
      final spec = parseUri(bare.replaceAll('#n', '&profile=junk#n'))!;
      expect(spec.emit(TemplateVars.empty).map['profile'], 'cloudflare');
      expect(_registry(spec).map((w) => '${w.code}@${w.path}'),
          contains('type_invalid@profile'));
      expect(_registry(spec).firstWhere((w) => w.path == 'profile').value,
          'junk');
      // Значение из набора проходит молча.
      final ok = parseUri(bare.replaceAll('#n', '&profile=standard#n'))!;
      expect(ok.emit(TemplateVars.empty).map['profile'], 'standard');
      expect(_registry(ok), isEmpty);
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном masque ничего не добавляет',
        () {
      final spec = parseUri('masque://PRIVDER%3D%3D@192.0.2.44:443'
          '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32&vhttp=tcp#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });

  // БЕЗ ГЕЙТА: тест идёт через `parseSingboxEntry` напрямую, реестр ему не
  // нужен, а симметрию эмиттера и парсера тела он стережёт на любом прогоне.
  group('§472 — состав ветки json_parsers сверен с body.fields', () {
    test('всё, что пишет emitMasque, парсер тела читает обратно', () {
      final a = parseUri('masque://PRIVDER%3D%3D@192.0.2.44:443'
          '?publickey=PUBDER%3D%3D&address=172.16.0.2%2F32%2C2001%3Adb8%3A%3A2'
          '&profile=standard&vhttp=h2&sni=a.example&disable_sni=1&mtu=1400'
          '&idle_timeout=5m&keep_alive=45s#n')!;
      final body = a.emit(TemplateVars.empty).map;
      final b = parseSingboxEntry(Map<String, dynamic>.from(body))!;
      expect(b.emit(TemplateVars.empty).map, body,
          reason: 'поле, которое эмиттер пишет, а парсер тела не читает, — '
              'молчаливая потеря на пересохранении через JSON');
    });
  });
}
