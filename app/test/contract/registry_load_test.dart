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

    test('реестр 1.1.46 грузится', () {
      expect(ContractRegistry.I.isLoaded, isTrue);
      expect(ContractRegistry.I.version, '1.1.46');
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

      // Поля-ссылки остаются ссылками — санитайзер спускается в них сам.
      expect(schema.fields['tls']!.ref, 'tls');
      expect(schema.fields['transport']!.ref, 'transports');
      expect(schema.fields['multiplex']!.ref, 'multiplex');

      // `__dialer` влился плоско: слота в порядке нет, а поля dialer есть,
      // причём ровно на его месте — в хвосте, как в структуре ядра.
      expect(schema.order, isNot(contains('__dialer')));
      expect(schema.order, contains('bind_interface'));
      expect(schema.order, contains('connect_timeout'));
      expect(schema.order.indexOf('bind_interface'),
          greaterThan(schema.order.indexOf('transport')));

      // Скаляры dialer.common доступны по своим именам.
      expect(schema.fields['server']!.ref, 'dialer.common');
      expect(schema.fields['server_port']!.ref, 'dialer.common');
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

    test('каждый файл protocols/ прочитан — состав списка не разошёлся', () {
      // Список файлов в registry.dart перечислен поимённо (rootBundle каталог
      // не листает). Бамп контракта, добавивший протокол, обязан попасть и
      // туда — иначе схема новой записи молча не нашлась бы.
      final onDisk = Directory('$kRegistryRoot/registry/protocols')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
      var loaded = 0;
      for (final type in const [
        'anytls', 'chain', 'http', 'hysteria', 'hysteria2', 'masque', 'naive',
        'shadowsocks', 'socks', 'ssh', 'tailscale', 'trojan', 'tuic', 'vless',
        'vmess', 'wireguard',
      ]) {
        if (ContractRegistry.I.schemaFor(type) != null) loaded++;
      }
      // group.json схемы тела не несёт (selector|urltest) — отсюда −1.
      expect(loaded, onDisk - 1,
          reason: 'список _kProtocolFiles разошёлся с registry/protocols/');
    });

    test('зеркало assets совпадает с копией контракта', () async {
      // Тесты грузят реестр из зеркала. Сверка файл-в-файл — в
      // check_contract_lock; здесь при наличии вендоренной копии сверяем
      // версию с ней. Без копии (CI, чистый worktree) кейс не скипается:
      // зеркало уже проверено тестами выше.
      expect(ContractRegistry.I.version, '1.1.46');
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
