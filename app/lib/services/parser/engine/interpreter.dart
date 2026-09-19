/// §480 W1 — ИНТЕРПРЕТАТОР СЕКЦИИ: единственный движок на все виды источника.
///
/// Устроен как санитайзер (`body_sanitizer.dart`): один проход по ОБЪЯВЛЕННЫМ
/// записям, значение достаётся только через `source`, ни одного имени схемы.
/// Разница в направлении — санитайзер судит уже собранное тело, движок его
/// собирает.
///
/// Порядок исполнения (норма SPEC 133 §5, `selector` + `when`):
///
/// 1. `scheme_sets` — написание схемы даёт присваивания (схема несёт тело);
/// 2. `defaults` секции — адрес/порт по умолчанию;
/// 3. userinfo по `uri.userinfo`;
/// 4. **первый проход**: записи с `selector: true`, в порядке объявления;
/// 5. **второй проход**: остальные записи — `when` у каждой проверяется по
///    УЖЕ ПОСТРОЕННОМУ телу и/или по источникам;
/// 6. `default_from` / `default_when` / `materialize_default` — заполнение
///    пустоты объявленными источниками;
/// 7. метка и неизвестные параметры.
///
/// Тело остаётся СЫРЫМ: значения кладутся как пришли, годность их судит
/// санитайзер по реестру. Единственное, что решает движок, — СТРУКТУРА
/// («есть ли блок `tls`», «какой транспорт»), потому что санитайзеру
/// отсутствие ключа неотличимо от «не задано».
library;

import 'dart:convert' show Base64Codec;

import '../../../models/node_warning.dart';
import 'decoders.dart';
import 'lexer.dart';
import 'section.dart';
import 'source_space.dart';

/// Итог исполнения секции.
final class EngineResult {
  const EngineResult({
    required this.body,
    required this.label,
    this.warnings = const [],
    this.extensionFields = const {},
    this.wsEarlyDataHeaderImplicit = false,
    this.tagAddress,
  });

  /// Сырая карта тела в ключах sing-box.
  final Map<String, dynamic> body;

  /// Метка из объявленных источников, уже нормализованная.
  final String label;

  final List<NodeWarning> warnings;
  final Map<String, dynamic> extensionFields;
  final bool wsEarlyDataHeaderImplicit;
  final (String, int)? tagAddress;
}

/// Исполнить секцию на тексте источника.
///
/// `null` — записи нет: не сработала ни одна форма, либо обязательная запись
/// (`required`) не нашла значения. Тем же `null` отвечали рукописные мапперы.
EngineResult? runSection(MapperSection section, String text) {
  final space = _selectForm(section, text);
  if (space == null) return null;
  return _Run(section, space).execute();
}

/// Выбрать форму (P1) и построить пространство источников.
///
/// Формы пробуются ПО ПОРЯДКУ, первая, чей `detect` сработал, выигрывает;
/// `detect.default` — ветка «всё остальное». W1 исполняет только `space: url`;
/// `json`/`ini` приедут волной W5 вместе со своими видами источника, и
/// пространство для них уже заведено ([SourceSpace.json], [SourceSpace.ini]).
SourceSpace? _selectForm(MapperSection section, String text) {
  final forms = section.forms.isEmpty
      ? const [MapperForm(id: 'url', space: 'url')]
      : section.forms;
  for (final form in forms) {
    if (!_formMatches(form, text)) continue;
    switch (form.space) {
      case 'url':
        final space = lexUri(text, formId: form.id);
        if (space != null) return space;
      default:
        // Пространства json/ini заводятся волной W5 вместе с их видами
        // источника. Молча выдавать пустое тело нельзя — это был бы узел
        // из ничего, поэтому форма просто не отвечает.
        continue;
    }
  }
  return null;
}

bool _formMatches(MapperForm form, String text) {
  final d = form.detect;
  if (d == null || d['default'] == true) return true;
  final schemeIn = (d['scheme_in'] as List?)?.cast<String>();
  if (schemeIn != null) {
    final colon = text.indexOf(':');
    final scheme = colon > 0 ? text.substring(0, colon).toLowerCase() : '';
    if (!schemeIn.any((s) => s.toLowerCase() == scheme)) return false;
  }
  final re = d['regex'] as String?;
  if (re != null && !RegExp(re).hasMatch(text)) return false;
  final txt = (d['text'] as Map?)?.cast<String, dynamic>();
  if (txt != null) {
    final prefix = txt['prefix_fold'] as String?;
    if (prefix != null &&
        !text.toLowerCase().startsWith(prefix.toLowerCase())) {
      return false;
    }
    final contains = txt['contains'] as String?;
    if (contains != null && !text.contains(contains)) return false;
  }
  return true;
}

