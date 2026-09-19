/// §480 W1 — МОДЕЛЬ СЕКЦИИ-МАППЕРА: JSON реестра в типизированную форму.
///
/// Имена атрибутов — СТРОГО по SPEC 133 `PRIMITIVES.md` §0 (грамматика
/// заморожена 19.09.2026, sha `4a3dbf3f`) и машиночитаемой
/// `contract/schema/registry_mapper.schema.json` (`f43f86fe`). Своих имён у
/// нас нет: разъехавшееся имя — это молчаливое расхождение двух приложений,
/// то есть ровно то, ради чего затеяна кампания.
///
/// DRAFT-примитивы (§0.7: `ini_dialect`, `ini.$comment.<Section>`, `$base`,
/// служебные `$`-записи, `emit.form_from`, `round_trip: false`, `unwrap`)
/// изолированы в [DraftNames] — одно место на всю их поверхность, чтобы
/// переименование у лаунчера правилось одной правкой.
library;

/// §0.7 DRAFT — имена, которые лаунчер может переименовать.
///
/// Вынесены сюда все разом, а не разбросаны по коду: это и есть «изолировать
/// чтение draft-примитивов в одном месте». Ни одно из них не является именем
/// схемы или протокола — греп-страж `engine_no_scheme_names_test.dart` это
/// проверяет.
abstract final class DraftNames {
  /// Префикс служебной записи без `maps_to` (`$multiport`, `$plaintext_port`).
  /// Такая запись в документацию не идёт и параметром источника не считается.
  static const serviceParamPrefix = r'$';

  /// Якорь пути формы, подставляемый в `source` вместо префикса.
  static const baseAnchor = r'$base';

  /// Источник «значение из комментария секции INI» (G7).
  static const iniCommentPrefix = r'ini.$comment.';

  /// Диалект INI-разбора у секции вида источника `conf`.
  static const iniDialect = 'ini_dialect';

  /// Выбор формы эмита по телу (W7).
  static const emitFormFrom = 'form_from';

  /// Оболочка-распаковщик у вида источника.
  static const unwrap = 'unwrap';
}

/// Форма источника (P1, FROZEN `forms[]`).
final class MapperForm {
  const MapperForm({
    required this.id,
    this.detect,
    this.decode = const [],
    this.space = 'url',
    this.base,
    this.level,
  });

  factory MapperForm.fromJson(Map<String, dynamic> j) => MapperForm(
        id: j['id'] as String? ?? '',
        detect: (j['detect'] as Map?)?.cast<String, dynamic>(),
        decode: ((j['decode'] as List?) ?? const []).toList(),
        space: j['space'] as String? ?? 'url',
        base: j['base'] as String?,
        level: j['level'] as String?,
      );

  final String id;
  final Map<String, dynamic>? detect;

  /// Конвейер декодеров оболочки: `url`, `percent`, `base64`, `base64url`,
  /// `base64?`, `json`, `ini`, `{reparse: url|authority}`.
  final List<dynamic> decode;

  /// Итоговое пространство источников: `url` | `json` | `ini`.
  final String space;

  /// DRAFT `$base` — якорь пути (xray, W5).
  final String? base;

  /// Уровень документа sing-box: `outbound` | `endpoint`.
  final String? level;
}

/// Наложенное пространство источников (FROZEN `overlays[]`, контракт 1.1.15).
///
/// Вложенный слой чужого диалекта, адресуемый в `source` своим префиксом
/// (`extra.scMaxEachPostBytes`). Слой держится ОТДЕЛЬНО от query, а не
/// сливается с ним, потому что «кто из двух побеждает» обязана решать сама
/// запись порядком своих источников: у части полей сильнее слой, у части —
/// плоский слой, причём даже будучи пустым.
final class OverlaySpec {
  const OverlaySpec({
    required this.name,
    this.source = const [],
    this.decode = const [],
    this.flatten = const [],
  });

  factory OverlaySpec.fromJson(Map<String, dynamic> j) => OverlaySpec(
        name: j['name'] as String? ?? '',
        source: _stringList(j['source'], fallback: const []),
        decode: ((j['decode'] as List?) ?? const []).cast<String>(),
        flatten: ((j['flatten'] as List?) ?? const []).cast<String>(),
      );

