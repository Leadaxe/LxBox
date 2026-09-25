/// §460 W1 — санитайзер тела узла по схеме реестра контракта.
///
/// Работает по таблице 2.2 спеки: неизвестный ключ снимается, значение
/// проверяется типом/enum'ом/форматом/границами, нарушение уходит в
/// `on_invalid`, а связи между полями (`conflicts`, `requires`,
/// `forbidden_for`, `min_core`, `platform`) решаются после — когда состав
/// тела уже известен.
///
/// Чего санитайзер НЕ делает (осознанно, W1):
/// - не материализует `default` (CANON §2.4: дефолты не пишутся) — кроме
///   `all_or_nothing`, где дописать их велит сам реестр;
/// - не трогает `tag` и `detour`: их пишет сборка конфига, а не тело узла;
/// - не трогает `tristate`, `managed`, `deprecated`, `decision_pending`,
///   `drop_always`, `build_tag` — это волна W2.
///
/// Порядок ключей результата — `order` схемы (24.1.1): по нему же идёт
/// эмиттер, поэтому и список warnings детерминирован.
library;

import 'dart:convert' show base64, base64Url;
import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data' show Uint8List;

import '../../models/node_warning.dart';
import '../app_log.dart';
import '../parser/uri_utils.dart'
    show decodeBase64Lenient, normalizeSingboxDuration, urlPathOk;
import 'registry.dart';

/// §473 — вход, которым тело приехало в приложение.
///
/// Единственное место контракта, где вход влияет на РЕЗУЛЬТАТ, а не только на
/// разбор: `max_when.except_sources` (контракт 1.1.5, решение владельца
/// 18.09.2026). Основание не техническое, а по владению — тело sing-box
/// человек или подписка написали в собственной форме ядра, и молча
/// переписывать его приложение не вправе; значение из ссылки или `.conf`
/// сочинял генератор провайдера.
///
/// §480 — перечисление ПОВТОРЯЕТ словарь `sources` реестра
/// (`uri`/`singbox`/`xray`/`wgconf`/`amnezia`), потому что теперь вход
/// НАЗЫВАЕТ СЕБЯ САМ: секция-маппер объявляет `body_source`, и конвейер
/// передаёт объявленное значение сюда. До этого на всех входах, кроме
/// sing-box-JSON, стояла заглушка `other` — правило `except_sources` судило
/// по ней, и стоило реестру перечислить в исключениях любой другой вход, как
/// тела у нас и у лаунчера разошлись бы молча.
///
/// Сравнение идёт по [registryName], поэтому расширение набора поведение не
/// меняет: `uri` под списком `["singbox"]` не подпадает, как не подпадал
/// `other`.
///
/// [other] остался для входов, за которыми секции-маппера нет (форма
/// редактора): различать вход тоньше нам там нечем. Появится второе
/// правило с другим делением — перечисление расширится по нему, а не заранее.
enum BodySource {
  /// Тело в собственной форме ядра: объект `outbounds[]`/`endpoints[]`,
  /// пришедший JSON-ом (`origin.kind: json`, §455) либо дословная карта
  /// провайдера при разборе JSON-подписки.
  singbox('singbox'),

  /// §480 — ссылка. Секция-маппер объявляет это `body_source: "uri"`.
  uri('uri'),

  /// §480 — Xray-JSON.
  xray('xray'),

  /// §480 — `.conf` / INI (wg-quick).
  wgconf('wgconf'),

  /// §480 — контейнер Amnezia (`vpn://`).
  amnezia('amnezia'),

  /// Вход, который себя не назвал: форма редактора и прочее, где тело собрал
  /// наш разбор, а секции-маппера за ним не стоит.
  ///
  /// Под `except_sources` не подпадает ни при каком списке — имя пустое.
  other('');

  const BodySource(this.registryName);

  /// Имя входа в словаре `sources` реестра; у [other] пустое.
  final String registryName;

  /// §480 — вход по имени из секции-маппера (`body_source`).
  ///
  /// Неизвестное имя даёт [other], а не ошибку: реестр вправе уехать вперёд
  /// кода (24.1), и новый вид источника обязан вести себя как «вход себя не
  /// назвал», а не ронять разбор.
  static BodySource byRegistryName(String? name) {
    if (name == null || name.isEmpty) return other;
    for (final v in values) {
      if (v.registryName == name) return v;
    }
    return other;
  }
}

/// Результат санитайзинга одной записи.
final class SanitizeResult {
  const SanitizeResult(this.body, this.warnings, {this.explicitDropNode = false});

  /// Очищенное тело; `null` — запись снята целиком (`drop_node`).
  final Map<String, dynamic>? body;

  final List<RegistryWarning> warnings;

  /// §477 — запись снята ЯВНЫМ правилом `on_invalid: { action: drop_node }`,
  /// а не как побочное следствие недостающего обязательного поля.
  ///
  /// Различать их обязательно, и разница не косметическая. Оба исхода дают
  /// `body == null`, но означают разное:
  ///
  /// - **явный `drop_node`** — реестр сказал «такую запись ядро не примет и не
  ///   стартует на всём конфиге» (`vless.encryption` вне формы, метод
  ///   shadowsocks вне набора). Такой узел обязан исчезнуть ещё при разборе:
  ///   держать его в списке рабочим значило бы обещать пользователю связь,
  ///   которой не будет;
  /// - **нет обязательного поля** — запись неполна, но приложение веками
  ///   показывало такой узел и снимало его только на сборке. Отбраковывать его
  ///   при разборе — отдельное решение с другой ценой (у узла из подписки
  ///   пропала бы строка, в которой человек читал причину), и §477 его не
  ///   принимал.
  final bool explicitDropNode;
}

/// Ключи, которые санитайзер не трогает.
///
/// `tag`/`detour` пишет сборка конфига, а не тело узла (`detour` вычисляется
/// из Направлений и цепочек). `type` — сам дискриминатор записи: схему по
/// нему и выбрали, и в `body.order` протокола его нет именно поэтому.
const _kBuildManagedKeys = {'type', 'tag', 'detour'};

/// Код по умолчанию для нарушения `type`: в правилах реестра он явно не
/// пишется (SPEC 131 §3.2).
const _kDefaultInvalidCode = 'type_invalid';

/// §469 — предел длины `value` предупреждения в рунах (CANON §6,
/// `WarningValueMax` контракта).
const _kWarningValueMax = 64;

/// Санитайзер тела записи по схеме реестра.
final class RegistrySanitizer {
  const RegistrySanitizer._();

  /// Очистить тело записи `outbounds[]`/`endpoints[]`.
  ///
  /// [scheme] — `type` записи (он же `singbox_type` реестра), [coreVersion] —
  /// версия запущенного ядра для гейта `min_core` (24.1.6), [platform] — ОС
  /// для гейта `platform`.
  ///
  /// Реестр не загружен либо схемы для [scheme] нет — тело возвращается как
  /// есть: неизвестный тип не повод выкидывать запись пользователя.
  ///
  /// §460 W2a — [applyCoreGates] `false` выключает гейты `min_core` и
  /// `platform`: они зависят от ЗАПУЩЕННОГО ядра, а `entry` узла от него не
  /// зависит (24.1.6). При разборе узла ядра ещё нет (и версия его к моменту
  /// сборки может стать другой), поэтому поле, которое ядро «пока не знает»,
  /// при разборе не снимается и о нём не сообщается — это работа гарда
  /// сборки.
  ///
  /// §473 — [source] нужен ровно одному правилу, `max_when.except_sources`:
  /// на входе [BodySource.singbox] завышенное значение сохраняется и узел
  /// получает info-код вместо замены. Параметр явный и обязательный к
  /// передаче на том пути, где вход известен: глобального состояния у
  /// санитайзера нет и не будет — оно разошлось бы с телом на первом же
  /// параллельном разборе. Дефолт [BodySource.other] — консервативный: он
  /// означает «вход неизвестен», и правило применяется как прежде, заменой.
  ///
  /// Контракт 1.1.22 — [kinds] РОД узла, объявленный входом (`kind_when`
  /// маппера), рядом с [source]: его читает оператор `when.source_kind`. У нас
  /// узел хранится ИСТОЧНИКОМ, и род восстанавливается перепарсом всегда, так
  /// что хранить его отдельно не нужно (MAPPER_ENGINE.md). Пусто — род
  /// неизвестен, и правило судит тело прежним `any_set`.
  static SanitizeResult sanitize(
    Map<String, dynamic> body, {
    required String scheme,
    required String coreVersion,
    String platform = 'android',
    bool applyCoreGates = true,
    BodySource source = BodySource.other,
    Set<String> kinds = const {},
  }) {
    final schema = ContractRegistry.I.schemaFor(scheme);
    if (schema == null) return SanitizeResult(body, const []);

    final ctx = _Ctx(
      scheme: scheme,
      coreVersion: coreVersion,
      platform: platform,
      applyCoreGates: applyCoreGates,
      source: source,
      kinds: kinds,
      root: body,
    );
    final out = ctx.sanitizeObject(body, schema.order, schema.fields, '');
    // §481 (контракт 1.1.11) — связи уровня ТЕЛА, по ЧИСТОЙ карте.
    //
    // Ловушка, на которую наступил лаунчер и которую здесь обходим с самого
    // начала: связь обязана читать результат санитайзинга, а не исходное тело.
    // Поле, снятое за негодное значение, в тело не поедет, и ядро прочтёт
    // вместо него свой дефолт; загляни связь в исходник, снятый
    // `h1 = "1-4294967296"` продолжал бы «пересекаться» с соседями и хоронил
    // бы узел кодом `awg_headers_overlap` вместо честного `awg_header_invalid`
    // на самом поле — вина уезжала бы не на того.
    if (!ctx.dropNode) ctx.applyBodyRelations(out, schema.relations);
    // Контракт 1.1.61 — правила-починки (`requires[].set`, `coerce_when`)
    // судятся по ГОТОВОМУ телу, после всех снятий; у отбракованного узла не
    // исполняются.
    if (!ctx.dropNode) ctx.applyRepairs(out);
    if (ctx.dropNode) {
      return SanitizeResult(null, ctx.warnings,
          explicitDropNode: ctx.explicitDropNode);
    }
    return SanitizeResult(out, ctx.warnings);
  }

  /// Значение для `value` предупреждения: у `secret`-полей — `***`, длинное
  /// обрезается до 64 РУН (24.1.4, CANON §6).
  ///
  /// §469 — форма нормирована КОРПУСОМ, не языком: карта печатается
  /// `map[ключ:значение ключ:значение]` с ключами по возрастанию, список —
  /// `[a b c]`, обрезка — 64 руны плюс `…`. Раньше здесь стоял `toString()`
  /// Dart (`{enabled: true, …}`) и обрезка 61+`...`, и `value` объектных
  /// полей расходился с ожиданиями корпуса (`tls_field_unsupported_naive` на
  /// `tls.utls`, `tls_not_applicable_quic` на QUIC) на одном лишь способе
  /// печати. Своего смысла у формы нет — это канон записи, и держать его надо
  /// одинаковым с обеих сторон.
  ///
  /// Публичный, потому что у `value` появился второй производитель: коды,
  /// которые при разборе ставит парсер, а не санитайзер
  /// (`forbiddenTlsBlockWarnings`, `parse_warnings.dart`).
  static String renderWarningValue(Object value, {bool secret = false}) {
    if (secret) return '***';
    return _truncateWarningValue(_renderWarningScalar(value));
  }
}

/// Печать значения по канону корпуса (см. [RegistrySanitizer.renderWarningValue]).
String _renderWarningScalar(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return 'map[${[
      for (final k in keys) '$k:${_renderWarningScalar(value[k])}',
    ].join(' ')}]';
  }
  if (value is List) {
    return '[${[for (final e in value) _renderWarningScalar(e)].join(' ')}]';
  }
  return value is String ? value : '$value';
}

/// Обрезка до [_kWarningValueMax] РУН (не кодовых единиц: значение вправе
/// нести не-ASCII) с многоточием-символом — зеркало `TruncateWarningValue`
/// контракта.
String _truncateWarningValue(String s) {
  final runes = s.runes.toList(growable: false);
  if (runes.length <= _kWarningValueMax) return s;
  return '${String.fromCharCodes(runes.take(_kWarningValueMax))}…';
}

/// Состояние одного прогона: накопитель warnings, флаг `drop_node` и корень
/// тела — связи (`conflicts`/`requires`) адресуются путями от корня
/// (`tls.reality.public_key`), а не от текущего объекта.
final class _Ctx {
  _Ctx({
    required this.scheme,
    required this.coreVersion,
    required this.platform,
    required this.applyCoreGates,
    required this.source,
    required this.kinds,
    required this.root,
  });

  final String scheme;
  final String coreVersion;
  final String platform;

  /// §473 — вход тела; читает его только `max_when.except_sources`.
  final BodySource source;

  /// Контракт 1.1.22 — РОД узла внутри одной схемы, объявленный ВХОДОМ
  /// (`kind_when` маппера), рядом с [source]. Читает его оператор
  /// `when.source_kind`.
  ///
  /// Род нельзя вывести из тела: негодные значения снимает правило поля, и к
  /// проверке потолка тело становится неотличимо от обычного узла, хотя
  /// протокол автор просил другой. Поэтому род едет контекстом, а не ключом
  /// тела — в тело он не пишется (MAPPER_ENGINE.md, «Контекст санитайзера:
  /// body_source + kind»).
  ///
  /// Пусто — род неизвестен (тело приехало без разбора источника); условие
  /// `source_kind` тогда ложно, и правило судит тело прежним `any_set`.
  final Set<String> kinds;

  /// §460 W2a — считать ли гейты, зависящие от запущенного ядра
  /// (`min_core`, `platform`). При разборе — нет (24.1.6).
  final bool applyCoreGates;
  final Map<String, dynamic> root;

  final warnings = <RegistryWarning>[];
  bool dropNode = false;

  /// §477 — запись сняло ЯВНОЕ правило `on_invalid: { action: drop_node }`,
  /// а не отсутствие обязательного поля. См. [SanitizeResult.explicitDropNode].
  bool explicitDropNode = false;

