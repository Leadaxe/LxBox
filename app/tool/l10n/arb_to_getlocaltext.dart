// §285 Ф2 — разовый конвертер ARB → getLocalText natural-key словарь.
//
// Читает lib/l10n/app_en.arb + app_ru.arb и порождает:
//   - assets/l10n/ui/ru.json            — плоский Map<englishKey, entry> для движка
//   - tool/l10n/_arb_migration_map.json — карта ARB_key → {en, ru, kind, collision}
//     для будущей Ф3 (переписывание call-site'ов context.l.<K> → getLocalText).
//
// Ключ русского словаря — АНГЛИЙСКИЙ текст дословно (natural key). Плейсхолдеры
// ARB `{name}` конвертируются в printf `%s`/`%d` (число-типизированные из @meta).
// ICU-plural раскрывается в plural-объект {one,few,many,other} по ru-веткам.
//
// Скрипт НЕ трогает call-site'ы и НЕ трогает сам ARB. Только генерация ассетов.

import 'dart:convert';
import 'dart:io';

// Пивот plural-ICU у нас всегда `count` (проверено по ARB). Держим набор на
// случай `n`, но конвертер число-пивота ищет именно объявленный ICU-var.
const _pluralPivots = {'count', 'n'};

void main() {
  final root = _appRoot();
  final en = _loadArb('$root/lib/l10n/app_en.arb');
  final ru = _loadArb('$root/lib/l10n/app_ru.arb');

  // Только «настоящие» ключи (не @-метаданные).
  final keys = en.keys.where((k) => !k.startsWith('@')).toList()..sort();

  // englishKey → выбранный entry (первый победитель при коллизии).
  final dict = <String, Map<String, dynamic>>{};
  // englishKey → ARB-ключ, который занял корневой value (для отчёта коллизий).
  final rootOwner = <String, String>{};
  final migMap = <String, Map<String, dynamic>>{};

  final collisions = <_Collision>[];
  final pluralHandfill = <String>[];
  var pluralCount = 0;
  var placeholderKeyCount = 0;

  for (final k in keys) {
    final enVal = en[k];
    final ruVal = ru[k] ?? enVal; // нет перевода → fallback на en (не должно быть)
    final meta = en['@$k'];
    final placeholders = _placeholderTypes(meta);

    final enIsPlural = _isIcuPlural('$enVal');
    final ruIsPlural = _isIcuPlural('$ruVal');
    // kind=plural если ЛИБО сторона — ICU-plural: call-site обязан звать .plural(n),
    // иначе ru-формы (one/few/many) не выберутся. En-only plural тоже plural.
    final isPlural = enIsPlural || ruIsPlural;

    final String enKey;
    final dynamic value;

    if (isPlural) {
      pluralCount++;
      // Английский ключ: берём en. Если en — ICU, раскрываем его «other»-ветку
      // (репрезентативная форма) как natural key; иначе en уже простой ({count} nodes).
      enKey = _pluralEnglishKey('$enVal', placeholders);
      final forms = _ruPluralForms('$ruVal', '$enVal', placeholders);
      value = forms.map;
      if (forms.needsHandfill) pluralHandfill.add(k);
    } else {
      enKey = _convertPlaceholders('$enVal', placeholders);
      value = _convertPlaceholders('$ruVal', placeholders);
    }

    if (placeholders.isNotEmpty || enKey.contains('%')) placeholderKeyCount++;

    migMap[k] = {
      'en': enKey,
      'ru': value,
      'kind': isPlural ? 'plural' : 's',
      'collision': false,
    };

    final existing = dict[enKey];
    if (existing == null) {
      dict[enKey] = {'value': value};
      rootOwner[enKey] = k;
    } else {
      // Тот же englishKey уже занят. Сравниваем ru-значения.
      final sameRu = _deepEq(existing['value'], value);
      if (sameRu) {
        // Полный дубль (одинаковый en И ru) → тихо схлопываем, ничего не пишем.
        continue;
      }
      // Коллизия: одинаковый en, РАЗНЫЙ ru. Первый остаётся корневым value,
      // второй уходит в special-форму (индекс = порядковый номер коллизии для
      // этого ключа). Помечаем оба в migMap.
      final owner = rootOwner[enKey]!;
      final specialIdx = _nextSpecialIndex(dict[enKey]!);
      (dict[enKey]!['special'] ??= <String, dynamic>{})[specialIdx.toString()] =
          {'value': value};
      migMap[k]!['collision'] = true;
      migMap[k]!['special'] = specialIdx;
      migMap[owner]!['collision'] = true;
      collisions.add(_Collision(
        k1: owner,
        k2: k,
        en: enKey,
        ru1: (dict[enKey]!['value']),
        ru2: value,
        specialIndex: specialIdx,
      ));
    }
  }

  // Запись ru.json — отсортированные ключи, pretty, unicode как есть.
  final sortedDict = <String, dynamic>{
    for (final k in (dict.keys.toList()..sort())) k: dict[k],
  };
  final ruJsonPath = '$root/assets/l10n/ui/ru.json';
  File(ruJsonPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(sortedDict));

  // Запись migration-map — по ARB-ключу.
  final sortedMap = <String, dynamic>{
    for (final k in (migMap.keys.toList()..sort())) k: migMap[k],
  };
  final mapPath = '$root/tool/l10n/_arb_migration_map.json';
  File(mapPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(sortedMap));

  // ── Отчёт ─────────────────────────────────────────────────────────────
  stdout.writeln('=== ARB → getLocalText migration ===');
  stdout.writeln('ARB keys total        : ${keys.length}');
  stdout.writeln('ru.json entries        : ${dict.length}');
  stdout.writeln('plural entries         : $pluralCount');
  stdout.writeln('keys with placeholders : $placeholderKeyCount');
  stdout.writeln('collisions (en same,   : ${collisions.length}');
  stdout.writeln('           ru differ)  ');
  stdout.writeln('plural needs few/many  : ${pluralHandfill.length}');
  stdout.writeln('  hand-fill');
  stdout.writeln('');

  if (pluralHandfill.isNotEmpty) {
    stdout.writeln('--- plural needs few/many hand-fill ---');
    for (final k in pluralHandfill) {
      stdout.writeln('  $k');
    }
    stdout.writeln('');
  }

  if (collisions.isNotEmpty) {
    stdout.writeln('--- COLLISION REPORT (manual triage) ---');
    for (final c in collisions) {
      stdout.writeln('  en=${jsonEncode(c.en)}');
      stdout.writeln('    ${c.k1} (root)      ru=${jsonEncode(c.ru1)}');
      stdout.writeln(
          '    ${c.k2} (special[${c.specialIndex}]) ru=${jsonEncode(c.ru2)}');
    }
    stdout.writeln('');
  }

  stdout.writeln('wrote $ruJsonPath');
  stdout.writeln('wrote $mapPath');
}

