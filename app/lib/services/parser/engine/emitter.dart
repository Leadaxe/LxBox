/// §480 W7 — ЭМИТТЕР ССЫЛКИ: ОБРАЩЕНИЕ той же таблицы, что ведёт разбор.
///
/// Направление второе, таблица ОДНА. Не «второй план на эмит», а обход тех же
/// записей секции задом наперёд: `maps_to⁻¹` (путь тела → канон имени
/// параметра), `value_map⁻¹`, `sets⁻¹`/`implies⁻¹`, `scheme_sets⁻¹`,
/// userinfo `into⁻¹`. Два плана и породили сегодняшние асимметрии, которые
/// кампания снимает: `?ed=N` жил в четырёх слоях, `fp=random` писался у одной
/// схемы и не писался у другой.
///
/// **Вход — КАНОНИЧЕСКОЕ ТЕЛО** (карта sing-box, та самая, что отдаёт разбор)
/// плюс метка. Модели `NodeSpec` эмиттер не знает вовсе: знал бы — знал бы и
/// имена схем, а греп-страж их в пакете не терпит.
///
/// **Обратимость — критерий, а не надежда.** Круг `parse(emit(body))` обязан
/// дать то же тело байт в байт; запись, которая этого не даёт, объявляет
/// `round_trip: false` с причиной — и тогда потеря видна в данных, а не
/// обнаруживается на узле пользователя.
///
/// Норма — `MAPPER_ENGINE.md` раздел НОРМА (обратный ход эмита) и SPEC 133
/// `PRIMITIVES.md`: `param_order` алфавитный, пробел на выходе `%20`,
/// каноническое имя параметра — ПЕРВОЕ в `aliases`.
library;

import 'dart:convert';

import 'section.dart';

/// §0.7 DRAFT — имена атрибутов ЭМИТА, которых в замороженной грамматике ещё
/// нет.
///
/// Здесь они лежат ровно по той же причине, что и [DraftNames]: у лаунчера
/// обратный ход — «общий долг», эмит от таблицы не написан ни у кого, и первое
/// написание имени делаем мы. Переименование по итогам согласования обязано
/// быть правкой ОДНОЙ строки, а не обходом дерева.
///
/// Ни одно имя не является именем схемы или протокола.
abstract final class EmitNames {
  // ─── уже есть в схеме реестра (`registry_mapper.schema.json`) ───

  /// Блок обратного хода у секции. `null` — обратного хода нет.
  static const emit = 'emit';

  /// Идентификатор формы, которой собирается ссылка (`url`, `sip002`,
  /// `v2rayn`). Совпадает с `forms[].id` разбора: форма одна на оба хода.
  static const form = 'form';

  /// Выбор формы (и через неё — написания схемы) ПО ТЕЛУ.
  /// `{"<путь тела>": {"<значение>": "<форма>", "*": "<форма>"}}`.
  static const formFrom = 'form_from';

  /// Порядок параметров в query. Сегодня единственное значение —
  /// [paramOrderAlphabetical].
  static const paramOrder = 'param_order';

  /// Значения, которые не пишутся, будучи равными умолчанию.
  static const omitDefault = 'omit_default';

  /// Когда параметр пишется вопреки общему правилу (`always`).
  static const emitWhen = 'emit_when';

  /// `param_order: "alphabetical"` — единственное сегодняшнее правило.
  static const paramOrderAlphabetical = 'alphabetical';

  /// `emit_when: {<имя>: "always"}` — писать всегда, даже пустое.
  static const emitWhenAlways = 'always';

  // ─── НОВОЕ волной W7 (список на согласование лаунчеру) ───

  /// Запись, у которой обратного хода НЕТ, с причиной прозой.
  /// `"round_trip": false` плюс `"round_trip_why": "<причина>"`.
  ///
  /// Зачем: без объявления потеря на круге молчалива. Объявленная — она
  /// видна линтеру и попадает в отчёт, а не в тело узла пользователя.
  static const roundTrip = 'round_trip';

  /// Причина отсутствия обратного хода (проза, только для человека).
  static const roundTripWhy = 'round_trip_why';

  /// Сборка ОДНОГО параметра из НЕСКОЛЬКИХ путей тела — обращение `extract`.
  ///
  /// `"compose": {"template": "{plugin};{opts}", "from": {...}, "omit_when_empty": [...]}`
  ///
  /// Зачем: `extract` режет одно значение регуляркой на несколько путей, и
  /// обратный ход регуляркой не выражается — шаблон объявляет его прямо.
  /// Примеры секций перечислены в спеке 480, раздел «Что вышло: W7»: имена
  /// протоколов в пакете движка не живут.
  static const compose = 'compose';

  /// Шаблон сборки: `{<имя группы>}` подставляется значением.
  static const composeTemplate = 'template';

  /// Имя группы → путь тела, откуда берётся её значение.
  static const composeFrom = 'from';

  /// Группы, отсутствие которых срезает свой хвост шаблона.
  static const composeOmitWhenEmpty = 'omit_when_empty';