  /// §472 шаг 5 — снят ВЛОЖЕННЫЙ объект, а не узел: у него не хватило поля,
  /// объявленного `required` внутри него самого.
  ///
  /// Флаг живёт ровно один вызов `_sanitizeObjectField`: тот ставит его в
  /// `false` перед спуском и читает сразу после. Отдельный от [dropNode] он
  /// потому, что и отказ другой: узел остаётся, пропадает одна его секция
  /// (`hysteria2.obfs` без пароля — узел живёт без обфускации).
  bool dropObject = false;

  /// Снимок уже проверенных значений по абсолютному пути от корня тела.
  ///
  /// Связи (`conflicts`/`requires`) адресуются именно так
  /// (`tls.reality.public_key`), и смотреть им надо на состояние ПОСЛЕ
  /// проверки: поле, снятое как невалидное, зависимые обязаны считать
  /// отсутствующим — иначе `short_id` пережил бы мусорный `public_key`.
  final sanitized = <String, Object?>{};

  /// §472 шаг 3 — пути, СНЯТЫЕ этим же прогоном с объяснением.
  ///
  /// Зависимое поле (`requires`) уходит вслед за тем, чего ему не хватает, и
  /// второго сообщения это не заслуживает: человек уже прочёл, ПОЧЕМУ ушёл
  /// `tls.reality.public_key`, а «`short_id` требует `public_key`» добавляет
  /// к этому только шум. Корпус нормирует ровно так: у
  /// `vless/reality_pbk_junk_degrade`, `tls_pbk_junk_enabled` и
  /// `reality_key_share_without_pbk_ignored` в ожидании ОДИН код —
  /// `reality_pbk_invalid`, а комментарий последнего говорит прямо: «снят не
  /// он, а весь блок, поэтому кода `reality_key_share_invalid` НЕТ».
  ///
  /// Поле, которого в теле НЕ БЫЛО вовсе, сюда не попадает: там `requires`
  /// — единственное объяснение, и код нужен (корпус
  /// `hysteria2/salamander_ignores_gecko_sizes`).
  final explainedDrops = <String>{};

  /// §544 (контракт 1.1.55) — пути, снятые как ВЫКЛЮЧАТЕЛЬ: литерал
  /// `absent_values` (`encryption: none`) или объект по `absent_when`
  /// (`tls: {enabled: false}`).
  ///
  /// Для связей такое поле НЕ ЗАДАНО, хотя в исходном теле оно написано:
  /// связи читают исходное тело ([_presentInSource]), и без этой пометки
  /// `encryption: none` отменял бы `unless_set` конфликта `flow ↔ transport`,
  /// хотя слоя шифрования нет. У лаунчера то же делает предварительный проход
  /// (`markAbsentObjects`); здесь хватает записи в момент снятия — связи
  /// объекта судятся после разбора всех его полей.
  final switchedOff = <String>{};

  /// Контракт 1.1.56 (норма 1) — чистые карты объектов, обход которых ЕЩЁ
  /// ИДЁТ, по префиксу пути (`transport`; корень — `''`).
  ///
  /// В снимок [sanitized] поля объекта попадают только по завершении его
  /// обхода, а условия соседей (`default_when.when` с предикатом по значению)
  /// судятся посреди него. Карта живёт ровно на время обхода объекта. Эталон
  /// — `building` в `nodeflow/sanitize.go`.
  final _building = <String, Map<String, Object?>>{};

  /// Контракт 1.1.61 — отложенные правила-починки: записываются по ходу
  /// обхода (там, где встал бы их код), исполняются [applyRepairs] по
  /// готовому телу.
  final _repairs = <_Repair>[];

  /// §556 — позиция в [warnings] сразу за кодами поля (абсолютный путь).
  final _fieldEnd = <String, int>{};

  /// Код связи поля [order]`[i]` — на место поля в обходе, а не в хвост.
  void _relWarn(List<String> order, int i, String prefix, String code,
      {String? path, Map<String, String> params = const {}}) {
    final me = _join(prefix, order[i]);
    final pos = _fieldEnd[me] ?? warnings.length;
    warnings.insert(
        pos, RegistryWarning(code: code, path: path, params: params));
    final later = {for (final k in order.skip(i)) _join(prefix, k)};
    for (final e in _fieldEnd.entries.toList()) {
      if (e.value > pos || (e.value == pos && later.contains(e.key))) {
        _fieldEnd[e.key] = e.value + 1;
      }
    }
    for (final r in _repairs) {
      if (r.index >= pos) r.index++;
    }
  }

  void warn(
    String code, {
    String? path,
    Object? value,
    bool secret = false,
    Map<String, String> params = const {},
  }) {
    warnings.add(RegistryWarning(
      code: code,
      path: path,
      value: value == null
          ? null
          : RegistrySanitizer.renderWarningValue(value, secret: secret),
      params: params,
    ));
  }

  /// §472 шаг 5 — параметры кода, объявленного у `required`-поля.
  ///
  /// Текст такого кода говорит о БЛОКЕ, и назвать блок он может только
  /// соседним полем: `obfs_password_missing` печатает `{type}` — какую именно
  /// обфускацию сняли. Значение берётся из ИСХОДНОГО объекта: к этому моменту
  /// разбор до соседа мог и не дойти, а в теле он уже лежит.
  ///
  /// Соседа нет или он не строка — параметра нет вовсе: подстановка `{type}`
  /// останется видна в тексте, и это честнее выдуманного значения.
  Map<String, String> _requiredParams(Map<String, dynamic> src) {
    final type = src['type'];
    return type is String && type.isNotEmpty ? {'type': type} : const {};
  }

  /// Обход объекта по схеме. [prefix] — путь от корня тела (пустой у корня),
  /// он же адресация связей и текст `{path}` предупреждений.
  Map<String, dynamic> sanitizeObject(
    Map<String, dynamic> src,
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
  ) {
    final out = <String, dynamic>{};

    // 1. Неизвестные реестру ключи — снять (24.1.3). Ядро отвергает такой
    // ключ ошибкой на ВЕСЬ конфиг, оставить его нельзя.
    //
    // §470 — `value` ставится и здесь: конверт корпуса называет его у
    // `unknown_key` (`manual_object_junk`), и лаунчер печатает снятое
    // значение (`nodeflow/sanitize.go` → `s.warn("unknown_key", path,
    // src[name], …)`). Без него человек видел «ключ снят» и не знал, ЧТО
    // именно снято, а раннер тел молча расходился с контрактом на одном
    // недостающем поле. `secret` тут неоткуда взять: ключа в схеме нет, а
    // значит нет и его флага — печатаем как есть, ровно как вторая сторона.
    // Контракт 1.1.57 — неизвестные ключи судятся по алфавиту (корпус
    // `masque_legacy_flat_keys`), а не в порядке прибытия.
    for (final key in src.keys.toList()..sort()) {
      if (fields.containsKey(key)) continue;
      if (prefix.isEmpty && _kBuildManagedKeys.contains(key)) continue;
      warn('unknown_key', path: _join(prefix, key), value: src[key]);
    }

    // 2. Значения — по одному, в порядке схемы: и результат, и список
    // warnings становятся детерминированными.
    final kept = <String, Object?>{};
    _building[prefix] = kept;
    try {
      return _sanitizeObjectBody(src, order, fields, prefix, kept, out);
    } finally {
      _building.remove(prefix);
    }
  }

  Map<String, dynamic> _sanitizeObjectBody(
    Map<String, dynamic> src,
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
    Map<String, Object?> kept,
    Map<String, dynamic> out,
  ) {
    String? prevPath;
    for (final key in order) {
      // §556 — конец кодов поля в `warnings`: код связи встаёт сюда, как у
      // лаунчера (поле судится целиком, прежде чем обход идёт дальше).
      if (prevPath != null) _fieldEnd[prevPath] = warnings.length;
      prevPath = _join(prefix, key);
      final f = fields[key];
      if (f == null) continue;
      final unset = !src.containsKey(key) || _unsetForDefault(src[key], f);
      if (unset && src.containsKey(key)) {
        // Контракт 1.1.56 (норма 2) — пустая строка у обычного поля и
        // литерал-выключатель (`absent_values`) равны отсутствию ключа:
        // `default_when` срабатывает так же, как на пропущенный ключ
        // (`mode: ""` + header → packet-up). Не сработал — прежний путь:
        // выключатель снимается [_sanitizeScalar] (с пометкой
        // [switchedOff]), пустая строка — молча, как у лаунчера
        // (`omitAsUnset`).
        final dw = f.defaultWhen;
        final fires = dw != null &&
            dw['absent'] == true &&
            _conditionHolds(dw['when'], src);
        if (!fires) {
          final v = src[key];
          if (v is String && v.isEmpty) continue;
          final path = _join(prefix, key);
          final res = _sanitizeValue(v, f, path);
          if (dropNode) return out;
          if (res.keep) kept[key] = res.value;
          continue;
        }
      }
      if (unset) {
        // §464 (W2d) — `default_when`: дефолт, без которого ядро не поднимает
        // outbound вовсе (полоса hysteria v1 — «missing upload speed» фаталом
        // на ВЕСЬ конфиг). В отличие от `default` (CANON §2.4 — не пишется),
        // такой дефолт материализуется явно, и кода на него нет: узел жив и в
        // порядке.
        //
        // §473 (контракт 1.1.5) — у `default_when` появилось условие `when`:
        // дефолт, зависящий от РОДА узла. `mtu: 1280` дописывается только
        // AmneziaWG-узлу; обычный WireGuard поля не получает вовсе — ядро
        // берёт свой 1408, и наш дефолт спорил бы с ним и ломал identity-хеш
        // (CANON §2.4).
        // §481 (контракт 1.1.11) — `min_when.absent_is_zero`: порог действует
        // и на ОТСУТСТВУЮЩЕЕ поле. Стоит ДО `default_when`: у `s1`–`s4`
        // дефолта нет вовсе, а появись он — материализованный дефолт судил бы
        // сам себя.
        //
        // §549 R2 — путь строится внутри, только когда правило есть: у
        // большинства полей схемы его нет, а отсутствующих полей у узла — все,
        // кроме нескольких.
        _minWhenOnAbsent(f, prefix, key);
        if (dropNode) return out;
        final dw = f.defaultWhen;
        if (dw != null &&
            dw['absent'] == true &&
            _conditionHolds(dw['when'], src)) {
          kept[key] = dw['value'];
          final code = dw['code'] as String?;
          if (code != null) warn(code, path: _join(prefix, key));
          continue;
        }
        // `required` без поля — запись уходит целиком (24.1.7): ядро такую
        // не принимает и роняет весь конфиг.
        //
        // §472 шаг 5 — но только на КОРНЕ тела. Внутри вложенного объекта
        // единица отказа — сам объект, а не узел: реестр пишет это прямо у
        // `hysteria2.obfs.password` («отсутствие пароля снимает блок obfs
        // целиком, узел живёт без обфускации»), и корпус ждёт того же
        // (`uri/hysteria2/obfs_no_password_dropped` — узел с телом и одним
        // кодом `obfs_password_missing`). Прежний код ронял такой узел
        // ЦЕЛИКОМ; заметить это было нечем, пока obfs собирал рукописный
        // `normalizeHysteria2Obfs` до санитайзера, а в корпусе тел кейса без
        // пароля нет вовсе.
        //
        // Форма записи у двух кодов разная, и разводит их сам реестр. Общий
        // `field_missing` — про УЗЕЛ («узел отброшен»), адреса у него нет, имя
        // поля лежит в `params.field`. Код, объявленный у поля через `code`, —
        // про БЛОК (`obfs_password_missing`: «весь блок обфускации снят, узел
        // подключается без обфускации»), и он адресуется полем: ожидание
        // корпуса называет `path: obfs.password`, а `params` у него свои
        // (`type` — какую обфускацию сняли).
        if (f.required) {
          final own = f.code;
          if (own == null) {
            warn('field_missing', params: {'field': _join(prefix, key)});
          } else {
            warn(own, path: _join(prefix, key), params: _requiredParams(src));
          }
          if (prefix.isEmpty) {
            dropNode = true;
          } else {
            dropObject = true;
            return out;
          }
        }
        continue;
      }
      final path = _join(prefix, key);
      final res = _sanitizeValue(src[key], f, path);
      if (dropNode) return out;
      // §472 шаг 5 — обязательное поле, СНЯТОЕ как негодное, равносильно
      // отсутствующему: причина уже названа своим кодом (`type_invalid` на
      // `uuid` не в форме UUID), а запись без него ядро не примет — у tuic
      // это «invalid uuid» фаталом на ВЕСЬ конфиг. Прежде такой узел уезжал
      // с ПУСТЫМ значением: ни прежнего поведения, ни честной отбраковки.
      //
      // Граница та же, что у отсутствующего поля выше: на корне уходит узел,
      // внутри объекта — сам объект (мусорный `reality.public_key` оставляет
      // узел на plain TLS, ровно как этого требует реестр).
      if (!res.keep && f.required) {
        if (prefix.isEmpty) {
          dropNode = true;
        } else {
          dropObject = true;
        }
        return out;
      }
      if (res.keep) {
        kept[key] = res.value;
        _recordCoerceWhen(f, path, res.value);
      }
    }

    // Состояние ПОСЛЕ проверки значений: связи обязаны видеть его, а не
    // исходное тело. Поле, снятое как невалидное, для зависимых от него —
    // отсутствует (reality.short_id без валидного public_key).
    //
    // §549 R2 — пути записанных ключей запоминаются: синхронизации после
    // связей нужны только они (ключа вне `kept` в снимке нет — других
    // писателей у `sanitized` нет, а пути у объектов разные).
    if (prevPath != null) _fieldEnd[prevPath] = warnings.length;
    final written = <String, String>{};
    for (final e in kept.entries) {
      final path = _join(prefix, e.key);
      written[e.key] = path;
      sanitized[path] = e.value;
    }

    // 3. Связи между полями — когда состав уже известен: `requires` смотрит
    // на соседей, `conflicts` снимает декларанта (§474).
    _applyRelations(kept, order, fields, prefix);

    // Связи могли что-то снять — синхронизируем снимок.
    for (final e in written.entries) {
      if (!kept.containsKey(e.key)) sanitized.remove(e.value);
    }

    // Порядок ключей результата — ВХОДЯЩИЙ, а не `order` схемы.
    //
    // `order` реестра нормирует ЭМИТТЕР (24.1.1), а гард §460 — второй
    // эшелон над уже собранным телом: он снимает негодные значения, но
    // переставлять ключи ему нечего — валидный конфиг обязан остаться байт в
    // байт прежним (эталоны rich_v0/avd_v0). Порядок станет схемным вместе с
    // переездом эмиссии на реестр, волной W2.
    //
    // Ключи сборки (`type`/`tag`/`detour`) идут здесь же, на своих местах:
    // схема их не описывает, но снимать их нельзя — без `tag` запись
    // безымянна, без `detour` рушится маршрут.
    for (final key in src.keys) {
      if (kept.containsKey(key)) {
        out[key] = kept[key];
      } else if (prefix.isEmpty && _kBuildManagedKeys.contains(key)) {
        out[key] = src[key];
      }
    }
    // Ключи, появившиеся в санитайзинге (дефолты all_or_nothing лежат внутри
    // своего объекта, но на всякий случай) — в конец.
    for (final e in kept.entries) {
      if (!out.containsKey(e.key)) out[e.key] = e.value;
    }
    return out;
  }

