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
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/registry.dart';

const _contractRoot = 'contract';

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();

  group('ContractRegistry', () {
    setUpAll(() async {
      if (!synced) return;
      await ContractRegistry.I.loadFromDirectory(_contractRoot);
    });

    test('реестр 1.1.9 грузится', () {
      expect(ContractRegistry.I.isLoaded, isTrue);
      expect(ContractRegistry.I.version, '1.1.9');
    }, skip: synced ? null : 'контракт не синхронизирован');

    // §468 (контракт 1.1.2) — severity кода живёт в реестре, а рукописный
    // класс обязан её оттуда читать: владелец понизил `reality_fp_not_chrome`
    // до `info`, и зашитая в классе копия разошлась бы с нормой.
    test('severity reality_fp_not_chrome — info из реестра', () {
      expect(ContractRegistry.I.textFor('reality_fp_not_chrome')?.severity,
          'info');
      expect(const RealityFingerprintWarning('edge').severity,
          WarningSeverity.info);
    }, skip: synced ? null : 'контракт не синхронизирован');

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
    }, skip: synced ? null : 'контракт не синхронизирован');

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
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('суб-схема tls раскрывается по ref', () {
      final tls = ContractRegistry.I.sharedSchema('tls');
      expect(tls, isNotNull);
      expect(tls!.order.first, 'enabled');
      expect(tls.fields['reality']!.fields!['key_share'], isNotNull);
      // naive-запреты — атрибут поля, а не отдельная таблица.
      expect(tls.fields['alpn']!.forbiddenFor, contains('naive'));
      expect(tls.fields['alpn']!.code, 'tls_field_unsupported_naive');
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('warnings.json даёт title_ru / text_en для unknown_key', () {
      final w = ContractRegistry.I.textFor('unknown_key');
      expect(w, isNotNull);
      expect(w!.severity, 'warning');
      expect(w.titleRu, isNotEmpty);
      expect(w.textEn, contains('{path}'));
      // path/value подставляются всегда (text_params_implicit).
      expect(w.params, contains('path'));
      expect(w.params, contains('value'));
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('каждый файл protocols/ прочитан — состав списка не разошёлся', () {
      // Список файлов в registry.dart перечислен поимённо (rootBundle каталог
      // не листает). Бамп контракта, добавивший протокол, обязан попасть и
      // туда — иначе схема новой записи молча не нашлась бы.
      final onDisk = Directory('$_contractRoot/registry/protocols')
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
    }, skip: synced ? null : 'контракт не синхронизирован');

    test('зеркало assets совпадает с копией контракта', () async {
      // Приложение грузит реестр из assets/contract — если зеркало отстало,
      // санитайзер в APK работал бы по другой схеме, чем тесты.
      final mirror = ContractRegistry.I;
      await mirror.loadFromDirectory('assets/contract');
      expect(mirror.version, '1.1.9');
      expect(mirror.schemaFor('vless'), isNotNull);
      // Вернуть загрузку с копии — остальные тесты файла уже отработали, но
      // порядок в группе не нормирован.
      await mirror.loadFromDirectory(_contractRoot);
    }, skip: synced ? null : 'контракт не синхронизирован');
  });
}
