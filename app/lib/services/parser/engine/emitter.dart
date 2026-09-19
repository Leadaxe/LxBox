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

/// Имена атрибутов ЭМИТА — СВЕДЕНЫ С ЛАУНЧЕРОМ 19.09.2026
/// (SPEC 133 `GRAMMAR_SYNC.md` «Сведение №2», §5).
///
/// Держатся в одном месте, как и [DraftNames]: обратный ход у лаунчера ещё не
/// написан («общий долг»), первое написание имён делали мы, и переименование
/// по итогам сведения обязано быть правкой ОДНОЙ строки, а не обходом дерева.
/// Так оно и вышло — префикс `emit_` снят у четырёх имён одной правкой здесь.
///
/// Итог сведения: принято как есть — `round_trip`+`round_trip_why`, `emit_as`;
/// имя очищено от избыточного префикса — `emit.omit_port`, `emit.userinfo`,
/// `emit.json_map`, `emit.json_always` (внутри объекта `emit` префикс называл
/// бы `emit` дважды); сведено к существующему FROZEN-имени — `compose`
/// (расширение значений строка → объект); ОТКЛОНЕНО — `emit_name`.
///
/// Префикс `emit_` сохраняется у атрибутов, живущих У ЗАПИСИ (`emit_as`,
/// `emit_when`): там он не избыточен, а необходим — он отличает атрибут
/// ВЫХОДА от атрибута входа в одном словаре записи.
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

  /// Ключ-ПРЕДИКАТ внутри [formFrom]: «хоть один из путей заполнен».
  /// `{"any_set": {"<форма>": ["<путь>", …], "*": "<форма>"}}`.
  ///
  /// Зачем: род узла у части схем объявлен НАБОРОМ полей, а не одним
  /// значением одного пути, и обычная ветка `form_from` его не выражает.
  /// Имя взято у `kind_when` разбора — тот же предикат в ту же сторону,
  /// второго словаря не заводится.
  static const formFromAnySet = 'any_set';

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

  // ─── заведено волной W7, сведено с лаунчером (GRAMMAR_SYNC §5.2) ───

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

  /// Написание имени параметра НА ВЫХОДЕ, объявленное СХЕМОЙ:
  /// `"names": {"<имя записи>": "<написание в ссылке>"}` внутри `emit`.
  ///
  /// Умолчание остаётся прежним — ПЕРВОЕ имя в `aliases` (имя записи). Карта
  /// её лишь перекрывает, и только там, где схема объявила это сама.
  ///
  /// Зачем именно схемой, а не перестановкой `aliases` общего блока: де-факто
  /// написание — свойство СХЕМЫ, а не поля. Один и тот же признак «не
  /// проверять сертификат» читается всеми написаниями сразу, но пишется у
  /// каждой схемы своим: тем, которое читают её клиенты. Перестановка
  /// `aliases` в общем блоке навязала бы одно написание всем схемам разом.
  ///
  /// Выбор ограничен написаниями САМОЙ записи (имя либо алиас) — это судит
  /// линтер секций: иначе вход и выход разъехались бы молча, а «пишем то,
  /// чего не читаем» и есть ссылка, которую сами не разберём.
  static const names = 'names';

  /// Порт, который в ссылке ОПУСКАЕТСЯ, будучи равным этому значению.
  ///
  /// `"omit_port": 443` в блоке `emit` секции.
  ///
  /// Зачем: каноническая форма части схем порт по умолчанию не пишет, а часть
  /// пишет всегда. Обращать `defaults.server_port` напрямую нельзя: у схемы
  /// бывает дефолт разбора (подставить порт, когда его нет) БЕЗ права
  /// опускать его на выходе — иначе ссылка перестала бы читаться клиентами,
  /// которые дефолта не знают.
  static const omitPort = 'omit_port';

  /// Кодирование userinfo на выходе.
  ///
  /// Короткое написание — строка (`"raw"` | `"base64"`); полное — объект
  /// `{form, padding}`: паддинг base64 объявляется ОТДЕЛЬНО, потому что две
  /// реализации пишут его по-разному (`=` на конце), обе читают обе формы, а
  /// ссылки различаются побайтово — и ни одна сторона не меняет свою молча.
  ///
  /// Зачем вообще: `userinfo.decode` разбора это КОНВЕЙЕР ПОПЫТОК (`percent`,
  /// `base64?`), и обратить его нельзя — `base64?` значит «может быть, а
  /// может и нет». Выходная форма обязана быть названа однозначно.
  static const userinfo = 'userinfo';

  /// Ключ формы внутри объектного написания [userinfo].
  static const userinfoForm = 'form';

  /// Ключ паддинга внутри объектного написания [userinfo].
  static const userinfoPadding = 'padding';

  /// Ключ внутри объектного написания [userinfo]: писать разделитель `@`
  /// даже у ПУСТОГО userinfo.
  ///
  /// Зачем: у схемы, где userinfo — единственное поле авторизации, «`@` без
  /// значения» это часть канонического вида ссылки, которую сегодня пишет
  /// LxBox и читают чужие клиенты. Вывести флаг из разбора нельзя: разбор
  /// пустой userinfo и отсутствующий userinfo не различает, а тексты ссылок
  /// различаются побайтово.
  static const userinfoEmptySeparator = 'empty_separator';

  /// Значение формы [userinfo]: percent-кодирование.
  static const userinfoRaw = 'raw';

  /// Значение формы [userinfo]: base64.
  static const userinfoBase64 = 'base64';

  /// Форма, которая собирает не query-ссылку, а base64(JSON) — `v2rayn`.
  /// Карта «ключ JSON → путь тела».
  ///
  /// Зачем: у формы `v2rayn` пространство источников не `url`, а `json`, и
  /// записи адресуют его своими `source`. Обратный ход тот же, что у query,
  /// но сериализация другая: объект, base64.
  static const jsonMap = 'json_map';

  /// Ключи JSON-формы, которые пишутся ВСЕГДА, даже когда тело их не несёт
  /// (v2rayN-совместимость: клиенты ждут полный набор, и ключа, которого
  /// нет, часть из них не переживает).
  ///
  /// Перечень — значение по умолчанию пустая строка; карта
  /// `{"<ключ>": "<значение>"}` называет заполнитель явно: `aid` пустой
  /// строкой чужие клиенты читают хуже, чем нулём, а версия контейнера
  /// вообще константа.
  static const jsonAlways = 'json_always';

  /// Условия, при которых ссылка НЕ собирается: форма тела не выражает.
  /// Список карт `{path, len_gt}` — отказ, если длина значения по пути
  /// больше порога. Пустая ссылка — тот же исход, что у схемы без
  /// переносимой формы (Copy link на пустой строке молча не копирует).
  static const refuseWhen = 'refuse_when';
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
  if (!sectionEmits(section)) return null;
  return _Emit(section, section.emit!, body, label).run();
}

