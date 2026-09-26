/// §56/§60 (контракт 1.1.60) — подпись уровня протокола узла по реестру.
///
/// Тело протокола объявляет `levels` (по возрастанию), поле — `level` и
/// `level_mark`, форма-диапазон `awg_range` — `range_form.level`. Подпись =
/// старший уровень заданных полей и их форм-диапазонов плюс суффиксы
/// `level_mark` заданных полей. Имён протоколов и полей здесь нет: что и на
/// каком уровне — данные реестра.
library;

import 'registry.dart';

/// Значение формы-диапазона `N-M` (строка с дефисом между числами).
final _reRange = RegExp(r'^\s*\d+\s*-\s*\d+\s*$');

/// Подпись уровня тела [raw] протокола [singboxType]: `awg2`, `awg1.5+`.
/// `null` — у схемы нет `levels` (реестр не загружен, протокол без уровней)
/// или ни одно заданное поле уровня не несёт.
String? protocolLevelByRegistry(String singboxType, Map<String, dynamic> raw) {
  final schema = ContractRegistry.I.schemaFor(singboxType);
  if (schema == null || schema.levels.isEmpty) return null;
  final levels = schema.levels;
  var top = -1;
  final marks = <String>[];

  void note(String? level) {
    if (level == null) return;
    final i = levels.indexOf(level);
    if (i > top) top = i;
  }

  void walk(Map<String, dynamic> body, List<String> order,
      Map<String, FieldSchema> fields) {
    for (final key in order) {
      final f = fields[key];
      final v = body[key];
      if (f == null || v == null) continue;
      note(f.level);
      final rangeLevel = f.rangeForm?['level'];
      if (rangeLevel is String && v is String && _reRange.hasMatch(v)) {
        note(rangeLevel);
      }
      final mark = f.levelMark;
      if (mark != null && mark.isNotEmpty && !marks.contains(mark)) {
        marks.add(mark);
      }
      final nested = f.fields;
      if (v is Map && nested != null) {
        walk(v.cast<String, dynamic>(), f.order ?? nested.keys.toList(),
            nested);
      }
      final item = f.items;
      final itemFields = item?.fields;
      if (v is List && itemFields != null) {
        for (final e in v) {
          if (e is Map) {
            walk(e.cast<String, dynamic>(),
                item!.order ?? itemFields.keys.toList(), itemFields);
          }
        }
      }
    }
  }

  walk(raw, schema.order, schema.fields);
  // Суффикс без уровня не бывает: поле с `level_mark` несёт и свой `level`.
  if (top < 0) return null;
  return '${levels[top]}${marks.join()}';
}
