/// §460 W1 — реестр контракта в приложении: схема тела узла и тексты кодов.
///
/// Контракт 1.1.0 (`TASKS_LXBOX.md` §24) вынес схему тела 384 полей из
/// структур ядра `1.14.1-lx.4` в `registry/`. Раньше правила «какое поле у
/// какого протокола допустимо» жили рукописными таблицами в Dart по
/// протоколу и расходились с лаунчером и с ядром на каждом пине. Теперь
/// реестр едет в assets, и по нему работает [RegistrySanitizer].
///
/// Слой: сервис без Flutter-зависимостей по существу — `rootBundle` спрятан
/// за [AssetLoader], поэтому юнит-тесты грузят реестр с диска
/// ([ContractRegistry.loadFromDirectory]) и биндинга не требуют.
///
/// Файлы читаются из `assets/contract/` — зеркала вендоренной копии
/// `app/contract/`, которое кладёт `tool/sync_contract.sh`. Зеркало в git
/// (в отличие от копии), потому что сборка без репозитория лаунчера (CI,
/// F-Droid) обязана собираться.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// Чтение файла реестра. Инъекция ради тестов: прод читает `rootBundle`,
/// тест — файловую систему, и сервис остаётся свободен от биндинга.
typedef AssetLoader = Future<String> Function(String path);

/// Схемы-ссылки (`ref`), которые тело узла разворачивает по имени.
const _kSharedRefs = <String, String>{
  'tls': 'tls.json',
  'transports': 'transports.json',
  'multiplex': 'multiplex.json',
  'dialer': 'dialer.json',
  'dialer.common': 'dialer.json',
};

/// Общие файлы реестра БЕЗ цели `ref`: тело узла в них не спускается, их
/// читают другие слои по имени файла ([ContractRegistry.rawShared]).
const _kStandaloneShared = <String>['source_kinds.json'];

/// Описание поля тела — обёртка над картой реестра.
///
/// Атрибуты не копируются в поля класса: их 30+, читает их санитайзер
/// точечно, и лишний слой конвертации разошёлся бы со схемой на первом же
/// новом атрибуте. Геттеры — только для тех, что нужны санитайзеру.
final class FieldSchema {
  FieldSchema(this.raw)
      : _nested = null,
        _variants = null;

  /// §553 — поле, собранное разворотом ссылки ([ContractRegistry._expand]):
  /// вложенная схема уже разобрана, второй раз её из [raw] не строим.
  FieldSchema._expanded(this.raw, this._nested, this._variants);

  final Map<String, dynamic> raw;

  final Map<String, FieldSchema>? _nested;
  final Map<String, FieldSchema>? _variants;

  String get type => raw['type'] as String? ?? 'string';

  /// Цель ссылки у НЕ развёрнутого поля (`type: ref`). После загрузки такое
  /// поле остаётся только там, где ссылку разрешить не удалось (§553).
  String? get ref => raw['ref'] as String?;

  /// §553 — из какой ссылки поле получено при развороте (`tls`, `multiplex`,
  /// `dialer`, `transports`, `dialer.common`). У объекта это граница общей
  /// суб-схемы: там действует норма §472 шаг 5 — не хватило `required`
  /// внутри неё, снимается она, а не узел.
  String? get originRef => raw['origin_ref'] as String?;

  /// §553 — поле-объект с вариантами по дискриминатору (`transport` по
  /// `type`). Ключ варианта — значение дискриминатора, вариант — объект с
  /// `order`/`fields`. `null` — вариантов у поля нет.
  String? get discriminator => raw['discriminator'] as String?;

  late final Map<String, FieldSchema>? variants = _variants ?? _parseVariants();

  Map<String, FieldSchema>? _parseVariants() {
    final v = raw['variants'];
    if (v is! Map) return null;
    return {
      for (final e in v.entries)
        e.key as String: FieldSchema((e.value as Map).cast<String, dynamic>()),
    };
  }

  bool get inline => raw['inline'] == true;

  /// §560 — поле пишет СБОРКА (`detour`), а не тело узла: разбор его не
  /// переносит и не снимает.
  bool get managed => raw['managed'] == true;

  bool get required => raw['required'] == true;

  bool get secret => raw['secret'] == true;

  bool get allOrNothing => raw['all_or_nothing'] == true;

  /// `trim` | `lower` | `trim_lower` | `hex_only` — нормализация ДО
  /// проверки enum/format.
  String? get normalize => raw['normalize'] as String?;

  /// §464 (W2d) — код, который ставится, если [normalize] ИЗМЕНИЛА значение.
  /// Нормализация без него молчалива (`trim_lower` у enum'ов), с ним —
  /// объявляет потерю: `0x1a2` → `01a2` это ДРУГОЙ short_id.
  String? get normalizeCode => raw['normalize_code'] as String?;

  /// §464 (W2d) — дефолт, который ядру НУЖЕН: без поля outbound не
  /// поднимается вовсе (полоса hysteria v1 — «missing upload speed» фаталом
  /// на весь конфиг). В отличие от `default`, материализуется явно.
  ///
  /// Форма реестра: `{"absent": true, "value": 100}`; §473 (контракт 1.1.5)
  /// добавил ей условие `when` — дефолт, зависящий от РОДА узла (1280 у
  /// AmneziaWG, у обычного WireGuard поля нет вовсе).
  Map<String, dynamic>? get defaultWhen =>
      (raw['default_when'] as Map?)?.cast<String, dynamic>();