/// Приоритет значения из `defaults` секции: слабее любой записи таблицы
/// (`priority` у записей — небольшие числа вокруг нуля).
const int _kDefaultPriority = 1 << 20;

/// Исполнение одной записи: состояние живёт ровно на время разбора.
final class _Run {
  _Run(this.section, this.space);

  final MapperSection section;
  SourceSpace space;

  final Map<String, dynamic> body = {};
  final Map<String, dynamic> extensionFields = {};
  final List<NodeWarning> warnings = [];

  /// Какая запись заняла путь и с каким `priority` — для G3 (`priority` +
  /// `merge`): без этого две записи в один путь дрались бы порядком обхода.
  final Map<String, int> _writtenBy = {};

  /// Имена источников, которые записи ПРОЧИТАЛИ: всё остальное в query —
  /// неизвестный параметр (`unknown_key`).
  final Set<String> _consumed = {};

  bool _wsEarlyDataHeaderImplicit = false;

  EngineResult? execute() {
    body['type'] = section.singboxType;

    // 1. `scheme_sets` — написание схемы НЕСЁТ ТЕЛО: у части схем цифра или
    // суффикс в написании это дискриминатор версии либо транспорта, а не
    // алиас, и присваивания берутся прямо из него.
    final schemeSet = _lookupFold(section.schemeSets, space.scheme);
    if (schemeSet is Map) _applySets(schemeSet.cast<String, dynamic>(), null);

    // 2. `defaults` секции — то, чего ссылка может не сказать (порт). Пишутся
    // ДО записей, но слабее любой из них: дефолт обязан уступить значению,
    // которое источник всё-таки назвал.
    for (final e in section.defaults.entries) {
      _put(e.key, e.value);
      _writtenBy[e.key] = _kDefaultPriority;
    }

    // Адрес НЕ подставляется движком: секция объявляет его записями
    // (`server` ← `host`, `server_port` ← `port`) наравне с прочими. Иначе у
    // схем, где адрес лежит не в authority (endpoint-схемы, json-формы),
    // пришлось бы заводить исключение в коде.

    // 3. userinfo (P2).
    if (!_applyUserinfo()) return null;

    // 4–5. Два прохода: сперва селекторы, потом зависимые.
    final ordered = _orderedParams();
    for (final p in ordered.where((p) => p.selector)) {
      _applyParam(p);
    }
    for (final p in ordered.where((p) => !p.selector)) {
      _applyParam(p);
    }

    // 6. Заполнение пустоты объявленными источниками.
    for (final p in ordered) {
      _applyDefaults(p);
    }

    // Обязательные записи: их отсутствие — это «узла нет».
    for (final p in ordered) {
      if (!p.required) continue;
      final path = p.mapsTo;
      if (path == null) continue;
      final v = _read(path);
      if (v == null || (v is String && v.isEmpty)) return null;
    }

    // 7. Неизвестные параметры источника.
    _reportUnknown();

    return EngineResult(
      body: body,
      label: _label(),
      warnings: warnings,
      extensionFields: extensionFields,
      wsEarlyDataHeaderImplicit: _wsEarlyDataHeaderImplicit,
    );
  }

  /// Записи в порядке исполнения: `priority` (меньше = раньше), при равенстве
  /// — порядок объявления в секции (G3, FROZEN).
  List<MapperParam> _orderedParams() {
    final list = section.params.values.toList();
    final index = {for (var i = 0; i < list.length; i++) list[i].name: i};
    list.sort((a, b) {
      final pa = a.priority ?? 0;
      final pb = b.priority ?? 0;
      if (pa != pb) return pa.compareTo(pb);
      return index[a.name]!.compareTo(index[b.name]!);
    });
    return list;
  }

  // ───────────────────────────── userinfo ─────────────────────────────

