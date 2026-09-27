/// §577 (контракт 1.1.87, PARSING_PRINCIPLES §10) — единственная точка
/// правки тела узла по правилу реестра.
///
/// Решение владельца 27.09.2026: на авторском теле реестр сообщает, но
/// ничего не меняет. Тело авторское, когда выполнены четыре условия §576
/// (свой сервер или член папки; не группа автовыбора; вид источника ровно
/// `singbox_outbound`; текст — JSON-объект); у записи сборки это
/// [SingboxEntry.authored], при разборе — `parsingAuthoredBody`.
///
/// | Тело       | Правило мягкое                          | Правило жёсткое     |
/// |------------|-----------------------------------------|---------------------|
/// | обычное    | правка, код                             | правка, код         |
/// | авторское  | тело не меняется, код с `applied:false` | правка, код         |
///
/// Жёсткие правила: запись без строкового непустого `type`; узловой гейт
/// ядра (`drop_node` по `build_tag`/`min_core`); правило или связь реестра с
/// `core_rejects: true` (нарушение роняет старт всего конфига).
///
/// Шаги сборки, меняющие тело по реестру (гард реестра, уступка `detour`,
/// страховки uTLS и REALITY), правят тело только отсюда: прямая запись в
/// карту тела в них запрещена (`test/builder/body_edit_point_test.dart`).
library;

import '../../models/node_warning.dart';
import 'body_sanitizer.dart';
import 'registry.dart';

/// Жёсткое ли правило, давшее код [code] на пути [path] тела схемы [scheme]:
/// у правила или связи реестра стоит `core_rejects`.
///
/// Путь судится по полям схемы без индексов массивов; у объекта с вариантами
/// (`transport`) поле ищется во всех вариантах. Реестр не загружен — судить
/// нечем, правило считается жёстким (поведение прежнее).
bool ruleCoreRejects(String scheme, String code, String? path) {
  if (!ContractRegistry.I.isLoaded) return true;
  if (code.isEmpty) return false;
  final schema = ContractRegistry.I.schemaFor(scheme);
  if (schema == null) return false;
  for (final rel in schema.relations) {
    if (rel['core_rejects'] != true || rel['code'] != code) continue;
    if (path == null) return true;
    final paths = (rel['paths'] as List?)?.map((e) => '$e') ?? const [];
    if (paths.contains(path)) return true;
  }
  if (path == null || path.isEmpty) return false;
  for (final f in _fieldsAt(schema.fields, _pathParts(path))) {
    if (_fieldRuleCoreRejects(f, code)) return true;
  }
  return false;
}

/// Жёсткое ли правило, давшее запись [w] у схемы [scheme].
bool ruleIsHard(String scheme, RegistryWarning w) {
  if (w.code == 'field_missing' && (w.path == 'type' || w.params['field'] == 'type')) {
    return true;
  }
  return ruleCoreRejects(scheme, w.code, w.path);
}

/// Применять ли правку, о которой говорит [w]. Обычное тело — всегда;
/// авторское — только по жёсткому правилу. Вторая часть — запись с
/// признаком `applied`.
(bool, RegistryWarning) decideBodyEdit(
  String scheme, {
  required bool authored,
  required RegistryWarning w,
}) {
  if (!authored || ruleIsHard(scheme, w)) return (true, w);
  return (false, w.notApplied());
}

/// Перенести в тело [body] правки санитайзера (или иного шага по реестру).
///
/// [edited] — тело после правил, [warnings] — их коды. Обычное тело
/// получает [edited] целиком, НА МЕСТЕ (те же карты уже разошлись по
/// аккумуляторам сборки). Авторское — только пути жёстких кодов и
/// [hardPaths] (тихие правки с `core_rejects`): значение берётся из
/// [edited], нет его там — путь снимается.
///
/// Возвращает коды с признаком `applied`.
List<RegistryWarning> applyRegistryEdits(
  Map<String, dynamic> body, {
  required String scheme,
  required bool authored,
  required Map<String, dynamic> edited,
  required List<RegistryWarning> warnings,
  List<String> hardPaths = const [],
}) {
  if (!authored) {
    if (!identical(body, edited)) {
      body
        ..clear()
        ..addAll(edited);
    }
    return warnings;
  }
  final out = <RegistryWarning>[];
  for (final w in warnings) {
    final (apply, w2) = decideBodyEdit(scheme, authored: true, w: w);
    final path = w.path;
    if (apply && path != null && path.isNotEmpty) {
      _patchFrom(body, edited, path);
    }
    out.add(w2);
  }
  for (final p in hardPaths) {
    _patchFrom(body, edited, p);
  }
  return out;
}

