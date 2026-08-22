import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';

// Конформанс-раннер корпуса шаблонов (SPEC 103, фаза 3, D-047), сторона LxBox.
// Аналог core/template/contract_template_test.go в singbox-launcher — гоняет
// ТОТ ЖЕ корпус contract/corpus/template/** через walk()/makeResolver() и
// сравнивает с <case>.expected.json.
//
// Ожидания здесь ОБЩИЕ с лаунчером (без per-app суффикса, в отличие от корпуса
// URI): движок шаблонов унифицируется полностью (D-046) — расхождение между
// приложениями = баг движка, а не разница платформ. Сами шаблоны при этом
// остаются разными, поэтому корпус не зависит от словаря ни одного из них.
//
// Формат кейса — contract/corpus/template/README.md:
//   <case>.template.json  {"vars": [...], "config": {...}, "_changed": "имя"}
//   <case>.vars.json      {"имя": "строка"}  (null = optional-var)
//   <case>.expected.json  {"config": {...}, "warnings": [...], "vars_after": {}}

/// Корень скопированного контракта — кладёт tool/sync_contract.sh.
const _contractRoot = 'contract';

/// Коды warning'ов движка шаблонов (contract/registry/warnings.json).
const _warnVarUndeclared = 'template_var_undeclared';
const _warnUnknownDirective = 'template_unknown_directive';
const _warnIntClamped = 'template_int_clamped';
const _warnIntInvalid = 'template_int_invalid';

/// Накопитель warning'ов кейса: список кодов без дублей, отсортированный —
/// порядок warning'ов контрактом не нормируется.
class _Warnings {
  final Set<String> _codes = {};
  void add(String code) => _codes.add(code);
  List<String> toSorted() => _codes.toList()..sort();
}

/// Разобранная тройка файлов кейса.
class _Case {
  _Case({
    required this.name,
    required this.vars,
    required this.config,
    required this.changed,
    required this.varValues,
    required this.expected,
  });

  final String name;
  final List<WizardVar> vars;
  final dynamic config;

  /// Имя переменной, которую «изменил пользователь» — включает проверку
  /// on_change (§4.6). Пусто — обычный кейс подстановки.
  final String changed;

  /// Значения переменных; null = optional-var (§5.1).
  final Map<String, String?> varValues;

  final Map<String, dynamic> expected;
}

_Case _loadCase(String base) {
  final tpl = jsonDecode(File('$base.template.json').readAsStringSync())
      as Map<String, dynamic>;
  final varsRaw = jsonDecode(File('$base.vars.json').readAsStringSync())
      as Map<String, dynamic>;
  final expected = jsonDecode(File('$base.expected.json').readAsStringSync())
      as Map<String, dynamic>;

  final vars = <WizardVar>[
    for (final v in (tpl['vars'] as List? ?? const []))
      WizardVar.fromJson(v as Map<String, dynamic>),
  ];

  return _Case(
    name: base,
    vars: vars,
    config: tpl['config'],
    changed: (tpl['_changed'] as String?) ?? '',
    varValues: {
      for (final e in varsRaw.entries) e.key: e.value as String?,
    },
    expected: expected,
  );
}

/// Резолвер по канону §5.2, поверх [makeResolver]:
///   • имя НЕ объявлено → null (walk оставит плейсхолдер) + warning;
///   • имя объявлено, значения нет → Dropped-каскад;
///   • иначе — типизированное значение.
///
/// Warning'и на int-коэрцию снимаются здесь же: coerceVarValue клампит и
/// возвращает строку на не-число молча, а контракт требует кода.
VarResolver _canonResolver(_Case c, _Warnings warns) {
  final nodes = {for (final v in c.vars) v.name: v};
  final declared = nodes.keys.toSet();

  return (String name) {
    if (!declared.contains(name)) {
      warns.add(_warnVarUndeclared);
      return null; // плейсхолдер остаётся видимым (§5.2)
    }
    final raw = c.varValues[name];
    if (raw == null) {
      // Объявлена, значения нет — штатная optional-var, а не опечатка.
      final fallback = nodes[name]?.defaultValue ?? '';
      if (fallback.isEmpty && c.varValues.containsKey(name)) {
        return Dropped.instance;
      }
      if (fallback.isEmpty) return Dropped.instance;
      return _coerceWithWarnings(fallback, nodes[name]!.type, warns);
    }
    return _coerceWithWarnings(raw, nodes[name]!.type, warns);
  };
}

/// Обёртка coerceVarValue, поднимающая коды warning'ов (§2.2).
dynamic _coerceWithWarnings(String raw, String type, _Warnings warns) {
  if (type == 'int') {
    final n = int.tryParse(raw.trim());
    if (n == null) {
      warns.add(_warnIntInvalid);
    } else if (n < 0 || n > 65535) {
      warns.add(_warnIntClamped);
    }
  }
  return coerceVarValue(raw, type);
}