  /// Как СЕРИАЛИЗУЕТСЯ значение параметра, когда тело хранит его не строкой.
  ///
  /// `"emit_as": "join"` — список через `list.sep`; `"bool01"` — `true` → `1`;
  /// `"json"` — компактный JSON.
  ///
  /// Зачем: обратный ход `type`/`list` не однозначен. `alpn` в теле — список,
  /// в ссылке — строка через запятую; `insecure` в теле булев, в ссылке `1`.
  /// Угадывать по типу значения нельзя: булев параметр, писанный словом
  /// `true`, и булев, писанный `1`, — разные ссылки у живых панелей.
  static const emitAs = 'emit_as';

  /// Значение [emitAs]: список → строка через `list.sep`.
  static const emitAsJoin = 'join';

  /// Значение [emitAs]: `true` → `1`, `false` не пишется.
  static const emitAsBool01 = 'bool01';

  /// Значение [emitAs]: компактный JSON.
  static const emitAsJson = 'json';

  /// Значение [emitAs]: как есть, строкой.
  static const emitAsRaw = 'raw';

  /// Написание имени параметра в ССЫЛКЕ, когда оно не равно канону разбора.
  ///
  /// Зачем: канон разбора — первое в `aliases`, и обычно он же уезжает в
  /// ссылку. Но у части схем исторически пишется НЕ канон: запись читает имя
  /// с подчёркиванием, а пишет слитное. Асимметрия становится данными вместо
  /// ветки в коде.
  static const emitName = 'emit_name';

  /// Порт, который в ссылке ОПУСКАЕТСЯ, будучи равным этому значению.
  ///
  /// `"emit_omit_port": 443` в блоке `emit` секции.
  ///
  /// Зачем: каноническая форма части схем порт по умолчанию не пишет, а часть
  /// пишет всегда. Обращать `defaults.server_port` напрямую нельзя: у схемы
  /// бывает дефолт разбора (подставить порт, когда его нет) БЕЗ права
  /// опускать его на выходе — иначе ссылка перестала бы читаться клиентами,
  /// которые дефолта не знают.
  static const emitOmitPort = 'emit_omit_port';

  /// Кодирование userinfo на выходе: `"raw"` (percent) либо `"base64"`
  /// (SIP002 — base64 без паддинга).
  ///
  /// Зачем: `userinfo.decode` разбора это КОНВЕЙЕР ПОПЫТОК (`percent`,
  /// `base64?`), и обратить его нельзя — `base64?` значит «может быть, а
  /// может и нет». Выходная форма обязана быть названа однозначно.
  static const emitUserinfo = 'emit_userinfo';

  /// Значение [emitUserinfo]: percent-кодирование.
  static const emitUserinfoRaw = 'raw';

  /// Значение [emitUserinfo]: base64 без паддинга.
  static const emitUserinfoBase64 = 'base64';

  /// Форма, которая собирает не query-ссылку, а base64(JSON) — `v2rayn`.
  /// Карта «ключ JSON → путь тела».
  ///
  /// Зачем: у формы `v2rayn` пространство источников не `url`, а `json`, и
  /// записи адресуют его своими `source`. Обратный ход тот же, что у query,
  /// но сериализация другая: объект, base64, без паддинга.
  static const emitJsonMap = 'emit_json_map';

  /// Ключи JSON-формы, которые пишутся ВСЕГДА, даже пустыми
  /// (v2rayN-совместимость: клиенты ждут полный набор).
  static const emitJsonAlways = 'emit_json_always';
}

/// Каноническая ссылка, собранная секцией из канонического тела.
final class EmitResult {
  const EmitResult({required this.uri, this.lost = const []});

  /// Текст ссылки.
  final String uri;

  /// Пути тела, которые в ссылку НЕ уехали и объявлены `round_trip: false`.
  /// Пустой список — круг полон.
  final List<String> lost;
}

/// Собрать ссылку секцией [section] из канонического тела [body] с меткой
/// [label].
///
/// `null` — у секции нет блока `emit` (обратного хода не объявлено), и схема
/// остаётся на рукописном эмите до своей волны.
EmitResult? emitViaSection(
  MapperSection section,
  Map<String, dynamic> body,
  String label,
) {
  final emit = section.emit;
  if (emit == null) return null;
  return _Emit(section, emit, body, label).run();
}

/// Есть ли у секции объявленный обратный ход.
bool sectionEmits(MapperSection section) => section.emit != null;

final class _Emit {
  _Emit(this.section, this.emit, this.body, this.label);

  final MapperSection section;
  final Map<String, dynamic> emit;
  final Map<String, dynamic> body;
  final String label;

  /// Пары query в порядке объявления; сортировка — на сериализации.
  final List<(String, String)> _query = [];

  /// Пути тела, уже уехавшие в ссылку: по ним считается потеря на круге.
  final Set<String> _consumed = {};

  final List<String> _lost = [];