// ── ICU-plural ────────────────────────────────────────────────────────────

bool _isIcuPlural(String v) => RegExp(r'\{\w+, plural,').hasMatch(v);

/// Английский natural-ключ из ICU-plural: раскрываем `other`-ветку (или `one`
/// если other нет), конвертируем плейсхолдеры. Если en уже простой — просто
/// конвертируем как есть.
String _pluralEnglishKey(String enVal, Map<String, String> placeholders) {
  if (!_isIcuPlural(enVal)) return _convertPlaceholders(enVal, placeholders);
  final branches = _parseIcuBranches(enVal);
  final body = branches['other'] ?? branches['one'] ?? branches.values.first;
  return _convertPlaceholders(body, placeholders);
}

class _RuForms {
  _RuForms(this.map, this.needsHandfill);
  final Map<String, String> map;
  final bool needsHandfill;
}

/// Русские plural-формы {one,few,many,other} из ru-значения.
/// Если ru — ICU: берём его ветки. Если ru простой (не ICU, но en был plural):
/// размножаем строку по всем 4 формам и помечаем на ручной разбор.
_RuForms _ruPluralForms(
    String ruVal, String enVal, Map<String, String> placeholders) {
  const need = {'one', 'few', 'many', 'other'};
  if (_isIcuPlural(ruVal)) {
    final branches = _parseIcuBranches(ruVal);
    final map = <String, String>{};
    for (final f in need) {
      final b = branches[f];
      if (b != null) map[f] = _convertPlaceholders(b, placeholders);
    }
    // Если ICU дал не все 4 (напр. только one/other) — дозаполняем имеющимся
    // «other» и флажим на ручную правку few/many.
    final missing = need.difference(map.keys.toSet());
    if (missing.isEmpty) return _RuForms(map, false);
    final filler = map['other'] ?? map['one'] ?? map.values.first;
    for (final f in missing) {
      map[f] = filler;
    }
    return _RuForms(_ordered(map), true);
  }
  // ru простой строкой — en был plural. Размножаем + флаг ручной правки.
  final flat = _convertPlaceholders(ruVal, placeholders);
  return _RuForms(
    {'one': flat, 'few': flat, 'many': flat, 'other': flat},
    true,
  );
}

