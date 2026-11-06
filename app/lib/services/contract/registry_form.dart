/// Контракт 1.1.122 (`TASKS_LXBOX.md` §119 п. 5, `REGISTRY_DESIGN.md` §3
/// SPEC 167 лаунчера) — модель формы узла по реестру. Контракт 1.1.123
/// (§120, SPEC 168 §2.4): общие секции через `form` ref-поля, варианты
/// транспорта по дискриминатору, `fixed`, элемент `[0]` массива, активный
/// вариант по самому длинному совпадению, `implies`.
///
/// Чистые функции от тела узла, без Flutter: раскладка блоков, видимость
/// (`visible_when`), обязательность (`required`/`required_unless`), диапазон
/// формы (`min`/`max`), группы взаимоисключающих вариантов (`choices`) и коды
/// `advisory` поля. Эталон — `registry.FormState` лаунчера
/// (`core/config/registry/form.go`); сверка — корпус `corpus/form`.
///
/// Атрибут `form` читают только формы: санитайзер, эмиттер, гейт и маппер его
/// не читают. Функции тело не меняют, кроме явных правок
/// ([withFormValue], [applyFormOption]), которые возвращают новую карту.
/// Скрытое поле из тела не снимается.
///
/// Подписи полей и блоков — строки UI приложения, не `desc_*` реестра.
library;

import 'body_sanitizer.dart' show RegistrySanitizer, registryConditionHolds;
import 'registry.dart';

/// Вариант группы выбора (`body.form.choices[].options[]`).
final class FormChoiceOption {
  const FormChoiceOption({
    required this.id,
    this.paths = const [],
    this.set = const {},
  });

  final String id;

  /// Пути тела, задание любого из которых делает вариант активным. Пусто —
  /// вариант по умолчанию (активен, когда не задан ни один путь группы).
  final List<String> paths;

  /// Что пишет выбор варианта: путь → значение (`tls.insecure: true`).
  final Map<String, Object?> set;
}

/// Группа взаимоисключающих вариантов (`body.form.choices[]`).
final class FormChoice {
  const FormChoice({required this.id, this.block, this.options = const []});

  final String id;

  /// Блок формы, в котором рисуется группа.
  final String? block;

  final List<FormChoiceOption> options;

  FormChoiceOption? option(String id) {
    for (final o in options) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Все пути всех вариантов группы — их рисует группа, а не отдельные поля.
  Set<String> get paths => {for (final o in options) ...o.paths};
}

/// Поле формы: поле реестра с атрибутом `form`.
final class FormFieldSpec {
  const FormFieldSpec({
    required this.path,
    required this.field,
    this.ancestors = const [],
    String? block,
    this.variant,
    this.variantOf,
    this.discriminatorKey,
    this.discriminator = false,
    this.choiceId,
    this.optionId,
  }) : _block = block;

  /// Путь от корня тела через точку (`tls.server_name`, `peers.0.address`).
  /// У поля варианта — без имени варианта (`transport.path` у ws и у http).
  final String path;

  /// Описание поля реестра (тип, `values`, `default`, `secret`, `advisory`).
  /// У дискриминатора — синтетический `enum` из `""` и вариантов.
  final FieldSchema field;

  /// Поля-контейнеры над этим полем, от корня. Скрытый предок скрывает
  /// поддерево.
  final List<FieldSchema> ancestors;

  final String? _block;

  /// Контракт 1.1.123 — имя варианта вариантной секции (`ws`): поле видно,
  /// только когда дискриминатор [variantOf] равен ему. `null` вне вариантов.
  final String? variant;

  /// Путь вариантного объекта (`transport`); `null` вне вариантов.
  final String? variantOf;

  /// Имя дискриминатора вариантного объекта [variantOf] (`type`).
  final String? discriminatorKey;

  /// Поле выбора варианта (`transport.type`): пусто — объект не пишется.
  final bool discriminator;

  /// Путь занимает вариант группы выбора ([FormLayout.choices]): поле рисует
  /// группа, а не блок.
  final String? choiceId;
  final String? optionId;