  EmitResult run() {
    final scheme = _scheme();
    final userinfo = _userinfo();

    // Записи обходятся в порядке объявления. Порядок ВЫХОДА задаёт
    // `param_order`, но порядок ОБХОДА важен для `consumed`: запись,
    // забравшая путь, снимает его у следующей (иначе `sni` уехало бы и
    // параметром, и частью `compose`).
    for (final p in section.params.values) {
      _emitParam(p);
    }

    // Пути, поставленные `scheme_sets`/`defaults`, в query не едут: их несёт
    // написание схемы либо умолчание, и запись их дублировала бы.
    _consumeSchemeSets(scheme);
    _consumeDefaults();

    _collectLost();

    final form = _form();
    if (form == _kFormV2rayn) return EmitResult(uri: _emitJson(scheme), lost: _lost);

    final host = _wrapIpv6(_str(_read('server')) ?? '');
    final portPart = _portPart();
    final qs = _serializeQuery();
    final frag = label.isEmpty ? '' : '#${_encodeFragment(label)}';
    final ui = userinfo.isEmpty ? '' : '$userinfo@';

    return EmitResult(
      uri: '$scheme://$ui$host$portPart'
          '${qs.isEmpty ? '' : '?$qs'}$frag',
      lost: _lost,
    );
  }

  static const _kFormV2rayn = 'v2rayn';
  static const _kFormSip002 = 'sip002';

  // ───────────────────────────── схема ─────────────────────────────

  String _form() => emit[EmitNames.form] as String? ?? 'url';

  /// **`form_from`** — форма (и через неё написание схемы) выбирается ТЕЛОМ.
  ///
  /// `scheme_sets⁻¹`: у схемы, где написание НЕСЁТ ТЕЛО (версия протокола,
  /// наличие TLS, вид транспорта — всё это бывает зашито в написание),
  /// обратный ход обязан вернуть то же написание, иначе круг терял бы поле,
  /// которого в query нет вовсе.
  String _scheme() {
    final ff = emit[EmitNames.formFrom];
    if (ff is Map) {
      for (final e in ff.entries) {
        final actual = _read(e.key as String);
        final branches = (e.value as Map).cast<String, dynamic>();
        final key = _fold(actual);
        for (final b in branches.entries) {
          if (b.key == '*') continue;
          if (_fold(b.key) == key) return b.value as String;
        }
        final star = branches['*'];
        if (star is String) return star;
      }
    }
    // Написание одно — его называет `detect.scheme_in` секции разбора: канон
    // ПЕРВЫЙ, ровно как у имён параметров (§0.6).
    final si = section.detect?['scheme_in'];
    if (si is List && si.isNotEmpty) return '${si.first}';
    return section.singboxType;
  }

  /// Пути, которые уже назвало написание схемы: в query они не повторяются.
  void _consumeSchemeSets(String scheme) {
    for (final e in section.schemeSets.entries) {
      if (_fold(e.key) != _fold(scheme)) continue;
      final sets = e.value;
      if (sets is! Map) continue;
      for (final s in sets.entries) {
        final k = s.key as String;
        if (k.startsWith(DraftNames.serviceParamPrefix)) continue;
        // Снимаем путь только когда тело НЕСЁТ РОВНО ТО, что ставит схема:
        // иначе значение, отличное от подразумеваемого схемой, потерялось бы
        // молча.
        final v = s.value;
        if (v is String && v.startsWith(DraftNames.serviceParamPrefix)) {
          _consumed.add(k);
          continue;
        }
        if (_matches(_read(k), v)) _consumed.add(k);
      }
    }
  }

  /// Пути, занятые `defaults` секции: значение, равное умолчанию, в ссылке не
  /// нужно — разбор подставит его сам.
  void _consumeDefaults() {
    for (final e in section.defaults.entries) {
      if (e.key.startsWith(DraftNames.serviceParamPrefix)) continue;
      if (_matches(_read(e.key), e.value)) _consumed.add(e.key);
    }
    // `type` телу принадлежит, но ссылке — нет: его несёт сама схема.
    _consumed.add('type');
  }

  String _portPart() {
    final port = _read('server_port');
    if (port == null) return '';
    final omit = emit[EmitNames.emitOmitPort];
    if (omit != null && '$omit' == '$port') return '';
    return ':$port';
  }

  // ──────────────────────────── userinfo ────────────────────────────

