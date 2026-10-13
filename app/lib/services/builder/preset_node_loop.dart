/// §643 (контракт 1.1.119, TEMPLATE_LANG §2.1, §6.5–§6.7) — рубеж загрузки
/// обхода узлов пресета и объявлений переменных.
///
/// [parsePresetNodeLoop] — ОДНА функция разбора-валидации обхода: ей
/// пользуются и загрузчик шаблона (`validateTemplateConstructs`), и
/// корпусный раннер (`load: reject` = её исключение). Структуру обхода по
/// закрытым спискам разбирает модель ([PresetNodeLoop.parse]); здесь сверху
/// — условие `#filter` против объявленных имён и объявления переменных
/// пресета (`unique`, имена `node` / `node.*`).
library;

import 'dart:collection';

import '../../models/parser_config.dart';
import 'if_engine.dart' show TemplateIfError, validateCondNode;

/// Объявление переменной (глобальной или пресета) по нормам 1.1.119:
/// `unique` — только bool и только у `text_list`; имя `node` / `node.*`
/// зарезервировано за узлом обхода. Нарушение — [TemplateIfError].
/// Ref-запись (`{"ref": …}`) объявлением не является и не проверяется.
void validateVarDeclaration(Map<String, dynamic> raw, String path) {
  final ref = raw['ref'];
  if (ref is String && ref.isNotEmpty) return;
  final name = raw['name'];
  if (name is String && PresetNodeLoop.isReservedName(name)) {
    throw TemplateIfError('$path: variable name `$name` is reserved for the '
        'node of a node loop (contract 1.1.119)');
  }
  if (raw.containsKey('unique')) {
    final type = raw['type'] is String ? raw['type'] as String : 'text';
    if (raw['unique'] is! bool) {
      throw TemplateIfError('$path: `unique` must be bool');
    }
    if (type != 'text_list') {
      throw TemplateIfError(
          '$path: `unique` is allowed only for text_list (type `$type`)');
    }
  }
}

/// Разбор-валидация обхода узлов пресета [preset] (сырой JSON записи
/// `selectable_rules[]` или `preset` кейса корпуса) против глобальных
/// объявлений [globals]. null — обхода у пресета нет. Ошибка загрузки —
/// [TemplateIfError]: нарушение закрытых списков §6.5/§6.7
/// ([PresetNodeLoop.parse]), объявление переменной пресета
/// ([validateVarDeclaration]) или условие `#filter` (§4.1–4.2; в scope —
/// глобальные имена, переменные пресета и имена узла §6.6).
PresetNodeLoop? parsePresetNodeLoop(
  Map<String, dynamic> preset,
  Map<String, WizardVar> globals, {
  String path = 'preset',
}) {
  for (final v in (preset['vars'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()) {
    validateVarDeclaration(v, '$path.vars[${v['name'] ?? v['ref']}]');
  }
  final PresetNodeLoop? loop;
  try {
    loop = PresetNodeLoop.parse(preset);
  } on FormatException catch (e) {
    throw TemplateIfError('$path: ${e.message}');
  }
  if (loop == null) return null;
  final filter = loop.filter;
  if (filter != null) {
    final key =
        loop.isNode ? PresetNodeLoop.keyNode : PresetNodeLoop.keyNodeDo;
    validateCondNode(filter, PresetNodeScope(presetVarScope(preset, globals)),
        '$path.$key.#filter');
  }
  return loop;
}

/// Область видимости имён внутри пресета: глобальные переменные плюс
/// собственные `vars[]` пресета. Ref-запись метаданных не несёт — её тип
/// берётся из глобальной декларации, поэтому она глобаль не переопределяет.
Map<String, WizardVar> presetVarScope(
  Map<String, dynamic> preset,
  Map<String, WizardVar> globals,
) {
  final scope = Map<String, WizardVar>.from(globals);
  for (final v in (preset['vars'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()) {
    final ref = v['ref'] as String? ?? '';
    if (ref.isNotEmpty) continue; // тип и остальное — у глобали
    final name = v['name'] as String? ?? '';
    if (name.isEmpty) continue;
    scope[name] = WizardVar.fromJson(v);
  }
  return scope;
}

/// Область видимости с именами узла обхода (§6.6): `@node` (тег, text),
/// `@node.skip_presets` (bool), `@node.body.<путь>` (поле тела, text). Путь
/// тела заранее не известен, поэтому имена узла вычисляются при обращении,
/// а не перечисляются.
class PresetNodeScope extends MapBase<String, WizardVar> {
  PresetNodeScope(this._base);

  final Map<String, WizardVar> _base;

  static const String _node = PresetNodeLoop.nodeName;

  @override
  WizardVar? operator [](Object? key) {
    final own = _base[key];
    if (own != null || key is! String) return own;
    if (key == _node || key.startsWith('$_node.body.')) {
      return WizardVar(name: key, type: 'text', defaultValue: '');
    }
    if (key == '$_node.skip_presets') {
      return WizardVar(name: key, type: 'bool', defaultValue: '');
    }
    return null;
  }

  @override
  void operator []=(String key, WizardVar value) => _base[key] = value;

  @override
  void clear() => _base.clear();

  @override
  Iterable<String> get keys => _base.keys;

  @override
  WizardVar? remove(Object? key) => _base.remove(key);
}

/// Типы тела узла (`body.type`), которыми условие [filter] ограничивает
/// обход: равенство `{"@node.body.type": "<тип>"}` или `#in` со списком
/// литералов — само условие или член верхнего `#and` (сахар-список тоже
/// `#and`). null — тип не ограничен (любой узел может пройти).
///
/// Только сужение для экрана: какие узлы вообще стоит эмитить, чтобы
/// вычислить условие. Узел вне множества условие не пройдёт по построению.
Set<String>? nodeLoopTypeHint(Object? filter) {
  const typeRef = '@${PresetNodeLoop.nodeName}.body.type';
  Set<String>? fromPred(Object? p) {
    if (p is! Map || p.length != 1 || p.keys.first != typeRef) return null;
    final arg = p[typeRef];
    if (arg is String && !arg.startsWith('#') && !arg.startsWith('@')) {
      return {arg};
    }
    if (arg is Map && arg.length == 1 && arg['#in'] is List) {
      final list = arg['#in'] as List;
      if (list.every((e) => e is String && !e.startsWith('@'))) {
        return list.cast<String>().toSet();
      }
    }
    return null;
  }

  final direct = fromPred(filter);
  if (direct != null) return direct;
  final conj = switch (filter) {
    List l => l,
    Map m when m.length == 1 && (m['#and'] ?? m['and']) is List =>
      (m['#and'] ?? m['and']) as List,
    _ => null,
  };
  if (conj == null) return null;
  Set<String>? out;
  for (final p in conj) {
    final s = fromPred(p);
    if (s == null) continue;
    out = out == null ? s : out.intersection(s);
  }
  return out;
}