  /// Контракт 1.1.56 (норма 2) — значение, равное отсутствию ключа: пустая
  /// строка у обычного поля (не `required`, не `tristate` — у них пустое
  /// значимо) и скаляр-литерал `absent_values` (после `normalize`).
  static bool _unsetForDefault(Object? v, FieldSchema f) {
    if (v is! String) return false;
    if (v.isEmpty) return !f.required && f.raw['tristate'] != true;
    final absent = f.absentValues;
    if (absent == null) return false;
    final norm = f.normalize;
    final n = norm == null ? v : _normalizeString(v, norm);
    return absent.contains(n);
  }

  /// Гейты уровня поля: годность значения они не проверяют, но само значение
  /// им нужно — контракт требует его в `value` предупреждения (CANON §6:
  /// «исходное значение до деградации»). `true` — поле снято.
  bool _gated(FieldSchema f, String path, Object? value) {
    // `forbidden_for` / `allowed_for` — по схеме записи. Код обязателен по
    // схеме реестра; если его всё же нет, код типа лучше молчания.
    //
    // §469 (контракт 1.1.4) — код берётся через `forbidden_codes`: один и тот
    // же запрет у разных схем даёт разный исход, и словарь «схема → код» это
    // выражает (`tls.utls` на naive — потерянная настройка, на QUIC —
    // снятая бессмыслица).
    //
    // Значение снятого блока идёт в `value` предупреждения: контракт зовёт
    // его «исходным значением до деградации» (CANON §6), и для объекта это
    // сам объект. Секрета в `utls`/`reality` нет, `secret` у полей стоит
    // точечно и проверяется тем же `f.secret`.
    final forbidden = f.forbiddenFor;
    if (forbidden != null && forbidden.contains(scheme)) {
      warn(f.forbiddenCodeFor(scheme) ?? _kDefaultInvalidCode,
          path: path, value: value, secret: f.secret);
      return true;
    }
    final allowed = f.allowedFor;
    if (allowed != null && !allowed.contains(scheme)) {
      warn(f.code ?? _kDefaultInvalidCode,
          path: path, value: value, secret: f.secret);
      return true;
    }
    // `min_core` — гейт СБОРКИ (24.1.6): ключ, неизвестный запущенному ядру,
    // эмиттер опускает. Кода нет намеренно — узел жив и в порядке, причина
    // уходит в лог сборки, а не в ⚠ пользователю.
    if (!applyCoreGates) return false;
    final minCore = f.minCore;
    if (minCore != null && !coreAtLeast(coreVersion, minCore)) return true;
    // `platform` — то же самое: kTLS вне Linux валит весь конфиг.
    final plat = f.platform;
    if (plat != null && plat != platform) return true;
    return false;
  }

  _Value _sanitizeValue(Object? value, FieldSchema f, String path) {
    if (_gated(f, path, value)) return const _Value.drop();

    // §481 (контракт 1.1.12, CANON §6.1) — `absent_when`: ВЫКЛЮЧАТЕЛЬ ВНУТРИ
    // САМОГО ОБЪЕКТА. Совпали все перечисленные ключи — объект снимается
    // ЦЕЛИКОМ и ТИХО: это запись «настройки нет», а не деградация, и сообщать
    // человеку нечего.
    //
    // Проверка стоит ЗДЕСЬ, до спуска, и это нормативный порядок: судится ДО
    // правил полей самого объекта и ДО связей соседей (`conflicts`/`requires`/
    // `forbidden_for`, условия `when.any_set`). Снятый объект «не задан» для
    // любой проверки наличия, и вместе с ним исчезает всё, что внутри.
    // Иначе `tls: {enabled: false, reality: {…}}` дал бы коды на поля блока,
    // которого в теле не будет, а сосед потерял бы своё значение из-за
    // конфликта с несуществующим блоком.
    //
    // У `tls` атрибут стоит ОДИН раз, на секции суб-схемы, и реестр при
    // развороте ссылки переносит его в поле каждого протокола (§553) —
    // отдельной копии на схему не заводится.
    final absentWhen = f.absentWhen;
    if (absentWhen != null &&
        value is Map &&
        _absentWhenHolds(absentWhen, value)) {
      switchedOff.add(path);
      return const _Value.drop();
    }

    switch (f.type) {
      case 'object':
        if (f.variants != null) return _sanitizeVariantObject(value, f, path);
        return _sanitizeObjectField(value, f, path);
      case 'array':
        return _sanitizeArray(value, f, path);
      case 'ref':
        // §553 — ссылку, которую реестр не смог разрешить при загрузке,
        // судить нечем: значение остаётся как есть (так было и до
        // разворота). В бандле таких нет — это ловит registry_load_test.
        return _Value.keep(value);
      default:
        return _sanitizeScalar(value, f, path);
    }
  }

  /// §553 — объект с вариантами по дискриминатору (`transport` по `type`):
  /// реестр развернул ссылку `transports` при загрузке, вариант берётся из
  /// самого поля ([FieldSchema.variants]).
  _Value _sanitizeVariantObject(Object? value, FieldSchema f, String path) {
    if (value is! Map) return _invalid(f, path, value);
    final disc = f.discriminator ?? 'type';
    final map = value.cast<String, dynamic>();
    final type = map[disc];
    if (type is! String) {
      // Транспорт без `type` ядро не разберёт вовсе — тот же тип-фатал.
      return _invalid(f, path, value);
    }
    final variant = f.variants![type];
    if (variant == null) return _invalid(f, path, type);
    // `type` — сам дискриминатор: в `order` варианта его нет, но снимать
    // его нельзя, иначе транспорт перестанет быть транспортом.
    final inner = Map<String, dynamic>.from(map)..remove(disc);
    final cleaned = sanitizeObject(
        inner, variant.order ?? const [], variant.fields ?? const {}, path);
    return _Value.keep(<String, dynamic>{disc: type, ...cleaned});
  }

  /// Поле-объект: собственный объект схемы (`tls.reality`, `hysteria2.obfs`)
  /// и развёрнутая ссылка на общую суб-схему (`tls`, `multiplex`, §553 —
  /// у такого поля [FieldSchema.originRef]). Граница §472 шаг 5 у них одна:
  /// не хватило `required` внутри объекта — снимается он, а не узел, и не
  /// важно, описан объект ссылкой или на месте.
  _Value _sanitizeObjectField(Object? value, FieldSchema f, String path) {
    if (value is! Map) return _invalid(f, path, value);
    final map = value.cast<String, dynamic>();
    final fields = f.fields;
    // Объект без `fields` — свободная карта (`transport.headers`): состав
    // задаёт не реестр, внутрь санитайзер не смотрит.
    if (fields == null) return _Value.keep(map);

    // §472 шаг 5 — объект, которому не хватило собственного `required`-поля,
    // снимается целиком, а узел живёт. Флаг гасится ПЕРЕД спуском: он
    // относится к этому объекту, а не к соседу, разобранному раньше.
    dropObject = false;
    final cleaned = sanitizeObject(map, f.order ?? const [], fields, path);
    if (dropNode) return const _Value.drop();
    if (dropObject) {
      dropObject = false;
      return const _Value.drop();
    }

    // §467 — `all_or_nothing` НЕ влечёт действия санитайзера.
    //
    // Атрибут читался наоборот: считалось, что частичный объект надо
    // дополнить дефолтами соседей. Ядро при частично заданной секции
    // оставляет незаданные поля НУЛЯМИ (= без лимита), поэтому дописывание
    // навязывало узлу лимиты, которых у него не было: у 13 живых узлов
    // vless+xhttp одной подписки лаунчера так испортился рабочий `xmux`
    // (контракт §24.9). Атрибут остаётся в реестре документацией о поведении
    // ядра, частичный объект проходит как есть. Код `partial_object_defaulted`
    // снят из `warnings.json` вместе с этим правилом.
    return _Value.keep(cleaned);
  }

  _Value _sanitizeArray(Object? value, FieldSchema f, String path) {
    if (value is! List) return _invalid(f, path, value);
    final items = f.items;
    if (items == null) return _Value.keep(value);
    final out = <Object?>[];
    for (var i = 0; i < value.length; i++) {
      final res = _sanitizeValue(value[i], items, '$path[$i]');
      if (dropNode) return const _Value.drop();
      if (res.keep) out.add(res.value);
    }
    // `len` у массива — точное число элементов (wireguard.peers[].reserved).
    final len = f.len;
    if (len != null && out.length != len) return _invalid(f, path, value);
    return _Value.keep(out);
  }