Map<String, String> _ordered(Map<String, String> m) => {
      for (final f in const ['one', 'few', 'many', 'other'])
        if (m.containsKey(f)) f: m[f]!,
    };

/// Разбор ICU-веток `one{...} few{...} ...` с балансировкой вложенных `{}`.
Map<String, String> _parseIcuBranches(String v) {
  final out = <String, String>{};
  // Тело после `{count, plural,` до финальной `}`.
  final start = v.indexOf('plural,');
  if (start < 0) return out;
  var i = start + 'plural,'.length;
  while (i < v.length) {
    // Пропускаем пробелы.
    while (i < v.length && v[i] == ' ') {
      i++;
    }
    if (i >= v.length || v[i] == '}') break;
    // Читаем имя формы до '{'.
    final nameStart = i;
    while (i < v.length && v[i] != '{') {
      i++;
    }
    if (i >= v.length) break;
    final name = v.substring(nameStart, i).trim();
    // Балансируем '{'..'}'.
    var depth = 0;
    final bodyStart = i + 1;
    while (i < v.length) {
      if (v[i] == '{') depth++;
      if (v[i] == '}') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    final body = v.substring(bodyStart, i);
    if (name.isNotEmpty) out[name] = body;
    i++; // за закрывающую '}'
  }
  return out;
}

// ── Плейсхолдеры → printf ──────────────────────────────────────────────────

/// Типы объявленных плейсхолдеров из @meta: name → 'int'|'String'|...
/// Только объявленные плейсхолдеры конвертируются — так `{day}`-литерал внутри
/// plural-ветки (не объявлен в @meta) остаётся текстом.
Map<String, String> _placeholderTypes(dynamic meta) {
  final out = <String, String>{};
  if (meta is Map && meta['placeholders'] is Map) {
    (meta['placeholders'] as Map).forEach((name, def) {
      final t = (def is Map && def['type'] is String) ? def['type'] as String : 'String';
      out['$name'] = t;
    });
  }
  return out;
}

/// Конвертирует `{name}`-плейсхолдеры в printf. Число-типизированные (@type=int)
/// и пивоты plural (count/n) → %d; остальные → %s. Порядок появления → %1$s...
/// если плейсхолдеров ≥2 (позиционные, чтобы перевод мог переставить). Не
/// объявленные в @meta токены (`{day}`) остаются как есть.
String _convertPlaceholders(String s, Map<String, String> placeholders) {
  // Собираем порядок первого появления объявленных плейсхолдеров.
  final order = <String>[];
  final re = RegExp(r'\{(\w+)\}');
  for (final m in re.allMatches(s)) {
    final name = m.group(1)!;
    if (_isKnownPlaceholder(name, placeholders) && !order.contains(name)) {
      order.add(name);
    }
  }
  final positional = order.length >= 2;
  return s.replaceAllMapped(re, (m) {
    final name = m.group(1)!;
    if (!_isKnownPlaceholder(name, placeholders)) return m.group(0)!;
    final isNum = _pluralPivots.contains(name) || placeholders[name] == 'int';
    final conv = isNum ? 'd' : 's';
    if (!positional) return '%$conv';
    final pos = order.indexOf(name) + 1;
    return '%$pos\$$conv';
  });
}

bool _isKnownPlaceholder(String name, Map<String, String> placeholders) =>
    placeholders.containsKey(name) || _pluralPivots.contains(name);

// ── Коллизии / утилиты ─────────────────────────────────────────────────────

class _Collision {
  _Collision({
    required this.k1,
    required this.k2,
    required this.en,
    required this.ru1,
    required this.ru2,
    required this.specialIndex,
  });
  final String k1;
  final String k2;
  final String en;
  final dynamic ru1;
  final dynamic ru2;
  final int specialIndex;
}

int _nextSpecialIndex(Map<String, dynamic> entry) {
  final sp = entry['special'];
  if (sp is! Map) return 1;
  var i = 1;
  while (sp.containsKey(i.toString())) {
    i++;
  }
  return i;
}

bool _deepEq(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

Map<String, dynamic> _loadArb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// Корень app/ — файл лежит в app/tool/l10n/, поднимаемся на два уровня.
String _appRoot() {
  final self = File(Platform.script.toFilePath()).absolute;
  return self.parent.parent.parent.path;
}