  /// **`into⁻¹` / `single_into⁻¹`** — собрать userinfo из путей тела.
  ///
  /// `into` перечисляет поля ПО ПОРЯДКУ следования в userinfo, и обратный ход
  /// — просто склейка тех же путей тем же разделителем. Хвостовые пустые
  /// компоненты срезаются, кроме случая, когда разделитель несёт СМЫСЛ:
  /// `user:@` у схемы с `single_into: password` отличает имя от пароля (§465),
  /// и без двоеточия узел вернулся бы с именем в слоте пароля.
  String _userinfo() {
    final u = section.userinfo;
    if (u == null) return '';

    final paths = u.into;
    if (paths.isEmpty) return '';

    final values = [for (final p in paths) _str(_read(p)) ?? ''];
    for (final p in paths) {
      _consumed.add(p);
    }

    // Форма base64 (SIP002): `base64(method:password)` без паддинга.
    if (_userinfoMode() == EmitNames.emitUserinfoBase64) {
      if (values.every((v) => v.isEmpty)) return '';
      final joined = values.join(u.splitSep ?? ':');
      return base64.encode(utf8.encode(joined)).replaceAll('=', '');
    }

    // Один слот — весь userinfo целиком, без разделителя.
    if (paths.length == 1) return _encodeParam(values.first);

    final sep = u.splitSep ?? ':';
    final first = values.first;
    final rest = values.skip(1).toList();
    final restEmpty = rest.every((v) => v.isEmpty);

    if (first.isEmpty && restEmpty) return '';

    // Хвост пуст: разделитель нужен только там, где одиночный компонент
    // читается ВТОРЫМ слотом (`single_into` называет не первый путь) —
    // иначе `user@` вернулся бы паролем.
    if (restEmpty) {
      final single = u.singleInto;
      final needsSep = single != null && single != paths.first;
      return '${_encodeParam(first)}${needsSep ? sep : ''}';
    }

    // Голова пуста, хвост нет: `:pass@` — законная форма.
    return [
      _encodeParam(first),
      ...rest.map(_encodeParam),
    ].join(sep);
  }

  String _userinfoMode() =>
      emit[EmitNames.emitUserinfo] as String? ??
      (_form() == _kFormSip002
          ? EmitNames.emitUserinfoBase64
          : EmitNames.emitUserinfoRaw);

  // ───────────────────────────── записи ─────────────────────────────

  /// Обратный ход ОДНОЙ записи таблицы.
  void _emitParam(MapperParam p) {
    // Служебная запись (`$multiport`) параметром источника не является.
    if (p.isService) return;
    // Объявленный отказ от обратного хода.
    if (_roundTripOff(p)) return;
    // Запись, которая никуда не едет (`maps_to: null`), и обратно не едет.
    if (p.mapsToPresent && p.mapsTo == null && p.compose == null) return;

    // **Запись читает НЕ query.** Её значение несёт сама ссылка — authority
    // (`host`, `port`), userinfo, фрагмент, — и повторять его параметром
    // нельзя: получилась бы ссылка вида `?server=…&server_port=…` рядом с тем
    // же адресом в authority. Путь при этом СЧИТАЕТСЯ УЕХАВШИМ: он в ссылке
    // есть, просто не в query.
    if (!_readsQuery(p)) {
      final path = p.mapsTo;
      if (path != null && _read(path) != null) _consumed.add(path);
      for (final t in p.splitInto.keys) {
        _consumed.add(t);
      }
      return;
    }

    // Путь уже занят записью, прошедшей раньше: две записи в один путь — это
    // конкуренция за ЧТЕНИЕ (`sni` схемы против `sni` общего блока), и на
    // обратном ходе побеждает первая, иначе параметр ушёл бы в ссылку дважды.
    final target = p.mapsTo;
    if (target != null && _consumed.contains(target)) return;

    // `compose` — обращение `extract`: один параметр из нескольких путей.
    final composed = _compose(p);
    if (composed != null) {
      _add(p, composed);
      return;
    }

    // **`extract` в ОБЪЕКТ (`$key`/`$value`) обращается САМ.** Новое имя тут
    // не заводится: запись уже объявила и разделитель элементов (`list.sep`),
    // и то, что элемент — пара «ключ: значение». Обратный ход из этого
    // выводится однозначно, и объявлять его вторым способом значило бы
    // завести второй источник правды ровно там, где кампания его убирает.
    if (_extractsPairs(p)) {
      final pairs = _joinPairs(p);
      if (pairs != null) _add(p, pairs);
      return;
    }

    // **`split_into⁻¹`** — запись разложила ОДИН список источника по
    // нескольким путям тела (адреса по семействам); обратный ход собирает их
    // назад в один список. Идёт раньше `maps_to`, потому что у такой записи
    // его обычно нет вовсе.
    if (p.splitInto.isNotEmpty) {
      final joined = _joinSplit(p);
      if (joined != null) _add(p, joined);
      return;
    }

    final path = p.mapsTo;

    // **Запись-СЕЛЕКТОР**: своего `maps_to` у неё нет, всё, что она делает, —
    // развилка `sets` по значению. Обратный ход у такой записи единственно
    // возможный: найти ветку, которую тело подтверждает, и вернуть её ключ.
    // Идёт ПЕРВЫМ — иначе `security` (у которой `maps_to` нет вовсе) вышла бы
    // из обхода раньше, чем дошла до своих веток, и блок `tls` остался бы
    // необъяснённым.
    if (path == null) {
      if (p.sets.isEmpty) return;
      final back = _valueFromSets(p);
      if (back != null) _add(p, back);
      return;
    }

    var value = _read(path);

    // **`implies⁻¹` / `sets⁻¹`.** Запись, которая ставит СВОИ пути помимо
    // `maps_to`, на обратном ходе обязана их снять: они не самостоятельные
    // параметры, а следствие этого. Снимаем только совпавшие — расхождение
    // означает, что путь занял кто-то другой, и терять его нельзя.
    if (value != null) {
      for (final s in [...p.implies.entries, ...p.sets.entries]) {
        final k = s.key;
        if (k.startsWith(DraftNames.serviceParamPrefix)) continue;
        if (_matches(_read(k), s.value)) _consumed.add(k);
      }
    }

    // `sets` по ЗНАЧЕНИЮ у записи, у которой `maps_to` ЕСТЬ, но тело его не
    // несёт: значение восстанавливается веткой.
    if (value == null && p.sets.isNotEmpty) {
      final back = _valueFromSets(p);
      if (back != null) {
        _add(p, back);
        return;
      }
    }

    if (value == null) return;
    _consumed.add(path);

    // **`value_map⁻¹`.** Инъективность проверена при загрузке секции
    // ([invertValueMap]); неинъективная таблица обратного хода не даёт, и
    // значение уезжает как есть — так у `fp: {random: null}` ветка `null`
    // просто не имеет обратного написания.
    final inv = invertValueMap(p.valueMap);
    if (inv != null) {
      final hit = inv[_fold(value)];
      if (hit != null) value = hit;
    }

    final text = _serializeValue(p, value);
    if (text == null) return;
    _add(p, text);
  }

