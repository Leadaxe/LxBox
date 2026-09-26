// §460 W1 — загрузка реестра контракта и раскрытие ссылок схемы.
//
// Реестр — не просто файлы в assets: по нему работает санитайзер сборки, и
// если ссылка (`ref`) развернулась не туда, гард молча перестал бы видеть
// половину полей. Поэтому проверяется именно раскрытие: tls, transports по
// дискриминатору и dialer, вливающийся плоско.
//
// Грузим с диска (`loadFromDirectory`) — та же копия, что сверяет
// check_contract_lock, и биндинг Flutter не нужен.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/registry.dart';


void main() {
  group('ContractRegistry', () {
    setUpAll(loadTestRegistry);

    // Версия — из VERSION зеркала, литерал устаревал бы на каждом бампе.
    final assetsVersion =
        File('assets/contract/VERSION').readAsStringSync().trim();

    test('реестр грузится с версией из VERSION', () {
      expect(ContractRegistry.I.isLoaded, isTrue);
      expect(ContractRegistry.I.version, assetsVersion);
    });

    // §468 (контракт 1.1.2) — severity кода живёт в реестре, а рукописный
    // класс обязан её оттуда читать: владелец понизил `reality_fp_not_chrome`
    // до `info`, и зашитая в классе копия разошлась бы с нормой.
    test('severity reality_fp_not_chrome — info из реестра', () {
      expect(ContractRegistry.I.textFor('reality_fp_not_chrome')?.severity,
          'info');
      expect(const RealityFingerprintWarning('edge').severity,
          WarningSeverity.info);
    });

    test('схема vless раскрывает tls / transports / dialer', () {
      final schema = ContractRegistry.I.schemaFor('vless');
      expect(schema, isNotNull, reason: 'у vless обязана быть секция body');
      expect(schema!.core, '1.14.1-lx.4');

      // §553 — ссылки развёрнуты в поля-объекты с вложенной схемой и
      // пометкой происхождения; транспорт — с вариантами по `type`.
      final tls = schema.fields['tls']!;
      expect(tls.type, 'object');
      expect(tls.originRef, 'tls');
      expect(tls.order!.first, 'enabled');
      expect(tls.fields!['reality']!.fields!['public_key'], isNotNull);
      // `absent_when` секции переехал в поле.
      expect(tls.absentWhen, {'enabled': false});
      final transport = schema.fields['transport']!;
      expect(transport.originRef, 'transports');
      expect(transport.discriminator, 'type');
      expect(transport.variants!['ws']!.fields!['path'], isNotNull);
      expect(transport.variants!['xhttp']!.order, contains('mode'));
      expect(schema.fields['multiplex']!.originRef, 'multiplex');
      expect(schema.fields['multiplex']!.fields, isNotEmpty);

      // `__dialer` влился плоско: слота в порядке нет, а поля dialer есть,
      // причём ровно на его месте — в хвосте, как в структуре ядра.
      expect(schema.order, isNot(contains('__dialer')));
      expect(schema.order, contains('bind_interface'));
      expect(schema.order, contains('connect_timeout'));
      expect(schema.order.indexOf('bind_interface'),
          greaterThan(schema.order.indexOf('transport')));

      // Скаляры dialer.common развёрнуты в поля суб-схемы (§553).
      expect(schema.fields['server']!.originRef, 'dialer.common');
      expect(schema.fields['server_port']!.originRef, 'dialer.common');
    });

    // §553 — ссылки развёрнуты при загрузке, как у лаунчера (`registry.go`,
    // `resolveSection`): читатель схемы не видит обёрток `type: ref`.
    // Не разрешённая ссылка при загрузке остаётся обёрткой — здесь она и
    // ловится.
    test('§553 каждая ссылка бандла разрешена', () {
      final unresolved = <String>[];
      void walk(Map<String, FieldSchema>? fields, String prefix) {
        if (fields == null) return;
        for (final e in fields.entries) {
          final path = '$prefix.${e.key}';
          if (e.value.type == 'ref') {
            unresolved.add('$path → ${e.value.ref}');
          }
          walk(e.value.fields, path);
          for (final v in (e.value.variants ?? const {}).entries) {
            walk(v.value.fields, '$path.${v.key}');
          }
        }
      }

      for (final type in ContractRegistry.I.protocolNames) {
        walk(ContractRegistry.I.schemaFor(type)?.fields, type);
      }
      expect(unresolved, isEmpty);
    });

    test('§553 именованная ссылка несёт правило суб-схемы', () {
      for (final type in ContractRegistry.I.protocolNames) {
        final server = ContractRegistry.I.schemaFor(type)?.fields['server'];
        if (server == null) continue;
        expect(server.required, isTrue, reason: '$type.server');
        expect(server.onInvalid?['action'], 'drop_node',
            reason: '$type.server');
        expect(server.format, 'host', reason: '$type.server');
      }
      // masque.network_list → dialer.common.network: правило сетевое, имя
      // поля своё, описание — обёртки.
      final nl =
          ContractRegistry.I.schemaFor('masque')!.fields['network_list']!;
      expect(nl.originRef, 'dialer.common');
      expect(nl.type, 'listable_string');
      expect(nl.values, containsAll(['tcp', 'udp']));
      expect(nl.normalize, 'trim_lower');
      expect(nl.onInvalid?['code'], 'type_invalid');
      expect(nl.raw['impl'], contains('masque'));
    });

    test('§553 обёртка ужесточает required объектной ссылки', () {
      // У суб-схемы tls обязательности нет, у hysteria2 её задаёт обёртка.
      final h2 = ContractRegistry.I.schemaFor('hysteria2')!.fields['tls']!;
      expect(h2.required, isTrue);
      expect(h2.originRef, 'tls');
      final vless = ContractRegistry.I.schemaFor('vless')!.fields['tls']!;
      expect(vless.required, isFalse);
    });

    test('транспорт выбирается по дискриминатору transport.type', () {
      final ws = ContractRegistry.I.transportVariant('ws');
      expect(ws, isNotNull);
      expect(ws!.order, contains('max_early_data'));
      expect(ws.fields['path'], isNotNull);

      final xhttp = ContractRegistry.I.transportVariant('xhttp');
      expect(xhttp!.fields['xmux']!.allOrNothing, isTrue);
      expect(xhttp.fields['mode']!.values, contains('stream-one'));

      // Неизвестный тип транспорта схемы не даёт — санитайзер снимет поле.
      expect(ContractRegistry.I.transportVariant('kcp'), isNull);
    });

    test('суб-схема tls раскрывается по ref', () {
      final tls = ContractRegistry.I.sharedSchema('tls');
      expect(tls, isNotNull);
      expect(tls!.order.first, 'enabled');
      expect(tls.fields['reality']!.fields!['key_share'], isNotNull);
      // naive-запреты — атрибут поля, а не отдельная таблица.
      expect(tls.fields['alpn']!.forbiddenFor, contains('naive'));
      expect(tls.fields['alpn']!.code, 'tls_field_unsupported_naive');
    });

    test('warnings.json даёт title_ru / text_en для unknown_key', () {
      final w = ContractRegistry.I.textFor('unknown_key');
      expect(w, isNotNull);
      expect(w!.severity, 'warning');
      expect(w.titleRu, isNotEmpty);
      expect(w.textEn, contains('{path}'));
      // path/value подставляются всегда (text_params_implicit).
      expect(w.params, contains('path'));
      expect(w.params, contains('value'));
    });

    test('§566 каждый файл protocols/ прочитан — состав из каталога', () {
      // Состав протоколов берётся листингом каталога (на диске) или
      // манифестом ассетов (бандл), а не списком в коде: протокол, приехавший
      // бампом контракта, обязан загрузиться без правки Dart.
      final onDisk = Directory('$kRegistryRoot/registry/protocols')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
      // Ключ записи — `singbox_type`, у всех файлов он свой.
      expect(ContractRegistry.I.protocolNames.length, onDisk);
    });

    test('§566 load() берёт состав protocols/ из манифеста', () async {
      // Манифест бандла подменяется листингом зеркала: ровно то, что прод
      // получил бы от `AssetManifest`, плюс посторонний путь, который в
      // состав попадать не должен.
      const root = 'assets/contract';
      final paths = [
        for (final f in Directory('$root/registry/protocols')
            .listSync()
            .whereType<File>())
          '$root/registry/protocols/${f.uri.pathSegments.last}',
        '$root/registry/tls.json',
      ];
      final before = ContractRegistry.I.protocolNames.toSet();
      ContractRegistry.I.resetForTesting();
      await ContractRegistry.I.load(
        loader: (p) => File(p).readAsString(),
        lister: () async => paths,
      );
      expect(ContractRegistry.I.protocolNames.toSet(), before);
    });

    test('зеркало assets совпадает с копией контракта', () async {
      // Тесты грузят реестр из зеркала. Сверка файл-в-файл — в
      // check_contract_lock; здесь при наличии вендоренной копии сверяем
      // версию с ней. Без копии (CI, чистый worktree) кейс не скипается:
      // зеркало уже проверено тестами выше.
      expect(ContractRegistry.I.version, assetsVersion);
      expect(ContractRegistry.I.schemaFor('vless'), isNotNull);
      if (!hasVendorContract) return;
      final mirrorVersion = ContractRegistry.I.version;
      final mirrorVless = ContractRegistry.I.schemaFor('vless');
      await ContractRegistry.I.loadFromDirectory(kVendorRoot);
      expect(ContractRegistry.I.version, mirrorVersion);
      final reloaded = ContractRegistry.I.schemaFor('vless');
      // BodySchema без operator== — после сброса кэша это другой экземпляр.
      expect(reloaded?.core, mirrorVless?.core);
      expect(reloaded?.order, mirrorVless?.order);
      expect(reloaded?.fields.keys, mirrorVless?.fields.keys);
    });
  });
}
