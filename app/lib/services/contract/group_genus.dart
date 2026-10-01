/// §565 — род группы-узла (PARSING_PRINCIPLES §5, `registry/protocols/group.json`
/// → `genus`).
///
/// Род — это сам `entry.type` группы: ручной выбор члена (`default`) или
/// автовыбор по замерам. Отдельного имени рода нет, значения и их роли
/// читаются из реестра:
///
/// - `genus.values` — допустимые значения;
/// - `genus.by_source` — во что разрешается род у вида источника
///   (`$as_is` — источник несёт тип сам).
///
/// Роли значений выводятся из той же таблицы: род синтетической группы
/// приложения (`by_source.uri`, `autogroup://`) — автовыбор, он же род групп,
/// которые LxBox собирает сам; оставшееся значение `values` — ручной выбор.
///
/// Пока реестр не загружен (юнит-тесты сборки без контракта, ранний старт),
/// действует зеркало [kGenusFallbackValues] / [kGenusFallbackAuto]; сверку
/// зеркала с реестром держит `group_genus_test`.
library;

import 'registry.dart';

/// Зеркало `genus.values` на случай незагруженного реестра.
const List<String> kGenusFallbackValues = ['selector', 'urltest'];

/// Зеркало `genus.by_source.uri` на случай незагруженного реестра.
const String kGenusFallbackAuto = 'urltest';

/// Маркер `by_source`: вид источника несёт род собой.
const String kGenusAsIs = r'$as_is';

/// Виды источника в `genus.by_source`.
const String kGenusSourceSingbox = 'singbox';
const String kGenusSourceXray = 'xray';
const String kGenusSourceUri = 'uri';

abstract final class GroupGenus {
  static int _gen = -1;
  static Map<String, dynamic>? _cached;

  /// Таблица `genus`; кэш живёт до перезагрузки реестра.
  static Map<String, dynamic>? _table() {
    final reg = ContractRegistry.I;
    if (reg.generation == _gen) return _cached;
    _gen = reg.generation;
    return _cached = _scan(reg);
  }

  static Map<String, dynamic>? _scan(ContractRegistry reg) {
    for (final name in reg.protocolNames) {
      final p = reg.rawProtocol(name);
      if (p?['kind'] == 'group' && p?['genus'] is Map) {
        return (p!['genus'] as Map).cast<String, dynamic>();
      }
    }
    return null;
  }

  /// Допустимые значения рода.
  static List<String> get values {
    final v = _table()?['values'];
    return v is List && v.isNotEmpty
        ? [for (final e in v) '$e']
        : kGenusFallbackValues;
  }

  /// Во что разрешается род у вида [source]; `null` — источник несёт род
  /// сам (`$as_is`) или вид не объявлен.
  static String? forSource(String source) {
    final by = _table()?['by_source'];
    if (by is! Map) {
      return source == kGenusSourceSingbox ? null : kGenusFallbackAuto;
    }
    final v = by[source];
    if (v is! String || v == kGenusAsIs) return null;
    return v;
  }

  /// Род автовыбора — род синтетической группы приложения.
  static String get auto => forSource(kGenusSourceUri) ?? kGenusFallbackAuto;

  /// Род ручного выбора — значение `values`, отличное от [auto].
  static String get manual =>
      values.firstWhere((v) => v != auto, orElse: () => auto);

  /// Известен ли род [value].
  static bool isKnown(String value) => values.contains(value);

  /// Род из `entry.type` источника вида [source]: объявленный `by_source`,
  /// иначе сам тип, если он в `values`; `null` — тип родом не является.
  static String? resolve(String source, String type) {
    final fixed = forSource(source);
    if (fixed != null) return fixed;
    return isKnown(type) ? type : null;
  }
}