  /// Раскладывает ли `extract` записи значение в ПАРЫ объекта — то есть
  /// объявлены ли служебные цели `$key`/`$value`.
  static bool _extractsPairs(MapperParam p) {
    final into = p.extract?.into;
    if (into == null) return false;
    return into.values.any((v) => v == r'$key') &&
        into.values.any((v) => v == r'$value');
  }

  /// Обращение `extract` в объект: пары тела обратно в одну строку.
  ///
  /// Разделитель ПАР — `list.sep` записи (у заголовков `\r\n`), разделитель
  /// ключа и значения — `": "`, потому что именно его и требует регулярка
  /// разбора (`k` до двоеточия, пробелы после него необязательны). Порядок —
  /// по ключу при `sort_keys`, иначе порядок тела: тело у нас упорядочено, и
  /// порядок ключей входит в identity.
  String? _joinPairs(MapperParam p) {
    final path = p.mapsTo;
    if (path == null) return null;
    final v = _read(path);
    if (v is! Map || v.isEmpty) return null;
    _consumed.add(path);
    var keys = v.keys.map((e) => '$e').toList();
    if (p.sortKeys) keys.sort();
    final sep = p.list?.sep ?? '\r\n';
    return keys.map((k) => '$k: ${v[k]}').join(sep);
  }

  /// **`split_into⁻¹`** — собрать разложенные по путям значения обратно в один
  /// список источника.
  ///
  /// Порядок — порядок ОБЪЯВЛЕНИЯ путей в `split_into`, а не порядок в
  /// исходной ссылке: восстановить второй нечем (запись развела значения по
  /// признаку, а не по месту), а объявленный порядок детерминирован и
  /// одинаков у обеих реализаций.
  String? _joinSplit(MapperParam p) {
    final items = <String>[];
    for (final path in p.splitInto.keys) {
      final v = _read(path);
      if (v == null) continue;
      _consumed.add(path);
      if (v is List) {
        items.addAll(v.map((e) => '$e'));
      } else {
        items.add('$v');
      }
    }
    if (items.isEmpty) return null;
    return items.join(p.list?.sep ?? ',');
  }

  /// **Читает ли запись query.** Значение записи, чей источник — authority,
  /// userinfo или фрагмент, ссылка уже несёт своим МЕСТОМ, и параметром его
  /// не повторяют.
  static bool _readsQuery(MapperParam p) {
    final sources = [
      ...p.source,
      for (final v in p.sourceByForm.values) ...v,
    ];
    if (sources.isEmpty) return false;
    return sources.any((s) => s.startsWith('query.') || s == 'query');
  }