/// Есть ли у секции объявленный обратный ход.
///
/// Пустая `params` обратного хода НЕ даёт, даже при объявленном блоке `emit`.
/// Случай живой и опасный: черновик-ОВЕРЛЕЙ несёт только свои ключи, и без
/// загруженного реестра из него собирается секция с одним `emit` и без единой
/// записи. Эмиттер по такой секции выдал бы ссылку БЕЗ userinfo и без
/// параметров — синтаксически годную и молча неверную, а `toUri()` у нас
/// форма хранения узла. Лучше отказ, который видно.
bool sectionEmits(MapperSection section) =>
    section.emit != null && section.params.isNotEmpty;

/// Написания, которыми запись [p] ЧИТАЕТСЯ: имя, алиасы и имена параметров из
/// её `source`.
///
/// Этим набором ограничен выбор [EmitNames.names]: писать можно только то, что
/// запись же и читает, иначе своя ссылка обратно не разберётся. Набор общий у
/// эмиттера и линтера секций — одно правило, одно место.
Set<String> readableNames(MapperParam p) => {
      ...p.spellings,
      for (final s in [
        ...p.source,
        for (final v in p.sourceByForm.values) ...v,
      ])
        if (s.startsWith('query.')) s.substring('query.'.length),
    };

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
    // Отказ формата — ДО обхода записей: иначе ссылка собралась бы из
    // первого элемента массива, а остальные числились бы уехавшими.
    if (_refuse()) return const EmitResult(uri: '');

    final scheme = _scheme();
    final userinfo = _userinfo();

    // Пути, которые НЕСЁТ САМО НАПИСАНИЕ СХЕМЫ, засчитываются ДО обхода
    // записей: иначе запись, ведущая в такой путь, уехала бы параметром —
    // а параметр этот дублирует то, что уже сказано схемой. У схем, где TLS
    // включён самим написанием, так появлялся лишний `security=tls`.
    _consumeSchemeSets(scheme);

    // Записи обходятся в порядке объявления. Порядок ВЫХОДА задаёт
    // `param_order`, но порядок ОБХОДА важен для `consumed`: запись,
    // забравшая путь, снимает его у следующей (иначе `sni` уехало бы и
    // параметром, и частью `compose`).
    for (final p in section.params.values) {
      _emitParam(p);
    }

    // Умолчания СЕКЦИИ — после записей: они заполняют оставшееся, а не
    // конкурируют (норма §10.1, тот же порядок, что у разбора).
    _consumeDefaults();

    _collectLost();

    final form = _form();
    // Форма-КОНТЕЙНЕР узнаётся по ПРОСТРАНСТВУ ИСТОЧНИКОВ, объявленному у неё
    // же в `forms[]` (`space: json`), а не по своему имени: имена форм —
    // данные, и знать их движку не положено ровно так же, как имена схем.
    if (_spaceOf(form) == 'json') {
      return EmitResult(uri: _emitJson(scheme), lost: _lost);
    }

    final host = _wrapIpv6(_str(_readSourcePath('host')) ?? '');
    final portPart = _portPart();
    final qs = _serializeQuery();
    final frag = label.isEmpty ? '' : '#${_encodeFragment(label)}';
    final ui = userinfo.isEmpty && !_userinfoEmptySeparator()
        ? ''
        : '$userinfo@';

    return EmitResult(
      uri: '$scheme://$ui$host$portPart'
          '${qs.isEmpty ? '' : '?$qs'}$frag',
      lost: _lost,
    );
  }

  /// Пространство источников формы по её id — из `forms[]` секции.
  /// Форма, которой в `forms[]` нет, считается обычной url-ссылкой.
  String _spaceOf(String id) {
    for (final f in section.forms) {
      if (f.id == id) return f.space;
    }
    return 'url';
  }

  /// Читает ли userinfo формы base64: у формы, чей разбор его декодирует
  /// (`userinfo.decode` содержит base64), обратный ход обязан кодировать.
  bool get _userinfoDecodesBase64 =>
      section.userinfo?.decode.any((d) => d.startsWith('base64')) ?? false;

  // ───────────────────────────── схема ─────────────────────────────

  String _form() => emit[EmitNames.form] as String? ?? 'url';

  /// **`form_from`** — форма (и через неё написание схемы) выбирается ТЕЛОМ.
  ///
  /// `scheme_sets⁻¹`: у схемы, где написание НЕСЁТ ТЕЛО (версия протокола,
  /// наличие TLS, вид транспорта — всё это бывает зашито в написание),
  /// обратный ход обязан вернуть то же написание, иначе круг терял бы поле,
  /// которого в query нет вовсе.
  ///
  /// Ключ записи — ПУТЬ ТЕЛА, и его значение выбирает ветку. Ключ
  /// [EmitNames.formFromAnySet] — предикат «хоть один из путей заполнен», тем
  /// же именем, каким его пишет `kind_when` разбора: род узла у части схем
  /// объявлен НАБОРОМ полей, а не одним, и одного пути тут не хватает.
  String _scheme() {
    final ff = emit[EmitNames.formFrom];
    if (ff is Map) {
      for (final e in ff.entries) {
        final key0 = '${e.key}';
        final branches = (e.value as Map).cast<String, dynamic>();

        if (key0 == EmitNames.formFromAnySet) {
          // `{any_set: {"<схема>": [<пути>], "*": "<схема>"}}` — первая ветка,
          // чей набор тело подтвердило хоть одним путём.
          for (final b in branches.entries) {
            if (b.key == '*') continue;
            final paths = b.value;
            if (paths is! List) continue;
            if (paths.any((p) => _read('$p') != null)) return b.key;
          }
          final star = branches['*'];
          if (star is String) return star;
          continue;
        }

        final actual = _read(key0);
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
  ///
  /// Ключ `*` — «при любом написании»: у схемы, где свойство безусловно
  /// (шифрование, которое протокол несёт сам), ветка одна и общая.
  void _consumeSchemeSets(String scheme) {
    for (final e in section.schemeSets.entries) {
      if (e.key != '*' && _fold(e.key) != _fold(scheme)) continue;
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
    final port = _readSourcePath('port');
    if (port == null) return '';
    final omit = emit[EmitNames.omitPort];
    if (omit != null && '$omit' == '$port') return '';
    return ':$port';
  }

  /// Значение для МЕСТА ССЫЛКИ (`host`, `port`) — по записи, которая это место
  /// читает.
  ///
  /// Путь тела здесь не зашит: у части схем адрес узла лежит не в `server`, а
  /// глубже (адрес пира у туннельных схем), и таблица это объявляет обычным
  /// `source: "host"` с собственным `maps_to`. Зашей мы `server` — у таких
  /// схем authority собиралась бы пустой, и ссылка теряла бы адрес.
  ///
  /// Записи перебираются в порядке объявления; берётся первая, чьё значение
  /// тело несёт.
  dynamic _readSourcePath(String place) {
    for (final p in section.params.values) {
      if (p.isService) continue;
      final path = p.mapsTo;
      if (path == null) continue;
      final sources = [
        ...p.source,
        for (final v in p.sourceByForm.values) ...v,
      ];
      if (!sources.contains(place)) continue;
      final v = _read(path);
      if (v != null) return v;
    }
    return null;
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
    final paths = u?.into ?? const <String>[];

    // Блок `userinfo` секции пуст (или его нет), но userinfo у схемы ЕСТЬ:
    // его называет своим первым источником обычная запись таблицы. Так
    // объявлен ключ у туннельных схем — `source: ["userinfo", "query.<имя>"]`,
    // где userinfo КАНОН, а параметр запасное написание входа. Не напиши мы
    // канон, ключ уезжал бы параметром: ссылка осталась бы читаемой, но
    // сменила бы вид у всех живых узлов схемы.
    if (paths.isEmpty || u == null) return _userinfoFromParam();

    final values = [for (final p in paths) _str(_read(p)) ?? ''];
    for (final p in paths) {
      _consumed.add(p);
    }

    // Форма base64 (SIP002): `base64(method:password)`. Паддинг объявлен
    // отдельно — две реализации пишут его по-разному, обе читают обе формы,
    // и менять своё написание молча ни одна не вправе.
    if (_userinfoForm() == EmitNames.userinfoBase64) {
      if (values.every((v) => v.isEmpty)) return '';
      final joined = values.join(u.splitSep ?? ':');
      final encoded = base64.encode(utf8.encode(joined));
      return _userinfoPadding() ? encoded : encoded.replaceAll('=', '');
    }

    // Один слот — весь userinfo целиком, без разделителя.
    if (paths.length == 1) return _encodeParam(values.first);

    final sep = u.splitSep ?? ':';
    final first = values.first;
    final rest = values.skip(1).toList();
    final restEmpty = rest.every((v) => v.isEmpty);

    if (first.isEmpty && restEmpty) return '';

    // **Форма ОДИНОЧНОГО userinfo.** `single_into` называет путь, в который
    // уезжает userinfo БЕЗ разделителя, и обратный ход обязан этот путь
    // узнавать: напиши мы разделитель там, где его не ждут, — или опусти
    // там, где ждут, — своя же ссылка вернулась бы с перепутанными слотами.
    final single = u.singleInto;
    final singleIdx = single == null ? -1 : paths.indexOf(single);

    // Заполнен ровно ОДИН слот, и это ровно тот, который читает одиночная
    // форма: пишем его голым, без разделителя.
    final filled = [
      for (var i = 0; i < values.length; i++)
        if (values[i].isNotEmpty) i,
    ];
    if (filled.length == 1 && filled.first == singleIdx) {
      return _encodeParam(values[singleIdx]);
    }

    // Хвост пуст: разделитель нужен там, где без него значение прочиталось бы
    // одиночной формой, то есть уехало бы В ДРУГОЙ слот.
    if (restEmpty) {
      final needsSep = singleIdx >= 0 && singleIdx != 0;
      return '${_encodeParam(first)}${needsSep ? sep : ''}';
    }

    // Голова пуста, хвост нет: `:pass@` — законная форма там, где одиночный
    // userinfo читается ИМЕНЕМ (иначе сюда не дойдёт: случай выше).
    return [
      _encodeParam(first),
      ...rest.map(_encodeParam),
    ].join(sep);
  }

  /// userinfo, названный ПЕРВЫМ ИСТОЧНИКОМ обычной записи, когда блок
  /// `userinfo` у секции пуст.
  ///
  /// Первым — потому что порядок источников и есть объявление канона: запись
  /// вида `["userinfo", "query.<имя>"]` говорит «канон в userinfo, параметр
  /// читается как запасное написание». Записей-кандидатов берётся первая по
  /// объявлению, чьё значение тело несёт.
  String _userinfoFromParam() {
    for (final p in section.params.values) {
      if (p.isService || _roundTripOff(p)) continue;
      final path = p.mapsTo;
      if (path == null || p.source.isEmpty) continue;
      if (p.source.first != 'userinfo') continue;
      final v = _str(_read(path));
      if (v == null || v.isEmpty) continue;
      _consumed.add(path);
      return _encodeParam(v);
    }
    return '';
  }

  /// Форма userinfo на выходе. Короткое написание — строка, полное — объект
  /// `{form, padding}`; не объявлено — выводится из РАЗБОРА: userinfo, который
  /// разбор декодирует из base64, обратный ход обязан кодировать.
  String _userinfoForm() {
    final raw = emit[EmitNames.userinfo];
    if (raw is String) return raw;
    if (raw is Map) {
      final f = raw[EmitNames.userinfoForm];
      if (f is String) return f;
    }
    return _userinfoDecodesBase64
        ? EmitNames.userinfoBase64
        : EmitNames.userinfoRaw;
  }

  /// Паддинг base64. Умолчание — БЕЗ паддинга: так пишет сегодняшняя ссылка
  /// LxBox, и по правилу «ссылка не меняется без дельты» умолчанием обязано
  /// быть своё сегодняшнее написание, а не чужое.
  bool _userinfoPadding() {
    final raw = emit[EmitNames.userinfo];
    if (raw is Map) {
      final p = raw[EmitNames.userinfoPadding];
      if (p is bool) return p;
    }
    return false;
  }

  /// Писать ли `@` у пустого userinfo. Умолчание — НЕТ: разделитель без
  /// значения пишет только схема, объявившая это сама.
  bool _userinfoEmptySeparator() {
    final raw = emit[EmitNames.userinfo];
    if (raw is Map) {
      final p = raw[EmitNames.userinfoEmptySeparator];
      if (p is bool) return p;
    }
    return false;
  }

  // ───────────────────────────── записи ─────────────────────────────

  /// Обратный ход ОДНОЙ записи таблицы.
  void _emitParam(MapperParam p) {
    // Служебная запись (`$multiport`) параметром источника не является.
    if (p.isService) return;
    // Объявленный отказ от обратного хода.
    if (_roundTripOff(p)) return;
    // Запись, которая никуда не едет (`maps_to: null`), и обратно не едет —
    // ЕСЛИ она вообще ничего не объясняет. Запись-СЕЛЕКТОР с явным
    // `maps_to: null` (так написан отказ от общей записи блока) остаётся
    // селектором: её обратный ход — ветка `sets`, а не `maps_to`, и вырезать
    // её здесь значило бы потерять параметр, который тело несёт ветками.
    if (p.mapsToPresent &&
        p.mapsTo == null &&
        p.compose == null &&
        p.sets.isEmpty) {
      return;
    }

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
    //
    // НО не тогда, когда путь ветки принадлежит ДРУГОЙ записи напрямую. У
    // такого пути есть свой хозяин — запись с `maps_to` в него, — и на
    // ЧТЕНИИ он же и побеждает (priority). Обратный ход обязан повторить тот
    // же выбор, иначе составное имя ветки («флоу с суффиксом») уезжало бы
    // вместо прямого параметра, и чужой клиент читал бы поле, которого автор
    // не писал.
    if (value == null && p.sets.isNotEmpty && !_setsOwnedByOthers(p)) {
      final back = _valueFromSets(p);
      if (back != null) {
        _add(p, back);
        return;
      }
    }

    if (value == null) return;
    _consumed.add(path);

    // **`value_map⁻¹`.** Написание берётся обращением таблицы — но ТОЛЬКО
    // если значение не является написанием само по себе.
    //
    // Почему проверка обязательна — см. [_isUntranslatedCanon]: у части
    // записей таблица переводит алиас в канон и тождественной пары не
    // содержит, и обращение вслепую подменяло бы канон именем алиаса.
    final inv = invertValueMap(p.valueMap);
    if (inv != null && !_isUntranslatedCanon(p, value)) {
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
  ///
  /// Пара, которую СВОЯ ЖЕ регулярка разбора не примет, не пишется. Проверка
  /// идёт ТОЙ ЖЕ регуляркой (`extract.re`), а не отдельным правилом в коде:
  /// напиши эмиттер такую пару — разбор её пропустил бы (`on_item_invalid`),
  /// и круг потерял бы её молча. Прежде то же самое делала рукописная функция
  /// проверки имени заголовка в коде эмита; теперь правило одно и живёт в
  /// данных.
  String? _joinPairs(MapperParam p) {
    final path = p.mapsTo;
    if (path == null) return null;
    final v = _read(path);
    if (v is! Map || v.isEmpty) return null;
    _consumed.add(path);
    final keys = v.keys.map((e) => '$e').toList();
    if (p.sortKeys) keys.sort();
    final sep = p.list?.sep ?? '\r\n';
    final re = _pairRegex(p);
    final items = <String>[];
    for (final k in keys) {
      final item = '$k: ${v[k]}';
      if (re != null && !re.hasMatch(item)) continue;
      items.add(item);
    }
    return items.isEmpty ? null : items.join(sep);
  }

  /// Регулярка элемента из `extract.re`, в Dart-написании именованных групп.
  static RegExp? _pairRegex(MapperParam p) {
    final re = p.extract?.re;
    if (re == null || re.isEmpty) return null;
    return _reCache.putIfAbsent(
        re, () => RegExp(re.replaceAll('(?P<', '(?<')));
  }

  static final Map<String, RegExp> _reCache = {};

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
  /// Все ли пути, которые ставят ветки [p], принадлежат ДРУГИМ записям
  /// напрямую (`maps_to` в тот же путь).
  ///
  /// Запись, у которой своего значения в теле нет, а все её ветки объясняются
  /// чужими записями, обратного хода не имеет: пусть пишет хозяин пути.
  bool _setsOwnedByOthers(MapperParam p) {
    final targets = <String>{};
    for (final branch in p.sets.values) {
      if (branch is! Map) continue;
      for (final k in branch.keys) {
        final path = '$k';
        if (path.startsWith(DraftNames.serviceParamPrefix)) continue;
        if (_read(path) != null) targets.add(path);
      }
    }
    if (targets.isEmpty) return false;
    final owned = <String>{};
    for (final o in section.params.values) {
      if (identical(o, p) || o.isService || _roundTripOff(o)) continue;
      final m = o.mapsTo;
      if (m != null && targets.contains(m)) owned.add(m);
    }
    return owned.length == targets.length;
  }

  String? _valueFromSets(MapperParam p) {
    String? best;
    var bestScore = -1;
    // Вес ветки УМОЛЧАНИЯ, если тело её подтвердило: `-1` — не подтвердило.
    var defaultScore = -1;

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
        defaultScore = score;
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

    // **Умолчание побеждает равную по весу ветку.** Тело, которое одинаково
    // объясняется и умолчанием, и явным значением, писать явным значением не
    // нужно: разбор восстановит его сам. Так снимается лишний параметр у
    // схем, где свойство безусловно (`scheme_sets` уже поставил тот же путь),
    // и сохраняется он там, где ветка объясняет БОЛЬШЕ умолчания.
    //
    // ИСКЛЮЧЕНИЕ — `emit_when: always`. «Разбор восстановит сам» верно для
    // НАШЕГО разбора; у чужого клиента умолчание бывает другим, и тогда
    // опущенный параметр меняет СМЫСЛ ссылки, а не только её вид: селектор
    // шифрования, чьё умолчание у соседа «шифрования нет», превращает наш
    // узел в открытое соединение. Схема, объявившая `always`, пишет ветку
    // даже равную умолчанию.
    if (defaultScore >= bestScore && !_alwaysEmitted(p)) return null;
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
  ///
  /// Две формы, обе законны (GRAMMAR_SYNC §5.2 п.2 — имя FROZEN, расширен
  /// словарь значений):
  ///
  /// - **строка** — сам шаблон, а `{...}` в нём это ПУТИ ТЕЛА напрямую
  ///   (`"{transport.path}?ed={transport.max_early_data}"`);
  /// - **объект** `{template, from, omit_when_empty}`, где `from` бывает двух
  ///   написаний: КАРТА «имя группы → путь» (шаблон пишет короткие имена
  ///   групп `extract`) и СПИСОК путей — форма реестра, в которой шаблон
  ///   адресует пути напрямую, а `from` лишь перечисляет их.
  ///
  /// Хвост, чьё значение отсутствует, СРЕЗАЕТСЯ вместе со своим
  /// разделителем: `{path}?ed={ed}` без `ed` обязан дать просто путь, иначе
  /// в ссылку уехал бы `?ed=` с пустотой, и разбор прочёл бы его нулём.
  String? _compose(MapperParam p) {
    final raw = p.raw[EmitNames.compose] ?? p.compose;
    if (raw is String) {
      return _composeTemplate(p, raw, (g) => g, _impliedOffGroups(p));
    }
    if (raw is! Map) return null;
    final spec = raw.cast<String, dynamic>();
    final template = spec[EmitNames.composeTemplate] as String?;
    if (template == null) return null;
    // `from` двух написаний. КАРТА «имя группы → путь» нужна шаблону, который
    // пишет короткие имена групп `extract`. СПИСОК путей (форма реестра,
    // контракт 1.1.36) ничего не переводит: такой шаблон адресует пути
    // напрямую, и `from` в нём лишь объявляет их перечнем. Подстановка тогда
    // тождественна — как у строковой формы.
    final fromRaw = spec[EmitNames.composeFrom];
    final from = fromRaw is Map ? fromRaw.cast<String, dynamic>() : null;
    // `omit_when_empty` реестра здесь НЕ нужен отдельным списком: он говорит
    // «срезать хвост, КОГДА значение пусто», а пустую группу шаблон срезает и
    // так (см. _composeTemplate). Безусловный запрет — только `implies`,
    // которого тело не подтверждает.
    return _composeTemplate(
      p,
      template,
      from == null ? (g) => g : (g) => '${from[g] ?? g}',
      _impliedOffGroups(p),
    );
  }

  /// Обращение `extract` С ОДНОЙ содержательной группой, у записи без
  /// `maps_to` и без `compose`.
  ///
  /// Такая запись — это `maps_to`, записанный регуляркой: группа одна, путь у
  /// неё один, и обратный ход у неё ровно тот же — взять значение пути. Хвост
  /// регулярки при этом ОТБРАСЫВАЕТСЯ намеренно (у xhttp `?…` срезается
  /// целиком, SPEC 002 §4.1): восстанавливать его не из чего, тело его не
  /// несёт. Запись с НЕСКОЛЬКИМИ группами сюда не попадает — там хвост
  /// значим, и собрать его обязан объявленный `compose`.
  String? _extractSingle(MapperParam p) {
    if (p.compose != null || p.raw[EmitNames.compose] != null) return null;
    final into = p.extract?.into;
    if (into == null || into.length != 1) return null;
    final spec = into.values.first;
    final path = spec is Map ? spec['path'] : spec;
    if (path is! String) return null;
    final v = _read(path);
    if (v == null) return null;
    _consumed.add(path);
    return _serializeValue(p, v);
  }

  /// Засчитать пути, которые ПОДРАЗУМЕВАЕТ написанная группа `compose`.
  ///
  /// Группа адресуется и именем, и путём: строковый шаблон пишет путь,
  /// объектный — имя группы, и какое из двух пришло, здесь неизвестно.
  void _consumeImplied(MapperParam p, String name, String path) {
    final into = p.extract?.into;
    if (into == null) return;
    for (final e in into.entries) {
      final spec = e.value;
      if (spec is! Map) continue;
      if (e.key != name && spec['path'] != path) continue;
      final implies = spec['implies'];
      if (implies is! Map) continue;
      for (final i in implies.keys) {
        _consumed.add('$i');
      }
    }
  }

  /// Группы `compose`, которые писать НЕЛЬЗЯ, потому что тело не подтверждает
  /// их `implies`.
  ///
  /// Живой случай: у `extract` группа «ранние данные» подразумевает имя
  /// заголовка (`implies` с `implicit: true`), и форма-хвост этим и
  /// отличается от плоского параметра. Тело БЕЗ этого имени пришло плоским
  /// параметром, и напиши эмиттер хвост — разбор восстановил бы заголовок,
  /// которого в исходном теле не было. Значение уедет плоской записью: она в
  /// таблице объявлена рядом и читает тот же путь.
  ///
  /// Проверяется по ДАННЫМ (`extract.into.<группа>.implies`), а не по имени
  /// группы: имён схем и полей движок не знает.
  Set<String> _impliedOffGroups(MapperParam p) {
    final into = p.extract?.into;
    if (into == null) return const {};
    final off = <String>{};
    for (final e in into.entries) {
      final spec = e.value;
      if (spec is! Map) continue;
      final implies = spec['implies'];
      if (implies is! Map) continue;
      for (final i in implies.entries) {
        final want = i.value;
        final expected = want is Map ? want['value'] : want;
        if (_matches(_read('${i.key}'), expected)) continue;
        // Строковый шаблон адресует группы ПУТЯМИ тела, объектный — именами
        // групп: запрещаем оба написания, лишнее просто не встретится.
        off.add(e.key);
        final path = spec['path'];
        if (path is String) off.add(path);
        break;
      }
    }
    return off;
  }

  /// Подстановка в шаблон: `{имя}` → значение пути, который даёт [pathOf].
  ///
  /// Группа без значения срезается вместе с предшествующим ей литералом
  /// (`?ed=`): границей литерала служит предыдущая группа либо начало
  /// шаблона. Перечислять такие группы в `omit_when_empty` не обязательно —
  /// список нужен лишь там, где срезать надо и НЕПУСТУЮ группу.
  String? _composeTemplate(
    MapperParam p,
    String template,
    String Function(String) pathOf,
    Set<String> omitEmpty,
  ) {
    final re = RegExp(r'\{([^{}]+)\}');
    final matches = re.allMatches(template).toList();
    if (matches.isEmpty) return null;

    final out = StringBuffer();
    var cursor = 0;
    var any = false;
    for (final m in matches) {
      final name = m.group(1)!;
      final path = pathOf(name);
      final v = _read(path);
      final text = v == null ? '' : '$v';
      final literal = template.substring(cursor, m.start);
      cursor = m.end;
      if (text.isEmpty || omitEmpty.contains(name)) {
        // Пусто — литерал перед группой уезжает вместе с ней.
        continue;
      }
      _consumed.add(path);
      // Группа, которая ПОДРАЗУМЕВАЕТ пути, забирает и их: значение приехало
      // самой формой, и отдельной записью его писать нельзя — иначе в ссылке
      // окажутся и хвост, и плоский параметр, а разбор прочтёт их дважды.
      _consumeImplied(p, name, path);
      out
        ..write(literal)
        ..write(text);
      any = true;
    }
    if (!any) return null;
    out.write(template.substring(cursor));
    final s = out.toString();
    return s.isEmpty ? null : s;
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

  /// Первое написание записи, которое её же `value_map` ведёт в ИСТИНУ.
  ///
  /// Порядок ключей таблицы нормативен (§0.6: канон ПЕРВЫЙ), и обратный ход
  /// обязан взять именно первое: тогда своя ссылка читается своим же разбором
  /// и не меняет написания у живых узлов. `null` — таблицы нет либо истины в
  /// ней не нашлось.
  String? _firstTruthySpelling(MapperParam p) {
    for (final e in p.valueMap.entries) {
      final v = e.value;
      if (v == true || v == 'true') return e.key;
    }
    return null;
  }

  /// Значение параметра текстом — по объявленному `emit_as`, а при его
  /// отсутствии по типу значения.
  String? _serializeValue(MapperParam p, dynamic value) {
    final mode = _emitAs(p);
    switch (mode) {
      case EmitNames.emitAsBool01:
        if (value == false) return null;
        // Написание истины — первым ключом `value_map` САМОЙ записи, если
        // таблица есть: у записи с `{"on": "true", "true": "true", "1":
        // "true", …}` каноном объявлено `on`, и подмена на `1` меняет
        // СОХРАНЁННЫЙ rawSource ручного узла и то, что уезжает по Copy link.
        // Таблицы нет — остаётся общее `1`.
        return _firstTruthySpelling(p) ?? '1';
      case EmitNames.emitAsJoin:
        final sep = p.list?.sep ?? ',';
        if (value is List) return value.isEmpty ? null : value.join(sep);
        return '$value';
      case EmitNames.emitAsJson:
        return jsonEncode(value);
    }

    // `emit_as: raw`, объявленный ЯВНО, пишет значение своим написанием:
    // булев уезжает словом `true`, а не `1`. Два написания булева — две
    // разные ссылки у живых панелей, и выбор между ними принадлежит записи, а
    // не типу значения. Проверка идёт ЗДЕСЬ, а не веткой switch: `raw` это
    // ещё и УМОЛЧАНИЕ вывода (`_emitAs`), и веткой она перехватывала бы
    // каждую необъявленную запись разом.
    if (value is bool &&
        _paramEmitAttr(p, EmitNames.emitAs) == EmitNames.emitAsRaw) {
      return value ? 'true' : null;
    }
    // Написание истины берётся у САМОЙ ЗАПИСИ — первым ключом её `value_map`,
    // который ведёт в истину. У записи с таблицей `{"on": "true", "true":
    // "true", "1": "true", …}` каноном объявлено `on`, и писать вместо него
    // `1` значит менять СОХРАНЁННЫЙ rawSource ручного узла и то, что уезжает
    // по Copy link в чужие клиенты (страж вида ссылки ловит это как класс).
    // Таблицы нет — остаётся общее `1`.
    if (value is bool) {
      if (!value) return null;
      return _firstTruthySpelling(p) ?? '1';
    }
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

  /// **Имя параметра в ссылке.** Умолчание — ПЕРВОЕ в `aliases`, то есть имя
  /// записи (§0.6); схема перекрывает его картой [EmitNames.names].
  ///
  /// Перекрытие берётся только из написаний САМОЙ записи: то, чего запись не
  /// читает, писать нельзя — иначе своя же ссылка обратно не разберётся.
  /// Написание вне набора линтер секций называет ошибкой, а эмит молча
  /// откатывается к канону.
  String _nameOf(MapperParam p) {
    final want = _declaredName(p);
    if (want != null) return want;
    return p.spellings.first;
  }

  /// Объявленное написание записи [p], если оно есть и ЗАКОННО.
  ///
  /// Два места объявления, конкретное сильнее общего: `forms[].emit.names`
  /// текущей формы бьёт `emit.names` секции. Написание вне набора, который
  /// запись ЧИТАЕТ, не берётся: линтер секций зовёт это ошибкой, а эмит молча
  /// откатывается к канону — своя ссылка обязана разобраться обратно.
  String? _declaredName(MapperParam p) {
    for (final src in [_formEmit()?[EmitNames.names], emit[EmitNames.names]]) {
      final want = (src as Map?)?[p.name];
      if (want is String && readableNames(p).contains(want)) return want;
    }
    return null;
  }

  /// Блок `emit` ТЕКУЩЕЙ формы из `forms[]`, если он объявлен.
  Map<String, dynamic>? _formEmit() {
    final id = _form();
    for (final f in section.forms) {
      if (f.id == id) return f.emit;
    }
    return null;
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
  /// Объявлено ли у записи «писать всегда» — своим атрибутом либо
  /// `emit.emit_when` секции. Имя в карте секции — ВЫХОДНОЕ (`_nameOf`): она
  /// говорит о том, что видно в ссылке.
  bool _alwaysEmitted(MapperParam p) {
    if (_paramEmitAttr(p, EmitNames.emitWhen) == EmitNames.emitWhenAlways) {
      return true;
    }
    final byName = (emit[EmitNames.emitWhen] as Map?)?[_nameOf(p)];
    return byName == EmitNames.emitWhenAlways;
  }

  bool _omitted(MapperParam p, String name, String value) {
    // Правило У САМОЙ ЗАПИСИ сильнее правила секции: секция говорит за все
    // записи разом, запись — за себя, и конкретное побеждает.
    if (_alwaysEmitted(p)) return false;
    final ownOmit = _paramEmitAttr(p, EmitNames.omitDefault);
    if (ownOmit == false) return false;
    if (ownOmit == true) return _isDefaultValue(p, value);

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

  /// Форма-КОНТЕЙНЕР: base64(JSON) вместо query-ссылки.
  ///
  /// Карта «ключ JSON → путь тела» берётся из `emit.json_map`, если секция её
  /// объявила, а иначе ВЫВОДИТСЯ ИЗ ТАБЛИЦЫ: запись, читающая в этой форме
  /// `json.<ключ>`, этим и называет свой ключ контейнера. Вывод предпочтён
  /// объявлению по той же причине, по какой вся волна затеяна: объявленная
  /// отдельно карта — второй источник правды, и разъезжается она на первом же
  /// новом поле.
  ///
  /// `json_always` остаётся объявленным: «клиент ждёт ключ даже пустым» из
  /// таблицы разбора не выводится никак — читать пустое и писать пустое это
  /// разные утверждения.
  String _emitJson(String scheme) {
    final map = <String, dynamic>{};
    final always = _jsonAlways();

    for (final e in _jsonMap().entries) {
      final v = _read(e.value);
      if (v == null) {
        if (always.containsKey(e.key)) map[e.key] = always[e.key]!;
        continue;
      }
      _consumed.add(e.value);
      // Текст значения — ТЕМ ЖЕ правилом, что и в query (`_serializeValue`):
      // написание значения принадлежит ЗАПИСИ (`emit_as`, `list.sep`), а не
      // месту вывода. Через `'$v'` список уезжал в контейнер дословным
      // `[cdn.example.com]`, и круг читал имя хоста вместе со скобками.
      final p = _jsonOwners[e.key];
      final text = p == null ? '$v' : _serializeValue(p, v);
      if (text == null) continue;
      map[e.key] = text;
    }

    // Записи, СОБИРАЮЩИЕ значение из нескольких путей (`compose`, обращение
    // `extract`). Своего `maps_to` у них нет, и в карту ключей они не попали,
    // а в контейнер уехать обязаны: у ws путь лежит ровно в такой записи
    // (`{transport.path}?ed={…}`). Пока ключ `path` держала безусловная
    // запись http, значение доезжало ЧУЖОЙ записью — и вместе с ним молча
    // терялся хвост `?ed=`. Порядок тот же, что у query: первая запись,
    // подтверждённая телом, занимает ключ.
    for (final p in section.params.values) {
      if (p.isService || p.mapsTo != null || _roundTripOff(p)) continue;
      if (!_whenAgreesWithBody(p.when)) continue;
      final key = _jsonKeyOf(p);
      if (key == null || map.containsKey(key)) continue;
      final composed = _compose(p) ?? _extractSingle(p);
      if (composed == null) continue;
      if (_omitted(p, key, composed)) continue;
      map[key] = composed;
    }

    // Записи-СЕЛЕКТОРЫ контейнера: своего `maps_to` у них нет, значение
    // восстанавливается веткой `sets`, которую подтверждает тело. В query они
    // проходят общим обходом; здесь обход свой, и пропустить их значило бы
    // потерять, например, признак шифрования — ключ, который в контейнере
    // лежит наравне с прочими.
    for (final p in section.params.values) {
      if (p.isService || p.mapsTo != null || p.sets.isEmpty) continue;
      if (_roundTripOff(p)) continue;
      final key = _jsonKeyOf(p);
      if (key == null || map.containsKey(key)) continue;
      final back = _valueFromSets(p);
      if (back != null && !_omitted(p, key, back)) map[key] = back;
    }
    // **МЕТКА** у формы-контейнера живёт не во фрагменте, а СВОИМ КЛЮЧОМ:
    // куда именно, объявляет `label.source` той же формы (`json.ps`).
    // Фрагмента у такой ссылки нет вовсе, и не положи мы метку сюда — имя
    // узла терялось бы на круге, а метка ВХОДИТ В IDENTITY.
    final labelKey = _labelJsonKey();
    if (labelKey != null && label.isNotEmpty) map[labelKey] = label;

    for (final e in always.entries) {
      map.putIfAbsent(e.key, () => e.value);
    }

    final bytes = utf8.encode(jsonEncode(_orderedJson(map)));
    final encoded = base64.encode(bytes);
    return '$scheme://${_userinfoPadding() ? encoded : encoded.replaceAll('=', '')}';
  }

  /// `json_always` в обоих написаниях: перечень (заполнитель — пустая строка)
  /// либо карта «ключ → заполнитель».
  Map<String, String> _jsonAlways() {
    final raw = emit[EmitNames.jsonAlways];
    if (raw is Map) {
      return {for (final e in raw.entries) '${e.key}': '${e.value}'};
    }
    if (raw is List) return {for (final k in raw) '$k': ''};
    return const {};
  }

  /// Порядок ключей контейнера — ТЕМ ЖЕ `param_order`, что и порядок query:
  /// правило одно, форм две. Перечень задаёт порядок явно, `alphabetical`
  /// сортирует, необъявленное — оставляет порядок сборки.
  ///
  /// Порядок здесь НЕ косметика: часть клиентов читает v2rayN-контейнер
  /// позиционно, и ключ, приехавший не на своём месте, они теряют.
  /// Не перечисленные ключи уезжают в хвост, сохраняя порядок сборки, —
  /// новое поле не переставляет старые.
  Map<String, dynamic> _orderedJson(Map<String, dynamic> map) {
    final order = emit[EmitNames.paramOrder];
    final keys = map.keys.toList();
    if (order == EmitNames.paramOrderAlphabetical) {
      keys.sort();
    } else if (order is List) {
      final idx = {for (var i = 0; i < order.length; i++) '${order[i]}': i};
      final at = {for (var i = 0; i < keys.length; i++) keys[i]: i};
      keys.sort((a, b) {
        final ia = idx[a] ?? (1 << 20) + at[a]!;
        final ib = idx[b] ?? (1 << 20) + at[b]!;
        return ia.compareTo(ib);
      });
    } else {
      return map;
    }
    return {for (final k in keys) k: map[k]};
  }

  /// Ключ контейнера, в который уезжает МЕТКА, по `label.source` текущей
  /// формы. `null` — метка этой формой в контейнер не кладётся.
  String? _labelJsonKey() {
    final form = _form();
    final sources = section.label.sourceByForm[form] ?? section.label.source;
    for (final s in sources) {
      if (s.startsWith('json.')) return s.substring('json.'.length);
    }
    return null;
  }

  /// Ключ контейнера, который читает запись в ТЕКУЩЕЙ форме.
  ///
  /// Канон — ПЕРВЫЙ источник формы, тем же правилом, что и канон имени
  /// параметра. `null` — в этой форме запись контейнер не читает.
  ///
  /// Два написания источника, и оба законны: явное `json.<ключ>` и обычное
  /// `query.<имя>`. Второе работает потому, что КОНТЕЙНЕР РАСКЛАДЫВАЕТСЯ
  /// ПЛОСКИМ СЛОЕМ ИМЁН — ту же запись блока, что читает `?path=` у ссылки,
  /// разбор применяет к ключу `path` контейнера. Обратный ход обязан
  /// повторить это ровно так же, иначе поля общих блоков (транспорт, TLS) в
  /// контейнер не попадали бы, хотя ИЗ него читаются.
  ///
  /// Имя ключа — КАНОН записи (первое в `aliases`), а не написание источника:
  /// `source` у блочной записи один на все схемы, а канон объявлен ею самой.
  ///
  /// **Объявленное написание сильнее первого источника.** У записи с ФОЛБЭКОМ
  /// источников первый из них — канон РАЗБОРА, и контейнеру он может быть
  /// неизвестен: цепочка `serviceName ∥ service_name ∥ path` читается вся, а
  /// v2rayN пишет только `path`. Выбор по первому источнику уводил поле в
  /// ключ, которого чужой клиент не читает, и круг его терял. Написание,
  /// названное формой (`forms[].emit.names`) или секцией (`emit.names`),
  /// берётся ВПЕРЁД источников — оно и есть выбор написания по форме.
  String? _jsonKeyOf(MapperParam p) {
    final sources = p.sourceByForm[_form()] ?? p.source;
    final declared = _declaredName(p);
    // Объявленное написание действует, только если запись вообще читается в
    // этой форме плоским слоем имён: у записи, чей источник тут `json.<путь>`,
    // ключ задан путём, и подменять его именем нельзя.
    if (declared != null &&
        sources.any((s) => s.startsWith('query.')) &&
        !sources.any((s) => s.startsWith('json.'))) {
      return declared;
    }
    for (final s in sources) {
      if (s.startsWith('json.')) return s.substring('json.'.length);
      if (s.startsWith('query.')) {
        final name = s.substring('query.'.length);
        return name == p.name ? _nameOf(p) : name;
      }
    }
    return null;
  }

  /// Карта «ключ контейнера → путь тела»: объявленная либо выведенная из
  /// источников записей ТЕКУЩЕЙ формы.
  Map<String, String> _jsonMap() {
    final declared = emit[EmitNames.jsonMap];
    if (declared is Map) {
      return {
        for (final e in declared.entries) '${e.key}': '${e.value}',
      };
    }
    final out = <String, String>{};
    _jsonOwners.clear();
    for (final p in section.params.values) {
      if (p.isService || _roundTripOff(p)) continue;
      // Запись, чьё условие ТЕЛО ОПРОВЕРГАЕТ, ключ не занимает. Ключ
      // контейнера бывает общим у нескольких записей, разведённых `when` по
      // роду транспорта: `path` читают и запись ws (`transport.path`), и
      // запись grpc (`transport.service_name`). Тело подтверждает ровно одну
      // из них, и без этой проверки ключ доставался первой по обходу — у
      // grpc-узла в контейнер уезжал пустой `transport.path`, а имя сервиса
      // терялось. Разбор такие записи различает (`_whenHolds`), обратный ход
      // обязан различать так же.
      if (!_whenAgreesWithBody(p.when)) continue;
      final path = p.mapsTo;
      if (path == null) continue;
      final key = _jsonKeyOf(p);
      if (key == null) continue;
      if (out.containsKey(key)) continue;
      out[key] = path;
      _jsonOwners[key] = p;
    }
    return out;
  }

  /// Запись, ЗАНЯВШАЯ ключ контейнера, — чтобы значение писалось её правилом
  /// написания. Заполняется [_jsonMap] и живёт ровно столько же.
  final Map<String, MapperParam> _jsonOwners = {};

  /// Не противоречит ли [when] телу.
  ///
  /// Судятся ТОЛЬКО условия по путям тела: на обратном ходе тело и есть вход,
  /// а условий по источнику (`query.…`, `$form`) ещё не из чего проверять —
  /// они молча считаются выполненными, чтобы не срезать записи по незнанию.
  /// Проза с `$`-префиксом предикатом не является (соглашение §0.7).
  bool _whenAgreesWithBody(Map<String, dynamic> when) {
    if (when.isEmpty) return true;
    for (final e in when.entries) {
      final key = e.key;
      if (key.startsWith(r'$') ||
          key == 'any_set' ||
          key.startsWith('query.') ||
          key.startsWith('json.') ||
          key.startsWith('ini.')) {
        continue;
      }
      // Путь, которого тело не несёт вовсе, условие не опровергает: значение
      // могло не доехать по другой причине, и терять из-за этого ключ хуже.
      final actual = _read(key);
      if (actual == null) continue;
      if (!_matches(actual, e.value)) return false;
    }
    return true;
  }

  // ───────────────────────────── потери ─────────────────────────────

  /// `emit.refuse_when` — форма ссылки тело не выражает. Пустая ссылка:
  /// Copy link на `uri.isEmpty` молча не копирует, как у схемы без
  /// переносимой формы.
  bool _refuse() {
    final raw = emit[EmitNames.refuseWhen];
    if (raw is! List) return false;
    for (final item in raw) {
      if (item is! Map) continue;
      if (_refuseRule(item.cast<String, dynamic>())) return true;
    }
    return false;
  }

  bool _refuseRule(Map<String, dynamic> rule) {
    final path = rule['path'];
    if (path is! String) return false;
    final actual = _read(path);
    final lenGt = rule['len_gt'];
    if (lenGt is num) {
      final n = actual is List ? actual.length : 0;
      return n > lenGt;
    }
    return false;
  }

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

  /// Все листовые пути тела, в ТОЙ ЖЕ записи, какой их адресуют записи
  /// таблицы: первый элемент массива объектов даёт сегмент `имя[]`.
  ///
  /// Нужно для учёта потерь: путь `hops[].key` объявлен записью именно так,
  /// и не совпади написание — уехавшее в ссылку поле числилось бы
  /// потерянным. Остальные элементы несут индекс (`имя[1]`): иначе
  /// consumed первого покрывал бы весь массив одним путём.
  static Iterable<String> _paths(Map<String, dynamic> m, String prefix) sync* {
    for (final e in m.entries) {
      final p = prefix.isEmpty ? e.key : '$prefix.${e.key}';
      final v = e.value;
      if (v is Map<String, dynamic> && v.isNotEmpty) {
        yield* _paths(v, p);
      } else if (v is List && v.isNotEmpty && v.first is Map<String, dynamic>) {
        // Массив ОБЪЕКТОВ. Первый — `имя[]` (как `_read`); остальные —
        // `имя[i]`, иначе один consumed-путь засчитывал бы все элементы.
        // Массив скаляров (alpn, address) сам по себе лист.
        for (var i = 0; i < v.length; i++) {
          final item = v[i];
          if (item is! Map<String, dynamic>) continue;
          yield* _paths(item, i == 0 ? '$p[]' : '$p[$i]');
        }
      } else {
        yield p;
      }
    }
  }

  // ───────────────────────────── мелочь ─────────────────────────────

  /// Чтение по точечному пути. Сегмент `имя[]` адресует МАССИВ, и читается из
  /// него ПЕРВЫЙ элемент.
  ///
  /// Первый, а не все: ссылка несёт один набор параметров, и запись
  /// `peers[].public_key` на входе наполняет ровно один элемент — разбор
  /// ссылки второго и не создаёт. Тело с несколькими элементами приходит
  /// только из JSON-входов, и лишние объявлены потерей (`_collectLost`
  /// увидит их пути), а не молча склеены в один параметр.
  dynamic _read(String path) {
    dynamic cur = body;
    for (final seg in path.split('.')) {
      if (seg.endsWith('[]')) {
        if (cur is! Map) return null;
        final list = cur[seg.substring(0, seg.length - 2)];
        if (list is! List || list.isEmpty) return null;
        cur = list.first;
        continue;
      }
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

/// Значение тела — КАНОН, которого таблица не переводит, и обращать его
/// нельзя.
///
/// Признак узкий и проверяется по самой таблице: значение встречается в ней
/// СПРАВА (то есть является каноном, в который переводятся алиасы) и при этом
/// НЕ СТОИТ СЛЕВА ни у одной пары (то есть написания с таким именем таблица не
/// знает).
///
/// Зачем: у части записей таблица переводит алиас в канон и тождественной
/// пары не содержит — канон стоит справа, слева его нет. Обрати её вслепую, и
/// канон уехал бы в ссылку под именем алиаса; а когда алиас вдобавок нагружен
/// своим `sets` (у живой записи так и есть), узел на обратном чтении получил
/// бы ещё и поле, которого у него не было.
///
/// Там, где канон и написание СОВПАДАЮТ (`true` среди `on|true|1`), признак
/// не срабатывает — значение стоит и слева тоже, — и написание выбирается
/// обращением, то есть первым объявленным. Это ровно то, что нужно: канон
/// написания объявлен ПОРЯДКОМ, а не совпадением с именем значения.
bool _isUntranslatedCanon(MapperParam p, dynamic value) {
  final v = '$value'.trim().toLowerCase();
  var isTarget = false;
  for (final e in p.valueMap.entries) {
    if (e.key.trim().toLowerCase() == v) return false;
    if (e.value != null && '${e.value}'.trim().toLowerCase() == v) {
      isTarget = true;
    }
  }
  return isTarget;
}

/// **`value_map⁻¹`.**
///
/// Таблица перевода написаний ссылки в значения тела; обратный ход берёт из
/// неё написание по значению.
///
/// **Неинъективность — норма, а не ошибка.** У живой записи в одно значение
/// тела ведут несколько написаний (`on`, `true`, `1` — всё это «включено»), и
/// обратный ход обязан выбрать одно. Выбирается ПЕРВОЕ ОБЪЯВЛЕННОЕ — тем же
/// правилом, что и каноническое имя параметра (первое в `aliases`, §0.6):
/// канон объявлен порядком, и менять его можно только перестановкой в секции
/// со строкой в `DELTAS.md`, а не молча в коде.
///
/// Ветка со значением `null` (`{random: null}`) из обращения ВЫПАДАЕТ: она
/// означает «поле не ставится», а не «значение такое».
///
/// `null` в ответе — обратного хода нет вовсе: таблица пуста либо её ветки не
/// переводят значение, а ставят пути (это `sets`, не `value_map`).
Map<String, String>? invertValueMap(Map<String, dynamic> vm) {
  if (vm.isEmpty) return null;
  final out = <String, String>{};
  for (final e in vm.entries) {
    if (e.value == null) continue;
    // Ветка-объект — это `sets`, а не перевод значения.
    if (e.value is Map || e.value is List) return null;
    // Пустой ключ — «параметра не было»: писать его обратно нельзя.
    if (e.key.isEmpty) continue;
    final key = '${e.value}'.trim().toLowerCase();
    // Первое объявленное написание побеждает; последующие — алиасы входа.
    out.putIfAbsent(key, () => e.key);
  }
  return out.isEmpty ? null : out;
}