  _Value _sanitizeScalar(Object? value, FieldSchema f, String path) {
    // §481 — `range_order` идёт ДО приведения типа, в отличие от прочих
    // нормализаций. Причина в том, что он ИСПРАВЛЯЕТ негодность: перевёрнутая
    // пара `awg_range` не проходит coerce вовсе (у таймингов AWG 3.x она и
    // должна не проходить), и своп после него никогда бы не сработал.
    // Нормализация написания обязана идти раньше судьи — здесь это видно
    // буквально.
    var value0 = value;
    if (f.normalize == 'range_order' && value0 is String) {
      value0 = _normalizeString(value0, 'range_order');
    }
    final coerced = _coerceType(value0, f.type);
    if (coerced == null) return _invalid(f, path, value);
    var v = coerced.value;

    // `normalize` — ДО проверки enum/format. Ставится только там, где ядро
    // case-sensitive и обе стороны нормализуют.
    final norm = f.normalize;
    if (norm != null && v is String) {
      v = _normalizeString(v, norm);
    }
    // `listable_string` нормализуется поэлементно.
    if (norm != null && v is List) {
      v = [
        for (final e in v)
          if (e is String) _normalizeString(e, norm) else e,
      ];
    }
    // Контракт 1.1.63 — `item_forbidden`: запрещённый элемент (после
    // normalize) снимается элементом со своим кодом, годные остаются.
    final itemForbidden = f.raw['item_forbidden'];
    if (itemForbidden is Map && v is List) {
      final banned =
          ((itemForbidden['values'] as List?) ?? const []).map((e) => '$e');
      final kept0 = [];
      for (var i = 0; i < v.length; i++) {
        final e = v[i];
        if (banned.contains('$e')) {
          warn(itemForbidden['code'] as String? ?? _kDefaultInvalidCode,
              path: '$path[$i]', value: e);
        } else {
          kept0.add(e);
        }
      }
      if (kept0.isEmpty) return const _Value.drop();
      v = kept0;
    }

    // §477 (контракт 1.1.9) — `absent_values`: значения-ВЫКЛЮЧАТЕЛИ.
    //
    // Порядок нормативен и одинаков на всех входах: нормализация (у
    // `encryption` это `trim`) → выключатель → остальные ограничения. Поле
    // просто не пишется: слоя нет, кода нет, судить нечего.
    //
    // Сравнение ТОЧНОЕ, и это изменение против прежнего поведения. Ядро
    // сличает свой литерал `none` с учётом регистра, поэтому `None` для него
    // НАСТОЯЩЕЕ значение, на котором падает весь конфиг. Спрячь мы его под
    // видом «слоя нет» — негодный узел уехал бы в ядро, и упал бы не он один,
    // а вся конфигурация. Поэтому `None` идёт дальше, к `pattern`, и
    // отбраковывается — одинаково в ссылке, в теле sing-box и в Xray-JSON.
    //
    // Проверка стоит ДО `values`/`format`/`pattern` и после `normalize`
    // намеренно: выключатель — это отсутствие значения, а не значение, и
    // судить его набором или выражением значило бы хоронить узел за
    // выключенную настройку.
    final absent = f.absentValues;
    if (absent != null && v is String && absent.contains(v)) {
      switchedOff.add(path);
      return const _Value.drop();
    }

    // §464 (W2d) — `normalize_code`: нормализация, которая ЗАБРАЛА часть
    // значения, обязана объявить потерю. `0x1a2` → `01a2` — другой short_id,
    // и молчать о нём нельзя ни на одном из входов (DRIFT §2(b)).
    //
    // Код ставится на исходном значении: человеку нужно видеть, что он
    // написал, а не что из этого осталось.
    //
    // §472 шаг 3 — сравнение идёт с `lower(trim(исходного))`, а не с самим
    // исходным. Регистр и обрамляющие пробелы не ЗАБИРАЮТ ничего: `sid=ABCD`
    // и `sid=abcd` — один и тот же идентификатор, и корпус на нём кода не
    // ждёт (`vless/reality_valid_pbk_sid` — `warnings` нет вовсе), тогда как
    // `0x1a2` и `48 ab12` его ждут. Эталон Go ровно такой же —
    // `realityShortIDWouldDegrade` сверяет с `strings.ToLower(TrimSpace(raw))`
    // (зеркало в Dart: `realityShortIdWouldDegrade`, `uri_utils.dart`).
    // Расхождение было латентным: до конвейера `hex_only` встречался только на
    // JSON-входе, где написанного заглавными `sid` в корпусе нет.
    final normCode = f.normalizeCode;
    if (normCode != null && v != _foldForNormalizeCode(coerced.value)) {
      warn(normCode, path: path, value: coerced.value, secret: f.secret);
    }

    // `values` — закрытый набор. У `listable_string` проверяется каждый
    // элемент (network: tcp/udp).
    final values = f.values;
    if (values != null) {
      final bad = v is List
          ? v.where((e) => !values.contains(e)).toList()
          : (values.contains(v) ? const [] : [v]);
      if (bad.isNotEmpty) return _invalid(f, path, bad.first, secret: f.secret);
    }

    // `format` / `min` / `max` / `len` / `len_parity`.
    final violation = _checkConstraints(v, f);
    if (violation != null) {
      return _invalid(f, path, violation, secret: f.secret);
    }

    // §477 (контракт 1.1.9) — `pattern`: форма строкового значения.
    //
    // Проверяется ПОСЛЕ `normalize` и `absent_values`, по значению, которое
    // ляжет в тело. Якоря — в самом выражении: режим «совпасть целиком»
    // сторонам не задать одинаково, а `^…$` читается одинаково и Go RE2, и
    // Dart.
    //
    // В код уезжает СЫРОЕ значение, до обрезки ([coerced.value]): человеку
    // нужно видеть, что он написал, а не то, что от написанного осталось. Это
    // та же причина, по которой сырое значение носит `normalize_code`.
    //
    // Некомпилируемое выражение ПРОПУСКАЕТСЯ (24.1: реестр впереди кода —
    // рабочее состояние, а не повод отбраковать годный узел). Опечатку в
    // выражении ловит линтер реестра, а не рантайм.
    final pattern = f.pattern;
    if (pattern != null && v is String) {
      final re = _compilePattern(pattern);
      if (re != null && !re.hasMatch(v)) {
        return _invalid(f, path, coerced.value, secret: f.secret);
      }
    }

    // Контракт 1.1.40 — `item_pattern` + `on_item_invalid`: форма ЭЛЕМЕНТА
    // списка. Запрос наш (19.09.2026), исход — атрибут реестра, а не код.
    //
    // Почему не `pattern`: тот судит значение ЦЕЛИКОМ, и один негодный
    // элемент снял бы список со всеми остальными. Ядру же довольно одного
    // негодного элемента, чтобы отвергнуть ВЕСЬ конфиг (hysteria2:
    // «bad port range»), — значит нужна операция, которая выбрасывает
    // элемент и оставляет соседей рабочими.
    //
    // Порядок нормативен (реестр, §36.2): `normalize` → элементы →
    // ограничения поля. `trim` у `tls.alpn` стоит рядом намеренно:
    // `alpn=h2, h3` даёт элемент с ведущим пробелом, и без обрезки формат
    // выбросил бы живое значение вместо того, чтобы его починить.
    //
    // Путь кода — ЭЛЕМЕНТ (`server_ports[0]`), по ИСХОДНОМУ индексу: дедуп
    // деградаций идёт по паре (код, путь), и общий путь схлопнул бы два
    // разных негодных элемента одного списка в одно сообщение. В код уезжает
    // элемент, каким его написал автор, — по той же причине, что у
    // `pattern`.
    //
    // Некомпилируемое выражение и `action`, которого код не знает,
    // ПРОПУСКАЮТСЯ: реестр вправе уехать вперёд кода (24.1), и это не повод
    // хоронить рабочий узел.
    final itemPattern = f.itemPattern;
    if (itemPattern != null && v is List) {
      final re = _compilePattern(itemPattern);
      final onItem = f.onItemInvalid;
      final action = onItem?['action'] as String?;
      final itemCode = onItem?['code'] as String?;
      if (re != null && itemCode != null) {
        if (action == 'drop_item') {
          final kept = <dynamic>[];
          for (var i = 0; i < v.length; i++) {
            final e = v[i];
            // Нестроковый элемент судится тоже (ревью после v2.25.1, M1).
            // `item_pattern` стоит только у полей, которые ядро читает как
            // `Listable[string]`, и число в элементе для него — ошибка
            // unmarshal на разборе, то есть отказ ВСЕГО конфига, а не узла.
            // Форма `listable_string` пропускает `String|num` (так пишут
            // источники), поэтому элемент-число сюда доезжает. Строкой ядро
            // его не прочтёт — элемент снимается тем же кодом, что и
            // негодная строка; в код уезжает как написан.
            if (e is! String || !re.hasMatch(e)) {
              warn(itemCode,
                  path: '$path[$i]', value: e, secret: f.secret);
              continue;
            }
            kept.add(e);
          }
          // Список, оставшийся пустым, — это отсутствие значения, а не
          // негодное значение: поле просто не пишется. Ядро в таком случае
          // берёт своё умолчание (у ALPN — протокол, вытекающий из
          // транспорта), и узел остаётся рабочим.
          if (kept.isEmpty) return const _Value.drop();
          v = kept;
        } else if (action != null) {
          _logUnknownExpression('on_item_invalid.action', action);
        }
      }
    }

    // §473 (контракт 1.1.5) — `max_when`: УСЛОВНЫЙ потолок. В отличие от
    // `max`, нарушение которого делает значение негодным (`on_invalid` →
    // поле снимается), здесь значение законно — потолок диктует род узла, и
    // исход правила зависит от того, КТО тело написал.
    v = _applyMaxWhen(v, f, path);

    // §481 (контракт 1.1.11) — `min_when`: УСЛОВНЫЙ порог снизу. Значение не
    // заменяется, узел уходит целиком (см. [_applyMinWhen]).
    if (_applyMinWhen(v, f, path)) return const _Value.drop();

    // `advisory` — ядро значение принимает, но узел получает info-код.
    // Поле НЕ меняется.
    //
    // Две формы отбора (§464, W2d):
    //   `values` — перечислено, на чём код ставится (ss legacy-шифры);
    //   `except` — перечислено, на чём НЕ ставится (reality_fp_not_chrome:
    //   отпечатков у ядра три десятка, а гибридный шар есть у девяти).
    // `when` — дополнительное условие по другому полю тела: код про REALITY
    // не имеет смысла на узле без REALITY.
    //
    // §474 (контракт 1.1.6) — `values` принимает и BOOLEAN: `tls.insecure:
    // true` даёт info-код `tls_insecure`, значение сохраняется. Отбор именно
    // по значению, а не `except`: у bool «не задано» и `false` неразличимы, и
    // код обязан стоять ровно на `true`. Сравнение `vals.contains(v)` работает
    // на bool как есть — отдельной ветки тип не требует.
    for (final a in f.advisory) {
      final code = a['code'] as String?;
      if (code == null) continue;
      final vals = (a['values'] as List?)?.cast<Object?>();
      final except = (a['except'] as List?)?.cast<Object?>();
      if (vals != null && !vals.contains(v)) continue;
      // Пустое значение под `except` не попадает по определению: «не задано»
      // — не выбор автора ссылки (tls.json, impl у fingerprint).
      if (except != null && (except.contains(v) || v == null || v == '')) {
        continue;
      }
      if (!_advisoryWhen(a['when'])) continue;
      warn(code,
          path: path,
          value: v,
          secret: f.secret,
          params: _advisoryParams(code, v));
    }

    return _Value.keep(v);
  }

  /// §474 — подстановки advisory-кода ПО ЕГО ОБЪЯВЛЕНИЮ в `warnings.json`.
  ///
  /// `path` и `value` подставляются всегда (`text_params_implicit`) и сюда не
  /// попадают — их несут одноимённые поля warning'а. Остаётся то, что код
  /// объявил сам, и единственная осмысленная подстановка для правила значения
  /// — само значение: `ss_method_legacy` зовёт его `{method}`.
  ///
  /// Раньше `{method}` ставился безусловно. Коду, который его не объявлял,
  /// лишний параметр не мешал, но и не помогал: `tls_insecure` объявляет
  /// `path` и `value`, и заполняются они сами. Явный разбор нужен, чтобы
  /// новый advisory-код со своим именем параметра не потребовал правки здесь
  /// — тест рендера всех кодов реестра поймает незаполненный `{…}` сразу.
  Map<String, String> _advisoryParams(String code, Object? v) {
    final declared = ContractRegistry.I.textFor(code)?.params ?? const [];
    final text = v is String ? v : '$v';
    return {
      for (final p in declared)
        if (p != 'path' && p != 'value') p: text,
    };
  }

  /// §473 — условный потолок `max_when`. Возвращает значение, которое
  /// остаётся в теле: заменённое потолком либо исходное.
  ///
  /// Три исхода, и путать их нельзя:
  ///
  /// 1. условие `when` не выполнено (узел не того рода) — правила нет вовсе;
  /// 2. выполнено, вход НЕ в `except_sources` — значение заменяется потолком,
  ///    код `code` (severity warning);
  /// 3. выполнено, вход В `except_sources` — значение остаётся, код
  ///    `note_code` (severity info).
  ///
  /// Исход 3 — единственное место контракта, где вход узла влияет на
  /// результат (решение владельца 18.09.2026): тело в форме ядра человек или
  /// подписка написали сами, и молча переписывать его нельзя.
  ///
  /// Условие читается по ИСХОДНОМУ телу объекта ([root] через [_anySetInBody]),
  /// а не по уже очищенному: род узла задаёт то, что автор написал. Битый
  /// `jc`, снятый парой строк выше, AmneziaWG-узел AmneziaWG-узлом быть не
  /// перестаёт (§463 — то же основание у рукописного `isAwg`).
  Object? _applyMaxWhen(Object? v, FieldSchema f, String path) {
    final rule = f.maxWhen;
    if (rule == null) return v;
    final ceiling = rule['max'];
    if (v is! num || ceiling is! num) return v;
    if (v <= ceiling) return v;
    if (!_conditionHolds(rule['when'], root)) return v;

    final except = (rule['except_sources'] as List?)?.map((e) => '$e');
    if (except != null && except.contains(source.registryName)) {
      final note = rule['note_code'] as String?;
      // `note_code` обязателен по схеме при `except_sources`; без него
      // молчание лучше выдуманного кода — значение всё равно сохраняется.
      if (note != null) warn(note, path: path, value: v, secret: f.secret);
      return v;
    }

    final code = rule['code'] as String?;
    // Код на ИСХОДНОМ значении: человеку нужно видеть, что он написал.
    if (code != null) warn(code, path: path, value: v, secret: f.secret);
    return ceiling;
  }

  /// §481 (контракт 1.1.12) — выполнено ли условие `absent_when`.
  ///
  /// Совпасть обязаны ВСЕ перечисленные ключи: перечисление — это «и», а не
  /// «или». Отсутствующий у объекта ключ условия совпадением не считается —
  /// `tls: {server_name: …}` без `enabled` это НЕ «TLS выключен», это тело без
  /// флага, и судить его надо обычными правилами.
  ///
  /// Сравнение — по ПЕЧАТНОЙ ФОРМЕ скаляра, как у `values` и `advisory`:
  /// `false` и `"false"` совпадают, потому что тело приезжает и разбором JSON,
  /// и от маппера, где булев флаг бывает строкой.
  static bool _absentWhenHolds(Map<String, dynamic> rule, Map<Object?, Object?> obj) {
    if (rule.isEmpty) return false;
    for (final e in rule.entries) {
      if (!obj.containsKey(e.key)) return false;
      if ('${obj[e.key]}' != '${e.value}') return false;
    }
    return true;
  }

  /// §481 (контракт 1.1.11) — связи секции `body.relations`.
  ///
  /// Видов два. `ranges_disjoint`: диапазоны перечисленных полей не должны
  /// пересекаться. Свойство НАБОРА, а не пары «поле и сосед», поэтому
  /// `conflicts`/`requires` его не выражают — виноват может быть любой
  /// из четырёх `h1`–`h4`, и снятие одного пару не развело бы.
  ///
  /// `cooccurrence` (контракт 1.1.22): свойство СОЧЕТАНИЯ настроек, ни одна
  /// из которых не битая. Узел живёт и менять в нём нечего — человеку
  /// сообщается цена сочетания, поэтому ни `on_invalid`, ни `conflicts` тут
  /// не подходят. Условие разнородное (булев флаг рядом с шириной диапазона),
  /// и читается оно оператором `$range_width` наравне с обычным сравнением
  /// значения.
  ///
  /// `defaults` обязателен по смыслу: незаданный заголовок участвует своим
  /// типом сообщения WireGuard (`h1=1 … h4=4`), и «поля нет» тут не значит
  /// «участника нет» — иначе `h1=2` рядом с незаданным `h2` прошло бы проверку
  /// и уронило конфиг на старте.
  ///
  /// [clean] — ЧИСТАЯ карта (см. вызов в [RegistrySanitizer.sanitize]).
  void applyBodyRelations(
      Map<String, dynamic> clean, List<Map<String, dynamic>> relations) {
    for (final rel in relations) {
      final kind = rel['kind'];
      if (kind == 'cooccurrence') {
        _applyCooccurrence(clean, rel);
        continue;
      }
      if (kind == 'ordered') {
        _applyOrdered(clean, rel);
        continue;
      }
      if (kind != 'ranges_disjoint') {
        _logUnknownExpression('relation', '$kind');
        continue;
      }
      final paths = ((rel['paths'] as List?) ?? const []).map((e) => '$e');
      final defaults = (rel['defaults'] as List?) ?? const [];
      final spans = <String, (int, int)>{};
      var i = -1;
      for (final p in paths) {
        i++;
        final raw = clean.containsKey(p)
            ? clean[p]
            : (i < defaults.length ? defaults[i] : null);
        final span = _rangeSpan(raw);
        if (span != null) spans[p] = span;
      }
      final names = spans.keys.toList();
      for (var a = 0; a < names.length; a++) {
        for (var b = a + 1; b < names.length; b++) {
          final x = spans[names[a]]!;
          final y = spans[names[b]]!;
          if (x.$1 > y.$2 || y.$1 > x.$2) continue;
          final code = rel['code'] as String?;
          if (code != null) {
            // Адресуется ПАРОЙ: человеку нужно знать, какие два заголовка
            // сошлись, а не только что где-то есть пересечение.
            warn(code,
                path: names[a],
                value: '${names[a]}=${clean[names[a]] ?? ''} '
                    '${names[b]}=${clean[names[b]] ?? ''}'.trim());
          }
          if (rel['action'] == 'drop_node') {
            dropNode = true;
            explicitDropNode = true;
          }
          return;
        }
      }
    }
  }