  /// §473 (контракт 1.1.5) — УСЛОВНЫЙ потолок значения.
  ///
  /// Обычный [max] действует всегда; этот — только когда выполнено `when`.
  /// Нужен там, где потолок диктует не поле, а род узла: у AmneziaWG
  /// накладные расходы на пакет делают `mtu` выше 1280 нерабочим
  /// (рукопожатие проходит, данные не идут), а у обычного WireGuard того же
  /// поля потолка нет — `max: 1280` снял бы `mtu` у каждого plain-WG-узла.
  ///
  /// Форма: `{max, code, when, except_sources?, note_code?}`.
  /// `except_sources` — входы, на которых замены НЕТ: значение остаётся, узел
  /// получает `note_code` (см. [BodySource]).
  Map<String, dynamic>? get maxWhen =>
      (raw['max_when'] as Map?)?.cast<String, dynamic>();

  /// §481 (контракт 1.1.11) — УСЛОВНЫЙ ПОРОГ снизу, зеркало [maxWhen] с
  /// тремя нарочными отличиями.
  ///
  /// Форма: `{min, code, action, absent_is_zero?, when}`.
  ///
  /// 1. **Значение НЕ заменяется.** У `max_when` завышенное число садится на
  ///    потолок; здесь подстановка минимума означала бы выдумать за
  ///    провайдера размер паддинга, от которого зависит рукопожатие.
  /// 2. **Исключения по входу нет** (`except_sources`): правило про то, что
  ///    ядро отвергает на загрузке ВСЕГО конфига, и кто написал тело —
  ///    неважно.
  /// 3. **`absent_is_zero`** — порог действует и на ОТСУТСТВУЮЩЕЕ поле: ядро
  ///    читает незаданный `s2` как 0, и «ключ защиты есть, паддинга нет» так
  ///    же фатально, как «ключ + паддинг 5». Без флага правило молчало бы
  ///    ровно на том случае, который встречается в живых подписках чаще
  ///    битого значения.
  ///
  /// Обычный [min] здесь не подошёл: он действует всегда и снял бы паддинг у
  /// каждого обычного AmneziaWG-узла, где порога нет вовсе.
  Map<String, dynamic>? get minWhen =>
      (raw['min_when'] as Map?)?.cast<String, dynamic>();

  /// §481 (контракт 1.1.12, CANON §6.1) — ВЫКЛЮЧАТЕЛЬ ВНУТРИ САМОГО ОБЪЕКТА:
  /// совпали все перечисленные ключи — объект снимается ЦЕЛИКОМ и ТИХО.
  ///
  /// Форма: `{"enabled": false}`. Нужен там, где выключатель секции лежит
  /// внутри неё: у ядра `tls: {enabled: false}` значит «TLS НЕ ЗАДАН»
  /// (конструктор возвращает `(nil, nil)`), а не «TLS с выключенным флагом».
  /// [absentValues] это не выражает — он про значение САМОГО поля и только
  /// строковый.
  ///
  /// Допустим у `type: object` и у секции суб-схемы ([BodySchema.absentWhen]);
  /// у `tls` объявлен ОДИН раз, на секции, и переезжает через `ref`.
  Map<String, dynamic>? get absentWhen =>
      (raw['absent_when'] as Map?)?.cast<String, dynamic>();

  String? get format => raw['format'] as String?;

  /// §477 (контракт 1.1.9) — регулярное выражение на строковое значение,
  /// проверяется ПОСЛЕ [normalize] и после [absentValues].
  ///
  /// Диалект — ОБЩЕЕ ПОДМНОЖЕСТВО Go RE2 и ECMAScript/Dart: без lookaround,
  /// без обратных ссылок, без inline-флагов. Совпадение по всей строке
  /// задаётся ЯКОРЯМИ В САМОМ ВЫРАЖЕНИИ (`^…$`), а не режимом проверки, —
  /// иначе одно выражение значило бы у сторон разное.
  ///
  /// Невалидное или некомпилируемое выражение санитайзер ПРОПУСКАЕТ (реестр
  /// вправе уехать вперёд кода, 24.1), поэтому опечатку обязан ловить линтер
  /// — `registry_invariant_test.dart`, группа «§477 — pattern».
  String? get pattern => raw['pattern'] as String?;

  /// Контракт 1.1.40 — регулярное выражение на ЭЛЕМЕНТ списка
  /// (`listable_string`/`string_array`), заведено по нашему запросу
  /// 19.09.2026.
  ///
  /// Отдельное имя, а не [pattern], потому что операции разные: [pattern]
  /// судит значение ЦЕЛИКОМ, и провал одного элемента снял бы список со
  /// всеми остальными. Ядру же довольно одного негодного элемента, чтобы
  /// отвергнуть ВЕСЬ конфиг, — значит нужна операция, которая выбрасывает
  /// элемент и оставляет соседей.
  ///
  /// Диалект и обращение с некомпилируемым выражением те же, что у
  /// [pattern]. Линтер требует, чтобы атрибут стоял только у списочных
  /// типов: у скалярного поля он не сработал бы ни разу и читался бы как
  /// рабочее правило.
  String? get itemPattern => raw['item_pattern'] as String?;

  /// Контракт 1.1.40 — что делать с элементом, провалившим [itemPattern].
  ///
  /// `action` закрыт одним значением `drop_item`: уронить поле целиком
  /// умеет [onInvalid], и второе значение было бы дублем. `code` обязателен
  /// (линтер), и путь кода — ЭЛЕМЕНТ (`server_ports[0]`), иначе дедуп
  /// деградаций по паре (код, путь) схлопнул бы два разных негодных
  /// элемента одного списка в одно сообщение.
  Map<String, dynamic>? get onItemInvalid =>
      (raw['on_item_invalid'] as Map?)?.cast<String, dynamic>();

  /// §477 (контракт 1.1.9) — ЗНАЧЕНИЯ-ВЫКЛЮЧАТЕЛИ: литералы, означающие
  /// «этого нет». Проверяются после [normalize] и ДО остальных ограничений;
  /// поле в тело не пишется, кода нет, правила его не судят.
  ///
  /// Сравнение ТОЧНОЕ и только строковое. Без этого атрибута правило судило
  /// бы выключатель (`encryption: "none"`) как строку грамматики и хоронило
  /// бы узел за выключенную настройку.
  List<String>? get absentValues =>
      (raw['absent_values'] as List?)?.map((e) => '$e').toList();

