// Ревью после v2.25.1 (движок), M1 — `item_pattern` судит и нестроковые
// элементы списка.
//
// `item_pattern` стоит у полей, которые ядро читает как `Listable[string]`
// (`tls.alpn`, `hysteria2.server_ports`). Форма `listable_string` пускает
// элементы `String|num`, а цикл `drop_item` судил только строки: число
// уезжало в конфиг, и ядро отвергало ВЕСЬ конфиг ошибкой unmarshal
// (`cannot unmarshal number into … string`), а не один узел. Гейт сборки —
// последний эшелон перед ядром, поэтому проверка здесь.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/services/builder/registry_gate.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import '../parser/engine_test_setup.dart';
import '../storage_migration/golden_harness.dart';

const _core = kGoldenCoreVersion;

List<RegistryWarning> _codes(RegistryGateReport r, String tag) => [
      for (final w in r.warningsByEmittedTag[tag] ?? const <NodeWarning>[])
        if (w is RegistryWarning) w,
    ];

void main() {
  setUpAll(loadEngineSections);

  group('M1 — нестроковый элемент списка с item_pattern', () {
    test('tls.alpn [443, "h2"] → ["h2"] + tls_alpn_item_invalid', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'trojan',
        'tag': 't-json',
        'server': '198.51.100.24',
        'server_port': 443,
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'alpn': [443, 'h2'],
        },
      });

      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(report.dropped, isEmpty, reason: 'узел остаётся в конфиге');
      expect((entry.map['tls'] as Map)['alpn'], ['h2']);
      final w = _codes(report, 't-json')
          .where((w) => w.code == 'tls_alpn_item_invalid')
          .toList();
      expect(w, hasLength(1), reason: report.warnings.join('\n'));
      expect(w.single.path, 'tls.alpn[0]');
      expect(w.single.value, '443');
    });

    test('hysteria2 server_ports [443] → поле снято с кодом элемента', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'hysteria2',
        'tag': 'hy2-json',
        'server': '198.51.100.24',
        'server_port': 443,
        'password': 'p',
        'server_ports': [443],
        'tls': {'enabled': true, 'server_name': 'example.com'},
      });

      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(report.dropped, isEmpty);
      expect(entry.map.containsKey('server_ports'), isFalse,
          reason: 'единственный элемент негоден — поле не пишется');
      final w = _codes(report, 'hy2-json')
          .where((w) => w.code == 'hysteria2_server_ports_item_invalid')
          .toList();
      expect(w, hasLength(1), reason: report.warnings.join('\n'));
      expect(w.single.path, 'server_ports[0]');
    });

    test('hysteria2 server_ports [443, "20000:30000"] → годный сосед цел', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'hysteria2',
        'tag': 'hy2-mixed',
        'server': '198.51.100.24',
        'server_port': 443,
        'password': 'p',
        'server_ports': [443, '20000:30000'],
        'tls': {'enabled': true, 'server_name': 'example.com'},
      });

      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(entry.map['server_ports'], ['20000:30000']);
      expect(
        _codes(report, 'hy2-mixed')
            .map((w) => (w.code, w.path))
            .toList(),
        contains(('hysteria2_server_ports_item_invalid', 'server_ports[0]')),
      );
    });

    test('sing-box JSON на вставке: alpn [443, "h2"] — код на узле', () {
      const body = '{"type":"trojan","tag":"t","server":"198.51.100.24",'
          '"server_port":443,"password":"p","tls":{"enabled":true,'
          '"server_name":"example.com","alpn":[443,"h2"]}}';
      final nodes = parseAll(decode(body));
      expect(nodes, hasLength(1));
      final codes = [
        for (final w in nodes.single.warnings)
          if (w is RegistryWarning) (w.code, w.path),
      ];
      expect(codes, contains(('tls_alpn_item_invalid', 'tls.alpn[0]')),
          reason: jsonEncode(codes.map((c) => '${c.$1}@${c.$2}').toList()));
    });

    test('строковые элементы — как прежде (контроль)', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'trojan',
        'tag': 't-ok',
        'server': '198.51.100.24',
        'server_port': 443,
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'alpn': ['h2', 'http/1.1'],
        },
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect((entry.map['tls'] as Map)['alpn'], ['h2', 'http/1.1']);
      expect(_codes(report, 't-ok'), isEmpty);
    });
  });

  // m1 — у hysteria v1 `server_ports` в реестре без `item_pattern` /
  // `on_item_invalid`, и санитайзеру судить элемент нечем: «198.51.100.24:443»
  // уезжает в ядро и роняет конфиг «bad port range». Правка — в реестре
  // лаунчера (запрос отправлен), у нас не чинится: код подгоняется под
  // реестр, а не наоборот. Сторож снимет skip, когда реестр догонит.
  test(
    'm1: hysteria v1 server_ports с адресом снимается кодом элемента',
    () {
      final entry = Outbound(<String, dynamic>{
        'type': 'hysteria',
        'tag': 'hy1',
        'server': '198.51.100.24',
        'server_port': 443,
        'server_ports': ['198.51.100.24:443', '20000:30000'],
        'up_mbps': 10,
        'down_mbps': 50,
        'tls': {'enabled': true, 'server_name': 'example.com'},
      });
      applyRegistryGate([entry], coreVersion: _core);
      expect(entry.map['server_ports'], ['20000:30000']);
    },
    skip: 'm1 (§510): реестр лаунчера — protocols/hysteria.json '
        'server_ports без item_pattern/on_item_invalid; запрос лаунчеру '
        'отправлен, у нас не чиним',
  );
}