  /// Связь `cooccurrence` (контракт 1.1.22) — цена СОЧЕТАНИЯ настроек.
  ///
  /// Условие — карта «путь → ожидание», и совпасть обязаны ВСЕ её записи:
  /// перечисление это «и». Ожидание бывает двух видов:
  ///
  /// - скаляр — сравнение по ПЕЧАТНОЙ ФОРМЕ, как у `absent_when`: тело
  ///   приезжает и разбором JSON, и от маппера, где булев флаг бывает строкой;
  /// - `$range_width` — ширина диапазона у ЛЮБОГО из перечисленных путей
  ///   (`gt`/`lt`, операторы строгие). Диапазоном считается только запись вида
  ///   «lo-hi»: заголовок-ЧИСЛО ширины не имеет и условие не выполняет.
  ///
  /// Код адресуется ПЕРВОМУ пути связи: он называет настройку, с которой
  /// человек начнёт разбираться. Повтор одного кода по одному пути снимается —
  /// связей с общим кодом в реестре бывает несколько, а сообщение об одной и
  /// той же цене человеку нужно один раз.
  /// Контракт 1.1.63 — `ordered`: значения `paths` по неубыванию (у
  /// диапазона `N-M` верхняя граница левого не выше нижней правого).
  /// Участник без значения пары не образует. `drop` снимает все участвующие
  /// поля, узел живёт; код — на первом пути.
  void _applyOrdered(Map<String, dynamic> clean, Map<String, dynamic> rel) {
    final paths = [
      for (final p in (rel['paths'] as List?) ?? const [])
        if (clean.containsKey('$p') && _rangeSpan(clean['$p']) != null) '$p',
    ];
    for (var i = 0; i + 1 < paths.length; i++) {
      final a = paths[i], b = paths[i + 1];
      if (_rangeSpan(clean[a])!.$2 <= _rangeSpan(clean[b])!.$1) continue;
      final code = rel['code'] as String?;
      if (code != null) {
        warn(code, path: a, params: {
          'a': a,
          'b': b,
          'value': '${clean[a]}',
          'with': '${clean[b]}',
        });
      }
      if (rel['action'] == 'drop_node') {
        dropNode = true;
        explicitDropNode = true;
      } else if (rel['action'] == 'drop') {
        for (final p in (rel['paths'] as List?) ?? const []) {
          clean.remove('$p');
        }
      }
      return;
    }
  }

  void _applyCooccurrence(Map<String, dynamic> clean, Map<String, dynamic> rel) {
    final when = rel['when'];
    if (when is! Map) return;
    for (final e in when.entries) {
      final key = '${e.key}';
      if (key == r'$range_width') {
        if (!_rangeWidthHolds(clean, e.value)) return;
        continue;
      }
      if (!clean.containsKey(key)) return;
      if ('${clean[key]}' != '${e.value}') return;
    }
    final code = rel['code'] as String?;
    if (code == null) return;
    final paths = ((rel['paths'] as List?) ?? const []).map((e) => '$e');
    final path = paths.isEmpty ? null : paths.first;
    if (!_cooccurrenceSeen.add('$code $path')) return;
    if (rel['action'] == 'drop_node') {
      dropNode = true;
      explicitDropNode = true;
    }
    warn(code, path: path);
  }

  /// Уже поставленные коды `cooccurrence`: `<код> <путь>`.
  final Set<String> _cooccurrenceSeen = <String>{};

  /// Оператор `$range_width`: ширина диапазона хотя бы у одного из путей
  /// удовлетворяет `gt`/`lt`.
  static bool _rangeWidthHolds(Map<String, dynamic> clean, Object? spec) {
    if (spec is! Map) return false;
    final paths = ((spec['paths'] as List?) ?? const []).map((e) => '$e');
    final gt = spec['gt'];
    final lt = spec['lt'];
    for (final p in paths) {
      final span = _rangeSpan(clean[p]);
      if (span == null) continue;
      final width = span.$2 - span.$1;
      if (gt is num && width > gt) return true;
      if (lt is num && width < lt) return true;
    }
    return false;
  }

  /// §481 (контракт 1.1.11) — условный порог снизу `min_when`.
  ///
  /// Возвращает `true`, когда правило сработало и поле снято (при
  /// `action: drop_node` узел к этому моменту уже помечен на отбраковку).
  ///
  /// Три отличия от [_applyMaxWhen], каждое нарочное:
  ///
  /// - **`action: drop_node`, а не снятие поля.** Ядро отвергает такую пару на
  ///   загрузке ВСЕГО конфига; снять поле значило бы отдать ядру узел, который
  ///   оно всё равно не примет, и уронить чужие узлы вместе с ним;
  /// - **замены значения нет** — подставить минимум значило бы выдумать за
  ///   провайдера размер паддинга, от которого зависит рукопожатие;
  /// - **исключения по входу нет** (`except_sources` у `max_when`): правило
  ///   про то, что ядро не примет ни от кого.
  ///
  /// Условие читается по ИСХОДНОМУ телу ([root]), как у `max_when`: род узла
  /// задаёт то, что написал автор, а не то, что уцелело после чистки.
  /// Отсутствующее поле разбирает [_minWhenOnAbsent] — сюда оно не доходит.
  bool _applyMinWhen(Object? v, FieldSchema f, String path) {
    final rule = f.minWhen;
    if (rule == null) return false;
    final floor = rule['min'];
    if (v is! num || floor is! num) return false;
    if (v >= floor) return false;
    if (!_conditionHolds(rule['when'], root)) return false;
    _minWhenViolated(rule, f, path, v);
    return true;
  }

  /// §481 — `min_when` с `absent_is_zero: true` на ОТСУТСТВУЮЩЕМ поле.
  ///
  /// Ядро читает незаданный `s2` как 0, и «ключ защиты заголовков есть,
  /// паддинга нет» так же фатально, как «ключ + паддинг 5». Без этой ветки
  /// правило молчало бы ровно на том случае, который в живых подписках
  /// встречается чаще битого значения (кейс `awg3_padding_absent_with_header_key`).
  void _minWhenOnAbsent(FieldSchema f, String prefix, String key) {
    final rule = f.minWhen;
    if (rule == null || rule['absent_is_zero'] != true) return;
    final floor = rule['min'];
    if (floor is! num || floor <= 0) return;
    if (!_conditionHolds(rule['when'], root)) return;
    _minWhenViolated(rule, f, _join(prefix, key), 0);
  }

  /// Общий исход обеих веток `min_when`: код и, при `drop_node`, отбраковка.
  void _minWhenViolated(
      Map<String, dynamic> rule, FieldSchema f, String path, Object? value) {
    final code = rule['code'] as String?;
    if (code != null) {
      warn(code,
          path: path,
          value: value,
          // Значение — размер паддинга, а не сам секрет: маскировать его
          // нечего даже у `secret`-соседей.
          params: {'field': path});
    }
    if (rule['action'] == 'drop_node') {
      dropNode = true;
      explicitDropNode = true;
    }
  }

  /// §473 — условие правила значения (`default_when.when`, `max_when.when`).
  ///
  /// Форма реестра одна: `{any_set: [ключ, …]}`. Пустое/отсутствующее условие
  /// — правило безусловно.
  ///
  /// [body] — объект, в котором ищутся ключи. Незнакомую форму условия читаем
  /// как «не выполнено»: правило значения, чьё условие непонятно, применять
  /// наугад нельзя (в отличие от незнакомого `normalize`, который просто
  /// ничего не делает).
  /// Условие правила (`max_when`/`min_when`/`default_when`).
  ///
  /// Операторы соединяются ИЛИ, а не И, и это нормативно: род узла читается
  /// ДВУМЯ способами, потому что ни один не полон. `source_kind` знает род от
  /// ВХОДА и работает там, где в теле не осталось ни одного опорного ключа
  /// (негодные значения снял судья поля). `any_set` судит тело и остаётся
  /// навсегда: у входа в собственной форме ядра рода от входа нет вовсе.
  /// Потребуй оба — правило перестало бы срабатывать в обоих случаях сразу.
  ///
  /// Контракт 1.1.56 — прочие ключи условия суть ПУТИ тела с предикатом по
  /// ЗНАЧЕНИЮ (грамматика `when` маппера: скаляр — равенство по печатной
  /// форме, `{in: […]}` / `{not_in: […]}`). Предикаты — И между собой и И с
  /// ветками `any_set`/`source_kind`; см. [_valuePredicateHolds].
  bool _conditionHolds(Object? when, Map<String, dynamic> body) {
    if (when == null) return true;
    if (when is! Map) return true;
    var known = false;
    var branches = false;

    for (final e in when.entries) {
      final key = '${e.key}';
      if (key == 'any_set' || key == 'source_kind') {
        branches = true;
        continue;
      }
      if (!_valuePredicateHolds(key, e.value)) return false;
    }
    if (!branches) return true;

    final sourceKind = (when['source_kind'] as List?)?.map((e) => '$e');
    if (sourceKind != null) {
      known = true;
      if (sourceKind.any(kinds.contains)) return true;
    }

    final anySet = (when['any_set'] as List?)?.map((e) => '$e');
    if (anySet != null) {
      known = true;
      if (_anySetInBody(anySet, body)) return true;
    }

    if (!known) _logUnknownExpression('when', when.keys.join(','));
    return false;
  }

  /// §473 — предикат «КЛЮЧ ПРИСУТСТВУЕТ», и только он.
  ///
  /// **Не путать с [_meaningful]** — предикатом «ЗНАЧЕНИЕ ЗАДАНО», по которому
  /// судят `conflicts`/`requires` (§467). Разница не стилистическая: `jc: 0`
  /// — законная запись «мусорные пакеты выключены» у настоящего
  /// AmneziaWG-узла (кейс корпуса `awg_jc_zero_explicit`, наш
  /// `awg_test.dart`). Прочитай условие рода узла через [_meaningful], с
  /// такого узла потолок MTU снялся бы, и туннель молча не понёс бы данные.
  ///
  /// Обратное смешение так же вредно: `max_concurrency: "16-32"` при
  /// `max_connections: "0"` — не конфликт, и там судить надо значение.
  ///
  /// Пути условия — ключи корня тела (реестр называет их так же, как
  /// `conflicts`/`requires`): вложенных условий у `any_set` сегодня нет, и
  /// выдумывать их разбор здесь нечего — сегмент с точкой просто не найдётся.
  ///
  /// Контракт 1.1.56 — пустая СТРОКА условия не выполняет: для ядра это
  /// отсутствие ключа (`uplink_data_placement: ""` не будит `default_when` у
  /// mode). Число 0 остаётся значением.
  static bool _anySetInBody(Iterable<String> keys, Map<String, dynamic> body) {
    for (final key in keys) {
      if (!body.containsKey(key)) continue;
      final v = body[key];
      if (v is String && v.isEmpty) continue;
      return true;
    }
    return false;
  }

  /// Контракт 1.1.56 — предикат по ЗНАЧЕНИЮ пути тела (ключ `condition`,
  /// не `any_set`/`source_kind`; тот же у `relation.when`).
  ///
  /// Значение берётся из чистого состояния, включая объект, обход которого
  /// ещё идёт ([_cleanAt]: материализованный `default_when` у
  /// `transport.mode` виден соседу), иначе из исходного тела. Снятое поле
  /// (выключатель, снятое с объяснением) и пустая строка — «не задано»: `in`
  /// ложен, `not_in` истинен, равенство ложно. Незнакомый оператор — ложь
  /// (реестр вправе уехать вперёд кода; эталон — `valuePredicateHolds` в
  /// `nodeflow/sanitize.go`).
  bool _valuePredicateHolds(String path, Object? want) {
    Object? got;
    var present = false;
    if (!_switchedOff(path) && !explainedDrops.contains(path)) {
      final clean = _cleanAt(path);
      if (clean.$1) {
        got = clean.$2;
        present = true;
      } else {
        got = _rawAt(path);
        present = got != null;
      }
      if (got is String && got.isEmpty) present = false;
    }
    if (want is Map) {
      final inList = want['in'];
      if (inList is List) {
        return present && inList.any((e) => '$e' == '$got');
      }
      final notIn = want['not_in'];
      if (notIn is List) {
        return !present || !notIn.any((e) => '$e' == '$got');
      }
      _logUnknownExpression('when', want.keys.join(','));
      return false;
    }
    return present && '$want' == '$got';
  }

  /// Значение по абсолютному пути в ЧИСТОМ состоянии: в снимке [sanitized]
  /// либо в объекте, обход которого ещё идёт ([_building]). Второе нужно
  /// связям и условиям между соседями одного вложенного объекта: сосед,
  /// материализованный по ходу обхода (`default_when`), в снимок попадает
  /// только вместе со всем объектом (контракт 1.1.56, норма 1).
  (bool, Object?) _cleanAt(String path) {
    if (sanitized.containsKey(path)) return (true, sanitized[path]);
    final parts = path.split('.');
    for (var i = parts.length - 1; i >= 0; i--) {
      final m = _building[parts.sublist(0, i).join('.')];
      if (m == null) continue;
      Object? cur = m;
      for (final seg in parts.sublist(i)) {
        if (cur is! Map || !cur.containsKey(seg)) return (false, null);
        cur = cur[seg];
      }
      return (true, cur);
    }
    return (false, null);
  }

  /// Нарушенное ограничение — возвращает значение для текста кода, `null`
  /// если всё в порядке.
  Object? _checkConstraints(Object? v, FieldSchema f) {
    final format = f.format;
    if (format != null && !_formatOk(v, format)) return v;

    final len = f.len;
    final parity = f.lenParity;
    // `len` у массива — число элементов (`reserved`: ровно три).
    if (v is List) {
      if (len != null && v.length != len) return v;
      // `min`/`max` у массива относятся к ЭЛЕМЕНТУ, а не к длине: длину
      // задаёт `len`, и второго смысла у границ быть не может. Прежде ветка
      // списка возвращалась здесь же, и границы не проверялись ВОВСЕ —
      // `reserved=1,2,999` уезжал в ядро, хотя у `peers[].reserved`
      // объявлено `0..255` (байт).
      //
      // СУДЯТСЯ элементы поштучно, а В КОД УЕЗЖАЕТ ВСЁ ПОЛЕ (CANON §6,
      // решение лаунчера 19.09.2026): `value` предупреждения — это то, что
      // человек написал, а написал он тройку. Один вырванный из неё элемент
      // (`999`) не показывает, какое поле негодно, и расходился с Go.
      final min = f.min;
      final max = f.max;
      if (min != null || max != null) {
        for (final e in v) {
          if (e is! num) continue;
          if (min != null && e < min) return v;
          if (max != null && e > max) return v;
        }
      }
      return null;
    }
    if (v is String) {
      if (len != null && v.length != len) return v;
      if (parity != null) {
        final even = v.length.isEven;
        if ((parity == 'even') != even) return v;
      }
      // `min`/`max` у строки — границы ДЛИНЫ.
      final min = f.min;
      final max = f.max;
      if (format == null && f.type == 'string') {
        if (min != null && v.length < min) return v;
        if (max != null && v.length > max) return v;
      }
    }
    if (v is num) {
      final min = f.min;
      final max = f.max;
      if (min != null && v < min) return v;
      if (max != null && v > max) return v;
    }
    return null;
  }