  /// Минимальная версия ядра; ниже неё ключ снимается на сборке (24.1.6).
  String? get minCore => raw['min_core'] as String?;

  /// ОС, на которой поле работает; на прочих ключ снимается на сборке.
  String? get platform => raw['platform'] as String?;

  /// Контракт 1.1.60 — тег сборки ядра, без которого поле ядру неизвестно.
  /// Сам по себе описателен; действует только вместе с [onCoreUnsupported].
  String? get buildTag => raw['build_tag'] as String?;

  /// Контракт 1.1.60 — узловой гейт ядра поля: `{action: drop_node, code}`.
  /// Требование того же уровня ([buildTag]/[minCore]) не выполнено → узел
  /// снимается на сборке ([nodeCoreRefusal]). Без атрибута `min_core` поля
  /// работает прежним полевым гейтом (снимается ключ).
  CoreUnsupported? get onCoreUnsupported =>
      CoreUnsupported.tryParse(raw['on_core_unsupported']);

  /// Контракт 1.1.60 — требования и уровень ФОРМЫ-ДИАПАЗОНА `N-M` у
  /// `awg_range`, когда они отличаются от числовой формы.
  RangeForm? get rangeForm => RangeForm.tryParse(raw['range_form']);

  /// Контракт 1.1.60 — уровень протокола, который даёт заданное поле
  /// (`BodySchema.levels`), и суффикс подписи (`level_mark`). Только модель:
  /// подпись уровня узла из них пока не строится.
  String? get level => raw['level'] as String?;

  String? get levelMark => raw['level_mark'] as String?;

  num? get min => raw['min'] as num?;

  num? get max => raw['max'] as num?;

  int? get len => raw['len'] as int?;

  /// `even` | `odd` — требование к чётности длины (reality.short_id).
  String? get lenParity => raw['len_parity'] as String?;

  List<Object?>? get values => (raw['values'] as List?)?.cast<Object?>();

  Map<String, dynamic>? get onInvalid =>
      (raw['on_invalid'] as Map?)?.cast<String, dynamic>();

  List<String>? get forbiddenFor =>
      (raw['forbidden_for'] as List?)?.cast<String>();

  List<String>? get allowedFor => (raw['allowed_for'] as List?)?.cast<String>();

  /// Код для `allowed_for`/`forbidden_for`.
  String? get code => raw['code'] as String?;

  /// §469 (контракт 1.1.4) — словарь «схема → код» поверх общего [code] у
  /// `forbidden_for`. Понадобился ровно потому, что один запрет даёт разный
  /// ИСХОД у разных схем: у naive снятый `tls.utls` это потерянная настройка
  /// (`tls_field_unsupported_naive`, severity warning), а на QUIC-схемах
  /// (hysteria, hysteria2, tuic, masque) uTLS и REALITY не применились бы в
  /// принципе — снята бессмыслица, узел ничего не теряет
  /// (`tls_not_applicable_quic`, severity info).
  ///
  /// Схема без записи в словаре берёт общий [code].
  Map<String, String>? get forbiddenCodes =>
      (raw['forbidden_codes'] as Map?)?.map((k, v) => MapEntry('$k', '$v'));

  /// §469 — код запрета для [scheme]: точечный из [forbiddenCodes], иначе
  /// общий [code]. `null` — кода реестр не назвал.
  String? forbiddenCodeFor(String scheme) =>
      forbiddenCodes?[scheme] ?? code;

  // §549 R3 — связи разбираются один раз на экземпляр, а не на каждый вызов
  // геттера: санитайзер спрашивает их у каждого поля каждого узла, а схема
  // (и `raw` под ней) после `load()` не меняется.
  late final List<Map<String, dynamic>> conflicts = _relations('conflicts');

  late final List<Map<String, dynamic>> requires = _relations('requires');

  /// Значения, которые ядро принимает, но узел получает info-код.
  late final List<Map<String, dynamic>> advisory = _relations('advisory');

  /// §474 (контракт 1.1.6) — элемент связи читается в ДВУХ формах: объект
  /// `{with, code}` и голая строка.
  ///
  /// Объект — единственная форма, которую реестр пишет сегодня (схема требует
  /// `code` у каждой записи), и по ней у `vless.flow ↔ transport` появился
  /// свой код `vision_with_transport` вместо общего `field_conflict`: ядро эту
  /// пару ПРИНИМАЕТ, снимается бессмыслица, и severity у неё info, а не
  /// warning.
  ///
  /// Строка читается как `{with: <строка>}` без кода — на случай, если реестр
  /// поедет впереди клиента сокращённой записью. Дороже она нам ничего не
  /// стоит, а выкинутый молча элемент означал бы неисполненное правило связи.
  List<Map<String, dynamic>> _relations(String key) {
    final raw0 = (raw[key] as List?) ?? const [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw0) {
      if (e is Map) {
        out.add(e.cast<String, dynamic>());
      } else if (e is String && e.isNotEmpty) {
        // У `conflicts` сосед зовётся `with`, у `requires` — `path`; строкой
        // записывается ровно тот ключ, который читает эта связь.
        out.add(key == 'requires' ? {'path': e} : {'with': e});
      }
    }
    return List.unmodifiable(out);
  }

  Object? get defaultValue => raw['default'];

  /// Описание элемента массива (`type: array`).
  FieldSchema? get items {
    final it = raw['items'];
    return it is Map ? FieldSchema(it.cast<String, dynamic>()) : null;
  }