  /// Префикс, под которым слой адресуется в `source`.
  final String name;

  /// Откуда берётся ТЕКСТ слоя.
  final List<String> source;

  /// Конвейер декодеров текста: `percent`, `base64?`, `base64`.
  final List<String> decode;

  /// Вложенные объекты слоя, чьи члены поднимаются в плоский слой.
  final List<String> flatten;
}

/// Разбор userinfo (P2, FROZEN `userinfo`).
final class UserinfoSpec {
  const UserinfoSpec({
    this.decode = const [],
    this.splitSep,
    this.splitLimit,
    this.into = const [],
    this.singleInto,
    this.required = false,
  });

  factory UserinfoSpec.fromJson(Map<String, dynamic> j) {
    final split = (j['split'] as Map?)?.cast<String, dynamic>();
    return UserinfoSpec(
      required: j['required'] as bool? ?? false,
      decode: ((j['decode'] as List?) ?? const []).cast<String>(),
      splitSep: split?['sep'] as String?,
      // `limit: 2` — резать по ПЕРВОМУ разделителю: иначе пароль с двоеточием
      // теряется (живой дефект у лаунчера).
      splitLimit: (split?['limit'] as num?)?.toInt(),
      into: ((j['into'] as List?) ?? const []).cast<String>(),
      singleInto: j['single_into'] as String?,
    );
  }

  final List<String> decode;
  final String? splitSep;
  final int? splitLimit;
  final List<String> into;
  final String? singleInto;

  /// `required: true` — ссылка БЕЗ userinfo не узел этой схемы: элемент
  /// отбраковывается целиком. Судит ОБОЛОЧКУ, а не запись таблицы, поэтому
  /// объявлен здесь: поля, которые userinfo наполняет, приходят позициями
  /// `into`, и записи под ними у части схем нет вовсе.
  final bool required;
}

/// Метка узла (P11, FROZEN `label`).
final class LabelSpec {
  const LabelSpec({
    this.source = const ['fragment'],
    this.normalize = const [],
    this.valueMap = const {},
    this.fallbackTemplate,
    this.fallbackSchemeSource = 'singbox_type',
    this.fallbackScheme,
    this.fallbackServerPath,
    this.fallbackPortPath,
  });

  factory LabelSpec.fromJson(Map<String, dynamic> j) {
    final fb = (j['fallback'] as Map?)?.cast<String, dynamic>();
    return LabelSpec(
      source: _stringList(j['source'], fallback: const ['fragment']),
      normalize: ((j['normalize'] as List?) ?? const []).cast<String>(),
      valueMap: ((j['value_map'] as Map?) ?? const {}).cast<String, dynamic>(),
      fallbackTemplate: fb?['template'] as String?,
      // §0.5 FROZEN — решение владельца: `singbox_type`. У схем, где написание
      // ссылки и тип тела совпадают, разницы нет; там, где нет (`hy2`, `ss`),
      // это решение переименовывает узлы и оформляется дельтой своей волной.
      fallbackSchemeSource: fb?['scheme_source'] as String? ?? 'singbox_type',
      // `scheme` — ЯВНОЕ написание имени в теге-фолбэке безымянного узла,
      // когда оно не равно типу тела. Совпадений нет у двух протоколов, и
      // обе разницы историчны: прежние ветки этого входа звали фолбэк
      // короткой формой. Тег И ЕСТЬ identity (`node_hash.dart`), поэтому
      // написание объявлено ДАННЫМИ, а не остаётся свойством кода: возьми
      // конвейер имя типа, у живых безымянных узлов слетели бы выбор,
      // отключения и цепочки.
      fallbackScheme: fb?['scheme'] as String?,
      // Где в ТЕЛЕ лежит адрес, которым шаблон фолбэка заполняет `{server}` и
      // `{server_port}`. По умолчанию корень (`server`/`server_port`), но у
      // схем уровня `endpoint` корневого адреса не бывает вовсе — он лежит в
      // элементе массива. Объявляется ДАННЫМИ: тег и есть identity, и
      // «откуда брать адрес» — свойство формы тела, а не ветка в коде.
      fallbackServerPath: fb?['server_path'] as String?,
      fallbackPortPath: fb?['port_path'] as String?,
    );
  }