  /// Нарушение ограничения → `on_invalid`. Без `on_invalid` — снять поле с
  /// кодом типа (спека §2.2).
  _Value _invalid(FieldSchema f, String path, Object? value,
      {bool secret = false}) {
    final rule = f.onInvalid;
    final code = rule?['code'] as String? ?? _kDefaultInvalidCode;
    final action = rule?['action'] as String? ?? 'drop';
    switch (action) {
      case 'coerce':
        warn(code, path: path, value: value, secret: secret || f.secret);
        return _Value.keep(rule?['value']);
      // Контракт 1.1.57 — `unwrap`: значение приехало обёрткой соседнего
      // диалекта (объект вместо скаляра). Годный член `key` становится
      // значением поля с кодом `code`; объект без годного члена — поле
      // снято с `else_code` (параметры — скалярные члены объекта, кроме
      // `key`); не объект — `type_invalid`.
      case 'unwrap':
        if (value is! Map) {
          warn(_kDefaultInvalidCode,
              path: path, value: value, secret: secret || f.secret);
          explainedDrops.add(path);
          return const _Value.drop();
        }
        final key = rule?['key'] as String?;
        final member = key == null ? null : value[key];
        if (member != null) {
          final probe = _Ctx(
            scheme: scheme,
            coreVersion: coreVersion,
            platform: platform,
            applyCoreGates: applyCoreGates,
            source: source,
            kinds: kinds,
            root: root,
          );
          final plain = FieldSchema({...f.raw}..remove('on_invalid'));
          final res = probe._sanitizeScalar(member, plain, path);
          final blank = res.value is String && (res.value as String).trim().isEmpty;
          if (res.keep && probe.warnings.isEmpty && !blank) {
            warn(code, path: path, value: member, secret: secret || f.secret);
            return _Value.keep(res.value);
          }
        }
        final params = <String, String>{
          for (final e in value.entries)
            if (e.key != key &&
                (e.value is String || e.value is num || e.value is bool))
              '${e.key}': '${e.value}',
        };
        warn(rule?['else_code'] as String? ?? _kDefaultInvalidCode,
            path: path, params: params);
        explainedDrops.add(path);
        return const _Value.drop();
      case 'drop_node':
        dropNode = true;
        explicitDropNode = true;
        warn(code,
            path: path,
            value: value,
            secret: secret || f.secret,
            params: {'field': path});
        return const _Value.drop();
      default:
        warn(code, path: path, value: value, secret: secret || f.secret);
        // §472 шаг 3 — поле снято и причина названа: зависимым от него
        // второго кода не полагается. См. [explainedDrops].
        explainedDrops.add(path);
        return const _Value.drop();
    }
  }

  /// `conflicts` и `requires` — после того, как состав объекта известен.
  void _applyRelations(
    Map<String, Object?> kept,
    List<String> order,
    Map<String, FieldSchema> fields,
    String prefix,
  ) {
    // `conflicts`: снимается ДЕКЛАРАНТ — поле, у которого правило записано.
    //
    // §474 (контракт 1.1.6). Раньше здесь снималось «младшее по `order`», и
    // это было ошибкой прочтения: формулировка описывала типичный случай, а
    // не контракт. Уступает всегда сторона-декларант, а соседа видно и в
    // ИСХОДНОМ теле — потому правило работает и тогда, когда сосед стоит по
    // `body.order` позже. Ровно так судит лаунчер
    // (`nodeflow/sanitize.go` → `relationsOK`), и по всем 22 записям реестра
    // противоположная сторона не нужна ни разу.
    //
    // Разница видна на `vless.flow ↔ transport`: `flow` (order 3) идёт раньше
    // `transport` (order 9), и прежнее «младшее» оставляло оба поля — из-за
    // чего гашение vision жило рукописным правилом в маппере. Симметричные
    // пары (`tls.ech.enabled` ↔ `tls.reality.enabled`) записаны у ОБОИХ
    // участников, и снятие декларанта их не ломает: первый по обходу уходит
    // сам, второй перестаёт видеть соседа и остаётся.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      final myPath = _join(prefix, key);
      for (final rel in f.conflicts) {
        final with0 = rel['with'] as String?;
        if (with0 == null) continue;
        if (!_conditionHolds(rel['when'], kept)) continue;
        // Контракт 1.1.64 — сосед без точки, которого нет в своём объекте,
        // — поле корня (`tls.fragment` ↔ `vhttp` у masque); у схемы без
        // такого поля связь не срабатывает.
        final rootRival = !with0.contains('.') &&
            prefix.isNotEmpty &&
            !fields.containsKey(with0);
        if (rootRival
            ? !_presentInSource(with0, const {}, '')
            : !_presentInSource(with0, kept, prefix)) {
          continue;
        }
        if (_unlessHolds(rel, kept, prefix)) continue;
        kept.remove(key);
        _relWarn(order, order.indexOf(key), prefix,
            rel['code'] as String? ?? 'field_conflict',
            path: myPath, params: {'with': with0});
        // §474 — поле снято и причина названа: зависимым от него второго кода
        // не полагается (та же граница, что у `requires`).
        explainedDrops.add(myPath);
        break;
      }
    }

    // `requires`: нет требуемого — поле снимается, само по себе не влияет.
    //
    // §464 (W2d) — `equals`: требуется не наличие соседа, а его КОНКРЕТНОЕ
    // значение (`obfs.min_packet_size` осмыслен только при
    // `obfs.type = gecko`). Без этого поле gecko переживало salamander и
    // расходилось с тем же узлом, пришедшим другим входом.
    for (final key in order) {
      if (!kept.containsKey(key)) continue;
      final f = fields[key];
      if (f == null) continue;
      for (final rel in f.requires) {
        final need = rel['path'] as String?;
        if (need == null) continue;
        // Контракт 1.1.56 — `relation.when`: ложно — связь не судится вовсе
        // (у `uplink_data_placement` mode=packet-up нужен лишь header/cookie).
        if (!_conditionHolds(rel['when'], kept)) continue;
        final ok = rel.containsKey('equals')
            ? _valueAt(need, kept, prefix) == rel['equals']
            : _present(need, kept, prefix);
        if (ok) continue;
        if (_unlessHolds(rel, kept, prefix)) continue;
        // Контракт 1.1.61 — `requires[].set`: недостающий путь не снимает
        // поле, а материализуется значением `set` по готовому телу. Путь,
        // который схема не допускает, — обычное снятие ниже.
        if (rel.containsKey('set')) {
          final target = need.contains('.') ? need : _join(prefix, need);
          if (_pathAllowed(target)) {
            _repairs.add(_Repair.set(
              index: _fieldEnd[_join(prefix, key)] ?? warnings.length,
              path: _join(prefix, key),
              target: target,
              need: need,
              value: rel['set'],
              code: rel['code'] as String? ?? 'field_requires',
            ));
            continue;
          }
        }
        kept.remove(key);
        // §472 шаг 3 — требуемое поле снял этот же прогон и уже объяснил
        // почему: молча уходим следом. См. [explainedDrops].
        if (!explainedDrops.contains(need)) {
          _relWarn(order, order.indexOf(key), prefix,
              rel['code'] as String? ?? 'field_requires',
              path: _join(prefix, key), params: {'requires': need});
        }
        break;
      }
    }
  }

  /// Контракт 1.1.61 — `coerce_when`: годное значение из `values` поля
  /// запоминается; замена — по готовому телу в [applyRepairs].
  void _recordCoerceWhen(FieldSchema f, String path, Object? v) {
    final rule = f.raw['coerce_when'];
    if (rule is! Map) return;
    final values = rule['values'];
    if (values is! List || !values.any((e) => '$e' == '$v')) return;
    _repairs.add(_Repair.coerce(
      index: warnings.length,
      path: path,
      original: v,
      value: rule['value'],
      when: rule['when'],
      code: rule['code'] as String?,
    ));
  }

  /// Допускает ли схема путь [path] (каждый сегмент объявлен и не запрещён
  /// схеме записи) — только тогда `requires[].set` вправе его завести.
  bool _pathAllowed(String path) {
    Map<String, FieldSchema>? fields =
        ContractRegistry.I.schemaFor(scheme)?.fields;
    for (final seg in path.split('.')) {
      final f = fields?[seg];
      if (f == null) return false;
      if (f.forbiddenFor?.contains(scheme) ?? false) return false;
      final allowed = f.allowedFor;
      if (allowed != null && !allowed.contains(scheme)) return false;
      fields = f.fields;
    }
    return true;
  }

  /// Исполнить отложенные починки по готовому телу [out]. Код встаёт в
  /// `warnings` туда, где встал бы при обходе.
  void applyRepairs(Map<String, dynamic> out) {
    if (_repairs.isEmpty) return;
    final inserts = <(int, RegistryWarning)>[];
    for (final r in _repairs) {
      final w = r.apply(out, this);
      if (w != null) inserts.add((r.index, w));
    }
    for (var i = inserts.length - 1; i >= 0; i--) {
      warnings.insert(inserts[i].$1, inserts[i].$2);
    }
  }

  /// Условие правила по ГОТОВОМУ телу (грамматика `condition`).
  bool finalConditionHolds(Object? when, Map<String, dynamic> body) {
    if (when is! Map) return true;
    var branches = false;
    for (final e in when.entries) {
      final key = '${e.key}';
      if (key == 'any_set' || key == 'source_kind') {
        branches = true;
        continue;
      }
      final got = finalAt(body, key);
      final present = got != null && !(got is String && got.isEmpty);
      final want = e.value;
      if (want is Map) {
        final inList = want['in'];
        final notIn = want['not_in'];
        if (inList is List) {
          if (!(present && inList.any((x) => '$x' == '$got'))) return false;
        } else if (notIn is List) {
          if (present && notIn.any((x) => '$x' == '$got')) return false;
        } else if (want.containsKey('type_of')) {
          if (!_typeOf(got, '${want['type_of']}')) return false;
        } else {
          return false;
        }
      } else if (!(present && '$want' == '$got')) {
        return false;
      }
    }
    if (!branches) return true;
    final sourceKind = (when['source_kind'] as List?)?.map((e) => '$e');
    if (sourceKind != null && sourceKind.any(kinds.contains)) return true;
    final anySet = (when['any_set'] as List?)?.map((e) => '$e');
    if (anySet != null) {
      for (final k in anySet) {
        final v = finalAt(body, k);
        if (v != null && !(v is String && v.isEmpty)) return true;
      }
    }
    return false;
  }

  static bool _typeOf(Object? v, String t) => switch (t) {
        'object' => v is Map,
        'array' => v is List,
        'string' => v is String,
        'number' => v is num,
        'bool' => v is bool,
        _ => false,
      };

  /// Значение по абсолютному пути готового тела; `null` — пути нет.
  static Object? finalAt(Map<String, dynamic> body, String path) {
    Object? cur = body;
    for (final seg in path.split('.')) {
      if (cur is! Map || !cur.containsKey(seg)) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Значение по пути связи — для `requires` с `equals`.
  ///
  /// Пути `equals`-правил реестра записаны от корня тела (`obfs.type`), но
  /// само правило лежит внутри того же объекта (`obfs.min_packet_size`), так
  /// что сосед по последнему сегменту находится раньше снимка: он проверен в
  /// этом же проходе и в `kept` уже есть.
  Object? _valueAt(String path, Map<String, Object?> siblings, String prefix) {
    final last = path.split('.').last;
    if (siblings.containsKey(last)) return siblings[last];
    if (sanitized.containsKey(path)) return sanitized[path];
    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map || !cur.containsKey(seg)) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Условие `when` у `advisory`: `{path, present: true}` — правило работает
  /// только когда поле по пути задано и осмысленно.
  bool _advisoryWhen(Object? when) {
    if (when == null) return true;
    if (when is! Map) return true;
    final path = when['path'] as String?;
    if (path == null) return true;
    final present = _present(path, const {}, '');
    return when['present'] == false ? !present : present;
  }

  /// Есть ли поле по пути связи — по состоянию ПОСЛЕ санитайзинга.
  ///
  /// Пути в реестре двух форм: абсолютные от корня тела
  /// (`tls.reality.public_key`) и короткие — имя соседа в том же объекте
  /// (`ip`, `realm`, `server_ports`). Сначала пробуем соседа: правила внутри
  /// одного объекта так и написаны.
  bool _present(String path, Map<String, Object?> siblings, String prefix) {
    if (!path.contains('.')) {
      return siblings.containsKey(path) && _meaningful(siblings[path]);
    }
    // Абсолютный путь: сперва снимок санитайзера, и только если ветка ещё не
    // обработана (связь смотрит вперёд) — исходное тело.
    if (sanitized.containsKey(path)) return _meaningful(sanitized[path]);
    final parent = path.substring(0, path.lastIndexOf('.'));
    // Родитель уже разобран, а ключа в снимке нет — значит поле снято.
    if (sanitized.containsKey(parent) || _branchDone(parent)) return false;

    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map) return false;
      if (!cur.containsKey(seg)) return false;
      cur = cur[seg];
    }
    return _meaningful(cur);
  }

  /// §544 (контракт 1.1.55) — `relation.unless_set`: связь НЕ действует, если
  /// задан ЛЮБОЙ из путей. «Задан» — тот же предикат, что у соседа связи
  /// ([_presentInSource]): непустое значение по исходному телу, не снятое
  /// схемой и не выключатель ([switchedOff]). Пример реестра —
  /// `vless.flow ↔ transport`: с VLESS Encryption Vision идёт поверх слоя
  /// шифрования, и транспорт ему не помеха.
  bool _unlessHolds(
      Map<String, dynamic> rel, Map<String, Object?> siblings, String prefix) {
    final unless = rel['unless_set'];
    if (unless is! List) return false;
    for (final p in unless) {
      if (p is String && _presentInSource(p, siblings, prefix)) return true;
    }
    return false;
  }

  /// Снят ли [path] (или объект над ним) как выключатель — см. [switchedOff].
  bool _switchedOff(String path) {
    if (switchedOff.isEmpty) return false;
    var p = path;
    while (true) {
      if (switchedOff.contains(p)) return true;
      final i = p.lastIndexOf('.');
      if (i < 0) return false;
      p = p.substring(0, i);
    }
  }

  /// §474 — сосед для `conflicts`: виден и в ИСХОДНОМ теле.
  ///
  /// Отличие от [_present] ровно одно и оно намеренное. `requires` судит
  /// состояние ПОСЛЕ санитайзинга: поле, снятое как негодное, для зависимых
  /// от него отсутствует — иначе `short_id` пережил бы мусорный `public_key`.
  /// `conflicts` судит иначе: он отвечает на вопрос «что автор написал в
  /// теле», и ответ не зависит от того, дошёл ли обход до соседа. `flow`
  /// (order 3) обязан увидеть `transport` (order 9), которого в снимке ещё
  /// нет вовсе; лаунчерский `pathPresent` читает `srcRoot` по той же
  /// причине.
  ///
  /// Снятое санитайзером поле соседом всё же не считается ([explainedDrops] и
  /// снимок проверяются первыми): конфликтовать с тем, чего в теле уже не
  /// будет, нечему.
  bool _presentInSource(String path, Map<String, Object?> siblings, String prefix) {
    if (!path.contains('.')) {
      // Сосед по тому же объекту: обход идёт по `order`, и поле, стоящее
      // позже, в `siblings` ещё не лежит — читаем исходную карту объекта.
      if (siblings.containsKey(path)) return _meaningful(siblings[path]);
      final abs = _join(prefix, path);
      if (explainedDrops.contains(abs)) return false;
      if (_switchedOff(abs)) return false;
      if (sanitized.containsKey(abs)) return _meaningful(sanitized[abs]);
      return _meaningful(_rawAt(abs));
    }
    if (explainedDrops.contains(path)) return false;
    if (_switchedOff(path)) return false;
    if (sanitized.containsKey(path)) return _meaningful(sanitized[path]);
    final parent = path.substring(0, path.lastIndexOf('.'));
    // Ветку уже разобрали, а ключа в снимке нет — поле снято проверкой
    // значения, и для конфликта его нет.
    if (sanitized.containsKey(parent) || _branchDone(parent)) return false;
    return _meaningful(_rawAt(path));
  }

  /// Значение по абсолютному пути в ИСХОДНОМ теле; `null` — пути нет.
  Object? _rawAt(String path) {
    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is! Map || !cur.containsKey(seg)) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// Разобрана ли уже ветка [prefix] — есть ли в снимке хоть один её ключ.
  bool _branchDone(String prefix) =>
      sanitized.keys.any((k) => k.startsWith('$prefix.'));

  /// Предикат «задано» — ОДИН на весь слой связей (`conflicts`, `requires`,
  /// `forbidden_when`); §467, контракт §24.9.
  ///
  /// Судится ЗНАЧЕНИЕ, а не наличие ключа. Не задано: ключ отсутствует,
  /// `null`, `""`, `0`, `false`, пустой объект, пустой массив и строка-число
  /// из одних нулей (`"0"`, `"0-0"` — диапазоны `XmuxRange` приходят
  /// строками).
  ///
  /// Провайдеры присылают секции в полной форме, где незаданные поля выписаны
  /// нулями. По наличию ключа `max_concurrency: "16-32"` при
  /// `max_connections: "0"` читался как конфликт, рабочее значение снималось и
  /// возвращалось дефолтом `"1-1"` — пропускная способность узла падала молча
  /// (13 узлов на реальном state лаунчера). Ядро
  /// (`transport/v2rayxhttp/xmux.go`) считает конфликтом только оба > 0.
  /// Правило общее: так же судятся `certificate` ↔ `pins` и `reality` ↔ `ech`.
  static bool _meaningful(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty && !_allZeroNumeric(v);
    if (v is Iterable) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  /// Строка-число из одних нулей: `"0"`, `"0-0"`, `"00"`. Форма «N-M» —
  /// `XmuxRange`: диапазон из нулей это тот же ноль, то есть «не задано».
  /// Строка с непустой цифрой (`"0-32"`) задана.
  static bool _allZeroNumeric(String s) {
    var sawDigit = false;
    for (final unit in s.codeUnits) {
      if (unit == 0x30) {
        sawDigit = true;
        continue;
      }
      // Разделитель диапазона и пробелы игнорируем, любой другой символ
      // (в т.ч. цифра 1..9 и буква) делает строку заданной.
      if (unit == 0x2D || unit == 0x20) continue;
      return false;
    }
    return sawDigit;
  }

}