  /// Вложенный объект: порядок + поля. Объект без `fields` (например
  /// `transport.headers`) — свободная карта, внутрь санитайзер не смотрит.
  late final List<String>? order =
      (raw['order'] as List?)?.cast<String>().toList(growable: false);

  /// Разбирается один раз: реестр иммутабелен после загрузки, а санитайзер
  /// спускается во вложенные объекты (`tls`, `tls.reality`) на каждом узле.
  late final Map<String, FieldSchema>? fields = _nested ?? _parseFields();

  Map<String, FieldSchema>? _parseFields() {
    final f = raw['fields'];
    if (f is! Map) return null;
    return {
      for (final e in f.entries)
        e.key as String: FieldSchema((e.value as Map).cast<String, dynamic>()),
    };
  }
}

/// Схема тела записи: порядок ключей + поля. Порядок нормативен — по нему
/// идут и санитайзер, и эмиттер, поэтому список warnings детерминирован
/// (24.1.1).
final class BodySchema {
  const BodySchema({
    required this.core,
    required this.order,
    required this.fields,
    this.relations = const [],
    this.absentWhen,
    this.exitCapableWhen,
    this.buildTag,
    this.minCore,
    this.onCoreUnsupported,
    this.levels = const [],
  });

  /// Тег ядра, по которому сверен список полей.
  final String core;

  /// Контракт 1.1.60 — тег сборки и минимальная версия ядра для протокола
  /// целиком. Описательны, пока у тела нет [onCoreUnsupported].
  final String? buildTag;
  final String? minCore;

  /// Контракт 1.1.60 — узловой гейт тела: требование не выполнено → узел
  /// снимается на сборке с этим кодом ([nodeCoreRefusal]).
  final CoreUnsupported? onCoreUnsupported;

  /// Контракт 1.1.60 — уровни протокола по возрастанию (`wireguard`: awg …
  /// awg3.1). Только модель: подпись уровня узла из них пока не строится.
  final List<String> levels;

  final List<String> order;

  final Map<String, FieldSchema> fields;

  /// §481 (контракт 1.1.11) — связи уровня ТЕЛА, а не поля.
  ///
  /// `conflicts`/`requires` живут у поля и говорят про пару «я и сосед»;
  /// `ranges_disjoint` у `h1`–`h4` — свойство НАБОРА: виноват может быть любой
  /// из четырёх, и снятие одного пару не развело бы.
  ///
  /// Форма элемента: `{kind, paths, defaults?, action, code}`.
  final List<Map<String, dynamic>> relations;

  /// §481 (контракт 1.1.12) — `absent_when` секции: объявленный ОДИН раз у
  /// суб-схемы (`tls`), он при разрешении `ref` действует в каждом протоколе.
  /// Смысл и порядок — [FieldSchema.absentWhen] и CANON §6.1.
  final Map<String, dynamic>? absentWhen;

  /// Контракт 1.1.63 — `exit_capable_when` тела протокола (грамматика
  /// `condition`, без `source_kind`): при каком готовом теле узел годится
  /// ВЫХОДОМ — кандидатом в пул Направления. `null` — годится всегда.
  final Map<String, dynamic>? exitCapableWhen;

}

/// Контракт 1.1.60 — `on_core_unsupported`: что делать с узлом, когда
/// требование к ядру (`build_tag`/`min_core` того же уровня) не выполнено.
final class CoreUnsupported {
  const CoreUnsupported({required this.action, required this.code});

  /// Единственное значение схемы — `drop_node`.
  final String action;
  final String code;

  bool get dropsNode => action == 'drop_node';

  static CoreUnsupported? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final action = raw['action'];
    final code = raw['code'];
    if (action is! String || code is! String) return null;
    return CoreUnsupported(action: action, code: code);
  }
}

/// Контракт 1.1.60 — `range_form` у `awg_range`: требования, уровень и
/// узловой гейт формы-диапазона (`N-M`).
final class RangeForm {
  const RangeForm({
    this.minCore,
    this.buildTag,
    this.level,
    this.onCoreUnsupported,
  });

  final String? minCore;
  final String? buildTag;
  final String? level;
  final CoreUnsupported? onCoreUnsupported;

  static RangeForm? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return RangeForm(
      minCore: raw['min_core'] as String?,
      buildTag: raw['build_tag'] as String?,
      level: raw['level'] as String?,
      onCoreUnsupported: CoreUnsupported.tryParse(raw['on_core_unsupported']),
    );
  }
}

/// Текст кода предупреждения из `registry/warnings.json`.
final class WarningText {
  const WarningText({
    required this.code,
    required this.severity,
    required this.titleEn,
    required this.titleRu,
    required this.textEn,
    required this.textRu,
    required this.params,
    this.causeEn,
    this.causeRu,
    this.fixEn = const [],
    this.fixRu = const [],
  });

  final String code;

  /// `info` | `warning` | `error`.
  final String severity;

  final String titleEn;
  final String titleRu;
  final String textEn;
  final String textRu;

  /// §467 — «почему так вышло», одной строкой; контракт 1.1.1. Кода без
  /// причины в реестре быть может, и это норма: блок просто не рисуется
  /// (карточка — W2b, раздел 8 спеки 460).
  final String? causeEn;
  final String? causeRu;

  /// §467 — «что сделать», списком шагов. Пустой список = блока нет.
  final List<String> fixEn;
  final List<String> fixRu;

  /// Имена подстановок помимо неявных `path`/`value`.
  final List<String> params;
}

/// Реестр контракта — синглтон, грузится один раз в `main()` до `runApp`.
///
/// Незагруженный реестр — рабочее состояние, а не ошибка: санитайзер
/// пропускает записи, приложение живёт как до §460.
final class ContractRegistry {
  ContractRegistry._();

  static final ContractRegistry I = ContractRegistry._();

  static const _assetRoot = 'assets/contract';