  bool _applyUserinfo() {
    final u = section.userinfo;
    if (u == null) return true;
    // Декодер ФОРМЫ (`decode: ["url"]`) снимает percent один раз со всего
    // пространства — это и есть норма «percent один раз и до всего
    // остального». В userinfo `+` при этом ЛИТЕРАЛЕН: form-encoding там не
    // действует (`pa+ss123` — пароль с плюсом, а не с пробелом).
    var raw = percentDecodeOnce(space.userinfo, mode: DecodeMode.path);

    // `decode` секции — ПОВЕРХ него, и порядок задан ею: у ss percent идёт
    // ДО base64, и выразить это можно только списком.
    for (final step in u.decode) {
      switch (step) {
        case 'percent':
          // Userinfo — не query: `+` здесь литерален.
          raw = percentDecodeOnce(raw, mode: DecodeMode.path);
        case 'base64':
        case 'base64?':
          final decoded = _tryBase64(raw);
          if (decoded != null) {
            raw = decoded;
          } else if (step == 'base64') {
            return false;
          }
        case 'base64_if_no_colon':
          if (!raw.contains(':')) {
            final decoded = _tryBase64(raw);
            if (decoded != null) raw = decoded;
          }
      }
    }

    if (raw.isEmpty && u.into.isNotEmpty) {
      // Пустой userinfo у схемы, которая его требует, — это «узла нет».
      // Решает `required` у записи; здесь только не пишем пустоту.
      return true;
    }

    final sep = u.splitSep;
    if (sep == null || !raw.contains(sep)) {
      // Разделителя нет: значение целиком идёт в ОДНО поле.
      //
      // Умолчание — ПЕРВОЕ имя `into`, а не последнее. Так устроен сам
      // примитив: `into` перечисляет поля по порядку следования в userinfo, и
      // единственный компонент — это первый из них. `single_into` существует
      // ровно затем, чтобы умолчание ПЕРЕОПРЕДЕЛИТЬ там, где конвенция
      // протокола другая, и обе формы живут рядом в секциях волны W4: одна
      // объявляет первым именем, другая — последним. Будь умолчанием
      // последнее, вторая запись была бы пустой, а секции, не объявляющие
      // ничего, читались бы задом наперёд.
      //
      // Именно это и показала сверка W4 с эталоном: одинокий userinfo уезжал
      // в последнее поле вместо первого — пять красных кейсов снимка.
      //
      // `userinfo.pass` пространства источников заполняется только когда
      // значение действительно уехало в ПОСЛЕДНЕЕ имя: иначе запись с
      // `source: "userinfo.pass"` прочитала бы первый компонент.
      final single =
          u.singleInto ?? (u.into.isNotEmpty ? u.into.first : null);
      if (single != null && raw.isNotEmpty) {
        _write(single, raw, null);
        if (u.into.isNotEmpty && single == u.into.last) {
          space = space.copyWith(userinfoPass: raw);
        } else {
          space = space.copyWith(userinfoUser: raw);
        }
      }
      return true;
    }

    // `limit: 2` — резать по ПЕРВОМУ разделителю: хвост остаётся в последнем
    // поле целиком. Без лимита пароль с двоеточием теряется.
    final limit = u.splitLimit;
    List<String> parts;
    if (limit != null && limit > 0) {
      final idx = raw.indexOf(sep);
      parts = [raw.substring(0, idx), raw.substring(idx + sep.length)];
      if (limit == 1) parts = [raw];
    } else {
      parts = raw.split(sep);
    }

    for (var i = 0; i < u.into.length && i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      _write(u.into[i], parts[i], null);
    }
    space = space.copyWith(
      userinfoUser: parts.isNotEmpty ? parts.first : null,
      userinfoPass: parts.length > 1 ? parts[1] : null,
    );
    return true;
  }

  // ───────────────────────────── запись ─────────────────────────────

  void _applyParam(MapperParam p) {
    if (!_whenHolds(p.when)) return;

    final raw = _valueOf(p);
    if (raw == null) {
      // Параметра нет. `implies` не срабатывает (он от НАЛИЧИЯ), `sets` — у
      // ключа `""`, если секция его объявила: так выражается «пусто тоже
      // значение» (`security` без параметра включает TLS).
      final absentSet = p.sets[''];
      if (absentSet is Map && p.sets.containsKey('')) {
        _applySets(absentSet.cast<String, dynamic>(), p);
      }
      return;
    }

    var value = raw;

    // `decode_extra` — поверх первого прохода декодера формы.
    final de = p.decodeExtra;
    if (de != null && value is String) {
      value = decodeExtra(
        value,
        mode: de.mode == 'path' ? DecodeMode.path : DecodeMode.query,
        passes: de.untilStable ? null : de.passes,
        max: de.max,
      );
    }

    // `normalize` — общие нормализаторы (форма записи, не смысл).
    if (p.normalize != null && value is String) {
      value = _normalize(value, p.normalize!);
    }

    // `maps_to: null` — значение ОБЪЯВЛЕННО никуда не едет (ECH, padding).
    // Проверяется до `extract`: у такой записи регулярка не раскладывает
    // значение по телу, а вырезает из него ту часть, которую показывают
    // человеку в коде ([_applyOnPresent]).
    if (p.mapsToPresent && p.mapsTo == null && p.sets.isEmpty) {
      // `value_map` сюда всё же заглядывает: значение-выключатель
      // (`none`, пусто) переведено в «ничего нет», и кода за него быть не
      // должно — человек ничего не терял, он ничего и не просил.
      final off = value is String && p.valueMap.isNotEmpty
          ? _mapValue(p.valueMap, value)
          : (matched: false, value: value);
      if (!(off.matched && off.value == null)) {
        _applyOnPresent(p, value is String ? value : '$value');
      }
      _applyImplies(p);
      return;
    }

    // `extract` — одно значение по нескольким путям.
    if (p.extract != null && value is String) {
      _applyExtract(p, value);
      return;
    }

    // `value_map` — перевод значений диалекта. `null` = «ключа нет».
    if (p.valueMap.isNotEmpty && value is String) {
      final mapped = _mapValue(p.valueMap, value);
      if (mapped.matched) {
        if (mapped.value == null) {
          // Значение переведено в «ключа нет»: `sets` того же значения при
          // этом ОСТАЁТСЯ в силе (у `flow` так и устроено).
          _applyValueSets(p, value);
          _applyImplies(p);
          return;
        }
        value = mapped.value;
      }
    }

    // `sets` по значению — набор присваиваний вместо/вместе с `maps_to`.
    final hadSets = _applyValueSets(p, raw is String ? raw : '$raw');

    // Приведение типа (`type`) — форма, а не суждение.
    final typed = _coerceType(p, value);
    if (typed == null) {
      _applyImplies(p);
      return;
    }

    if (p.mapsTo != null) {
      _write(p.mapsTo!, typed, p);
    } else if (!hadSets && p.mapsToPresent) {
      _applyOnPresent(p, raw is String ? raw : '$raw');
    }

    _applyImplies(p);
  }