  final List<String> source;
  final List<String> normalize;
  final Map<String, dynamic> valueMap;
  final String? fallbackTemplate;
  final String fallbackSchemeSource;
  final String? fallbackScheme;
  final String? fallbackServerPath;
  final String? fallbackPortPath;
}

/// Правила списка (P9, FROZEN `list`).
final class ListSpec {
  const ListSpec({this.sep = ',', this.item, this.len, this.coerceScalar = false});

  factory ListSpec.fromJson(Map<String, dynamic> j) => ListSpec(
        sep: j['sep'] as String? ?? ',',
        item: j['item'] as String?,
        len: (j['len'] as num?)?.toInt(),
        coerceScalar: j['coerce_scalar'] as bool? ?? false,
      );

  final String sep;
  final String? item;
  final int? len;
  final bool coerceScalar;
}

/// Правила повторного percent-декода (FROZEN `decode_extra`).
final class DecodeExtraSpec {
  const DecodeExtraSpec({
    this.mode = 'query',
    this.passes,
    this.untilStable = false,
    this.max = 16,
    this.plusLiteral,
  });

  factory DecodeExtraSpec.fromJson(Map<String, dynamic> j) {
    final p = j['passes'];
    return DecodeExtraSpec(
      mode: j['mode'] as String? ?? 'query',
      passes: p is num ? p.toInt() : null,
      untilStable: p == 'until_stable',
      max: (j['max'] as num?)?.toInt() ?? 16,
      plusLiteral: j['plus_literal'] as bool?,
    );
  }

  final String mode;
  final int? passes;
  final bool untilStable;
  final int max;

  /// `null` — не указано явно, выводится из `format: base64*` поля (§0.4).
  final bool? plusLiteral;
}

/// Раскладка одного значения по нескольким путям (P8, FROZEN `extract`).
final class ExtractSpec {
  const ExtractSpec({required this.re, this.into = const {}});

  factory ExtractSpec.fromJson(Map<String, dynamic> j) => ExtractSpec(
        re: j['re'] as String? ?? '',
        into: ((j['into'] as Map?) ?? const {}).cast<String, dynamic>(),
      );

  final String re;

  /// Имя группы → путь тела (строкой) либо объект с `path`/`type`/`implies`.
  final Map<String, dynamic> into;
}

/// Запись таблицы: один параметр источника (FROZEN `params.<имя>`).
final class MapperParam {
  const MapperParam({
    required this.name,
    this.source = const [],
    this.sourceByForm = const {},
    this.mapsTo,
    this.mapsToPresent = false,
    this.aliases = const [],
    this.type,
    this.required = false,
    this.selector = false,
    this.priority,
    this.merge,
    this.valueMap = const {},
    this.sets = const {},
    this.implies = const {},
    this.when = const {},
    this.extract,
    this.compose,
    this.list,
    this.splitInto = const {},
    this.normalize,
    this.decodeExtra,
    this.defaultFrom = const [],
    this.defaultWhen = const {},
    this.materializeDefault = false,
    this.coerceObjectToScalar,
    this.coerceScalarToList = false,
    this.flatten = const [],
    this.lift,
    this.sortKeys = false,
    this.empty = 'absent',
    this.format,
    this.onInvalid = const {},
    this.onPresent = const {},
    this.onLenGt = const {},
    this.onNoMatch = const {},
    this.onWhenFalse = const {},
    this.onImpliesWritten = const {},
    this.onItemInvalid = const {},
    this.valueMapCase,
    this.implicit = false,
    this.raw = const {},
  });

