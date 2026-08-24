import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/hysteria2_obfs.dart';
import 'package:lxbox/services/parser/utls_fingerprint.dart';

// Sync-тесты реестра контракта (SPEC 103, фаза 2), сторона LxBox.
// Парные к core/config/subscription/registry_sync_test.go.
//
// Реестр объявлен нормативным источником словарей (D-020), но нормативность
// без проверки — просто текст: словарь в коде уезжает, реестр остаётся, и обе
// стороны расходятся молча. На Go-стороне такой тест сразу нашёл gecko,
// который добавили в парсер, но забыли внести в allowlists.json.

const _contractRoot = 'contract';

Map<String, dynamic>? _loadAllowlists() {
  final file = File('$_contractRoot/registry/allowlists.json');
  if (!file.existsSync()) return null; // контракт не синхронизирован
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (data['allowlists'] as Map).cast<String, dynamic>();
}

List<String> _values(Map<String, dynamic> allowlists, String name) {
  final entry = allowlists[name];
  expect(entry, isNotNull, reason: 'в реестре нет списка "$name"');
  return ((entry as Map)['values'] as List).cast<String>();
}

void _checkAllowlist(String name, Set<String> code, Map<String, dynamic> reg) {
  final registry = _values(reg, name).toSet();
  final missingInRegistry = code.difference(registry).toList()..sort();
  final missingInCode = registry.difference(code).toList()..sort();

  expect(missingInRegistry, isEmpty,
      reason: '$name: код принимает значения, которых нет в реестре — '
          'реестр нормативен (D-020): либо внести, либо убрать из кода');
  expect(missingInCode, isEmpty,
      reason: '$name: реестр объявляет значения, которых код не принимает');
}

void main() {
  final allowlists = _loadAllowlists();
  if (allowlists == null) return;

  group('contract registry sync', () {
    // uTLS: чужой отпечаток валит ВЕСЬ конфиг, словарь обязан совпадать.
    test('utls_fingerprints', () {
      _checkAllowlist('utls_fingerprints', kUtlsFingerprints, allowlists);
    });

    test('hysteria2_obfs', () {
      _checkAllowlist('hysteria2_obfs', kHysteria2ObfsTypes, allowlists);
    });

    // Значение вне словаря обязано отвергаться — иначе allowlist декоративен.
    test('значения вне словаря отвергаются', () {
      expect(kHysteria2ObfsTypes.contains('nonsense'), isFalse);
      expect(normalizeUtlsFingerprintValue('garbage').junk, isTrue);
    });
  });
}
