import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/special_node_display.dart';

/// §125 — подмена служебных нод (direct/auto) по ТИПУ из конфига, не по маске.
void main() {
  group('specialNodeDisplayForType', () {
    test('direct → «Direct» + public', () {
      final d = specialNodeDisplayForType('direct');
      expect(d, isNotNull);
      expect(d!.label, 'Direct');
      expect(d.icon, Icons.public);
    });

    test('urltest → «Auto» + auto_awesome (✨)', () {
      final d = specialNodeDisplayForType('urltest');
      expect(d, isNotNull);
      expect(d!.label, 'Auto');
      expect(d.icon, Icons.auto_awesome);
    });

    test('обычная прокси-нода (vless/null/selector) → null (показываем tag)', () {
      expect(specialNodeDisplayForType('vless'), isNull);
      expect(specialNodeDisplayForType('selector'), isNull);
      expect(specialNodeDisplayForType('shadowsocks'), isNull);
      expect(specialNodeDisplayForType(null), isNull);
      expect(specialNodeDisplayForType(''), isNull);
    });

    test('подмена по ТИПУ — auto-двойник с любым tag-именем ловится', () {
      // vpn-1-auto / vpn-7-auto / ✨auto — все type==urltest → одинаково «Auto»
      // (имя тега не важно, важен только type из конфига).
      expect(specialNodeDisplayForType('urltest')!.label, 'Auto');
    });
  });
}