  factory MapperParam.fromJson(String name, Map<String, dynamic> j) {
    final srcRaw = j['source'];
    var source = <String>[];
    var byForm = <String, List<String>>{};
    if (srcRaw is String) {
      source = [srcRaw];
    } else if (srcRaw is List) {
      source = srcRaw.cast<String>();
    } else if (srcRaw is Map) {
      byForm = srcRaw.map((k, v) =>
          MapEntry(k as String, _stringList(v, fallback: const [])));
    }

    final coerce = (j['coerce'] as Map?)?.cast<String, dynamic>();
    final de = (j['decode_extra'] as Map?)?.cast<String, dynamic>();
    final ex = (j['extract'] as Map?)?.cast<String, dynamic>();
    final ls = (j['list'] as Map?)?.cast<String, dynamic>();

    return MapperParam(
      name: name,
      source: source,
      sourceByForm: byForm,
      mapsTo: j['maps_to'] as String?,
      // `maps_to: null` — ЗАЯВЛЕННОЕ «никуда не едет» (ech, padding). От
      // «ключа нет вовсе» отличается тем, что параметр объявлен и в
      // `uri_param_unknown` не попадает.
      mapsToPresent: j.containsKey('maps_to'),
      aliases: ((j['aliases'] as List?) ?? const []).cast<String>(),
      type: j['type'] as String?,
      required: j['required'] as bool? ?? false,
      selector: j['selector'] as bool? ?? false,
      priority: (j['priority'] as num?)?.toInt(),
      merge: j['merge'] as String?,
      valueMap: ((j['value_map'] as Map?) ?? const {}).cast<String, dynamic>(),
      sets: ((j['sets'] as Map?) ?? const {}).cast<String, dynamic>(),
      implies: ((j['implies'] as Map?) ?? const {}).cast<String, dynamic>(),
      when: ((j['when'] as Map?) ?? const {}).cast<String, dynamic>(),
      extract: ex == null ? null : ExtractSpec.fromJson(ex),
      compose: j['compose'] as String?,
      list: ls == null ? null : ListSpec.fromJson(ls),
      splitInto:
          ((j['split_into'] as Map?) ?? const {}).cast<String, dynamic>(),
      normalize: j['normalize'] as String?,
      decodeExtra: de == null ? null : DecodeExtraSpec.fromJson(de),
      defaultFrom: _stringList(j['default_from'], fallback: const []),
      defaultWhen:
          ((j['default_when'] as Map?) ?? const {}).cast<String, dynamic>(),
      materializeDefault: j['materialize_default'] as bool? ?? false,
      coerceObjectToScalar: coerce?['object_to_scalar'] as String?,
      coerceScalarToList: coerce?['scalar_to_list'] as bool? ?? false,
      flatten: ((j['flatten'] as List?) ?? const []).cast<String>(),
      lift: j['lift'] as String?,
      sortKeys: j['sort_keys'] as bool? ?? false,
      empty: j['empty'] as String? ?? 'absent',
      format: j['format'] as String?,
      onInvalid:
          ((j['on_invalid'] as Map?) ?? const {}).cast<String, dynamic>(),
      onPresent:
          ((j['on_present'] as Map?) ?? const {}).cast<String, dynamic>(),
      onLenGt:
          ((j['on_len_gt'] as Map?) ?? const {}).cast<String, dynamic>(),
      onNoMatch:
          ((j['on_no_match'] as Map?) ?? const {}).cast<String, dynamic>(),
      onWhenFalse:
          ((j['on_when_false'] as Map?) ?? const {}).cast<String, dynamic>(),
      onImpliesWritten: ((j['on_implies_written'] as Map?) ?? const {})
          .cast<String, dynamic>(),
      onItemInvalid:
          ((j['on_item_invalid'] as Map?) ?? const {}).cast<String, dynamic>(),
      valueMapCase: j['value_map_case'] as String?,
      implicit: j['implicit'] as bool? ?? false,
      raw: j,
    );
  }

  final String name;
  final List<String> source;
  final Map<String, List<String>> sourceByForm;
  final String? mapsTo;
  final bool mapsToPresent;
  final List<String> aliases;
  final String? type;
  final bool required;
  final bool selector;
  final int? priority;
  final String? merge;
  final Map<String, dynamic> valueMap;
  final Map<String, dynamic> sets;
  final Map<String, dynamic> implies;
  final Map<String, dynamic> when;
  final ExtractSpec? extract;
  final String? compose;
  final ListSpec? list;
  final Map<String, dynamic> splitInto;
  final String? normalize;
  final DecodeExtraSpec? decodeExtra;
  final List<String> defaultFrom;
  final Map<String, dynamic> defaultWhen;
  final bool materializeDefault;
  final String? coerceObjectToScalar;
  final bool coerceScalarToList;
  final List<String> flatten;
  final String? lift;
  final bool sortKeys;
  final String empty;

