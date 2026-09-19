import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/parser/engine/engine_mapper.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';

import 'engine_test_setup.dart';

/// §480 — ВХОД доезжает до санитайзера: `body_source` секции, а не заглушка.
///
/// Единственное место контракта, где вход влияет на РЕЗУЛЬТАТ, а не только на
/// разбор, — `max_when.except_sources` (§473). До этой правки конвейер
/// передавал туда `other` на всех входах, кроме sing-box-JSON: правило
/// работало вслепую, и стоило реестру перечислить в исключениях `uri` или
/// `wgconf`, как тела у нас и у лаунчера разошлись бы МОЛЧА — без красного
/// теста и без кода.
void main() {
  setUpAll(loadEngineSections);

  test('секция объявляет body_source, и он доезжает до маппинга', () {
    final section = MapperSections.I.sectionFor('uri', 'trojan');
    expect(section, isNotNull);
    expect(section!.bodySource, 'uri',
        reason: 'секция обязана называть свой вид источника');

    final mapping =
        mapViaEngine('trojan://pw@example.com:443?security=tls#n', 'trojan')!;
    expect(mapping.bodySource, BodySource.uri,
        reason: 'вход из секции обязан доехать до конвейера — именно его '
            'конвейер передаёт санитайзеру');
  });

  group('BodySource.byRegistryName — словарь sources реестра', () {
    const cases = <String, BodySource>{
      'uri': BodySource.uri,
      'singbox': BodySource.singbox,
      'xray': BodySource.xray,
      'wgconf': BodySource.wgconf,
      'amnezia': BodySource.amnezia,
    };
    cases.forEach((name, want) {
      test('«$name» → $want', () {
        expect(BodySource.byRegistryName(name), want);
      });
    });

    // Реестр вправе уехать вперёд кода (24.1): новый вид источника обязан
    // вести себя как «вход себя не назвал», а не ронять разбор.
    test('незнакомое имя — other, без падения', () {
      expect(BodySource.byRegistryName('clash'), BodySource.other);
      expect(BodySource.byRegistryName(''), BodySource.other);
      expect(BodySource.byRegistryName(null), BodySource.other);
    });
  });

  test('расширение набора не трогает правило except_sources', () {
    // Сравнение идёт по имени из реестра, поэтому новые значения под список
    // `["singbox"]` не подпадают — ровно как не подпадал `other`.
    const except = ['singbox'];
    expect(except.contains(BodySource.uri.registryName), isFalse);
    expect(except.contains(BodySource.wgconf.registryName), isFalse);
    expect(except.contains(BodySource.other.registryName), isFalse);
    expect(except.contains(BodySource.singbox.registryName), isTrue);
  });
}