  /// `sets` по значению параметра; `true` — набор нашёлся и применён.
  bool _applyValueSets(MapperParam p, String value) {
    if (p.sets.isEmpty) return false;
    final set = _lookupFold(p.sets, value);
    if (set is! Map) return false;
    _applySets(set.cast<String, dynamic>(), p);
    return true;
  }

  void _applyImplies(MapperParam p) {
    if (p.implies.isEmpty) return;
    _applySets(p.implies, p);
    if (p.implicit) _wsEarlyDataHeaderImplicit = true;
  }

  /// Присваивания из `sets`/`implies`/`scheme_sets`.
  ///
  /// **G2 (FROZEN): `null` в присваивании СНИМАЕТ путь.** Это не то же, что
  /// «не писать»: флаг «не отправлять SNI» обязан УБРАТЬ уже поставленное
  /// имя сервера, а не промолчать.
  void _applySets(Map<String, dynamic> sets, MapperParam? p) {
    for (final e in sets.entries) {
      if (e.value == null) {
        _erase(e.key);
      } else {
        _write(e.key, e.value, p);
      }
    }
  }

  void _applyExtract(MapperParam p, String value) {
    final spec = p.extract!;
    final m = _regex(spec.re).firstMatch(value);
    if (m == null) return;
    for (final e in spec.into.entries) {
      String? group;
      try {
        group = m.namedGroup(e.key);
      } catch (_) {
        group = null;
      }
      if (group == null || group.isEmpty) continue;
      final target = e.value;
      if (target is String) {
        _write(target, group, p);
      } else if (target is Map) {
        final t = target.cast<String, dynamic>();
        final path = t['path'] as String?;
        if (path == null) continue;
        final typed = t['type'] == 'int' ? int.tryParse(group.trim()) : group;
        if (typed == null) continue;
        // `int` с неположительным значением — это «ed не задан», а не ноль:
        // режим включает только `max_early_data > 0`.
        if (typed is int && typed <= 0) continue;
        _write(path, typed, p);
        final implies = (t['implies'] as Map?)?.cast<String, dynamic>();
        if (implies != null) {
          for (final i in implies.entries) {
            final iv = i.value;
            if (iv is Map && iv['implicit'] == true) {
              // §103 D-008 — значение подставлено КОНВЕНЦИЕЙ, а не ссылкой:
              // в теле оно есть, а в ссылку при эмите не пишется.
              _wsEarlyDataHeaderImplicit = true;
              _writeIfAbsent(i.key, iv['value'], p);
            } else {
              _writeIfAbsent(i.key, iv, p);
            }
          }
        }
      }
    }
  }