/// Итог санитайзера [res] для тела [raw] через точку правки.
///
/// Обычное тело — [res] как есть. Авторское — [raw] (копия) с правками
/// только жёстких правил; снятие узла остаётся, только если его код жёсткий,
/// иначе тело живёт, а код снятия приходит с `applied: false`.
SanitizeResult settleSanitized(
  String scheme,
  Map<String, dynamic> raw,
  SanitizeResult res, {
  required bool authored,
}) {
  if (!authored) return res;
  final body = _deepCopyMap(raw);
  final dropped = res.body == null;
  var dropHard = false;
  if (dropped && res.dropFrom >= 0 && res.dropFrom < res.warnings.length) {
    dropHard = ruleIsHard(scheme, res.warnings[res.dropFrom]);
  } else if (dropped) {
    dropHard = true;
  }
  final ws = applyRegistryEdits(
    body,
    scheme: scheme,
    authored: true,
    edited: res.body ?? res.partial ?? const {},
    warnings: res.warnings,
    hardPaths: res.hardPaths,
  );
  if (dropped && dropHard) {
    return SanitizeResult(null, ws,
        explicitDropNode: res.explicitDropNode, dropFrom: res.dropFrom);
  }
  return SanitizeResult(body, ws);
}

/// Правка одного пути тела шагом-страховкой сборки (uTLS, REALITY) через
/// точку решения: [code] — код реестра, чьё правило описывает эту правку.
///
/// Задан [value] — путь получает значение; [remove] — путь снимается.
/// Возвращает, применена ли правка.
bool editBodyPath(
  Map<String, dynamic> body, {
  required bool authored,
  required String code,
  required String path,
  Object? value,
  bool remove = false,
}) {
  final scheme = body['type'];
  final w = RegistryWarning(code: code, path: path);
  final (apply, _) = decideBodyEdit(
    scheme is String ? scheme : '',
    authored: authored,
    w: w,
  );
  if (!apply) return false;
  final parts = path.split('.');
  if (remove) {
    _deletePath(body, parts);
  } else {
    _setPath(body, parts, value);
  }
  return true;
}

// ---------------------------------------------------------------------------

Iterable<FieldSchema> _fieldsAt(
    Map<String, FieldSchema>? fields, List<String> parts) sync* {
  if (parts.isEmpty || fields == null) return;
  final f = fields[parts.first];
  if (f == null) return;
  var rest = parts.sublist(1);
  while (rest.isNotEmpty && _isIndex(rest.first)) {
    rest = rest.sublist(1);
  }
  if (rest.isEmpty) {
    yield f;
    return;
  }
  yield* _fieldsAt(f.fields ?? f.items?.fields, rest);
  final vs = f.variants;
  if (vs != null) {
    for (final v in vs.values) {
      yield* _fieldsAt(v.fields, rest);
    }
  }
}

bool _isIndex(String s) => s.isNotEmpty && int.tryParse(s) != null;

/// Сегменты пути предупреждения: индекс элемента пишется в скобках
/// (`peers[0].port`, `server_ports[1]`) и становится отдельным сегментом.
List<String> _pathParts(String path) =>
    path.replaceAll('[', '.').replaceAll(']', '').split('.');

/// Жёсткое ли правило поля [f] с кодом [code]. Код правила со своим
/// объектом решает признак этого объекта; код из `forbidden_codes` —
/// мягкий; прочее (тип, values, format, required, forbidden_for) — признак
/// самого поля.
bool _fieldRuleCoreRejects(FieldSchema f, String code) {
  var own = false;
  var hard = false;
  void see(Object? c, Object? flag) {
    if (c is String && c.isNotEmpty && c == code) {
      own = true;
      if (flag == true) hard = true;
    }
  }

  final r = f.raw;
  final oi = r['on_invalid'];
  if (oi is Map) {
    see(oi['code'] ?? 'type_invalid', oi['core_rejects']);
    see(oi['else_code'], oi['core_rejects']);
  }
  for (final k in const ['default_when', 'max_when', 'min_when', 'coerce_when']) {
    final m = r[k];
    if (m is Map) see(m['code'], m['core_rejects']);
  }
  final mw = r['max_when'];
  if (mw is Map) see(mw['note_code'], false);
  for (final rel in [...f.conflicts, ...f.requires]) {
    see(rel['code'], rel['core_rejects']);
  }
  if (hard) return true;
  if (own) return false;
  if (f.forbiddenCodes?.values.contains(code) ?? false) return false;
  return r['core_rejects'] == true;
}