  String _version = '';
  final Map<String, Map<String, dynamic>> _protocols = {};
  final Map<String, Map<String, dynamic>> _shared = {};
  final Map<String, WarningText> _warnings = {};

  /// Кэш раскрытых схем ([schemaFor]). Слот-обёртка, а не `BodySchema?`:
  /// «схемы нет» — тоже результат, и хранить его надо, иначе чужой тип
  /// (`direct`, `selector`) раскрывался бы заново на каждом узле.
  final Map<String, _SchemaSlot> _schemaCache = {};
  bool _loaded = false;

  /// §551 — ПОКОЛЕНИЕ набора протоколов: растёт на каждом изменении
  /// [_protocols] (сброс, запись протокола при загрузке, конец загрузки).
  ///
  /// Нужно кешам ВНЕ реестра, которые считаются от его протоколов
  /// (`MapperSections.typesFor`, маршрут схем ссылки): сравнить число дешевле,
  /// чем пересобирать набор на каждой ссылке, а ручной сброс из реестра в
  /// чужой кеш завязал бы слой контракта на движок разбора.
  int _generation = 0;

  int get generation => _generation;

  bool get isLoaded => _loaded;

  /// §500 — сброс синглтона после теста, чтобы загруженный реестр не
  /// остался соседям в том же изоляте.
  @visibleForTesting
  void resetForTesting() {
    _loaded = false;
    _version = '';
    _protocols.clear();
    _shared.clear();
    _warnings.clear();
    _schemaCache.clear();
    _transportCache.clear();
    _sharedCache.clear();
    _generation++;
  }

  /// Версия контракта из `contract/VERSION` (например `1.1.0`).
  String get version => _version;

  /// Загрузка из assets. [loader] — для тестов; по умолчанию `rootBundle`.
  Future<void> load({AssetLoader? loader}) async {
    final read = loader ?? (String p) => rootBundle.loadString(p);
    await _load((rel) => read('$_assetRoot/$rel'));
  }

  /// Загрузка из каталога на диске — путь к КОРНЮ контракта (`contract`),
  /// где лежат `VERSION` и `registry/`. Для юнит-тестов: биндинг Flutter не
  /// нужен, читается та же копия, которую сверяет `check_contract_lock`.
  Future<void> loadFromDirectory(String dir) async {
    await _load((rel) => File('$dir/$rel').readAsString());
  }

  Future<void> _load(Future<String> Function(String rel) read) async {
    _version = (await read('VERSION')).trim();

    for (final entry in _kSharedRefs.entries) {
      // dialer и dialer.common живут в одном файле — читаем один раз.
      if (_shared.containsKey(entry.value)) continue;
      _shared[entry.value] =
          jsonDecode(await read('registry/${entry.value}')) as Map<String, dynamic>;
    }

    // Контракт 1.1.41 — `source_kinds.json` цели `ref` не имеет: тело узла в
    // него не спускается, его читает опознание ИСТОЧНИКА (`documents`
    // загрузчика секций). Поэтому он грузится отдельно, а не вместе с
    // разворотом `ref`.
    //
    // Отсутствие файла — рабочее состояние, а не поломка: контракт старше
    // 1.1.41 его не несёт, и опознание тогда идёт прежним путём. Ронять на
    // нём загрузку всего реестра нельзя.
    for (final name in _kStandaloneShared) {
      if (_shared.containsKey(name)) continue;
      try {
        _shared[name] =
            jsonDecode(await read('registry/$name')) as Map<String, dynamic>;
      } catch (_) {
        // Нет файла (или он не читается) — ветки просто нет.
      }
    }

    for (final scheme in _kProtocolFiles) {
      final data = jsonDecode(await read('registry/protocols/$scheme.json'))
          as Map<String, dynamic>;
      // Ключ — singbox_type записи, а не имя файла: санитайзер получает
      // `type` из тела узла, и для схем-алиасов (hy2 → hysteria2) имя файла
      // сошлось бы не всегда.
      final singboxType = data['singbox_type'] as String? ?? scheme;
      _protocols[singboxType] = data;
      _generation++;
    }

    final warnings = jsonDecode(await read('registry/warnings.json'))
        as Map<String, dynamic>;
    final byCode = (warnings['warnings'] as Map).cast<String, dynamic>();
    // `path`/`value` подставляются всегда (text_params_implicit) — в params
    // кодов они не перечислены.
    final implicit =
        ((warnings['text_params_implicit'] as List?) ?? const []).cast<String>();
    for (final e in byCode.entries) {
      final w = (e.value as Map).cast<String, dynamic>();
      _warnings[e.key] = WarningText(
        code: e.key,
        severity: w['severity'] as String? ?? 'warning',
        titleEn: w['title_en'] as String? ?? '',
        titleRu: w['title_ru'] as String? ?? '',
        textEn: w['text_en'] as String? ?? '',
        textRu: w['text_ru'] as String? ?? '',
        // §467 — контракт 1.1.1: причина строкой, способ исправления списком
        // строк. Отсутствие любого из них — норма (реестр наполняется
        // постепенно), поэтому читаются мягко и загрузку не роняют.
        causeEn: w['cause_en'] as String?,
        causeRu: w['cause_ru'] as String?,
        fixEn: _stringList(w['fix_en']),
        fixRu: _stringList(w['fix_ru']),
        params: [
          ...implicit,
          ...((w['params'] as List?) ?? const []).cast<String>(),
        ],
      );
    }

    // Перезагрузка (тесты грузят реестр не один раз) обязана сбросить кэш
    // раскрытых схем: иначе второй `load()` отдавал бы схемы первого.
    _schemaCache.clear();
    _transportCache.clear();
    _sharedCache.clear();
    _generation++;

    _loaded = true;
  }