  Map<String, dynamic> get _form => field.form ?? const {};

  /// Блок формы (id из [FormLayout.blocks]): свой `form.block`, иначе блок
  /// ref-поля, подключившего общую секцию. `null` — поле рисует группа
  /// выбора ([choiceId]), а не блок.
  String? get block => choiceId != null ? null : _block;

  /// Условие видимости (грамматика `condition`); `null` — видно всегда.
  Object? get visibleWhen => _form['visible_when'];

  /// `form.required` — без снятия `required_unless` (см. [FormState.required]).
  bool get required => _form['required'] == true;

  Map<String, dynamic>? get requiredUnless =>
      (_form['required_unless'] as Map?)?.cast<String, dynamic>();

  /// Диапазон формы. Пустое поле границей не судится (ключ не пишется).
  num? get min => _form['min'] as num?;

  num? get max => _form['max'] as num?;

  /// Контракт 1.1.123 — `form.implies`: путь от корня тела → значение.
  /// Форма, записав поле непустым, пишет и эти пути; очистив — снимает.
  Map<String, Object?> get implies => {
    for (final e in ((_form['implies'] as Map?) ?? const {}).entries)
      '${e.key}': e.value,
  };

  /// Тип поля реестра: `string`, `int`, `bool`, `enum`, `duration`,
  /// `listable_string`, `object`, `array`, …
  String get type => field.type;

  /// Допустимые значения `enum`.
  List<Object?>? get values => field.values;

  bool get secret => field.secret;

  /// `default` поля реестра — подсказка формы; в тело не пишется.
  Object? get defaultValue => field.defaultValue;

  bool get isObject => type == 'object';

  /// Контейнер (объект, массив, вариантный объект): форма его не рисует,
  /// рисует его поля. В [FormState.visible] он входит своим путём.
  bool get isContainer =>
      !discriminator &&
      (type == 'object' || type == 'array' || field.variants != null);
}

/// Значение вне диапазона формы.
final class FormRangeViolation {
  const FormRangeViolation({
    required this.path,
    required this.value,
    this.min,
    this.max,
  });

  final String path;
  final num value;
  final num? min;
  final num? max;

  @override
  String toString() => '$path=$value';
}

/// Что форма делает с телом сейчас. Списки путей — в порядке `order`
/// реестра (обход вглубь: поле, затем его вложенные поля).
final class FormState {
  const FormState({
    this.visible = const [],
    this.required = const [],
    this.missing = const [],
    this.choices = const {},
    this.outOfRange = const [],
  });

  /// Поля с `form`, которые форма рисует: `visible_when` истинно и ни один
  /// предок не скрыт.
  final List<String> visible;

  /// Видимые поля, обязательность формы которых действует (`required` и не
  /// снята `required_unless`).
  final List<String> required;

  /// Обязательные поля, которых в теле нет: форма не сохраняет.
  final List<String> missing;

  /// id группы выбора → id активного варианта.
  final Map<String, String> choices;

  /// Видимые заданные числовые поля вне `form.min`/`form.max`.
  final List<FormRangeViolation> outOfRange;

  bool isVisible(String path) => visible.contains(path);

  bool isRequired(String path) => required.contains(path);

  bool isMissing(String path) => missing.contains(path);

  FormRangeViolation? outOfRangeAt(String path) {
    for (final v in outOfRange) {
      if (v.path == path) return v;
    }
    return null;
  }

  /// Форма сохраняет тело: обязательные заданы, числа в диапазоне.
  bool get canSave => missing.isEmpty && outOfRange.isEmpty;
}

/// Раскладка формы схемы: блоки, поля с `form` в порядке `order`, группы
/// выбора.
final class FormLayout {
  const FormLayout({
    required this.scheme,
    required this.blocks,
    required this.fields,
    required this.choices,
    this.fixed = const {},
  });

  /// `type` записи sing-box (`openconnect`).
  final String scheme;

  /// id блоков по порядку (`connection`, `security`, `advanced`).
  final List<String> blocks;

