/// §704 §5 п.2 — автодополнение поля Target по курсору.
///
/// Источник — конфиг, который миксин увидит ([mixinPreviewBase]). Набор
/// зависит от позиции курсора:
/// - начало строки или после `.` — ключи объекта на этом уровне; ключ,
///   набранный целиком, дополняется `[` (список) или `.` (объект); у
///   уровня-списка — индексы;
/// - после `[` — поля элементов списка (объединение по всем элементам,
///   только скаляры и списки скаляров) и индексы;
/// - после `=` — значения этого поля у элементов, уникальные, в порядке
///   появления;
/// - после `,` в скобках — поля, кроме уже использованных;
/// - после `]` — `.`.
///
/// Префикс до курсора, который не разбирается, подсказок не даёт.
library;

import 'mixin_path.dart';

/// Подсказки и место подстановки: [items] заменяют `text[replaceStart,
/// cursor)`.
class MixinPathSuggestions {
  final int replaceStart;
  final List<String> items;
  const MixinPathSuggestions(this.replaceStart, this.items);

  static const none = MixinPathSuggestions(0, []);
}

/// Только строки подсказок (см. [suggestMixinPathAt]).
List<String> suggestMixinPath(String text, int cursor, Map config) =>
    suggestMixinPathAt(text, cursor, config).items;

/// Подставить подсказку [item]: новый текст и позиция курсора за ней.
(String, int) applyMixinPathSuggestion(
    String text, int cursor, MixinPathSuggestions s, String item) {
  final c = cursor.clamp(0, text.length);
  final start = s.replaceStart.clamp(0, c);
  final next = text.substring(0, start) + item + text.substring(c);
  return (next, start + item.length);
}

MixinPathSuggestions suggestMixinPathAt(String text, int cursor, Map config) {
  final c = cursor.clamp(0, text.length);
  final prefix = text.substring(0, c);
  if (prefix.startsWith(r'$')) return MixinPathSuggestions.none;
  final open = prefix.lastIndexOf('[');
  final close = prefix.lastIndexOf(']');
  if (open > close) return _inBrackets(prefix, open, config);
  if (prefix.endsWith(']')) return MixinPathSuggestions(c, const ['.']);
  return _keys(prefix, config);
}

/// Узлы пути [path] (пусто — корень); не разбирается — `null`.
List<Object?>? _nodes(String path, Map config) {
  final parsed = parseMixinPath(path);
  if (parsed is! MixinPath) return null;
  return [for (final m in parsed.resolve(config)) m.value];
}

/// Отбор по набранному фрагменту без учёта регистра: сначала начинающиеся
/// с него, затем содержащие.
List<String> _filter(Iterable<String> all, String typed) {
  final t = typed.toLowerCase();
  final starts = <String>[];
  final contains = <String>[];
  for (final s in all) {
    final l = s.toLowerCase();
    if (l.startsWith(t)) {
      starts.add(s);
    } else if (l.contains(t)) {
      contains.add(s);
    }
  }
  return [...starts, ...contains];
}

MixinPathSuggestions _keys(String prefix, Map config) {
  final dot = prefix.lastIndexOf('.');
  final parentPath = dot < 0 ? '' : prefix.substring(0, dot);
  final typed = prefix.substring(dot + 1);
  final start = dot + 1;
  final nodes = _nodes(parentPath, config);
  if (nodes == null) return MixinPathSuggestions.none;
  final keys = <String>{};
  final kinds = <String, Object?>{};
  var maxLen = 0;
  for (final n in nodes) {
    if (n is Map) {
      for (final e in n.entries) {
        final k = e.key.toString();
        keys.add(k);
        kinds.putIfAbsent(k, () => e.value);
      }
    } else if (n is List && n.length > maxLen) {
      maxLen = n.length;
    }
  }
  final out = <String>[
    ..._filter(keys, typed),
    ..._filter([for (var i = 0; i < maxLen; i++) '$i'], typed),
  ];
  // Ключ набран целиком: следующий шаг — скобка у списка, точка у объекта.
  if (keys.contains(typed)) {
    final v = kinds[typed];
    if (v is List) out.add('$typed[');
    if (v is Map) out.add('$typed.');
  }
  return MixinPathSuggestions(start, out);
}

/// Скаляр или список скаляров.
bool _scalarish(Object? v) =>
    v is String ||
    v is num ||
    v is bool ||
    (v is List && v.every((x) => x is String || x is num || x is bool));

MixinPathSuggestions _inBrackets(String prefix, int open, Map config) {
  final listPath = prefix.substring(0, open);
  final nodes = _nodes(listPath, config);
  if (nodes == null) return MixinPathSuggestions.none;
  final elements = <Object?>[
    for (final n in nodes)
      if (n is List) ...n,
  ];
  final inner = prefix.substring(open + 1);
  final comma = inner.lastIndexOf(',');
  final current = inner.substring(comma + 1);
  final fragStart = open + 1 + comma + 1;
  final usedFields = <String>{
    for (final c in (comma < 0 ? '' : inner.substring(0, comma)).split(','))
      if (c.contains('=')) c.substring(0, c.indexOf('=')).trim(),
  };

  final eq = current.indexOf('=');
  if (eq >= 0) {
    // Значения поля.
    final field = current.substring(0, eq).trim().split('.');
    final typedRaw = current.substring(eq + 1);
    final typed = typedRaw.trimLeft();
    final values = <String>{};
    for (final el in elements) {
      final v = _at(el, field);
      for (final s in (v is List ? v : [v])) {
        if (s is String || s is num || s is bool) {
          final t = s.toString();
          // Запятая и `]` в значении в v1 не выражаются.
          if (!t.contains(',') && !t.contains(']')) values.add(t);
        }
      }
    }
    final start = fragStart + eq + 1 + (typedRaw.length - typed.length);
    return MixinPathSuggestions(start, _filter(values, typed));
  }

  // Поля (с вложенным путём через точку) и индексы.
  final lead = current.length - current.trimLeft().length;
  final typedField = current.trimLeft();
  final fdot = typedField.lastIndexOf('.');
  final base = fdot < 0 ? <String>[] : typedField.substring(0, fdot).split('.');
  final typed = typedField.substring(fdot + 1);
  final fields = <String>{};
  for (final el in elements) {
    final obj = base.isEmpty ? el : _at(el, base);
    if (obj is! Map) continue;
    for (final e in obj.entries) {
      final k = e.key.toString();
      final full = [...base, k].join('.');
      if (usedFields.contains(full)) continue;
      if (_scalarish(e.value)) {
        fields.add(k);
      } else if (e.value is Map) {
        fields.add('$k.');
      }
    }
  }
  final out = <String>[
    for (final f in _filter(fields, typed)) f.endsWith('.') ? f : '$f=',
  ];
  if (comma < 0 && base.isEmpty) {
    out.addAll(_filter(
        [for (var i = 0; i < elements.length; i++) '$i]'], typed));
  }
  return MixinPathSuggestions(
      fragStart + lead + (fdot < 0 ? 0 : fdot + 1), out);
}

Object? _at(Object? el, List<String> path) {
  Object? cur = el;
  for (final p in path) {
    if (cur is Map && cur.containsKey(p)) {
      cur = cur[p];
    } else {
      return null;
    }
  }
  return cur;
}