  /// Схема тела по `type` записи sing-box. Ссылки (`ref`) уже развёрнуты
  /// все (§553, [_expand]): `transport` — поле-объект с вариантами по
  /// дискриминатору `type` ([FieldSchema.variants]).
  ///
  /// `null` — схемы нет (реестр не загружен либо тип чужой): санитайзер
  /// такую запись не трогает.
  /// §460 W2a — результат кэшируется по `singbox_type`: разбор раскрывает
  /// `ref`-ы (tls + dialer + multiplex) на КАЖДЫЙ узел, а на подписке в 2000
  /// узлов это 2000 одинаковых разворотов одной и той же схемы. Реестр
  /// иммутабелен после `load()`, схема из него — тоже, поэтому кэш безопасен.
  BodySchema? schemaFor(String singboxType) {
    final cached = _schemaCache[singboxType];
    if (cached != null) return cached.schema;
    final proto = _protocols[singboxType];
    Map<String, dynamic>? body;
    if (proto != null) body = (proto['body'] as Map?)?.cast<String, dynamic>();
    final schema = body == null ? null : _expand(body);
    _schemaCache[singboxType] = _SchemaSlot(schema);
    return schema;
  }

  /// Вариант транспорта по значению дискриминатора (`transport.type`).
  /// `null` — тип неизвестен реестру.
  BodySchema? transportVariant(String type) {
    final cached = _transportCache[type];
    if (cached != null) return cached.schema;
    final schema = _transportVariant(type);
    _transportCache[type] = _SchemaSlot(schema);
    return schema;
  }

  final Map<String, _SchemaSlot> _transportCache = {};

  BodySchema? _transportVariant(String type) {
    final body =
        (_shared['transports.json']?['body'] as Map?)?.cast<String, dynamic>();
    if (body == null) return null;
    final variant = (body['variants'] as Map?)?[type];
    if (variant is! Map) return null;
    final v = variant.cast<String, dynamic>();
    return BodySchema(
      core: body['core'] as String? ?? '',
      order: ((v['order'] as List?) ?? const []).cast<String>(),
      fields: _fieldsOf(v),
    );
  }

  /// Схема общей суб-схемы по имени `ref` (`tls`, `multiplex`, `dialer`,
  /// `dialer.common`). Транспорты сюда не ходят — у них дискриминатор.
  ///
  /// §549 R1 — результат кэшируется по имени `ref`, как [schemaFor] и
  /// [transportVariant]: санитайзер спрашивает `tls`/`dialer.common` на каждое
  /// поле-ссылку каждого узла (§548: без кэша это ~40 % гарда), а реестр
  /// иммутабелен после `load()`. Сброс — вместе с остальными кэшами.
  BodySchema? sharedSchema(String ref) {
    final cached = _sharedCache[ref];
    if (cached != null) return cached.schema;
    final schema = _sharedSchema(ref);
    _sharedCache[ref] = _SchemaSlot(schema);
    return schema;
  }

  final Map<String, _SchemaSlot> _sharedCache = {};

  BodySchema? _sharedSchema(String ref) {
    final file = _kSharedRefs[ref];
    if (file == null) return null;
    final data = _shared[file];
    if (data == null) return null;
    // `dialer.common` — секция `common` того же файла.
    final section = ref == 'dialer.common' ? 'common' : 'body';
    final body = (data[section] as Map?)?.cast<String, dynamic>();
    if (body == null || body.containsKey('variants')) return null;
    return _expand(body);
  }

  /// Текст кода из `warnings.json`; `null` — кода в реестре нет.
  WarningText? textFor(String code) => _warnings[code];

  /// §480 — СЫРОЙ JSON протокола по `singbox_type`.
  ///
  /// Нужен движку маппера: он читает секции (`mappers.<kind>`), которых нет в
  /// [BodySchema] — та описывает ТЕЛО, а секция-маппер описывает превращение
  /// источника в тело. Раскрывать её в типизированную форму здесь нечем:
  /// грамматика секций своя ([MapperSection]), и живёт она в пакете движка.
  ///
  /// `null` — протокола нет (реестр не загружен либо тип чужой).
  Map<String, dynamic>? rawProtocol(String singboxType) =>
      _protocols[singboxType];

  /// §480 W5 — имена загруженных протоколов.
  ///
  /// Нужны загрузчику секций, чтобы перебрать секции вида источника, не
  /// перечисляя протоколы в коде (в пакете движка имён схем быть не должно).
  Iterable<String> get protocolNames => _protocols.keys;

  /// §480 — СЫРОЙ JSON общего файла по имени (`tls.json`, `transports.json`).
  ///
  /// Движку маппера нужны `blocks` — исполняемые записи общих блоков по
  /// диалектам; [sharedSchema] отдаёт только схему ТЕЛА и про них не знает.
  Map<String, dynamic>? rawShared(String fileName) => _shared[fileName];