  /// Формат значения поля; из `base64*` выводится `decode_extra.plus_literal`
  /// (§0.4 FROZEN) — то самое «исключение из реестра, а не из списка имён».
  final String? format;
  final Map<String, dynamic> onInvalid;
  final Map<String, dynamic> onPresent;

  /// `on_len_gt: {n, action, code}` — у источника-МАССИВА больше `n`
  /// элементов, и лишние отбрасываются. Сегодня это молчаливая потеря
  /// (Q133-18: второй сервер подписки просто исчезает); запись даёт ей код,
  /// не меняя поведения.
  final Map<String, dynamic> onLenGt;

  /// `on_no_match: {action, code}` — значение не попало ни в один ключ
  /// `sets`/`value_map`. `action: drop_node` снимает узел целиком.
  final Map<String, dynamic> onNoMatch;

  /// `on_when_false: {action, code}` — код за ПОДАВЛЕНИЕ значения условием
  /// `when`: во входе значение было, но структурное правило не дало ему
  /// доехать до тела. Ставится только когда источник действительно ответил —
  /// иначе запись, чьё условие ложно на каждом втором узле, шумела бы впустую.
  final Map<String, dynamic> onWhenFalse;

  /// `on_implies_written: {action, code}` — код за то, что `implies` и вправду
  /// ДОПИСАЛ значение, которого во входе не было. Отличается от простого
  /// наличия `implies`: при занятом пути присваивание проигрывает владельцу,
  /// и сообщать не о чем.
  final Map<String, dynamic> onImpliesWritten;

  /// `on_item_invalid: {action, code}` — элемент списка не совпал с
  /// регуляркой `extract` и пропущен. Код ставится ОДИН раз на узел, сколько
  /// бы элементов ни отсеялось.
  final Map<String, dynamic> onItemInvalid;

  /// `value_map_case: "sensitive"` — регистр значения ЗНАЧИМ. Общее правило
  /// обратное (живые списки шлют `NONE`), но там, где ядро сравнивает литерал
  /// точно, регистронезависимое попадание молча проглатывало бы негодное
  /// значение вместо того, чтобы дать ему доехать до тела и быть отвергнутым.
  final String? valueMapCase;

  final bool implicit;

  /// §480 W7 — СЫРОЙ JSON записи.
  ///
  /// Нужен ЭМИТТЕРУ: атрибуты обратного хода (`emit_as`, `emit_name`,
  /// `round_trip`) ещё не в замороженной грамматике, имена могут поменяться по
  /// итогам согласования с лаунчером, и заводить под каждое типизированное
  /// поле значило бы править модель на каждом переименовании. Читаются они в
  /// ОДНОМ месте — `emitter.dart`, через [EmitNames].
  final Map<String, dynamic> raw;

  /// Служебная запись (DRAFT `$`-префикс): у неё нет `maps_to`, и параметром
  /// источника она не считается.
  bool get isService => name.startsWith(DraftNames.serviceParamPrefix);

  /// `+` читается буквально: явное указание либо вывод из формата.
  bool get plusLiteral =>
      decodeExtra?.plusLiteral ?? (format?.startsWith('base64') ?? false);

  /// Все написания имени параметра: канон плюс алиасы. Канон — первое (§0.6).
  Iterable<String> get spellings sync* {
    yield name;
    yield* aliases;
  }
}

/// Одна секция-маппер: вид источника у одного протокола (FROZEN `mapper`).
final class MapperSection {
  const MapperSection({
    required this.kind,
    required this.singboxType,
    this.detect,
    this.bodySource = 'uri',
    this.forms = const [],
    this.userinfo,
    this.label = const LabelSpec(),
    this.params = const {},
    this.include = const [],
    this.overlays = const [],
    this.schemeSets = const {},
    this.typeSynonyms = const {},
    this.defaults = const {},
    this.unknownKeyAction = 'drop',
    this.unknownKeyCode,
    this.ignoredKeys = const {},
    this.emit,
  });