/// Прогоняет кейс и возвращает фактический результат в форме expected.
Map<String, dynamic> _runCase(_Case c) {
  final warns = _Warnings();
  // Движок отдаёт свои warning'и (неизвестная директива) через глобальный хук.
  onTemplateWarning = warns.add;

  // Состояние переменных: null-значения не попадают (их отсутствие и есть
  // сигнал Dropped), остальные — как есть.
  final state = <String, String>{
    for (final e in c.varValues.entries)
      if (e.value != null) e.key: e.value!,
  };

  // on_change (§4.6) применяется ДО подстановки, в контексте нового значения
  // изменённой переменной — как это делает UI при переключении.
  if (c.changed.isNotEmpty) {
    _applyOnChange(c.changed, c.vars, state);
  }

  final caseWithState = _Case(
    name: c.name,
    vars: c.vars,
    config: c.config,
    changed: c.changed,
    varValues: {
      for (final e in c.varValues.entries)
        e.key: e.value == null ? null : state[e.key],
      for (final e in state.entries) e.key: e.value,
    },
    expected: c.expected,
  );

  final resolved = walk(
    _deepCopy(c.config),
    _canonResolver(caseWithState, warns),
  );

  onTemplateWarning = null; // хук глобальный — снимаем, чтобы не текло в другие тесты

  final out = <String, dynamic>{
    'config': identical(resolved, Dropped.instance) ? {} : resolved,
    'warnings': warns.toSorted(),
  };
  if (c.changed.isNotEmpty) out['vars_after'] = state;
  return out;
}

/// Применяет on_change изменённой переменной (§4.6): каскад по цепочке целей
/// с fixpoint-guard и жёстким предохранителем глубины.
void _applyOnChange(
  String changed,
  List<WizardVar> vars,
  Map<String, String> state, {
  int depth = 0,
}) {
  if (depth > 16) return; // предохранитель на топологии, которые fixpoint не ловит
  final node = vars.where((v) => v.name == changed).firstOrNull;
  final set = (node?.onChange?['#set'] ?? node?.onChange?['set']) as Map<String, dynamic>?;
  if (set == null) return;

  final nodes = {for (final v in vars) v.name: v};
  for (final entry in set.entries) {
    final target = entry.key.startsWith('@') ? entry.key.substring(1) : entry.key;
    final tree = entry.value;
    if (tree is! Map<String, dynamic>) continue;

    final resolve = makeResolver(state, nodes);
    final value = evalIfScalar(tree, resolve);
    if (value == null) continue; // ветка не выбрана — цель не трогаем

    // fixpoint-guard: значение не изменилось → записи нет, рекурсия обрывается.
    if (state[target] == value) continue;
    state[target] = value;
    _applyOnChange(target, vars, state, depth: depth + 1);
  }
}

dynamic _deepCopy(dynamic node) => jsonDecode(jsonEncode(node));

/// Сравнение JSON-деревьев по значению, не по байтам (CANON §7).
bool _jsonEqual(dynamic a, dynamic b) =>
    const DeepCollectionEquality().equals(a, b);

/// Раннер раздела corpus/template/deps/ (SPEC 107 §8.1) — ИНОЙ формат:
///
///     <case>.cond.json      условие языка (§5.1) без обёртки
///     <case>.expected.json  {"deps": ["a", "b"]}  — отсортированные имена
///
/// Тот же набор гоняет Go: извлечение зависимостей нормативно, потому что на
/// нём стоит реактивный пересчёт — разъехавшиеся deps означают, что на одной
/// платформе строка обновится при изменении переменной, а на другой нет.
void _runDepsCorpus(Directory root) {
  final bases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.cond.json'))
      .map((f) => f.path.substring(0, f.path.length - '.cond.json'.length))
      .toList()
    ..sort();

  group('contract corpus: cond deps', () {
    for (final base in bases) {
      final name = base.substring(root.path.length + 1);
      test(name, () {
        final cond = jsonDecode(File('$base.cond.json').readAsStringSync());
        final expected = jsonDecode(File('$base.expected.json').readAsStringSync())
            as Map<String, dynamic>;
        final want = ((expected['deps'] as List?) ?? const []).cast<String>();
        expect(condDeps(cond), want, reason: 'deps для ${jsonEncode(cond)}');
      });
    }
  });
}

void main() {
  final root = Directory('$_contractRoot/corpus/template');
  if (!root.existsSync()) {
    // Контракт не синхронизирован — прогон пропускается, а не падает
    // (tool/sync_contract.sh кладёт copy).
    return;
  }

  final bases = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.template.json'))
      .map((f) => f.path.substring(0, f.path.length - '.template.json'.length))
      .toList()
    ..sort();

  final depsRoot = Directory('$_contractRoot/corpus/template/deps');
  if (depsRoot.existsSync()) _runDepsCorpus(depsRoot);

  group('contract corpus: template engine', () {
    for (final base in bases) {
      final name = base.substring(root.path.length + 1);
      test(name, () {
        final c = _loadCase(base);
        final got = _runCase(c);

        final expectedWarnings =
            ((c.expected['warnings'] as List?) ?? const []).cast<String>().toList()
              ..sort();

        expect(
          _jsonEqual(got['config'], c.expected['config']),
          isTrue,
          reason: 'config: получено ${jsonEncode(got['config'])}, '
              'ожидалось ${jsonEncode(c.expected['config'])}',
        );
        expect(got['warnings'], expectedWarnings, reason: 'warnings');
        if (c.changed.isNotEmpty) {
          expect(got['vars_after'], c.expected['vars_after'],
              reason: 'vars_after');
        }
      });
    }
  });
}