  /// Все поля с `form`, в порядке обхода `order` (вглубь), с контейнерами и
  /// дискриминаторами. Поля всех вариантов вариантной секции идут подряд за
  /// её дискриминатором; какой вариант виден — [stateOf].
  final List<FormFieldSpec> fields;

  final List<FormChoice> choices;

  /// Контракт 1.1.123 — `body.form.fixed`: путь → значение, которое форма
  /// пишет всегда и не рисует.
  final Map<String, Object?> fixed;

  /// Поле по пути; у полей варианта с общим путём — первое (поле вне
  /// вариантов — раньше).
  FormFieldSpec? field(String path) {
    FormFieldSpec? found;
    for (final f in fields) {
      if (f.path != path) continue;
      if (f.variant == null) return f;
      found ??= f;
    }
    return found;
  }

  /// Поля блока [block] в порядке `order` (поля групп выбора сюда не
  /// входят: их рисует группа).
  List<FormFieldSpec> fieldsIn(String block) => [
    for (final f in fields)
      if (f.block == block) f,
  ];

  /// Группы выбора блока [block].
  List<FormChoice> choicesIn(String block) => [
    for (final c in choices)
      if (c.block == block) c,
  ];

  FormChoice? choice(String id) {
    for (final c in choices) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Тело [body] с наложенными значениями [fixed] (новая карта).
  Map<String, dynamic> withFixed(Map<String, dynamic> body) {
    var out = _copyMap(body);
    for (final p in fixed.keys.toList()..sort()) {
      out = withFormValue(out, p, _copy(fixed[p]));
    }
    return out;
  }

  /// Записать значение поля [path] так, как пишет форма: значение
  /// ([withFormValue]) и `form.implies` поля — пути пишутся, когда значение
  /// непустое, и снимаются, когда поле очищено. Возвращает новое тело.
  Map<String, dynamic> write(
    Map<String, dynamic> body,
    String path,
    Object? value,
  ) {
    var out = withFormValue(body, path, value);
    final f = field(path);
    if (f == null) return out;
    final written = !_isEmptyValue(value);
    final implies = f.implies;
    for (final p in implies.keys.toList()..sort()) {
      out = withFormValue(out, p, written ? _copy(implies[p]) : null);
    }
    return out;
  }

  /// Состояние формы на теле [body] (без `type`/`tag`; ключи сверх них
  /// не мешают). Значения [fixed] перед вычислением кладутся поверх тела.
  FormState stateOf(Map<String, dynamic> body) {
    final eval = fixed.isEmpty ? body : withFixed(body);
    final visible = <String>[];
    final required = <String>[];
    final missing = <String>[];
    final outOfRange = <FormRangeViolation>[];
    for (final f in fields) {
      final of = f.variantOf;
      if (of != null) {
        final d = formValueAt(eval, '$of.${f.discriminatorKey ?? 'type'}');
        if (d is! String || d.trim() != f.variant) continue;
      }
      if (!f.ancestors.every((a) => _fieldVisible(a, eval))) continue;
      if (!_fieldVisible(f.field, eval)) continue;
      visible.add(f.path);
      if (f.discriminator) continue;
      final present = formPathSet(eval, f.path);
      if (formRequired(f, eval)) {
        required.add(f.path);
        if (!present) missing.add(f.path);
      }
      if (present && (f.min != null || f.max != null)) {
        final v = formValueAt(eval, f.path);
        if (v is num &&
            ((f.min != null && v < f.min!) || (f.max != null && v > f.max!))) {
          outOfRange.add(
            FormRangeViolation(path: f.path, value: v, min: f.min, max: f.max),
          );
        }
      }
    }
    return FormState(
      visible: List.unmodifiable(visible),
      required: List.unmodifiable(required),
      missing: List.unmodifiable(missing),
      choices: {for (final c in choices) c.id: activeFormOption(c, eval)},
      outOfRange: List.unmodifiable(outOfRange),
    );
  }
}

/// Раскладка формы схемы [scheme]; `null` — у схемы нет секции `body.form`
/// (или реестр не загружен).
FormLayout? formLayoutFor(String scheme) {
  final schema = ContractRegistry.I.schemaFor(scheme);
  final form = schema?.form;
  if (schema == null || form == null) return null;
  final choices = [
    for (final c in (form['choices'] as List?) ?? const [])
      if (c is Map) _choiceOf(c.cast<String, dynamic>()),
  ];
  final fixed = <String, Object?>{
    for (final e in ((form['fixed'] as Map?) ?? const {}).entries)
      '${e.key}': e.value,
  };
  final w = _FormWalk(scheme, fixed, choices);
  w.fields('', schema.order, schema.fields, const _Ctx());
  return FormLayout(
    scheme: scheme,
    blocks: List.unmodifiable([
      for (final b in (form['blocks'] as List?) ?? const []) '$b',
    ]),
    fields: List.unmodifiable(w.out),
    choices: List.unmodifiable(choices),
    fixed: Map.unmodifiable(fixed),
  );
}

/// Состояние формы схемы [scheme] на теле [body]; `null` — формы у схемы нет.
FormState? formStateFor(String scheme, Map<String, dynamic> body) =>
    formLayoutFor(scheme)?.stateOf(body);

/// Тело, которое сохраняет форма схемы [scheme] (контракт 1.1.123, §120
/// п. 11): [entry] (`{type, tag, …}`) с наложенным `fixed`, прогнанное
/// санитайзером как НЕавторское (вход `other`). Тело из формы набрано не
/// руками в форме ядра: без прогона мягкие правила реестра (`default_when`
/// и др.) на нём не сработали бы — узел своего сервера с видом источника
/// `singbox_outbound` авторский (PARSING_PRINCIPLES §10), и реестр его не
/// правит. Узел снят санитайзером — [entry] как есть: причину скажет разбор.
Map<String, dynamic> formBodyForSave(
  String scheme,
  Map<String, dynamic> entry,
) {
  final layout = formLayoutFor(scheme);
  final body = layout == null ? _copyMap(entry) : layout.withFixed(entry);
  final res = RegistrySanitizer.sanitize(
    _copyMap(body),
    scheme: scheme,
    coreVersion: '0.0.0',
    applyCoreGates: false,
  );
  return res.body ?? body;
}

/// Активный вариант группы по самому длинному совпадению (контракт 1.1.123):
/// среди вариантов, у которых задан хоть один путь из `paths`, побеждает
/// тот, у кого задано больше путей из `paths` ∪ ключей `set`; при равенстве
/// — первый. Не задан ни один — вариант с пустыми `paths`; нет и его — пусто.
String activeFormOption(FormChoice c, Map<String, dynamic> body) {
  String? fallback;
  String? best;
  var bestScore = 0;
  for (final o in c.options) {
    if (o.paths.isEmpty) {
      fallback ??= o.id;
      continue;
    }
    if (!o.paths.any((p) => formPathSet(body, p))) continue;
    final score = {
      ...o.paths,
      ...o.set.keys,
    }.where((p) => formPathSet(body, p)).length;
    if (score > bestScore) {
      best = o.id;
      bestScore = score;
    }
  }
  return best ?? fallback ?? '';
}

/// Смена варианта группы [c] на [optionId]: пути прочих вариантов снимаются
/// (кроме тех, что выбранный вариант держит в `paths` или пишет `set`),
/// `set` выбранного пишется. Возвращает новое тело; незнакомый вариант —
/// копия без изменений.
Map<String, dynamic> applyFormOption(
  Map<String, dynamic> body,
  FormChoice c,
  String optionId,
) {
  var out = _copyMap(body);
  final chosen = c.option(optionId);
  if (chosen == null) return out;
  for (final o in c.options) {
    if (identical(o, chosen)) continue;
    for (final p in o.paths) {
      if (chosen.paths.contains(p) || chosen.set.containsKey(p)) continue;
      out = withFormValue(out, p, null);
    }
  }
  for (final e in chosen.set.entries) {
    out = withFormValue(out, e.key, e.value);
  }
  return out;
}

/// Действует ли обязательность формы поля [f] на теле [body]: `required`
/// задан и не снят `required_unless` (задан любой путь из `set`, в том числе
/// неописанный, либо в том же объекте не задан любой сосед из `absent`).
bool formRequired(FormFieldSpec f, Map<String, dynamic> body) {
  if (!f.required) return false;
  final ru = f.requiredUnless;
  if (ru == null) return true;
  for (final p in (ru['set'] as List?) ?? const []) {
    if (p is String && formPathSet(body, p)) return false;
  }
  final i = f.path.lastIndexOf('.');
  final prefix = i < 0 ? '' : f.path.substring(0, i + 1);
  for (final n in (ru['absent'] as List?) ?? const []) {
    if (n is String && !formPathSet(body, '$prefix$n')) return false;
  }
  return true;
}

/// Коды `advisory` поля, под которые попадает значение [value] (форма
/// показывает их рядом с полем). Пустое значение кодов не даёт.
List<String> formAdvisoryCodes(
  FormFieldSpec f,
  Object? value,
  Map<String, dynamic> body,
) {
  if (value == null || (value is String && value.isEmpty)) return const [];
  final out = <String>[];
  for (final a in f.field.advisory) {
    final code = a['code'];
    if (code is! String || code.isEmpty) continue;
    final values = a['values'];
    if (values is List && !values.any((x) => '$x' == '$value')) continue;
    final when = a['when'];
    if (when is Map) {
      final p = when['path'];
      if (p is String) {
        final set = formPathSet(body, p);
        if (when['present'] == false ? set : !set) continue;
      }
    }
    if (!out.contains(code)) out.add(code);
  }
  return out;
}

/// Текст поля ввода формы → значение для [withFormValue]. Пустое (после
/// trim) — `null`: ключ не пишется. `int` — число, если текст разбирается;
/// иначе текст как есть (санитайзер и `outOfRange` скажут сами). Секрет не
/// обрезается: пробелы по краям пароля — часть пароля.
Object? formInputValue(FormFieldSpec f, String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (f.secret) return text;
  if (f.type == 'int') return int.tryParse(t) ?? t;
  return t;
}

/// Список через запятую (`tls.peer_fingerprint`) → элементы без пустых.
/// Пустой ввод — пустой список: [withFormValue] ключ не пишет.
List<String> formListInput(String text) => [
  for (final s in text.split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Значение по пути [path] (через точку); `null` — пути нет. Числовой
/// сегмент у массива — индекс элемента (`peers.0.address`, контракт 1.1.123).
Object? formValueAt(Map<String, dynamic> body, String path) {
  Object? cur = body;
  for (final seg in path.split('.')) {
    if (cur is List) {
      final i = _index(seg);
      if (i == null || i >= cur.length) return null;
      cur = cur[i];
      continue;
    }
    if (cur is! Map || !cur.containsKey(seg)) return null;
    cur = cur[seg];
  }
  return cur;
}

/// «Задан» по норме формы: ключ есть, не `null` и не пустая (из пробелов)
/// строка (лаунчер: `bodyValue`).
bool formPathSet(Map<String, dynamic> body, String path) {
  final v = formValueAt(body, path);
  return v != null && !(v is String && v.trim().isEmpty);
}

/// Записать [value] по пути [path]; возвращает новое тело. Пустое значение
/// (`null`, пустая строка, пустой список) ключ НЕ пишет — снимает его; объект,
/// оставшийся пустым после снятия, снимается тоже (массив из одного пустого
/// элемента — тоже). Недостающие объекты создаются; числовой сегмент —
/// элемент массива: нет массива — создаётся, короче индекса — дополняется
/// пустыми объектами (форма правит `[0]`). Прочие ключи тела (в том числе
/// неописанные, скрытые и прочие элементы массива) не трогаются.
Map<String, dynamic> withFormValue(
  Map<String, dynamic> body,
  String path,
  Object? value,
) {
  final out = _copyMap(body);
  final segs = path.split('.');
  if (_isEmptyValue(value)) {
    _remove(out, segs);
    return out;
  }
  _set(out, segs, value);
  return out;
}

bool _isEmptyValue(Object? value) =>
    value == null ||
    (value is String && value.isEmpty) ||
    (value is List && value.isEmpty);

int? _index(String seg) =>
    seg.isNotEmpty && seg.codeUnits.every((c) => c >= 48 && c <= 57)
    ? int.tryParse(seg)
    : null;

void _set(Map<String, dynamic> m, List<String> segs, Object? value) {
  final key = segs.first;
  if (segs.length == 1) {
    m[key] = value;
    return;
  }
  final idx = _index(segs[1]);
  if (idx != null) {
    final cur = m[key];
    final list = cur is List ? cur : <Object?>[];
    while (list.length <= idx) {
      list.add(<String, dynamic>{});
    }
    m[key] = list;
    if (segs.length == 2) {
      list[idx] = value;
      return;
    }
    var elem = list[idx];
    if (elem is! Map<String, dynamic>) {
      elem = <String, dynamic>{};
      list[idx] = elem;
    }
    _set(elem, segs.sublist(2), value);
    return;
  }
  var child = m[key];
  if (child is! Map<String, dynamic>) {
    child = <String, dynamic>{};
    m[key] = child;
  }
  _set(child, segs.sublist(1), value);
}

/// Снять путь; `true` — узел стал пустым и родитель вправе его снять.
bool _remove(Object? node, List<String> segs) {
  if (node is Map<String, dynamic>) {
    final key = segs.first;
    if (segs.length == 1) {
      node.remove(key);
      return node.isEmpty;
    }
    if (!node.containsKey(key)) return false;
    if (_remove(node[key], segs.sublist(1))) node.remove(key);
    return node.isEmpty;
  }
  if (node is List) {
    final i = _index(segs.first);
    // Элемент целиком форма не снимает: индексы соседей сдвинулись бы.
    if (i == null || i >= node.length || segs.length == 1) return false;
    final elem = node[i];
    if (_remove(elem, segs.sublist(1))) {
      return elem is Map && elem.isEmpty && node.length == 1;
    }
  }
  return false;
}

Map<String, dynamic> _copyMap(Map<String, dynamic> m) => {
  for (final e in m.entries) e.key: _copy(e.value),
};

Object? _copy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': _copy(e.value),
    };
  }
  if (v is List) return [for (final e in v) _copy(e)];
  return v;
}

/// `visible_when` поля на теле (без предков). `default` поля в условие не
/// подставляется: отсутствующий `flavor` не равен `fortinet`.
bool _fieldVisible(FieldSchema f, Map<String, dynamic> body) {
  final when = f.form?['visible_when'];
  if (when == null) return true;
  return registryConditionHolds(when, body);
}

/// Состояние обхода формы на уровне объекта.
final class _Ctx {
  const _Ctx({
    this.ancestors = const [],
    this.block,
    this.variant,
    this.variantOf,
    this.discriminatorKey,
  });