  factory MapperSection.fromJson(
    String kind,
    String singboxType,
    Map<String, dynamic> j,
  ) {
    final uk = (j['unknown_key'] as Map?)?.cast<String, dynamic>();
    final params = <String, MapperParam>{};
    final rawParams = (j['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final e in rawParams.entries) {
      params[e.key] =
          MapperParam.fromJson(e.key, (e.value as Map).cast<String, dynamic>());
    }
    return MapperSection(
      kind: kind,
      singboxType: singboxType,
      detect: (j['detect'] as Map?)?.cast<String, dynamic>(),
      bodySource: j['body_source'] as String? ?? 'uri',
      forms: ((j['forms'] as List?) ?? const [])
          .map((f) => MapperForm.fromJson((f as Map).cast<String, dynamic>()))
          .toList(),
      userinfo: j['userinfo'] == null
          ? null
          : UserinfoSpec.fromJson((j['userinfo'] as Map).cast<String, dynamic>()),
      label: j['label'] == null
          ? const LabelSpec()
          : LabelSpec.fromJson((j['label'] as Map).cast<String, dynamic>()),
      params: params,
      include: ((j['include'] as List?) ?? const []).cast<String>(),
      overlays: ((j['overlays'] as List?) ?? const [])
          .map((o) => OverlaySpec.fromJson((o as Map).cast<String, dynamic>()))
          .toList(),
      schemeSets:
          ((j['scheme_sets'] as Map?) ?? const {}).cast<String, dynamic>(),
      typeSynonyms:
          ((j['type_synonyms'] as Map?) ?? const {}).cast<String, String>(),
      defaults: ((j['defaults'] as Map?) ?? const {}).cast<String, dynamic>(),
      unknownKeyAction: uk?['action'] as String? ?? 'drop',
      unknownKeyCode: uk?['code'] as String?,
      ignoredKeys:
          ((uk?['ignore'] as List?) ?? const []).cast<String>().toSet(),
      emit: (j['emit'] as Map?)?.cast<String, dynamic>(),
    );
  }

  /// Вид источника: `uri` | `xray` | `singbox` | `conf`.
  final String kind;

  /// Тип тела (`type` в карте sing-box) — его секция и строит.
  final String singboxType;

  final Map<String, dynamic>? detect;
  final String bodySource;
  final List<MapperForm> forms;
  final UserinfoSpec? userinfo;
  final LabelSpec label;
  final Map<String, MapperParam> params;
  final List<String> include;

  /// Наложенные пространства источников (FROZEN `overlays[]`).
  final List<OverlaySpec> overlays;
  final Map<String, dynamic> schemeSets;
  final Map<String, String> typeSynonyms;
  final Map<String, dynamic> defaults;
  final String unknownKeyAction;
  final String? unknownKeyCode;

  /// `unknown_key.ignore` — ключи УРОВНЯ ДОКУМЕНТА, которые полем узла не
  /// являются и неизвестными не считаются: бухгалтерия элемента
  /// (`protocol`/`type` — по ним элемент и опознан, `tag`, `remarks` — имя,
  /// которое читает сборка документа, а не маппер одного узла).
  final Set<String> ignoredKeys;

  final Map<String, dynamic>? emit;

  /// Секция с вмонтированными блоками `include` (общие tls/transports).
  MapperSection withParams(Map<String, MapperParam> merged) => MapperSection(
        kind: kind,
        singboxType: singboxType,
        detect: detect,
        bodySource: bodySource,
        forms: forms,
        userinfo: userinfo,
        label: label,
        params: merged,
        include: include,
        overlays: overlays,
        schemeSets: schemeSets,
        typeSynonyms: typeSynonyms,
        defaults: defaults,
        unknownKeyAction: unknownKeyAction,
        unknownKeyCode: unknownKeyCode,
        ignoredKeys: ignoredKeys,
        emit: emit,
      );
}

List<String> _stringList(dynamic v, {required List<String> fallback}) {
  if (v is String) return [v];
  if (v is List) return v.cast<String>();
  return fallback;
}
