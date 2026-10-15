/// Контракт 1.1.122 (`TASKS_LXBOX.md` §119 п. 5, `REGISTRY_DESIGN.md` §3
/// SPEC 167 лаунчера) — модель формы узла по реестру.
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

import 'body_sanitizer.dart' show registryConditionHolds;
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
  });

  /// Путь от корня тела через точку (`tls.server_name`).
  final String path;

  /// Описание поля реестра (тип, `values`, `default`, `secret`, `advisory`).
  final FieldSchema field;

  /// Поля-объекты над этим полем, от корня. Скрытый предок скрывает
  /// поддерево.
  final List<FieldSchema> ancestors;

  Map<String, dynamic> get _form => field.form ?? const {};

  /// Блок формы (id из [FormLayout.blocks]); `null` — поле рисует группа
  /// выбора ([FormLayout.choices]), а не блок.
  String? get block => _form['block'] as String?;

  /// Условие видимости (грамматика `condition`); `null` — видно всегда.
  Object? get visibleWhen => _form['visible_when'];

  /// `form.required` — без снятия `required_unless` (см. [FormState.required]).
  bool get required => _form['required'] == true;

  Map<String, dynamic>? get requiredUnless =>
      (_form['required_unless'] as Map?)?.cast<String, dynamic>();

  /// Диапазон формы. Пустое поле границей не судится (ключ не пишется).
  num? get min => _form['min'] as num?;

  num? get max => _form['max'] as num?;

  /// Тип поля реестра: `string`, `int`, `bool`, `enum`, `duration`,
  /// `listable_string`, `object`, …
  String get type => field.type;

  /// Допустимые значения `enum`.
  List<Object?>? get values => field.values;

  bool get secret => field.secret;

  /// `default` поля реестра — подсказка формы; в тело не пишется.
  Object? get defaultValue => field.defaultValue;

  bool get isObject => type == 'object';
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
  });

  /// `type` записи sing-box (`openconnect`).
  final String scheme;

  /// id блоков по порядку (`connection`, `security`, `advanced`).
  final List<String> blocks;

  /// Все поля с `form`, в порядке обхода `order` (вглубь).
  final List<FormFieldSpec> fields;

  final List<FormChoice> choices;

  FormFieldSpec? field(String path) {
    for (final f in fields) {
      if (f.path == path) return f;
    }
    return null;
  }

  /// Поля блока [block] в порядке `order` (поля групп выбора сюда не
  /// входят: у них нет `block`).
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

  /// Состояние формы на теле [body] (без `type`/`tag`; ключи сверх них
  /// не мешают).
  FormState stateOf(Map<String, dynamic> body) {
    final visible = <String>[];
    final required = <String>[];
    final missing = <String>[];
    final outOfRange = <FormRangeViolation>[];
    for (final f in fields) {
      if (!f.ancestors.every((a) => _fieldVisible(a, body))) continue;
      if (!_fieldVisible(f.field, body)) continue;
      visible.add(f.path);
      final present = formPathSet(body, f.path);
      if (formRequired(f, body)) {
        required.add(f.path);
        if (!present) missing.add(f.path);
      }
      if (present && (f.min != null || f.max != null)) {
        final v = formValueAt(body, f.path);
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
      choices: {for (final c in choices) c.id: activeFormOption(c, body)},
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
  final fields = <FormFieldSpec>[];
  _walk(fields, '', schema.order, schema.fields, const []);
  return FormLayout(
    scheme: scheme,
    blocks: List.unmodifiable([
      for (final b in (form['blocks'] as List?) ?? const []) '$b',
    ]),
    fields: List.unmodifiable(fields),
    choices: List.unmodifiable([
      for (final c in (form['choices'] as List?) ?? const [])
        if (c is Map) _choiceOf(c.cast<String, dynamic>()),
    ]),
  );
}

/// Состояние формы схемы [scheme] на теле [body]; `null` — формы у схемы нет.
FormState? formStateFor(String scheme, Map<String, dynamic> body) =>
    formLayoutFor(scheme)?.stateOf(body);

/// Активный вариант группы: первый, у которого задан хоть один путь из
/// `paths`; не задан ни один — вариант с пустыми `paths`; нет и его — пусто.
String activeFormOption(FormChoice c, Map<String, dynamic> body) {
  String? fallback;
  for (final o in c.options) {
    if (o.paths.isEmpty) {
      fallback ??= o.id;
      continue;
    }
    if (o.paths.any((p) => formPathSet(body, p))) return o.id;
  }
  return fallback ?? '';
}

/// Смена варианта группы [c] на [optionId]: пути прочих вариантов снимаются,
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
      if (chosen.paths.contains(p)) continue;
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

/// Значение по пути [path] (через точку); `null` — пути нет.
Object? formValueAt(Map<String, dynamic> body, String path) {
  Object? cur = body;
  for (final seg in path.split('.')) {
    if (cur is! Map || !cur.containsKey(seg)) return null;
    cur = cur[seg];
  }
  return cur;
}

/// «Задан» по норме формы: ключ есть, не `null` и не пустая строка.
bool formPathSet(Map<String, dynamic> body, String path) {
  final v = formValueAt(body, path);
  return v != null && !(v is String && v.isEmpty);
}

/// Записать [value] по пути [path]; возвращает новое тело. Пустое значение
/// (`null`, пустая строка, пустой список) ключ НЕ пишет — снимает его; объект,
/// оставшийся пустым после снятия, снимается тоже. Прочие ключи тела (в том
/// числе неописанные и скрытые) не трогаются.
Map<String, dynamic> withFormValue(
  Map<String, dynamic> body,
  String path,
  Object? value,
) {
  final out = _copyMap(body);
  final segs = path.split('.');
  final empty =
      value == null ||
      (value is String && value.isEmpty) ||
      (value is List && value.isEmpty);
  if (empty) {
    _remove(out, segs);
    return out;
  }
  var cur = out;
  for (final seg in segs.take(segs.length - 1)) {
    final next = cur[seg];
    if (next is Map<String, dynamic>) {
      cur = next;
    } else {
      final m = <String, dynamic>{};
      cur[seg] = m;
      cur = m;
    }
  }
  cur[segs.last] = value;
  return out;
}

void _remove(Map<String, dynamic> m, List<String> segs) {
  if (segs.length == 1) {
    m.remove(segs.single);
    return;
  }
  final next = m[segs.first];
  if (next is! Map<String, dynamic>) return;
  _remove(next, segs.sublist(1));
  if (next.isEmpty) m.remove(segs.first);
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

void _walk(
  List<FormFieldSpec> out,
  String prefix,
  List<String> order,
  Map<String, FieldSchema> fields,
  List<FieldSchema> ancestors,
) {
  for (final name in order) {
    // Wildcard `*` — не поле: в `fields` его нет, обход его пропускает.
    final f = fields[name];
    if (f == null || f.managed) continue;
    final path = prefix.isEmpty ? name : '$prefix.$name';
    if (f.form != null) {
      out.add(FormFieldSpec(path: path, field: f, ancestors: ancestors));
    }
    final nested = f.fields;
    if (f.type == 'object' && nested != null && nested.isNotEmpty) {
      _walk(
        out,
        path,
        f.order ?? nested.keys.toList(),
        nested,
        List.unmodifiable([...ancestors, f]),
      );
    }
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