  /// **`sets⁻¹` по ветке.** Запись-СЕЛЕКТОР вида
  /// `sets: {"<значение>": {<путь>: <v>}}` пишет разные пути при разных
  /// значениях; обратный ход ищет ветку, чьи присваивания тело подтверждает
  /// ЦЕЛИКОМ, и отдаёт её ключ значением параметра.
  ///
  /// Три тонкости, каждая — живой случай:
  ///
  /// - ветка `{path: null}` означает «путь СНЯТ», и подтверждается она
  ///   ОТСУТСТВИЕМ пути (`security=none` убирает блок `tls` целиком);
  /// - ветка с ПУСТЫМ ключом (`""`) — это «параметра не было»: она
  ///   описывает умолчание, и писать её обратно нельзя, иначе у каждого узла
  ///   появился бы пустой параметр;
  /// - ветки перебираются в порядке объявления, и первая совпавшая
  ///   побеждает — при двух ветках с одинаковыми присваиваниями (`tls` и
  ///   `""` обе дают `tls.enabled: true`) канон объявлен первым.
  String? _valueFromSets(MapperParam p) {
    String? best;
    var bestScore = -1;
    for (final e in p.sets.entries) {
      final branch = e.value;
      if (branch is! Map || branch.isEmpty) continue;
      var all = true;
      // Вес ветки — сколько ПОЛОЖИТЕЛЬНЫХ присваиваний она подтвердила.
      // Нужен, чтобы `reality` (две записи) побеждал `tls` (одна), когда тело
      // подтверждает обе: у более конкретной ветки присваиваний больше.
      var score = 0;
      for (final s in branch.entries) {
        final k = '${s.key}';
        if (k.startsWith(DraftNames.serviceParamPrefix)) continue;
        if (!_matches(_read(k), s.value)) {
          all = false;
          break;
        }
        if (s.value != null) score++;
      }
      if (!all) continue;
      // Пустой ключ описывает УМОЛЧАНИЕ, а не значение: обратного хода у него
      // нет — параметра в ссылке не будет. Но пути ветка ОБЪЯСНЯЕТ, и
      // засчитать их обязана, иначе они попали бы в «потеряно молча», хотя
      // разбор восстановит их сам, той же веткой умолчания.
      if (e.key.isEmpty) {
        _consumeBranch(branch);
        // Умолчание СИЛЬНЕЕ ветки-отрицания (см. ниже): когда тело
        // подтверждает обе, писать параметр не нужно вовсе.
        if (bestScore <= 0) {
          bestScore = 0;
          best = null;
        }
        continue;
      }
      // Ветка, которая ТОЛЬКО СНИМАЕТ пути (`none` → `tls: null`), веса не
      // набирает: подтверждается она отсутствием, а отсутствие подтверждает
      // и всякая другая ветка, чьих путей в теле нет. Но обратный ход у неё
      // ЕСТЬ, и он обязателен: не напиши мы `security=none`, разбор поднял бы
      // TLS веткой умолчания, и узел без шифрования стал бы узлом с ним.
      if (score == 0 && bestScore < 0) {
        bestScore = 0;
        best = e.key;
        continue;
      }
      if (score <= bestScore) continue;
      bestScore = score;
      best = e.key;
      _consumeBranch(branch);
    }
    return best;
  }

  void _consumeBranch(Map branch) {
    for (final s in branch.entries) {
      final k = '${s.key}';
      if (k.startsWith(DraftNames.serviceParamPrefix)) continue;
      // Ветка, СНИМАЮЩАЯ путь, ничего не занимает: снимать нечего.
      if (s.value == null) continue;
      _consumed.add(k);
    }
  }

  /// **`compose`** — обращение `extract`: собрать одно значение из нескольких
  /// путей тела по объявленному шаблону.
  String? _compose(MapperParam p) {
    final spec = _composeSpec(p);
    if (spec == null) return null;
    final template = spec[EmitNames.composeTemplate] as String?;
    final from = (spec[EmitNames.composeFrom] as Map?)?.cast<String, dynamic>();
    if (template == null || from == null) return null;
    final omitEmpty = ((spec[EmitNames.composeOmitWhenEmpty] as List?) ??
            const [])
        .map((e) => '$e')
        .toSet();

    final values = <String, String>{};
    for (final e in from.entries) {
      final v = _read('${e.value}');
      if (v == null) continue;
      final text = _str(v);
      if (text == null || text.isEmpty) continue;
      values[e.key] = text;
      _consumed.add('${e.value}');
    }
    // Головы нет — параметра нет вовсе.
    if (values.isEmpty) return null;

    var out = template;
    for (final g in from.keys) {
      final has = values.containsKey(g);
      if (!has && omitEmpty.contains(g)) {
        // Группа среза: убираем её вместе с предшествующим разделителем.
        out = out.replaceAll(RegExp('[^{}]?\\{$g\\}'), '');
        continue;
      }
      out = out.replaceAll('{$g}', values[g] ?? '');
    }
    return out.isEmpty ? null : out;
  }

  /// Объектная форма `compose`. Грамматика разбора знает `compose` СТРОКОЙ
  /// (`MapperParam.compose` — имя приёма); объектная форма с `template`/`from`
  /// — расширение волны W7, и читается из сырого JSON записи.
  Map<String, dynamic>? _composeSpec(MapperParam p) {
    final raw = p.raw[EmitNames.compose];
    return raw is Map ? raw.cast<String, dynamic>() : null;
  }

  /// **`round_trip: false`** — запись, у которой обратного хода нет, с
  /// причиной прозой. Её путь считается ОБЪЯВЛЕННОЙ потерей: он не едет в
  /// ссылку и не попадает в [EmitResult.lost] как разрыв.
  bool _roundTripOff(MapperParam p) {
    if (_paramEmitAttr(p, EmitNames.roundTrip) != false) return false;
    final path = p.mapsTo;
    if (path != null) _consumed.add(path);
    return true;
  }

  // ─────────────────────────── сериализация ───────────────────────────

