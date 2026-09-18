// §460 W1 — инвариант 24.1.7 над корпусом контракта.
//
// Норма: «значение с вердиктом B (фатал на ВЕСЬ конфиг) после санитайзера в
// entry остаться не может». Проверяем это практически: санитайзер
// идемпотентен — повторный прогон по уже очищенному телу не находит НИ
// ОДНОГО нарушения. Если бы после первого прохода осталось значение, которое
// реестр считает негодным, второй проход его бы нашёл.
//
// Корпус — общий с лаунчером (`contract/corpus/body/**`), берём `entry`
// узлов из `expected.json`: это уже нормированные тела, на которых обе
// стороны сошлись.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';

const _contractRoot = 'contract';

/// Пин ядра реестра: под ним `min_core`-поля корпуса законны.
const _core = '1.14.1-lx.4';

void main() {
  final root = Directory('$_contractRoot/corpus/body');
  final synced = root.existsSync() &&
      Directory('$_contractRoot/registry').existsSync();

  group('Инвариант 24.1.7 — санитайзер идемпотентен на корпусе', () {
    setUpAll(() async {
      if (!synced) return;
      await ContractRegistry.I.loadFromDirectory(_contractRoot);
    });

    if (!synced) {
      test('корпус контракта не синхронизирован', () {},
          skip: 'нет $_contractRoot/corpus/body — синхронизируйте контракт');
      return;
    }

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.expected.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final rel = file.path.substring(root.path.length + 1);
      test(rel, () {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final nodes = (data['nodes'] as List?) ?? const [];
        var checked = 0;

        for (final raw in nodes) {
          if (raw is! Map) continue;
          final entry = raw['entry'];
          if (entry is! Map) continue;
          final body = entry.cast<String, dynamic>();
          final type = body['type'];
          if (type is! String) continue;
          // Схемы нет (расширение чужой стороны) — санитайзер такую запись и
          // не трогает, проверять нечего.
          if (ContractRegistry.I.schemaFor(type) == null) continue;

          final first = RegistrySanitizer.sanitize(
            Map<String, dynamic>.from(body),
            scheme: type,
            coreVersion: _core,
          );
          // Запись, снятая целиком, инвариант не нарушает: в конфиг она не
          // попадёт.
          if (first.body == null) continue;

          final second = RegistrySanitizer.sanitize(
            Map<String, dynamic>.from(first.body!),
            scheme: type,
            coreVersion: _core,
          );
          expect(
            second.warnings.map((w) => '${w.code}@${w.path}').toList(),
            isEmpty,
            reason: '$rel: после санитайзера в теле ${raw['label']} '
                '($type) остались значения, которые реестр считает негодными',
          );
          // Второй проход ничего не меняет — тело устойчиво.
          expect(second.body, first.body,
              reason: '$rel: санитайзер не идемпотентен на ${raw['label']}');
          checked++;
        }

        // Кейс без единой записи под схемой реестра — не молчаливый пропуск,
        // а факт: помечаем skipped, чтобы он не выглядел зелёной проверкой.
        if (checked == 0) {
          markTestSkipped('$rel: записей со схемой реестра нет');
        }
      });
    }
  });

  // §469 (контракт 1.1.4) — линтер атрибута `forbidden_codes`.
  //
  // Атрибут переопределяет код запрета для отдельной схемы из
  // `forbidden_for`. Две ошибки в нём молчаливы и потому опасны: код для
  // схемы, которой в `forbidden_for` нет (правило не сработает никогда, а
  // выглядит написанным), и код, которого нет в `warnings.json` (узел получит
  // запись без текста — на строке останется голый идентификатор). Обе ловятся
  // здесь, а не в рантайме.
  group('§469 — forbidden_codes', () {
    final registryDir = Directory('$_contractRoot/registry');

    test('ключи — только схемы из forbidden_for, коды — только из warnings.json',
        () {
      final codes = ((jsonDecode(
                      File('$_contractRoot/registry/warnings.json')
                          .readAsStringSync())
                  as Map<String, dynamic>)['warnings'] as Map)
          .keys
          .map((e) => '$e')
          .toSet();

      var checkedFields = 0;
      for (final file in registryDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))) {
        final rel = file.path.substring(registryDir.path.length + 1);
        if (rel == 'warnings.json') continue;
        final data = jsonDecode(file.readAsStringSync());

        void walk(Object? node, String path) {
          if (node is Map) {
            final fc = node['forbidden_codes'];
            if (fc is Map) {
              checkedFields++;
              final forbiddenFor = ((node['forbidden_for'] as List?) ?? const [])
                  .map((e) => '$e')
                  .toSet();
              for (final e in fc.entries) {
                expect(forbiddenFor, contains('${e.key}'),
                    reason: '$rel $path: forbidden_codes называет схему '
                        '"${e.key}", которой нет в forbidden_for — правило '
                        'не сработает никогда');
                expect(codes, contains('${e.value}'),
                    reason: '$rel $path: код "${e.value}" из forbidden_codes '
                        'отсутствует в warnings.json — узел получил бы запись '
                        'без текста');
              }
            }
            for (final e in node.entries) {
              walk(e.value, path.isEmpty ? '${e.key}' : '$path.${e.key}');
            }
          } else if (node is List) {
            for (final e in node) {
              walk(e, path);
            }
          }
        }

        walk(data, '');
      }

      // Атрибут завела версия 1.1.4 ровно ради QUIC-среза; исчезнет он —
      // исчезнет и правило, и молчаливо зелёный линтер это скрыл бы.
      expect(checkedFields, greaterThan(0),
          reason: 'forbidden_codes в реестре не встречается вовсе — либо '
              'контракт откатили, либо линтер смотрит не туда');
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('санитайзер берёт код из forbidden_codes, а не общий', () {
      // `tls.utls` запрещён и naive, и QUIC-схемам — но исход разный, и код
      // тоже: у naive потерянная настройка, на QUIC снятая бессмыслица.
      Map<String, dynamic> body(String scheme) => {
            'type': scheme,
            'server': 'example-1.com',
            'server_port': 443,
            if (scheme == 'naive') 'username': 'u',
            if (scheme != 'naive') 'password': 'p',
            // Обязательные по схеме поля: без них запись уходит целиком
            // (24.1.7), и до правил TLS санитайзер не доберётся.
            if (scheme == 'tuic') 'uuid': '11111111-1111-1111-1111-111111111111',
            if (scheme == 'masque') ...{
              'profile': 'cloudflare',
              'private_key': 'k',
              'public_key': 'k',
            },
            'tls': {
              'enabled': true,
              'server_name': 'example-1.com',
              'utls': {'enabled': true, 'fingerprint': 'chrome'},
            },
          };

      for (final (scheme, code) in const [
        ('naive', 'tls_field_unsupported_naive'),
        ('hysteria2', 'tls_not_applicable_quic'),
        ('tuic', 'tls_not_applicable_quic'),
        ('masque', 'tls_not_applicable_quic'),
      ]) {
        final res = RegistrySanitizer.sanitize(body(scheme),
            scheme: scheme, coreVersion: _core);
        final utls = res.warnings.where((w) => w.path == 'tls.utls').toList();
        expect(utls, hasLength(1), reason: '$scheme: один код на блок');
        expect(utls.single.code, code, reason: '$scheme: код не тот');
        // Значение блока названо — форма канона корпуса, не Dart-`toString`.
        expect(utls.single.value, 'map[enabled:true fingerprint:chrome]');
        expect((res.body?['tls'] as Map?)?.containsKey('utls'), isFalse,
            reason: '$scheme: блок обязан быть снят');
      }
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('REALITY на QUIC — один код на блок, key_share/short_id молчат', () {
      final res = RegistrySanitizer.sanitize({
        'type': 'hysteria2',
        'server': 'example-1.com',
        'server_port': 443,
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'example-1.com',
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'short_id': 'ab',
            'key_share': 'hybrid',
          },
        },
      }, scheme: 'hysteria2', coreVersion: _core);

      expect(res.warnings.map((w) => '${w.code}@${w.path}'),
          ['tls_not_applicable_quic@tls.reality'],
          reason: 'снят не short_id и не key_share, а весь REALITY — '
              'вложенные поля своих кодов не дают');
      expect((res.body?['tls'] as Map?)?.containsKey('reality'), isFalse);
    }, skip: synced ? null : 'контракт не синхронизирован');
  });
}
