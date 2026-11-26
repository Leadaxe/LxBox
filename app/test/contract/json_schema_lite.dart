// §438 — проверка документа по JSON Schema в объёме, который использует
// `contract/schema/backup.schema.json`: `$ref` на `#/$defs/…`, `type`,
// `properties`, `required`, `additionalProperties`, `enum`, `const`, `items`,
// `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`, `minimum`/`maximum`,
// `minLength`, `minItems`, `pattern`, булева схема свойства (`false` —
// ключа быть не может) (контракт 1.1.158: `native_prefs.memory_limit`;
// 1.1.179, §757: `rules[].body` — `oneOf` простого правила и `logical`). `format`,
// `default`, `title`, `description` проверки не несут.
//
// Библиотеки валидатора в зависимостях проекта нет, а тянуть её ради одного
// теста — лишний пакет в сборке. Незнакомое ключевое слово — ошибка
// валидатора, а не молчаливый пропуск: схема, начавшая пользоваться новым
// словом, должна уронить тест, а не тихо ослабить его.

const Set<String> _known = {
  r'$schema',
  r'$id',
  r'$ref',
  r'$defs',
  'title',
  'description',
  'default',
  'format',
  'type',
  'properties',
  'required',
  'additionalProperties',
  'enum',
  'const',
  'items',
  'allOf',
  'anyOf',
  'oneOf',
  'not',
  'minItems',
  'if',
  'then',
  'minimum',
  'maximum',
  'minLength',
  'pattern',
};

/// Ошибки документа [value] по схеме [root]; пусто — документ валиден.
List<String> validateJsonSchema(Object? value, Map<String, dynamic> root) {
  final errors = <String>[];
  _validate(value, root, root, r'$', errors);
  return errors;
}

bool _matches(Object? value, Map<String, dynamic> schema, Map<String, dynamic> root) {
  final errors = <String>[];
  _validate(value, schema, root, r'$', errors);
  return errors.isEmpty;
}

void _validate(
  Object? value,
  Map<String, dynamic> schema,
  Map<String, dynamic> root,
  String at,
  List<String> errors,
) {
  for (final key in schema.keys) {
    if (!_known.contains(key)) {
      errors.add('$at: validator does not know keyword "$key"');
    }
  }

  final ref = schema[r'$ref'];
  if (ref is String) {
    const prefix = r'#/$defs/';
    if (!ref.startsWith(prefix)) {
      errors.add('$at: unsupported \$ref $ref');
      return;
    }
    final target = (root[r'$defs'] as Map)[ref.substring(prefix.length)];
    if (target is! Map) {
      errors.add('$at: missing \$ref target $ref');
      return;
    }
    _validate(value, target.cast<String, dynamic>(), root, at, errors);
  }

  final type = schema['type'];
  if (type != null) {
    final types = type is List ? type.cast<String>() : [type as String];
    if (!types.any((t) => _isType(value, t))) {
      errors.add('$at: expected ${types.join('|')}, got ${value.runtimeType}');
      return;
    }
  }

  if (schema.containsKey('const') && !_jsonEquals(value, schema['const'])) {
    errors.add('$at: expected const ${schema['const']}, got $value');
  }
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.any((e) => _jsonEquals(e, value))) {
    errors.add('$at: $value is not one of $enumValues');
  }
  if (value is num) {
    final min = schema['minimum'];
    if (min is num && value < min) errors.add('$at: $value < minimum $min');
    final max = schema['maximum'];
    if (max is num && value > max) errors.add('$at: $value > maximum $max');
  }
  if (value is String) {
    final minLength = schema['minLength'];
    if (minLength is int && value.length < minLength) {
      errors.add('$at: shorter than $minLength');
    }
    final pattern = schema['pattern'];
    if (pattern is String && !RegExp(pattern).hasMatch(value)) {
      errors.add('$at: "$value" does not match $pattern');
    }
  }

  if (value is Map) {
    final properties =
        (schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final req in (schema['required'] as List? ?? const [])) {
      if (!value.containsKey(req)) errors.add('$at: missing required "$req"');
    }
    final additional = schema['additionalProperties'];
    for (final entry in value.entries) {
      final key = '${entry.key}';
      final prop = properties[key];
      if (prop == false) {
        // §757 — булева схема: свойство запрещено (`refs` у `logical`).
        errors.add('$at: property "$key" is not allowed');
      } else if (prop is Map) {
        _validate(entry.value, prop.cast<String, dynamic>(), root, '$at.$key', errors);
      } else if (additional == false) {
        errors.add('$at: additional property "$key"');
      } else if (additional is Map) {
        _validate(entry.value, additional.cast<String, dynamic>(), root, '$at.$key', errors);
      }
    }
  }

  final minItems = schema['minItems'];
  if (value is List && minItems is int && value.length < minItems) {
    errors.add('$at: fewer than $minItems items');
  }

  // §757 — `not`: документ НЕ должен подходить под схему.
  final notSchema = schema['not'];
  if (notSchema is Map &&
      _matches(value, notSchema.cast<String, dynamic>(), root)) {
    errors.add('$at: matches "not" schema');
  }

  final items = schema['items'];
  if (value is List && items is Map) {
    for (var i = 0; i < value.length; i++) {
      _validate(value[i], items.cast<String, dynamic>(), root, '$at[$i]', errors);
    }
  }

  for (final sub in (schema['allOf'] as List? ?? const [])) {
    _validate(value, (sub as Map).cast<String, dynamic>(), root, at, errors);
  }

  // Контракт 1.0.1: `group.default` — ссылка объектом или строка dev-формы.
  final anyOf = schema['anyOf'];
  if (anyOf is List &&
      !anyOf.any((sub) =>
          _matches(value, (sub as Map).cast<String, dynamic>(), root))) {
    errors.add('$at: matches none of anyOf');
  }

  // §757 (контракт 1.1.179) — `rules[].body`: простое правило либо
  // `logical`; ровно одна ветка.
  final oneOf = schema['oneOf'];
  if (oneOf is List) {
    final n = oneOf
        .where((sub) =>
            _matches(value, (sub as Map).cast<String, dynamic>(), root))
        .length;
    if (n != 1) errors.add('$at: matches $n of oneOf (exactly one required)');
  }

  final ifSchema = schema['if'];
  final thenSchema = schema['then'];
  if (ifSchema is Map && thenSchema is Map) {
    if (_matches(value, ifSchema.cast<String, dynamic>(), root)) {
      _validate(value, thenSchema.cast<String, dynamic>(), root, at, errors);
    }
  }
}

bool _isType(Object? value, String type) => switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'boolean' => value is bool,
      'integer' => value is int || (value is double && value == value.roundToDouble()),
      'number' => value is num,
      'null' => value == null,
      _ => false,
    };

bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_jsonEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