  /// `on_present` — код о том, что ОБЪЯВЛЕННОЕ значение никуда не поехало.
  ///
  /// Отличается от `unknown_key` тем, что параметр реестру известен: человек
  /// написал его сознательно, и молчание тут — потеря. В теле этого значения
  /// уже нет, поэтому сказать о нём может только маппер.
  ///
  /// [value] несёт ту часть значения, которую показывают человеку. Чем она
  /// отличается от сырой, говорит `extract` записи: правило «до первого `+`»
  /// это форма значения, и держать его в коде значило бы завести первую
  /// схемную функцию в общем движке.
  void _applyOnPresent(MapperParam p, String raw) {
    final code = p.onPresent['code'] as String? ?? p.onInvalid['code'] as String?;
    if (code == null) return;
    var shown = raw.trim();
    final ex = p.extract;
    if (ex != null) {
      final m = _regex(ex.re).firstMatch(shown);
      final first = ex.into.keys.isEmpty ? null : ex.into.keys.first;
      if (m != null && first != null) {
        shown = m.namedGroup(first) ?? shown;
      }
    }
    warnings.add(NodeWarning.byCode(code, path: p.name, value: shown));
  }

  // ─────────────────────────── источники ───────────────────────────

  /// Значение записи по её `source`. `null` — ни один источник не ответил.
  dynamic _valueOf(MapperParam p) {
    final sources = p.sourceByForm.isNotEmpty
        ? (p.sourceByForm[space.formId] ?? const <String>[])
        : p.source;
    for (final src in sources) {
      final v = _readSource(src, p);
      if (v == null) continue;
      if (v is String && v.isEmpty && p.empty != 'significant') continue;
      return v;
    }
    return null;
  }

  dynamic _readSource(String src, MapperParam p) {
    if (src.startsWith('query.')) {
      final name = src.substring('query.'.length);
      // Написания: имя записи плюс `aliases`. Регистронезависимо, канон в
      // приоритете (§0.6 FROZEN). Отмечаем ПРОЧИТАННЫМ любое написание,
      // которое в ссылке есть, — иначе алиас уехал бы в `unknown_key`.
      final names = name == p.name ? p.spellings : [name];
      String? found;
      for (final n in names) {
        final v = space.query.get(n);
        if (v == null) continue;
        _consumeSpelling(n);
        found ??= v;
      }
      if (found == null) return null;
      return _decodeQueryValue(found, p);
    }
    switch (src) {
      case 'scheme':
        return space.scheme;
      case 'authority':
        return space.authority;
      case 'userinfo':
        return space.userinfo;
      case 'userinfo.user':
        return space.userinfoUser;
      case 'userinfo.pass':
        return space.userinfoPass;
      case 'host':
        return space.host;
      case 'port':
        return space.port;
      case 'port_raw':
        return space.portRaw;
      case 'path':
        return space.path;
      case 'fragment':
        return space.fragment;
    }
    if (src.startsWith('json.')) {
      return _readJsonPath(space.json, src.substring('json.'.length));
    }
    if (src.startsWith('ini.')) {
      return space.ini?[src.substring('ini.'.length).toLowerCase()];
    }
    return null;
  }

  /// Первый percent-декод query-значения (декодер формы `url`).
  ///
  /// `+` = пробел, кроме двух объявленных случаев (§0.4/§0.6 FROZEN):
  ///
  /// - поле `format: base64*` либо явный `decode_extra.plus_literal` —
  ///   «исключение из реестра, а не из списка имён»: четыре точечные заплаты
  ///   заплаты на ключах-секретах заменяются свойством поля;
  /// - запись с `decode_extra.mode: path` — path-семантика обязана
  ///   действовать на ОБОИХ проходах, а первый проход и есть этот. Иначе
  ///   `/ws+v2` стал бы `/ws v2` ещё до `decode_extra`, и второй проход
  ///   чинить было бы уже нечего (D133-14).
  String _decodeQueryValue(String raw, MapperParam p) {
    final pathMode = p.decodeExtra?.mode == 'path';
    return percentDecodeOnce(
      raw,
      mode: p.plusLiteral || pathMode ? DecodeMode.path : DecodeMode.query,
    );
  }

  void _consumeSpelling(String name) {
    _consumed.add(name.toLowerCase());
  }