  /// Значение параметра текстом — по объявленному `emit_as`, а при его
  /// отсутствии по типу значения.
  String? _serializeValue(MapperParam p, dynamic value) {
    final mode = _emitAs(p);
    switch (mode) {
      case EmitNames.emitAsBool01:
        if (value == false) return null;
        return '1';
      case EmitNames.emitAsJoin:
        final sep = p.list?.sep ?? ',';
        if (value is List) return value.isEmpty ? null : value.join(sep);
        return '$value';
      case EmitNames.emitAsJson:
        return jsonEncode(value);
    }
    if (value is bool) return value ? '1' : null;
    if (value is List) {
      if (value.isEmpty) return null;
      return value.join(p.list?.sep ?? ',');
    }
    if (value is Map) return jsonEncode(value);
    final text = '$value';
    return text.isEmpty ? null : text;
  }

  String _emitAs(MapperParam p) {
    // Явное объявление сильнее вывода.
    final declared = _paramEmitAttr(p, EmitNames.emitAs);
    if (declared is String) return declared;
    if (p.list != null) return EmitNames.emitAsJoin;
    if (p.type == 'bool') return EmitNames.emitAsBool01;
    return EmitNames.emitAsRaw;
  }

  /// Атрибут эмита у записи. Читается из СЫРОГО JSON записи ([MapperParam.raw])
  /// — пока грамматика обратного хода не заморожена, типизировать её поля
  /// значило бы править модель на каждом переименовании.
  dynamic _paramEmitAttr(MapperParam p, String name) => p.raw[name];

  /// **Каноническое имя параметра в ссылке** — первое в `aliases` (§0.6),
  /// если запись не назвала другое написание явно (`emit_name`).
  String _nameOf(MapperParam p) {
    final explicit = _paramEmitAttr(p, EmitNames.emitName);
    if (explicit is String && explicit.isNotEmpty) return explicit;
    return p.spellings.first;
  }

  void _add(MapperParam p, String value) {
    final name = _nameOf(p);
    if (_omitted(p, name, value)) return;
    _query.add((name, value));
  }

  /// **`omit_default`** — параметр не пишется, КОГДА ЕГО ЗНАЧЕНИЕ РАВНО
  /// УМОЛЧАНИЮ. Не «не пишется никогда»: селектор вида TLS попадает в
  /// `omit_default` потому, что включённый TLS подразумевается, — а значение
  /// «шифрования нет» обязано уехать в ссылку, иначе разбор поднимет TLS
  /// веткой умолчания и узел без шифрования станет узлом с ним.
  ///
  /// Умолчание берётся у самой записи: это ветка `sets` с ПУСТЫМ ключом
  /// («параметра не было»). Значение, дающее те же присваивания, что и она, и
  /// есть значение по умолчанию.
  ///
  /// `emit_when: always` правило снимает целиком.
  bool _omitted(MapperParam p, String name, String value) {
    // Правило У САМОЙ ЗАПИСИ сильнее правила секции: секция говорит за все
    // записи разом, запись — за себя, и конкретное побеждает.
    final ownWhen = _paramEmitAttr(p, EmitNames.emitWhen);
    if (ownWhen == EmitNames.emitWhenAlways) return false;
    final ownOmit = _paramEmitAttr(p, EmitNames.omitDefault);
    if (ownOmit == false) return false;
    if (ownOmit == true) return _isDefaultValue(p, value);

    final always = (emit[EmitNames.emitWhen] as Map?)?[name];
    if (always == EmitNames.emitWhenAlways) return false;
    final omit = emit[EmitNames.omitDefault];
    if (omit is! List || !omit.map((e) => '$e').contains(name)) return false;
    return _isDefaultValue(p, value);
  }

  /// Равно ли [value] умолчанию записи.
  ///
  /// Два источника умолчания, в порядке убывания точности:
  ///
  /// 1. ветка `sets` с пустым ключом — её присваивания И ЕСТЬ «как если бы
  ///    параметра не было»; значение, дающее те же, — умолчание;
  /// 2. `defaults` секции по пути `maps_to` — для записи без развилки.
  ///
  /// Не нашлось ни того, ни другого — значение умолчанием не считается и
  /// уезжает в ссылку: молчаливая потеря хуже лишнего параметра.
  bool _isDefaultValue(MapperParam p, String value) {
    final fallback = p.sets[''];
    if (fallback is Map) {
      final mine = p.sets[value];
      if (mine is Map) {
        return jsonEncode(_sorted(mine)) == jsonEncode(_sorted(fallback));
      }
      // Развилка есть, а ветки под этим значением нет: значение умолчанием
      // быть не может.
      return false;
    }
    final path = p.mapsTo;
    if (path == null) return false;
    final d = section.defaults[path];
    return d != null && _fold(d) == _fold(value);
  }

  static Map<String, dynamic> _sorted(Map m) {
    final keys = m.keys.map((e) => '$e').toList()..sort();
    return {for (final k in keys) k: m[k]};
  }