  /// Разворот секции `body` — все ссылки разрешаются здесь, один раз при
  /// загрузке, и читатель схемы видит уже развёрнутые поля (§553). Три ветки,
  /// зеркало лаунчера (`core/config/registry/registry.go`, `resolveSection`):
  ///
  /// 1. `inline: true` (`__dialer`) — поля суб-схемы вливаются плоско на
  ///    место слота в `order`, без дублей;
  /// 2. ссылка с точкой на плоскую суб-схему (`dialer.common`,
  ///    `dialer.common.network`) — поле суб-схемы ([_resolveNamedRef]) с
  ///    атрибутами обёртки поверх ([_mergeRefAttrs]);
  /// 3. прочие (`tls`, `multiplex`, `dialer`, `transports`) — поле-объект со
  ///    вложенной схемой ([_refAsObject]).
  ///
  /// Не разрешённая ссылка остаётся обёрткой `type: ref`: реестр, который
  /// едет впереди клиента, не должен ронять загрузку. Такую ссылку ловит
  /// `registry_load_test`.
  BodySchema _expand(Map<String, dynamic> body) {
    final rawFields = _fieldsOf(body);
    final rawOrder = ((body['order'] as List?) ?? const []).cast<String>();

    final order = <String>[];
    final fields = <String, FieldSchema>{};
    for (final key in rawOrder) {
      final f = rawFields[key];
      if (f == null) continue;
      if (f.inline && f.ref != null) {
        final sub = sharedSchema(f.ref!);
        if (sub == null) continue;
        // Поля dialer занимают место слота `__dialer` — ровно там, где
        // структура ядра держит DialerOptions.
        for (final k in sub.order) {
          final sf = sub.fields[k];
          if (sf == null || fields.containsKey(k)) continue;
          order.add(k);
          fields[k] = sf;
        }
        continue;
      }
      order.add(key);
      fields[key] = f.type == 'ref' && f.ref != null
          ? (_resolveRef(key, f, f.ref!) ?? f)
          : f;
    }
    // Поля вне `order` (схема их иметь не должна, но молча терять их нельзя:
    // иначе неописанный в order ключ выглядел бы неизвестным и снимался).
    for (final e in rawFields.entries) {
      if (fields.containsKey(e.key)) continue;
      if (e.value.inline) continue;
      final f = e.value;
      order.add(e.key);
      fields[e.key] = f.type == 'ref' && f.ref != null
          ? (_resolveRef(e.key, f, f.ref!) ?? f)
          : f;
    }

    return BodySchema(
      core: body['core'] as String? ?? '',
      order: order,
      fields: fields,
      relations: [
        for (final e in (body['relations'] as List?) ?? const [])
          if (e is Map) e.cast<String, dynamic>(),
      ],
      absentWhen: (body['absent_when'] as Map?)?.cast<String, dynamic>(),
      exitCapableWhen:
          (body['exit_capable_when'] as Map?)?.cast<String, dynamic>(),
      buildTag: body['build_tag'] as String?,
      minCore: body['min_core'] as String?,
      onCoreUnsupported: CoreUnsupported.tryParse(body['on_core_unsupported']),
      levels: [
        for (final e in (body['levels'] as List?) ?? const []) '$e',
      ],
    );
  }

  /// §553 — ветки 2 и 3 разворота. `null` — ссылку разрешить нечем (нет
  /// суб-схемы, нет поля, неоднозначный `desc_en`).
  FieldSchema? _resolveRef(String name, FieldSchema src, String ref) {
    final parts = ref.split('.');
    // `dialer.common.network` — секция `dialer.common`, поле названо явно.
    final section = parts.length >= 3 ? parts.take(2).join('.') : ref;
    if (section == 'transports') return _transportsAsObject(src);
    final sub = sharedSchema(section);
    if (sub == null) return null;
    if (ref.contains('.') && sub.fields.isNotEmpty) {
      final target = _resolveNamedRef(name, src, parts, sub);
      if (target == null) return null;
      return _mergeRefAttrs(src, target, section);
    }
    return _refAsObject(src, sub, section);
  }

  /// Поле плоской суб-схемы, на которое указывает ссылка. Порядок, как у
  /// лаунчера (`resolveNamedRef`): явное имя в ссылке → собственное имя поля
  /// → единственное поле с тем же `desc_en`. Неоднозначность — ошибка
  /// реестра, поле не выбирается.
  static FieldSchema? _resolveNamedRef(
      String name, FieldSchema src, List<String> parts, BodySchema sub) {
    if (parts.length >= 3) return sub.fields[parts.skip(2).join('.')];
    final own = sub.fields[name];
    if (own != null) return own;
    final desc = src.raw['desc_en'];
    if (desc is! String || desc.isEmpty) return null;
    FieldSchema? found;
    for (final k in sub.order) {
      final f = sub.fields[k];
      if (f == null || f.raw['desc_en'] != desc) continue;
      if (found != null) return null;
      found = f;
    }
    return found;
  }

  /// Атрибуты обёртки поверх поля суб-схемы (лаунчер: `mergeRefAttrs`).
  /// Обёртка может УЖЕСТОЧИТЬ `required` и задать `code`, `forbidden_for`,
  /// `allowed_for`, `forbidden_codes`; правила значения (`on_invalid`,
  /// `normalize`, `default_when`, `min_when`, `max_when`, связи) — только из
  /// суб-схемы. Описание (`desc_*`, `impl`) — обёртки: это текст про поле
  /// ЭТОЙ схемы (`masque.network_list`), а не про общее правило.
  static FieldSchema _mergeRefAttrs(
      FieldSchema src, FieldSchema target, String section) {
    final raw = <String, dynamic>{...target.raw, 'origin_ref': section};
    final w = src.raw;
    if (w['required'] == true) raw['required'] = true;
    for (final k in const [
      'code',
      'forbidden_for',
      'allowed_for',
      'forbidden_codes',
      'desc_en',
      'desc_ru',
      'impl',
    ]) {
      final v = w[k];
      if (v == null || (v is String && v.isEmpty)) continue;
      if ((v is List && v.isEmpty) || (v is Map && v.isEmpty)) continue;
      raw[k] = v;
    }
    return FieldSchema(Map.unmodifiable(raw));
  }

  /// Ссылка на общую суб-схему как поле-объект (лаунчер: `refAsObject`).
  /// Атрибуты обёртки (`required`, `code`, `desc_*`, гейты) — у поля;
  /// `absent_when` объявлен один раз у суб-схемы и переезжает сюда, если
  /// обёртка не задала свой.
  static FieldSchema _refAsObject(
      FieldSchema src, BodySchema sub, String section) {
    final raw = _wrapperAttrs(src, section);
    raw['order'] = List<String>.unmodifiable(sub.order);
    raw['fields'] = {
      for (final k in sub.order)
        if (sub.fields[k] != null) k: sub.fields[k]!.raw,
    };
    final aw = src.raw['absent_when'] ?? sub.absentWhen;
    if (aw != null) raw['absent_when'] = aw;
    return FieldSchema._expanded(
        Map.unmodifiable(raw), Map.unmodifiable(sub.fields), null);
  }