  final List<FieldSchema> ancestors;

  /// Блок ref-поля, подключившего общую секцию.
  final String? block;
  final String? variant;
  final String? variantOf;
  final String? discriminatorKey;

  _Ctx under(FieldSchema f, {String? block}) => _Ctx(
    ancestors: List.unmodifiable([...ancestors, f]),
    block: block ?? this.block,
    variant: variant,
    variantOf: variantOf,
    discriminatorKey: discriminatorKey,
  );
}

/// Обход полей формы схемы (лаунчер: `formWalk`, контракт 1.1.123): общие
/// секции входят только через `form` ref-поля, поле, запрещённое схеме
/// (`forbidden_for`/`allowed_for`), и пути `exclude_fields` отпадают с
/// поддеревом, у вариантной секции — дискриминатор и поля всех вариантов
/// без `exclude_variants`, у массива объектов с `form` — элемент `[0]`. Пути
/// `fixed` форма не рисует (обход в них спускается).
final class _FormWalk {
  _FormWalk(this.scheme, this.fixed, List<FormChoice> choices) {
    for (final c in choices) {
      for (final o in c.options) {
        for (final p in o.paths) {
          _option[p] = (c.id, o.id);
        }
      }
    }
  }

  final String scheme;
  final Map<String, Object?> fixed;
  final Set<String> _excluded = {};
  final Map<String, (String, String)> _option = {};
  final List<FormFieldSpec> out = [];