  static dynamic _readJsonPath(Map<String, dynamic>? json, String path) {
    if (json == null) return null;
    dynamic cur = json;
    for (final seg in path.split('.')) {
      if (cur is Map) {
        cur = cur[seg];
      } else if (cur is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.length) return null;
        cur = cur[i];
      } else {
        return null;
      }
      if (cur == null) return null;
    }
    return cur;
  }

  // ─────────────────────────── дефолты ───────────────────────────

  void _applyDefaults(MapperParam p) {
    final path = p.mapsTo;
    if (path == null) return;
    final present = _read(path) != null;

    // `default_from` — эвристика источника (SNI → server). Срабатывает, когда
    // поле пусто, и только если `when` записи держится.
    if (!present && p.defaultFrom.isNotEmpty && _whenHolds(p.when)) {
      for (final src in p.defaultFrom) {
        final v = _readSource(src, p);
        if (v == null) continue;
        if (v is String && v.isEmpty) continue;
        _write(path, v, p);
        break;
      }
    }

    // `default_when` — конвенционный дефолт по условию.
    if (p.defaultWhen.isNotEmpty && _whenHolds(p.when)) {
      final absent = p.defaultWhen['absent'] == true;
      if ((absent && _read(path) == null) ||
          (!absent && _read(path) == null)) {
        final v = p.defaultWhen['value'];
        if (v != null) _write(path, v, p);
      }
    }

    // `materialize_default` — маппер ОБЯЗАН записать дефолт, даже когда
    // источник молчал (отличается от дефолта санитайзера: тот дефолты не
    // материализует вовсе).
    if (p.materializeDefault && _read(path) == null) {
      final v = p.defaultWhen['value'] ?? section.defaults[path];
      if (v != null) _write(path, v, p);
    }
  }

  // ─────────────────────────── условия ───────────────────────────

  /// `when` — по УЖЕ ПОСТРОЕННОМУ телу, по типу тела (`$type`), по форме
  /// (`$form`) и **по ИСТОЧНИКУ** (`query.X` — это G1, FROZEN).
  bool _whenHolds(Map<String, dynamic> when) {
    if (when.isEmpty) return true;
    for (final e in when.entries) {
      final key = e.key;
      dynamic actual;
      if (key == r'$type') {
        actual = section.singboxType;
      } else if (key == r'$form') {
        actual = space.formId;
      } else if (key.startsWith('query.') ||
          key.startsWith('json.') ||
          key.startsWith('ini.') ||
          _kLexicalSources.contains(key)) {
        actual = _readSourceBare(key);
      } else {
        actual = _read(key);
      }
      if (!_matches(actual, e.value)) return false;
    }
    return true;
  }

  /// Чтение источника для условия: без записи в `_consumed` и без декода по
  /// правилам конкретной записи — условие не «читает» параметр, оно о нём
  /// спрашивает.
  dynamic _readSourceBare(String src) {
    if (src.startsWith('query.')) {
      final raw = space.query.get(src.substring('query.'.length));
      return raw == null ? null : percentDecodeOnce(raw);
    }
    switch (src) {
      case 'scheme':
        return space.scheme;
      case 'host':
        return space.host;
      case 'port':
        return space.port;
      case 'port_raw':
        return space.portRaw;
      case 'path':
        return space.path;
      case 'fragment':
        return space.fragment;
      case 'userinfo':
        return space.userinfo;
    }
    if (src.startsWith('json.')) {
      return _readJsonPath(space.json, src.substring('json.'.length));
    }
    if (src.startsWith('ini.')) {
      return space.ini?[src.substring('ini.'.length).toLowerCase()];
    }
    return null;
  }

  static const _kLexicalSources = {
    'scheme',
    'host',
    'port',
    'port_raw',
    'path',
    'fragment',
    'userinfo',
    'authority',
  };

  bool _matches(dynamic actual, dynamic expected) {
    if (expected is Map) {
      final m = expected.cast<String, dynamic>();
      if (m.containsKey('in')) {
        final list = (m['in'] as List).map(_fold).toSet();
        return list.contains(_fold(actual ?? ''));
      }
      // `not_in` — НЕ синоним `not: {in: […]}`: по НЕСУЩЕСТВУЮЩЕМУ адресу он
      // ИСТИНЕН (PRIMITIVES §0.9). Условие «значение не из набора» обязано
      // держаться и когда значения нет вовсе — иначе запись, зависящая от
      // отсутствия чужого параметра, молча не применялась бы.
      if (m.containsKey('not_in')) {
        if (actual == null) return true;
        final list = (m['not_in'] as List).map(_fold).toSet();
        return !list.contains(_fold(actual));
      }
      if (m.containsKey('not')) return !_matches(actual, m['not']);
      if (m.containsKey('present')) {
        return (actual != null) == (m['present'] == true);
      }
      if (m.containsKey('matches')) {
        return actual is String && RegExp(m['matches'] as String).hasMatch(actual);
      }
      if (m.containsKey('not_matches')) {
        return actual is! String ||
            !RegExp(m['not_matches'] as String).hasMatch(actual);
      }
      return false;
    }
    if (expected is bool) return actual == expected;
    if (expected == null) return actual == null;
    return _fold(actual ?? '') == _fold(expected);
  }

  static String _fold(dynamic v) => '$v'.trim().toLowerCase();

  // ─────────────────────────── значения ───────────────────────────

  ({bool matched, dynamic value}) _mapValue(
    Map<String, dynamic> map,
    String value,
  ) {
    // `prefix`/`strip` — режим перевода по началу имени (uTLS-идентификаторы
    // Xray: `HelloChrome_120` → `chrome`).
    final prefix = map['prefix'];
    if (prefix is Map) {
      var probe = value.toLowerCase();
      final strip = (map['strip'] as List?)?.cast<String>() ?? const [];
      for (final s in strip) {
        probe = probe.replaceAll(s, '');
      }
      // Длинный префикс проверяется раньше короткого: иначе `hellorandom`
      // перехватил бы `hellorandomized`.
      final keys = prefix.keys.cast<String>().toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final k in keys) {
        if (probe.startsWith(k.toLowerCase())) {
          return (matched: true, value: prefix[k]);
        }
      }
      return (matched: false, value: value);
    }
    if (map.containsKey(value)) return (matched: true, value: map[value]);
    final folded = value.toLowerCase();
    for (final e in map.entries) {
      if (e.key.toLowerCase() == folded) return (matched: true, value: e.value);
    }
    return (matched: false, value: value);
  }

  /// Приведение ФОРМЫ значения по `type`/`list`/`coerce`. Годность значения
  /// здесь не решается — это работа санитайзера.
  dynamic _coerceType(MapperParam p, dynamic value) {
    if (p.list != null) {
      final spec = p.list!;
      final items = <dynamic>[];
      if (value is List) {
        items.addAll(value);
      } else if (value is String) {
        for (final part in value.split(spec.sep)) {
          final t = part.trim();
          if (t.isEmpty) continue;
          items.add(t);
        }
      } else if (spec.coerceScalar) {
        items.add(value);
      }
      if (spec.item == 'int') {
        final ints = <int>[];
        for (final it in items) {
          final n = it is num ? it.toInt() : int.tryParse('$it'.trim());
          if (n != null) ints.add(n);
        }
        return ints.isEmpty ? null : ints;
      }
      return items.isEmpty ? null : items;
    }

    switch (p.type) {
      case 'int':
        if (value is num) return value.toInt();
        return int.tryParse('$value'.trim());
      case 'bool':
      case 'bool_spelled':
        // Общий набор написаний истины (§4 FROZEN): 1 | true | yes. Одно
        // правило на все булевы параметры всех схем — у лаунчера сегодня их
        // три, и `yes` работает не везде.
        final s = '$value'.trim().toLowerCase();
        final truthy = s == '1' || s == 'true' || s == 'yes';
        // Ложь = «не просили»: ключ не появляется вовсе.
        return truthy ? true : null;
      case 'object':
        if (value is Map) {
          final m = value.cast<String, dynamic>();
          if (!p.sortKeys) return m;
          // **G4 (FROZEN `sort_keys`)** — порядок ключей объекта входит в
          // тело, и оставлять его свойством реализации нельзя.
          final keys = m.keys.toList()..sort();
          return {for (final k in keys) k: m[k]};
        }
        return value;
      default:
        if (p.coerceScalarToList && value is! List) return [value];
        if (p.coerceObjectToScalar != null && value is Map) {
          return value[p.coerceObjectToScalar];
        }
        return value;
    }
  }

  String _normalize(String value, String name) {
    switch (name) {
      case 'trim':
        return value.trim();
      case 'trim_lower':
        return value.trim().toLowerCase();
      case 'base64_std':
        return value.replaceAll('-', '+').replaceAll('_', '/');
      case 'duration_bare_seconds':
        final n = int.tryParse(value.trim());
        return n == null ? value : '${n}s';
      default:
        return value;
    }
  }

  // ─────────────────────────── тело ───────────────────────────

  /// Записать значение по пути тела с учётом `priority`/`merge` (G3).
  void _write(String path, dynamic value, MapperParam? p) {
    if (value == null) return;
    final prio = p?.priority ?? 0;
    final occupied = _writtenBy[path];
    if (occupied != null) {
      final merge = p?.merge ?? 'keep_first';
      // Запись с МЕНЬШИМ priority уже победила — она раньше по норме.
      if (merge == 'keep_first' && occupied <= prio) return;
    }
    _writtenBy[path] = prio;
    _put(path, value);
  }

  void _writeIfAbsent(String path, dynamic value, MapperParam? p) {
    if (value == null || _read(path) != null) return;
    _write(path, value, p);
  }

  /// **G2** — снять путь целиком (`sets: {path: null}`).
  void _erase(String path) {
    final segs = path.split('.');
    Map<String, dynamic>? cur = body;
    for (var i = 0; i < segs.length - 1; i++) {
      final next = cur![segs[i]];
      if (next is! Map) return;
      cur = next.cast<String, dynamic>();
    }
    cur!.remove(segs.last);
    _writtenBy.remove(path);
  }

  /// Положить значение по точечному пути, заводя недостающие уровни.
  ///
  /// Вложенная карта НЕ пересобирается: `tls.enabled` и `tls.server_name` —
  /// две записи в один блок, и вторая обязана дописаться к первой.
  void _put(String path, dynamic value) {
    final segs = path.split('.');
    var cur = body;
    for (var i = 0; i < segs.length - 1; i++) {
      final next = cur[segs[i]];
      if (next is Map<String, dynamic>) {
        cur = next;
      } else {
        final fresh = <String, dynamic>{};
        cur[segs[i]] = fresh;
        cur = fresh;
      }
    }
    cur[segs.last] = value;
  }

  dynamic _read(String path) {
    dynamic cur = body;
    for (final seg in path.split('.')) {
      if (cur is! Map) return null;
      cur = cur[seg];
      if (cur == null) return null;
    }
    return cur;
  }

  // ─────────────────────────── метка ───────────────────────────

  /// Метка из объявленных источников с объявленной нормализацией (G8).
  ///
  /// Метка ВХОДИТ В IDENTITY (тег и есть identity, `node_hash.dart`), поэтому
  /// её обработка объявлена, а не остаётся свойством кода.
  String _label() {
    var raw = '';
    for (final src in section.label.source) {
      final v = _readSourceBare(src);
      if (v is String && v.isNotEmpty) {
        raw = v;
        break;
      }
    }
    if (raw.isEmpty) return '';
    // Фрагмент percent-декодируется с path-семантикой: `+` во фрагменте
    // литерален (form-encoding во фрагменте не действует).
    var label = percentDecodeOnce(raw, mode: DecodeMode.path);
    for (final n in section.label.normalize) {
      switch (n) {
        case 'strip_control':
          label = _stripControl(label);
        case 'trim':
          label = label.trim();
      }
    }
    for (final e in section.label.valueMap.entries) {
      label = label.replaceAll(e.key, '${e.value}');
    }
    return label;
  }

  /// Управляющие символы вон, кроме `\t`/`\n`/`\r` — их норма сохраняет в
  /// середине строки (`sanitizeForDisplay`, зеркало Go).
  static String _stripControl(String s) {
    if (s.isEmpty) return s;
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r == 9 || r == 10 || r == 13) {
        buf.writeCharCode(r);
        continue;
      }
      if (r <= 0x1F || r == 0x7F) continue;
      buf.writeCharCode(r);
    }
    return buf.toString();
  }

  // ─────────────────────── неизвестные параметры ───────────────────────

  /// `unknown_key` — параметр источника, которого не объявила ни одна запись.
  ///
  /// Объявленными считаются и параметры ОБЩИХ секций (tls, transports,
  /// dialer): они вмонтированы в `params` загрузчиком через `include`, и
  /// отдельного списка исключений заводить не нужно.
  void _reportUnknown() {
    final code = section.unknownKeyCode;
    if (code == null) return;
    for (final name in space.query.names) {
      if (_consumed.contains(name.toLowerCase())) continue;
      warnings.add(RegistryWarning(code: code, path: name, value: ''));
    }
  }

  /// Регулярка реестра, скомпилированная и закэшированная.
  ///
  /// Диалект нормы — RE2 ∩ ECMAScript, и именованная группа в нём пишется
  /// по-разному: Go принимает только `(?P<name>…)`, Dart — только
  /// `(?<name>…)`. Реестр пишется у лаунчера, то есть в Go-написании; перевод
  /// делается здесь, один раз на регулярку, а не правкой данных — иначе одна
  /// и та же запись не читалась бы двумя сторонами.
  ///
  /// Кэш — потому что записи исполняются на КАЖДОМ узле подписки: на 2000
  /// узлах это 2000 одинаковых компиляций одного выражения.
  static RegExp _regex(String re) => _regexCache.putIfAbsent(
        re,
        () => RegExp(re.replaceAll('(?P<', '(?<')),
      );

  static final Map<String, RegExp> _regexCache = {};

  static dynamic _lookupFold(Map<String, dynamic> map, String key) {
    if (map.containsKey(key)) return map[key];
    final folded = key.trim().toLowerCase();
    for (final e in map.entries) {
      if (e.key.toLowerCase() == folded) return e.value;
    }
    return null;
  }

  static String? _tryBase64(String raw) {
    try {
      var s = raw.replaceAll('-', '+').replaceAll('_', '/');
      final pad = s.length % 4;
      if (pad != 0) s = s.padRight(s.length + (4 - pad), '=');
      return String.fromCharCodes(_b64.decode(s));
    } catch (_) {
      return null;
    }
  }
}

const _b64 = Base64Codec();