  /// `transports` — вариантная суб-схема: поле-объект с вариантами по
  /// дискриминатору (`type`). Варианты — те же, что отдаёт
  /// [transportVariant].
  FieldSchema? _transportsAsObject(FieldSchema src) {
    final body =
        (_shared['transports.json']?['body'] as Map?)?.cast<String, dynamic>();
    final disc = body?['discriminator'];
    final vs = body?['variants'];
    if (disc is! String || disc.isEmpty || vs is! Map) return null;
    final variants = <String, FieldSchema>{};
    for (final e in vs.entries) {
      final v = transportVariant(e.key as String);
      if (v == null) continue;
      variants[e.key as String] = FieldSchema._expanded(
        Map.unmodifiable(<String, dynamic>{
          'type': 'object',
          'order': v.order,
          'fields': {for (final f in v.fields.entries) f.key: f.value.raw},
        }),
        Map.unmodifiable(v.fields),
        null,
      );
    }
    final raw = _wrapperAttrs(src, 'transports');
    raw['discriminator'] = disc;
    raw['variants'] = {for (final e in variants.entries) e.key: e.value.raw};
    return FieldSchema._expanded(
        Map.unmodifiable(raw), null, Map.unmodifiable(variants));
  }

  static Map<String, dynamic> _wrapperAttrs(FieldSchema src, String section) =>
      <String, dynamic>{
        for (final e in src.raw.entries)
          if (e.key != 'type' && e.key != 'ref' && e.key != 'inline')
            e.key: e.value,
        'type': 'object',
        'origin_ref': section,
      };

  Map<String, FieldSchema> _fieldsOf(Map<String, dynamic> section) {
    final f = section['fields'];
    if (f is! Map) return const {};
    return {
      for (final e in f.entries)
        e.key as String: FieldSchema((e.value as Map).cast<String, dynamic>()),
    };
  }
}

/// Слот кэша схем: отличает «ещё не считали» от «схемы нет».
final class _SchemaSlot {
  const _SchemaSlot(this.schema);

  final BodySchema? schema;
}

/// §467 — массив строк из реестра (`fix_en`/`fix_ru`). Не массив или его
/// отсутствие — пустой список: реестр вправе ехать впереди клиента, и
/// незнакомая форма поля загрузку не роняет.
List<String> _stringList(Object? v) {
  if (v is! List) return const [];
  return [for (final e in v) if (e is String) e];
}

/// §473/§472 шаг 7 — потолок `mtu` AmneziaWG-узла ПО РЕЕСТРУ
/// (`wireguard.body.fields.mtu` → `max_when.max`; у `default_when.value` то же
/// число, контракт 1.1.5, и разъезжаться им незачем).
///
/// Правило целиком живёт в реестре, и ИСПОЛНЯЕТ его санитайзер — по телу, на
/// всех входах. Этот геттер нужен ровно двум случаям, где санитайзер до
/// значения не дотягивается:
///
/// 1. узел, который ПРОСИЛ AmneziaWG, но не донёс ни одного годного AWG-поля
///    (§463; условие `when.any_set` реестра судит наличие ключа в теле, а его
///    там не осталось) — `mappers/uri_pipeline.dart`;
/// 2. реестр НЕ ЗАГРУЖЕН: тогда санитайзер не работает вовсе, и без потолка
///    AWG-узел с написанным `mtu: 1420` уехал бы в ядро — туннель поднялся бы,
///    а данные по нему не пошли. Здесь запасное число [kAwgMtuFallback]
///    обязано сработать: молчание тут не безопасно, в отличие от кодов, где
///    выдуманный код хуже его отсутствия.
///
/// `null` не возвращается никогда по той же причине — потолок у AWG есть
/// всегда. Тип оставлен nullable ради вызывающего, который проверяет
/// загруженность реестра сам.
int? awgMtuCeilingByRegistry() {
  final ceiling =
      ContractRegistry.I.schemaFor('wireguard')?.fields['mtu']?.maxWhen?['max'];
  return ceiling is num ? ceiling.toInt() : kAwgMtuFallback;
}

/// §473 — код о ЗАМЕНЕ `mtu` потолком, как его назвал реестр
/// (`max_when.code`). Второй копии имени в Dart не заводится.
String? awgMtuClampCodeByRegistry() => ContractRegistry.I
    .schemaFor('wireguard')
    ?.fields['mtu']
    ?.maxWhen?['code'] as String?;

/// Потолок AmneziaWG-MTU, когда реестр не загружен.
///
/// Реестр — не обязательное условие работы приложения (§460: не загрузился —
/// живём как до него), но `mtu` у AWG-узла обязан быть проставлен и ограничен:
/// без этого ядро берёт 1408, туннель поднимается, и данные по нему не идут.
/// Поэтому у ЭТОГО значения запасной путь есть, в отличие от кодов, где
/// молчание безопасно: выдуманный код хуже его отсутствия, а выдуманный MTU
/// здесь — единственный рабочий.
const kAwgMtuFallback = 1280;

/// Файлы `registry/protocols/` — перечислены поимённо: `rootBundle` каталог
/// не листает (AssetManifest дал бы список, но ценой второго формата
/// чтения), а состав меняется только вместе с бампом контракта, и тогда
/// список правится осознанно. Расхождение ловит `registry_load_test`.
const _kProtocolFiles = <String>[
  'anytls',
  'chain',
  'group',
  'http',
  'hysteria',
  'hysteria2',
  'masque',
  'naive',
  'shadowsocks',
  'socks',
  'ssh',
  'tailscale',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'wireguard',
];