void _patchFrom(
    Map<String, dynamic> body, Map<String, dynamic> edited, String path) {
  var parts = _pathParts(path);
  // Правка элемента массива (`server_ports[0]`: элемент снят) переносится
  // массивом целиком — после снятия индексы остальных элементов сдвинуты.
  while (parts.length > 1 && _isIndex(parts.last)) {
    parts = parts.sublist(0, parts.length - 1);
  }
  final (found, v) = _lookup(edited, parts);
  if (found) {
    _setPath(body, parts, _deepCopy(v));
    return;
  }
  // §580 (контракт 1.1.97, как Go `nodeflow.patchFromClean`): пути нет в
  // чистом теле, потому что снят его РОДИТЕЛЬ (`tls.reality.public_key` при
  // снятом блоке `reality`) — в авторском теле снимается самый верхний снятый
  // сегмент; снят элемент массива — массив переносится целиком.
  for (var k = 1; k < parts.length; k++) {
    final prefix = parts.sublist(0, k);
    if (_lookup(edited, prefix).$1) continue;
    if (_isIndex(prefix.last) && k > 1) {
      final arr = parts.sublist(0, k - 1);
      final (aFound, a) = _lookup(edited, arr);
      if (aFound) {
        _setPath(body, arr, _deepCopy(a));
        return;
      }
    }
    _deletePath(body, prefix);
    return;
  }
  _deletePath(body, parts);
}

(bool, Object?) _lookup(Object? v, List<String> parts) {
  var cur = v;
  for (final p in parts) {
    if (cur is Map) {
      if (!cur.containsKey(p)) return (false, null);
      cur = cur[p];
    } else if (cur is List) {
      final i = int.tryParse(p);
      if (i == null || i < 0 || i >= cur.length) return (false, null);
      cur = cur[i];
    } else {
      return (false, null);
    }
  }
  return (true, cur);
}

void _setPath(Map<String, dynamic> m, List<String> parts, Object? v) {
  if (parts.isEmpty) return;
  if (parts.length == 1) {
    m[parts.first] = v;
    return;
  }
  final next = m[parts.first];
  if (next is Map<String, dynamic>) {
    _setPath(next, parts.sublist(1), v);
  } else if (next is List) {
    final i = int.tryParse(parts[1]);
    if (i == null || i < 0 || i >= next.length) return;
    if (parts.length == 2) {
      next[i] = v;
    } else if (next[i] is Map<String, dynamic>) {
      _setPath(next[i] as Map<String, dynamic>, parts.sublist(2), v);
    }
  } else {
    final inner = <String, dynamic>{};
    m[parts.first] = inner;
    _setPath(inner, parts.sublist(1), v);
  }
}

void _deletePath(Map<String, dynamic> m, List<String> parts) {
  if (parts.isEmpty) return;
  if (parts.length == 1) {
    m.remove(parts.first);
    return;
  }
  final next = m[parts.first];
  if (next is Map<String, dynamic>) {
    _deletePath(next, parts.sublist(1));
  } else if (next is List) {
    final i = int.tryParse(parts[1]);
    if (i == null || i < 0 || i >= next.length) return;
    if (parts.length == 2) {
      m[parts.first] = [...next]..removeAt(i);
    } else if (next[i] is Map<String, dynamic>) {
      _deletePath(next[i] as Map<String, dynamic>, parts.sublist(2));
    }
  }
}

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> m) =>
    _deepCopy(m) as Map<String, dynamic>;

Object? _deepCopy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': _deepCopy(e.value),
    };
  }
  if (v is List) return [for (final e in v) _deepCopy(e)];
  return v;
}