String _join(String prefix, String key) => prefix.isEmpty ? key : '$prefix.$key';

/// Нормализации реестра (`normalize`). Неизвестная — значение НЕ трогается:
/// выражение из будущей версии контракта не повод портить рабочее поле.
String _normalizeString(String v, String norm) {
  switch (norm) {
    case 'trim':
      return v.trim();
    case 'lower':
      return v.toLowerCase();
    case 'trim_lower':
      return v.trim().toLowerCase();
    // §464 (W2d) — `hex_only`: чистка не-hex рун (моджибейк U+00C2, NBSP,
    // пробелы, префикс `0x`) с приведением к нижнему регистру. Правило жило
    // в URI-парсере (§343), теперь одно на все входы.
    case 'hex_only':
      final b = StringBuffer();
      for (final r in v.runes) {
        final c = String.fromCharCode(r);
        if (_reHexRune.hasMatch(c)) b.write(c.toLowerCase());
      }
      return b.toString();
    // §481 (контракт 1.1.11) — `range_order`: ТИХИЙ своп перевёрнутой пары
    // границ («40-10» → «10-40»).
    //
    // Кода у свопа нет, и это осознанно. Правило «замена значения подписки
    // видна» здесь не применяется: порядок границ смысла не несёт — ядро
    // выбирает значение ИЗ диапазона, и [10,40] = [40,10]. Это перевод
    // НАПИСАНИЯ, как `trim`, а не замена значения.
    //
    // Флаг стоит только у `h1`–`h4`. У таймингов AWG 3.x его нет намеренно:
    // там перевёрнутая пара — опечатка человека, которую он обязан увидеть
    // (SPEC 123 §2), и она уходит на `on_invalid` с `awg3_field_invalid`.
    //
    // Голое число («5») свопать нечего — возвращается как есть; мусор тоже
    // проходит насквозь, его судит `type`/`on_invalid` следом.
    // Контракт 1.1.63 — `cidr_masked`: голый адрес получает префикс хоста,
    // биты за длиной префикса обнуляются; мусор уезжает как есть (его судит
    // `format: cidr`).
    case 'cidr_masked':
      return _cidrMasked(v);
    case 'range_order':
      final s = v.trim();
      final dash = s.indexOf('-');
      if (dash <= 0) return v;
      final lo = int.tryParse(s.substring(0, dash));
      final hi = int.tryParse(s.substring(dash + 1));
      if (lo == null || hi == null || lo <= hi) return v;
      return '$hi-$lo';
    // D133-22 (контракт 1.1.22) — `base64_std` и `cidr_prefix` переехали из
    // маппера в `body.fields`: правило написания обязано действовать на ВСЕХ
    // входах, а не только там, где значение пришло ссылкой.
    //
    // `base64_std`: url-safe алфавит и отсутствие паддинга приводятся к
    // канону (std с паддингом). Это нормализация, а не суждение: `…ccC=` и
    // `…ccA=` декодируют в одни и те же байты, но уезжают в конфиг
    // по-разному, то есть одна нода давала бы два identity-хеша (D-030).
    // Годность (длину) судит `format` поля, поэтому здесь не проверяется
    // ничего: не-base64 возвращается как пришёл и снимается правилом реестра.
    case 'base64_std':
      // Декодер ЛЕНИВЫЙ — тот же, которым судит годность `base64_32`: канон
      // и суд обязаны читать значение одинаково, иначе ключ, признанный
      // годным, нормализация оставила бы неканоническим (или наоборот).
      final decoded = _decodeB64(v.trim());
      if (decoded == null) return v;
      final canon = base64.encode(decoded);
      // §549 R4 — канон декодируется в те же байты: следом его судит
      // `format: base64_32`, и второй декод того же ключа не нужен.
      _b64Key = canon;
      _b64Bytes = decoded;
      return canon;
    // D133-30 (контракт 1.1.40) — `base64_rawurl`: симметрия к `base64_std`,
    // заведена по нашему же запросу 19.09.2026. Отличие только в ЦЕЛЕВОМ
    // алфавите: std с паддингом против url-safe без него. Какой нужен полю,
    // решает ядро, а не форма значения, поэтому имя стоит у поля и из
    // `format` не выводится.
    //
    // Нужен ключу REALITY: ядро декодирует `public_key` только
    // `RawURLEncoding`, и написание со «+», «/», «=» проходит `base64_32`
    // (32 байта после декода там правда), а ядро отвечает «decode
    // public_key: illegal base64 data» отказом ВСЕГО конфига.
    //
    // Как и `base64_std`, о годности не судит: значение, которое не
    // декодируется, возвращается КАК ПРИШЛО, и его снимает `format` со своим
    // `on_invalid` (`reality_pbk_invalid`).
    //
    // Длина 32 — часть УСЛОВИЯ, а не суждение. `enabled` и `true` —
    // законный base64 на 5 и 3 байта, и перекодируй мы их, человек увидел бы
    // в коде `enablec` вместо написанного им `enabled`. Канонизировать
    // осмысленно только то, что ядро вообще возьмёт ключом; остальное —
    // работа `format base64_32` с его `on_invalid`, и в код обязано уехать
    // СЫРОЕ написание (та же причина, что у `pattern` и `normalize_code`).
    case 'base64_rawurl':
      final raw = _decodeB64(v.trim());
      if (raw == null || raw.length != 32) return v;
      final canon = base64Url.encode(raw).replaceAll('=', '');
      _b64Key = canon;
      _b64Bytes = raw;
      return canon;
    // `cidr_prefix`: голый адрес получает префикс — `/32` у v4, `/128` у v6.
    // Применяется поэлементно: поле-список нормализуется вызывающим по
    // элементам, и скаляр с той же записью ведёт себя так же.
    case 'cidr_prefix':
      final a = v.trim();
      if (a.isEmpty || a.contains('/')) return v;
      return a.contains(':') ? '$a/128' : '$a/32';
    // D133-26 (контракт 1.1.26) — `duration_bare_seconds` переехал из маппера
    // в `body.fields`: «голое число — это секунды» обязано действовать на ВСЕХ
    // входах, а не только там, где значение пришло ссылкой. До переезда тело
    // sing-box с `"tcp_keep_alive": 30` доезжало до ядра голым числом, а та же
    // настройка из ссылки — как `30s`: одна настройка, два написания.
    //
    // Негодное после нормализации значение НЕ чинится здесь: не-число
    // возвращается как пришло и уходит на `type_invalid` правилом поля
    // (`type: duration`). Это и есть принятая сторонами дельта — раньше такое
    // значение снималось молча.
    case 'duration_bare_seconds':
      final n = int.tryParse(v.trim());
      return n == null ? v : '${n}s';
    default:
      _logUnknownExpression('normalize', norm);
      return v;
  }
}

final _reHexRune = RegExp(r'^[0-9a-fA-F]$');

/// §477 — кеш скомпилированных `pattern` реестра.
///
/// Выражений в реестре единицы, а санитайзер бегает по каждому полю каждого
/// узла подписки: без кеша `RegExp` пересобирался бы тысячи раз на разбор.
/// `null` в значении — выражение НЕ компилируется; такое правило
/// пропускается, и повторно его никто не разбирает.
final _patternCache = <String, RegExp?>{};

/// Скомпилировать `pattern` реестра; `null` — выражение негодное.
///
/// Санитайзер на негодное выражение реагирует ПРОПУСКОМ, а не отбраковкой:
/// реестр вправе уехать вперёд кода, и опечатка в выражении не повод хоронить
/// рабочий узел. Ловит такое линтер (`registry_invariant_test.dart`).
RegExp? _compilePattern(String pattern) => _patternCache.putIfAbsent(pattern, () {
      try {
        return RegExp(pattern);
      } catch (_) {
        _logUnknownExpression('pattern', pattern);
        return null;
      }
    });

/// §472 шаг 3 — исходное значение в форме, с которой сверяется `normalize_code`.
///
/// Код объявляет ПОТЕРЮ, а регистр и обрамляющие пробелы ничего не теряют.
/// Значения другого типа (число, bool) нормализация строк не трогает — они
/// возвращаются как есть и сравниваются напрямую.
Object? _foldForNormalizeCode(Object? raw) =>
    raw is String ? raw.trim().toLowerCase() : raw;

/// Выражения реестра, о которых санитайзер уже сказал в лог. Один раз на
/// процесс: незнакомое выражение — это бамп контракта впереди кода, и
/// повторять о нём на каждом узле подписки бессмысленно.
final _seenUnknownExpressions = <String>{};

/// Неизвестное выражение реестра не роняет загрузку и не трогает значение
/// (24.1: реестр впереди кода — рабочее состояние, а не ошибка).
void _logUnknownExpression(String kind, String name) {
  if (!_seenUnknownExpressions.add('$kind:$name')) return;
  AppLog.I.warning(
      'RegistrySanitizer: неизвестное выражение реестра $kind=$name — '
      'значение оставлено как есть (контракт новее кода)');
}

