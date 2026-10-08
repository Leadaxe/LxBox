// §616 (контракт 1.1.114, PARSING_PRINCIPLES §6.3) — сравнение «до/после» у
// авторского тела: числа по величине при любом типе, объекты и массивы
// вглубь, строка и число — разные. Info-код без изменения значения по пути
// идёт без `applied: false`, особых кодов (прежде `awg_mtu_high`) нет.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/body_edit.dart';

import '../parser/engine_test_setup.dart';

void main() {
  group('sameJsonValue', () {
    test('int и double с равным значением — одно значение', () {
      expect(sameJsonValue(1420, 1420.0), isTrue);
      expect(sameJsonValue(1420.0, 1420), isTrue);
      expect(sameJsonValue(0, -0.0), isTrue);
    });

    test('разные величины и строка против числа — разные', () {
      expect(sameJsonValue(1420, 1280), isFalse);
      expect(sameJsonValue(1420, 1420.5), isFalse);
      expect(sameJsonValue('1420', 1420), isFalse);
      expect(sameJsonValue(1420, '1420'), isFalse);
      expect(sameJsonValue(null, 0), isFalse);
    });

    test('объекты и массивы — вглубь, числа внутри по величине', () {
      expect(
        sameJsonValue({
          'a': [1, 2.0, {'b': 3}],
        }, {
          'a': [1.0, 2, {'b': 3.0}],
        }),
        isTrue,
      );
      expect(sameJsonValue([1, 2], [1, 2, 3]), isFalse);
      expect(sameJsonValue({'a': 1}, {'a': '1'}), isFalse);
      expect(sameJsonValue({'a': 1}, {'b': 1}), isFalse);
    });
  });

  group('applyRegistryEdits: info-код авторского тела', () {
    setUpAll(loadEngineSections);
    tearDownAll(unloadEngineSections);

    List<RegistryWarning> run(Object rawMtu, Object cleanMtu) {
      final body = <String, dynamic>{'type': 'wireguard', 'mtu': rawMtu};
      final edited = <String, dynamic>{'type': 'wireguard', 'mtu': cleanMtu};
      return applyRegistryEdits(
        body,
        scheme: 'wireguard',
        authored: true,
        edited: edited,
        warnings: const [RegistryWarning(code: 'awg_mtu_high', path: 'mtu')],
      );
    }

    test('mtu 1420 против 1420.0 — без applied:false', () {
      final ws = run(1420, 1420.0);
      expect(ws.single.code, 'awg_mtu_high');
      expect(ws.single.applied, isTrue);
    });

    test('значение по пути изменилось — applied:false', () {
      expect(run(1420, 1280).single.applied, isFalse);
      expect(run('1420', 1420).single.applied, isFalse);
    });
  });
}