  /// Сериализация query по норме: **порядок алфавитный, пробел `%20`, `+` в
  /// значении кодируется `%2B`**.
  ///
  /// `%2B` обязателен: чтение декодирует `+` как пробел (form-encoding), и
  /// литеральный `+` в base64-ключе иначе вернулся бы пробелом — тот самый
  /// класс дефектов, который волна W4 чинила на входе (D133-7).
  String _serializeQuery() {
    if (_query.isEmpty) return '';
    final order = emit[EmitNames.paramOrder];
    final pairs = [..._query];
    if (order == null || order == EmitNames.paramOrderAlphabetical) {
      pairs.sort((a, b) => a.$1.compareTo(b.$1));
    } else if (order is List) {
      final idx = {for (var i = 0; i < order.length; i++) '${order[i]}': i};
      pairs.sort((a, b) =>
          (idx[a.$1] ?? 1 << 20).compareTo(idx[b.$1] ?? 1 << 20));
    }
    return pairs
        .map((e) => '${_encodeParam(e.$1)}=${_encodeParam(e.$2)}')
        .join('&');
  }

  /// Форма `v2rayn`: base64(JSON) без паддинга.
  String _emitJson(String scheme) {
    final map = <String, dynamic>{};
    final always = ((emit[EmitNames.emitJsonAlways] as List?) ?? const [])
        .map((e) => '$e')
        .toSet();
    final jsonMap =
        (emit[EmitNames.emitJsonMap] as Map?)?.cast<String, dynamic>() ??
            const {};
    for (final e in jsonMap.entries) {
      final v = _read('${e.value}');
      if (v == null) {
        if (always.contains(e.key)) map[e.key] = '';
        continue;
      }
      _consumed.add('${e.value}');
      map[e.key] = v is String ? v : '$v';
    }
    final bytes = utf8.encode(jsonEncode(map));
    return '$scheme://${base64.encode(bytes).replaceAll('=', '')}';
  }

  // ───────────────────────────── потери ─────────────────────────────

  /// Пути тела, не уехавшие в ссылку. Объявленная потеря (`round_trip:
  /// false`) — не ошибка; НЕобъявленная означает, что круг рвётся молча.
  void _collectLost() {
    for (final path in _paths(body, '')) {
      // Служебные ключи тела, ссылке не принадлежащие.
      if (path == 'type' || path == 'tag') continue;
      // Путь засчитан САМ либо засчитан его предок: запись, забравшая
      // `headers` целиком, забрала и каждый заголовок внутри — перечислять
      // их по одному она не обязана и не может (имена приходят от данных).
      if (_consumedWithAncestors(path)) continue;
      _lost.add(path);
    }
  }

  bool _consumedWithAncestors(String path) {
    if (_consumed.contains(path)) return true;
    for (var i = path.indexOf('.'); i >= 0; i = path.indexOf('.', i + 1)) {
      if (_consumed.contains(path.substring(0, i))) return true;
    }
    return false;
  }

  static Iterable<String> _paths(Map<String, dynamic> m, String prefix) sync* {
    for (final e in m.entries) {
      final p = prefix.isEmpty ? e.key : '$prefix.${e.key}';
      final v = e.value;
      if (v is Map<String, dynamic> && v.isNotEmpty) {
        yield* _paths(v, p);
      } else {
        yield p;
      }
    }
  }

  // ───────────────────────────── мелочь ─────────────────────────────

  dynamic _read(String path) {
    dynamic cur = body;
    for (final seg in path.split('.')) {
      if (cur is! Map) return null;
      cur = cur[seg];
      if (cur == null) return null;
    }
    return cur;
  }

  static String? _str(dynamic v) => v == null ? null : '$v';

  static String _fold(dynamic v) => '$v'.trim().toLowerCase();

  static bool _matches(dynamic actual, dynamic expected) {
    if (expected == null) return actual == null;
    if (actual == null) return false;
    return _fold(actual) == _fold(expected);
  }

  static String _wrapIpv6(String host) =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  /// Пробел → `%20`, литеральный `+` → `%2B` (см. [_serializeQuery]).
  static String _encodeParam(String s) =>
      Uri.encodeQueryComponent(s).replaceAll('+', '%20');

  static String _encodeFragment(String s) =>
      Uri.encodeComponent(s).replaceAll('+', '%20');
}

/// **`value_map⁻¹` с проверкой ИНЪЕКТИВНОСТИ.**
///
/// Таблица, в которой два написания ведут в одно значение тела, обратного хода
/// не имеет: выбирать между ними эмиттеру нечем, и тихий выбор первого
/// переписывал бы ссылки живых узлов. Такая таблица возвращает `null`, и
/// значение уезжает в ссылку как есть.
///
/// Ветка со значением `null` (`{random: null}`) из обращения ВЫПАДАЕТ: она
/// означает «поле не ставится», а не «значение такое».
Map<String, String>? invertValueMap(Map<String, dynamic> vm) {
  if (vm.isEmpty) return null;
  final out = <String, String>{};
  for (final e in vm.entries) {
    if (e.value == null) continue;
    // Ветка-объект — это `sets`, а не перевод значения.
    if (e.value is Map || e.value is List) return null;
    final key = '${e.value}'.trim().toLowerCase();
    if (out.containsKey(key)) return null; // не инъективна
    out[key] = e.key;
  }
  return out.isEmpty ? null : out;
}