/// Приведение к типу реестра. `null` — не приводится (→ `on_invalid`).
///
/// Приведение пробуется сначала (`"443"`→443, `"true"`→true, float без
/// дробной части→int): подписки шлют числа строками, и ронять из-за этого
/// рабочий узел незачем (память json-map-type-assert-trap).
///
/// Правило приведения одно: значение, которое ядро принимает, санитайзер НЕ
/// переписывает. Поэтому число под `type: string` остаётся числом — так
/// записаны AWGRange-поля (`h1`..`h4`, `persistent_keepalive_interval`):
/// реестр зовёт их строкой, потому что они принимают и «min-max», но форма
/// числом законна, а её подмена на `"1"` меняла бы конфиг на ровном месте.
({Object? value})? _coerceType(Object? value, String type) {
  switch (type) {
    case 'string':
      if (value is String) return (value: value);
      if (value is num || value is bool) return (value: value);
      return null;
    case 'bool':
      if (value is bool) return (value: value);
      if (value is String) {
        if (value == 'true') return (value: true);
        if (value == 'false') return (value: false);
      }
      return null;
    case 'int':
    case 'uint16':
      if (value is int) return (value: value);
      if (value is double && value == value.roundToDouble()) {
        return (value: value.toInt());
      }
      if (value is String) {
        final n = int.tryParse(value.trim());
        if (n != null) return (value: n);
      }
      return null;
    case 'duration':
      if (value is String) return (value: normalizeSingboxDuration(value.trim()));
      // Голое число ядро читает как наносекунды, подписки имеют в виду
      // секунды — нормализуем той же функцией, что и парсеры.
      if (value is int) return (value: normalizeSingboxDuration('$value'));
      return null;
    case 'listable_string':
      if (value is String) return (value: value);
      if (value is List && value.every((e) => e is String || e is num)) {
        return (value: value);
      }
      return null;
    case 'string_array':
      // Числа в массиве оставляем как есть по тому же правилу: `reserved`
      // реестр зовёт string_array, а ядро читает `[]uint8` — три числа —
      // и именно так его пишут все источники.
      if (value is List && value.every((e) => e is String || e is num)) {
        return (value: value);
      }
      return null;
    case 'enum':
      // Набор проверяется отдельно; здесь только форма значения.
      if (value is String || value is int) return (value: value);
      return null;
    // §464 (W2d) — типы, которых словарь SPEC 131 §4 не выражал.
    //
    // `awg_range` — поле AWG, принимающее и число, и диапазон «N-M» строкой
    // (h1..h4, таймеры lx.32). Форма прибытия законна ОБЕ, и подмена одной
    // на другую меняла бы конфиг на ровном месте, поэтому значение идёт как
    // есть; мусор вне этих двух форм снимается.
    //
    // §481 (контракт 1.1.11) — ГРАНИЦЫ uint32. Реестр объявил их у `awg_range`
    // прямо: шире ядро отвергает разбором и роняет ВЕСЬ конфиг, поэтому
    // значение снимается, а не усекается (усечение подсунуло бы серверу
    // другой magic-заголовок и молча сломало бы рукопожатие). Проверяются обе
    // границы диапазона и голое число.
    case 'awg_range':
      if (value is int) return _uint32Ok(value) ? (value: value) : null;
      if (value is double && value == value.roundToDouble()) {
        final n = value.toInt();
        return _uint32Ok(n) ? (value: n) : null;
      }
      if (value is String && _reAwgRange.hasMatch(value.trim())) {
        final s = value.trim();
        final parts = [for (final p in s.split('-')) int.tryParse(p)];
        for (final n in parts) {
          if (n == null || !_uint32Ok(n)) return null;
        }
        // §481 — ПЕРЕВЁРНУТАЯ пара негодна сама по себе. Разводит эти два
        // исхода `normalize: range_order`: поле с ним своп получает ТИХО и
        // сюда приезжает уже прямой парой (`h1`–`h4`), а поле без него —
        // тайминги AWG 3.x — доезжает как есть и снимается с кодом. Там
        // перевёрнутая пара опечатка человека, и он обязан её увидеть
        // (SPEC 123 §2).
        if (parts.length == 2 && parts[0]! > parts[1]!) return null;
        return (value: s);
      }
      return null;
    // `int_array` — массив целых (`peers[].reserved`: ровно три). Число
    // строкой приводится по общему правилу подписок.
    case 'int_array':
      if (value is! List) return null;
      final out = <int>[];
      for (final e in value) {
        if (e is int) {
          out.add(e);
        } else if (e is double && e == e.roundToDouble()) {
          out.add(e.toInt());
        } else if (e is String && int.tryParse(e.trim()) != null) {
          out.add(int.parse(e.trim()));
        } else {
          return null;
        }
      }
      return (value: out);
    default:
      _logUnknownExpression('type', type);
      return (value: value);
  }
}

/// Форма `awg_range`: голое число либо диапазон «N-M».
final _reAwgRange = RegExp(r'^\d+(-\d+)?$');

/// §481 — границы `awg_range` (контракт 1.1.11): ядро читает эти поля как
/// uint32 и на большем числе валит разбор ВСЕГО конфига.
bool _uint32Ok(int n) => n >= 0 && n <= 0xFFFFFFFF;

/// §481 — отрезок значения `awg_range` для `ranges_disjoint`: голое число `N`
/// — отрезок `[N, N]`, диапазон `"N-M"` — `[N, M]`. `null` — значение не в
/// форме диапазона (его уже осудил `on_invalid`, второй раз не судим).
String _cidrMasked(String v) {
  final s = v.trim();
  final slash = s.indexOf('/');
  final addrText = slash < 0 ? s : s.substring(0, slash);
  final addr = InternetAddress.tryParse(addrText);
  if (addr == null) return v;
  final bits = addr.rawAddress.length * 8;
  final len = slash < 0 ? bits : int.tryParse(s.substring(slash + 1));
  if (len == null || len < 0 || len > bits) return v;
  final raw = List<int>.of(addr.rawAddress);
  for (var i = 0; i < raw.length; i++) {
    final keep = len - i * 8;
    if (keep >= 8) continue;
    raw[i] = keep <= 0 ? 0 : raw[i] & (0xff << (8 - keep)) & 0xff;
  }
  final masked = InternetAddress.fromRawAddress(
      Uint8List.fromList(raw),
      type: addr.type);
  return '${masked.address}/$len';
}

(int, int)? _rangeSpan(Object? raw) {
  if (raw is int) return (raw, raw);
  if (raw is! String) return null;
  final s = raw.trim();
  final dash = s.indexOf('-');
  if (dash < 0) {
    final n = int.tryParse(s);
    return n == null ? null : (n, n);
  }
  final lo = int.tryParse(s.substring(0, dash));
  final hi = int.tryParse(s.substring(dash + 1));
  if (lo == null || hi == null) return null;
  return lo <= hi ? (lo, hi) : (hi, lo);
}

bool _formatOk(Object? v, String format) {
  if (v is List) return v.every((e) => _formatOk(e, format));
  switch (format) {
    case 'port':
      final n = v is int ? v : int.tryParse('$v');
      return n != null && n >= 1 && n <= 65535;
    case 'uuid':
      return v is String && _reUuid.hasMatch(v);
    case 'hex':
      return v is String && _reHex.hasMatch(v);
    case 'base64':
      return v is String && _reBase64.hasMatch(v);
    // §464 (W2d) — ключ ровно 32 байта ПОСЛЕ декода (REALITY `pbk`, ключи
    // WireGuard). Длина строки не годится: `enabled` — валидный base64 на
    // 5 байт, `true` — на 3, и прежний `base64` их пропускал, после чего
    // ядро отвечало «invalid public_key» фаталом на ВЕСЬ конфиг.
    case 'base64_32':
      return v is String && _base64Bytes(v) == 32;
    case 'host':
      return v is String && v.isNotEmpty && !v.contains(' ');
    case 'ipv4':
      return v is String && _ipv4Ok(v);
    // §463 / контракт §24.6 — новый формат W2c: ядро разбирает путь
    // транспорта через `url.Parse`, и битое percent-кодирование («%zz») роняет
    // ВЕСЬ config.json («ws: parse path: invalid URL escape»), а не один узел.
    case 'url_path':
      return v is String && urlPathOk(v);
    // Ядро разбирает префикс через `netip.ParsePrefix` и на негодном
    // значении (IPv4 с маской >32, `::::`, ведущие нули октета) отвечает
    // отказом ВСЕГО config.json, а не одного endpoint. Формат обязан
    // совпасть с ядром: адрес — строгим парсером, длина префикса — по
    // семейству. `contains(':')` как «это IPv6» здесь не годится.
    case 'cidr':
      return v is String && _cidrOk(v);
    default:
      _logUnknownExpression('format', format);
      return true;
  }
}

/// Длина ключа в байтах после декода base64 — любое из четырёх написаний
/// (std/url, с паддингом и без). `null` — строка не декодируется вовсе.
///
/// Декодер общий с §169 (`isValidRealityPublicKey`): расходиться в том, что
/// считать валидным base64, двум гардам одного и того же ключа нельзя.
///
/// Декодер ЛЕНИВЫЙ (D-030), как `encoding/base64` у Go и как `normalizeWGKey`
/// в парсере ссылки: ядро принимает неканоническую последнюю группу (`…ccC=`
/// и `…ccA=` — одни и те же 32 байта), а строгий `dart:convert` бросает на
/// ней `FormatException`. Строгим декодером длина такого ключа выходила
/// `null`, и `format: base64_32` ронял ЗАКОННЫЙ узел кодом `wg_key_invalid`
/// (корпус `uri_psk_keepalive`, где ключи лежат в query).
int? _base64Bytes(String v) => _decodeB64(v.trim())?.length;

/// §549 R4 — последний декод base64 (одна запись). Ключ WireGuard судят
/// подряд `normalize: base64_std` и `format: base64_32`, и без памяти один
/// ключ декодировался дважды (§548: ~40 % санитайзера WG-узла). Декод —
/// чистая функция строки, поэтому запись верна всегда; байты только читают.
String? _b64Key;
List<int>? _b64Bytes;

List<int>? _decodeB64(String s) {
  if (s == _b64Key) return _b64Bytes;
  final bytes = decodeBase64Lenient(s);
  _b64Key = s;
  _b64Bytes = bytes;
  return bytes;
}

bool _ipv4Ok(String v) {
  final parts = v.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// CIDR, который примет `netip.ParsePrefix`: адрес без ведущих нулей и зон,
/// префикс 0..32 у IPv4 и 0..128 у IPv6.
bool _cidrOk(String v) {
  final parts = v.split('/');
  if (parts.length != 2) return false;
  final bits = int.tryParse(parts[1]);
  if (bits == null) return false;
  final host = parts[0];
  if (_ipv4CidrHostOk(host)) return bits >= 0 && bits <= 32;
  if (_ipv6CidrHostOk(host)) return bits >= 0 && bits <= 128;
  return false;
}

/// Четыре десятичных октета 0..255 без ведущих нулей. `int.tryParse('01')`
/// дал бы 1 и пропустил бы написание, которое ядро отвергает.
bool _ipv4CidrHostOk(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (p.isEmpty) return false;
    if (p.length > 1 && p.startsWith('0')) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// IPv6 без зоны (`fe80::1%eth0` ядро не берёт префиксом). Тип проверяется
/// явно: `InternetAddress.tryParse` на IPv4-строке вернул бы v4.
bool _ipv6CidrHostOk(String host) {
  if (host.contains('%')) return false;
  final addr = InternetAddress.tryParse(host);
  return addr != null && addr.type == InternetAddressType.IPv6;
}

final _reUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _reHex = RegExp(r'^[0-9a-fA-F]*$');
final _reBase64 = RegExp(r'^[A-Za-z0-9+/_-]*={0,2}$');

/// Сравнение версий ядра `X.Y.Z-lx.N` (24.1.6). Суффикса `lx` нет — 0:
/// upstream-сборка старше любого форкового пина той же тройки.
bool coreAtLeast(String version, String required) {
  final a = _parseCore(version);
  final b = _parseCore(required);
  // Версия ядра неизвестна (пустая строка) — гейт не применяем: обрезать
  // поля из-за незнания хуже, чем оставить их ядру на разбор.
  if (a == null) return true;
  if (b == null) return true;
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return true;
}

List<int>? _parseCore(String v) {
  if (v.isEmpty) return null;
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-lx\.(\d+))?').firstMatch(v.trim());
  if (m == null) return null;
  return [
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.tryParse(m.group(4) ?? '0') ?? 0,
  ];
}

/// Результат обработки одного значения: оставить (с возможной заменой) или
/// снять.
final class _Value {
  const _Value.keep(this.value) : keep = true;
  const _Value.drop()
      : keep = false,
        value = null;

  final bool keep;
  final Object? value;
}

/// Контракт 1.1.61 — отложенное правило-починка (`requires[].set` либо
/// `coerce_when`), исполняемое по готовому телу.
final class _Repair {
  _Repair.set({
    required this.index,
    required this.path,
    required String this.target,
    required String this.need,
    required this.value,
    required this.code,
  })  : original = null,
        when = null;

  _Repair.coerce({
    required this.index,
    required this.path,
    required this.original,
    required this.value,
    required this.when,
    required this.code,
  })  : target = null,
        need = null;

  int index;
  final String path;
  final String? target;
  final String? need;
  final Object? original;
  final Object? value;
  final Object? when;
  final String? code;

  RegistryWarning? apply(Map<String, dynamic> out, _Ctx ctx) {
    final t = target;
    if (t != null) {
      // Декларант не пережил своих правил — дописывать нечего.
      if (!_Ctx._meaningful(_Ctx.finalAt(out, path))) return null;
      if (_Ctx._meaningful(_Ctx.finalAt(out, t))) return null;
      final segs = t.split('.');
      Map<String, dynamic> cur = out;
      for (final seg in segs.sublist(0, segs.length - 1)) {
        final next = cur[seg];
        if (next is Map<String, dynamic>) {
          cur = next;
        } else if (next == null) {
          final m = <String, dynamic>{};
          cur[seg] = m;
          cur = m;
        } else {
          return null;
        }
      }
      cur[segs.last] = value;
      return RegistryWarning(
          code: code ?? 'field_requires', path: path, params: {'requires': need!});
    }
    final got = _Ctx.finalAt(out, path);
    if (got == null || '$got' != '$original') return null;
    if (!ctx.finalConditionHolds(when, out)) return null;
    final segs = path.split('.');
    final parent = segs.length == 1
        ? out
        : _Ctx.finalAt(out, segs.sublist(0, segs.length - 1).join('.'));
    if (parent is! Map) return null;
    parent[segs.last] = value;
    final c = code;
    if (c == null) return null;
    return RegistryWarning(
        code: c,
        path: path,
        value: RegistrySanitizer.renderWarningValue(original as Object));
  }
}