  void fields(
    String prefix,
    List<String> order,
    Map<String, FieldSchema> fields,
    _Ctx ctx,
  ) {
    for (final name in order) {
      // Wildcard `*` — не поле: в `fields` его нет, обход его пропускает.
      final f = fields[name];
      if (f == null || f.managed) continue;
      final path = prefix.isEmpty ? name : '$prefix.$name';
      if (_excluded.contains(path) || !f.allowedForScheme(scheme)) continue;
      _field(path, f, ctx);
    }
  }

  void _field(String path, FieldSchema f, _Ctx ctx) {
    final form = f.form;
    final shared = f.originRef != null && f.type == 'object';
    // Общая секция без `form` у ref-поля в форму схемы не входит.
    if (shared && form == null) return;
    var block = ctx.block;
    if (shared) {
      block = (form!['block'] as String?) ?? block;
      for (final x in (form['exclude_fields'] as List?) ?? const []) {
        _excluded.add('$path.$x');
      }
    }
    if (form != null && !fixed.containsKey(path)) {
      _add(path, f, ctx, (form['block'] as String?) ?? block);
    }
    final inner = ctx.under(f, block: block);
    final variants = f.variants;
    if (variants != null) {
      if (form == null) return;
      final disc = f.discriminator ?? 'type';
      final dpath = '$path.$disc';
      final excluded = {
        for (final v in (form['exclude_variants'] as List?) ?? const []) '$v',
      };
      final names = [
        for (final v in f.variantValues)
          if (!excluded.contains(v)) v,
      ];
      if (!fixed.containsKey(dpath)) {
        out.add(
          FormFieldSpec(
            path: dpath,
            field: FieldSchema({
              'type': 'enum',
              'values': ['', ...names],
              'form': {'block': ?block},
            }),
            ancestors: inner.ancestors,
            block: block,
            discriminator: true,
          ),
        );
      }
      for (final name in names) {
        final v = variants[name];
        if (v == null) continue;
        fields(
          path,
          v.order ?? const [],
          v.fields ?? const {},
          _Ctx(
            ancestors: inner.ancestors,
            block: block,
            variant: name,
            variantOf: path,
            discriminatorKey: disc,
          ),
        );
      }
      return;
    }
    final nested = f.fields;
    if (f.type == 'object' && nested != null && nested.isNotEmpty) {
      fields(path, f.order ?? nested.keys.toList(), nested, inner);
      return;
    }
    final items = f.items;
    final itemFields = items?.fields;
    if (f.type == 'array' &&
        form != null &&
        itemFields != null &&
        itemFields.isNotEmpty) {
      // Массив объектов с `form`: форма правит элемент [0].
      fields(
        '$path.0',
        items!.order ?? itemFields.keys.toList(),
        itemFields,
        inner,
      );
    }
  }

  void _add(String path, FieldSchema f, _Ctx ctx, String? block) {
    final opt = _option[path];
    out.add(
      FormFieldSpec(
        path: path,
        field: f,
        ancestors: ctx.ancestors,
        block: block,
        variant: ctx.variant,
        variantOf: ctx.variantOf,
        discriminatorKey: ctx.discriminatorKey,
        choiceId: opt?.$1,
        optionId: opt?.$2,
      ),
    );
  }
}

FormChoice _choiceOf(Map<String, dynamic> c) => FormChoice(
  id: '${c['id'] ?? ''}',
  block: c['block'] as String?,
  options: [
    for (final o in (c['options'] as List?) ?? const [])
      if (o is Map)
        FormChoiceOption(
          id: '${o['id'] ?? ''}',
          paths: [for (final p in (o['paths'] as List?) ?? const []) '$p'],
          set: {
            for (final e in ((o['set'] as Map?) ?? const {}).entries)
              '${e.key}': e.value,
          },
        ),
  ],
);
