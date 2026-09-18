// §460 W1 — гард реестра на сборке конфига.
//
// Два вопроса, на которые отвечает файл:
//   1. Мусор в теле JSON-источника (§455 переносит его дословно) гард
//      действительно снимает, и предупреждение несёт текст реестра.
//   2. Валидный конфиг гард не трогает: эталоны rich_v0/avd_v0 обязаны
//      остаться байт в байт ТЕМИ ЖЕ при ЗАГРУЖЕННОМ реестре. Обычные
//      golden-тесты реестр не грузят, поэтому проверка живёт здесь.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/services/builder/registry_gate.dart';
import 'package:lxbox/services/contract/registry.dart';

import '../storage_migration/golden_harness.dart';

const _contractRoot = 'contract';

/// Версия ядра эталонов — та же, что в golden_harness.
const _core = kGoldenCoreVersion;

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('гард реестра на сборке', () {
    test('naive из JSON-источника: foo и tls.insecure сняты, certificate цел',
        () {
      // Тело в точности как его переносит §455 — дословно, вместе с мусором.
      final entry = Outbound(<String, dynamic>{
        'type': 'naive',
        'tag': 'naive-json',
        'server': '1.2.3.4',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'foo': 1,
        'tls': {
          'enabled': true,
          'server_name': 's.example.com',
          'insecure': true,
          'certificate': '-----BEGIN CERTIFICATE-----',
        },
      });

      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(report.dropped, isEmpty, reason: 'узел остаётся в конфиге');
      expect(entry.map.containsKey('foo'), isFalse);
      final tls = entry.map['tls'] as Map;
      expect(tls.containsKey('insecure'), isFalse,
          reason: 'naive не читает insecure — у ядра это фатал старта');
      expect(tls['certificate'], '-----BEGIN CERTIFICATE-----',
          reason: 'certificate naive читает — поле обязано уцелеть');
      expect(tls['server_name'], 's.example.com');

      // Ровно два предупреждения, и оба с текстом реестра, а не с кодом.
      expect(report.warnings.length, 2, reason: report.warnings.join('\n'));
      final joined = report.warnings.join('\n');
      expect(joined, contains('naive-json: '));
      // Путь есть у обоих. §469 — у запрета (`forbidden_for`) появилось и
      // ЗНАЧЕНИЕ: ожидания корпуса его называют
      // (`singbox/outbound_array_tls_fields` → `tls.insecure` = `true`), а
      // гейт до этого ставил код без него. `unknown_key` значения по-прежнему
      // не несёт — там снят сам ключ, и говорить про него нечего.
      expect(joined, contains('[foo]'));
      expect(joined, contains('[tls.insecure=true]'));
      // Текст из warnings.json, а не голый код.
      expect(joined, isNot(contains('unknown_key')));
      expect(joined, isNot(contains('tls_field_unsupported_naive')));
      expect(joined, contains('unknown key'));
      expect(joined, contains('naive: TLS field tls.insecure removed'));
    }, skip: skip);

    test('запись без обязательного поля снимается целиком', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'vless',
        'tag': 'no-uuid',
        'server': 'example.com',
        'server_port': 443,
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.dropped, [entry]);
      expect(report.warnings.single, contains('no-uuid: '));
    }, skip: skip);

    test('валидное тело гард не трогает и молчит', () {
      final body = <String, dynamic>{
        'type': 'vless',
        'tag': 'ok',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'tls': {'enabled': true, 'server_name': 'example.com'},
      };
      final entry = Outbound(Map<String, dynamic>.from(body));
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.warnings, isEmpty);
      expect(report.dropped, isEmpty);
      expect(entry.map, body);
    }, skip: skip);

    test('реестр не загружен — гард no-op', () {
      // Отдельного способа «выгрузить» реестр нет и заводить его незачем:
      // ветку проверяем на типе, схемы которого в реестре нет, — путь тот же
      // (schemaFor == null → тело как есть).
      final entry = Outbound(<String, dynamic>{
        'type': 'shadowtls',
        'tag': 'foreign',
        'server': 'example.com',
        'whatever': 1,
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.warnings, isEmpty);
      expect(entry.map['whatever'], 1);
    }, skip: skip);
  });

  group('эталоны при загруженном реестре', () {
    for (final name in kStorageFixtures) {
      test('$name: config.json не изменился', () async {
        final box = await StorageSandbox.create();
        addTearDown(box.dispose);
        await box.seed(name);

        final built = await buildGoldenConfig(box);
        // Тот же эталон, что сверяет storage_migration/golden_config_test —
        // гард обязан быть прозрачен для валидного конфига.
        expectGolden('$name.config.json', built.configJson);
        expectGolden('$name.config_warnings.json', prettyJson(built.warnings));
      }, skip: skip);
    }
  });
}
