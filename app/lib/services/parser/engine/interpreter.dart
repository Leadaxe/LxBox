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

import 'dart:convert' show Base64Codec, jsonDecode, utf8;

import '../../../models/node_warning.dart';
import 'decoders.dart';
import 'ini_space.dart';
import 'lexer.dart';
import 'section.dart';
import 'source_space.dart';
import 'trace.dart';

/// Итог исполнения секции.
final class EngineResult {
  const EngineResult({
    required this.body,
    required this.label,
    this.warnings = const [],
    this.extensionFields = const {},
    this.wsEarlyDataHeaderImplicit = false,
    this.tagAddress,
    this.tagScheme,
    this.kinds = const {},
    this.bodySource = '',
  });

  /// Сырая карта тела в ключах sing-box.
  final Map<String, dynamic> body;

  /// Метка из объявленных источников, уже нормализованная.
  final String label;

  final List<NodeWarning> warnings;
  final Map<String, dynamic> extensionFields;
  final bool wsEarlyDataHeaderImplicit;
  final (String, int)? tagAddress;

  /// Рода узла, объявленные ВХОДОМ (`kind_when`): их судит не тело, а
  /// источник.
  final Set<String> kinds;

  /// Написание имени в теге-фолбэке, объявленное секцией (`label.fallback
  /// .scheme`): `null` — фолбэк строится по типу тела, как у всех прочих.
  final String? tagScheme;

  /// §480 — ВХОД, которым тело приехало, как его назвала секция
  /// (`body_source`).
  ///
  /// Санитайзер судит по нему `max_when.except_sources` — единственное место
  /// контракта, где вход влияет на РЕЗУЛЬТАТ, а не только на разбор. До
  /// этого конвейер передавал туда заглушку на всех входах, кроме
  /// sing-box-JSON, и правило работало вслепую.
  final String bodySource;
}

/// Исполнить секцию на тексте источника.
///
/// `null` — записи нет: не сработала ни одна форма, либо обязательная запись
/// (`required`) не нашла значения. Тем же `null` отвечали рукописные мапперы.
EngineResult? runSection(MapperSection section, String text,
    {MapperTrace? trace}) {
  final space = _selectForm(section, text);
  if (space == null) return null;
  return _Run(section, space, trace).execute();
}

/// §480 W5 — исполнить секцию на РАЗОБРАННОМ документе-объекте.
///
/// Второй вход движка, и разница с [runSection] ровно одна: пространство
/// строится не лексером из текста, а из уже разобранной карты. Элемент к
/// этому моменту разобран один раз на весь документ (норма §1: «JSON
/// элемента разбирается один раз на элемент»), и просить движок разбирать
/// текст заново значило бы разбирать подписку из 2000 узлов дважды.
///
/// Всё остальное общее: те же формы, тот же `detect`, те же записи и тот же
/// порядок проходов. Вид источника движок не знает — `kind` выбирает
/// секцию у загрузчика, а не ветку здесь.
EngineResult? runSectionOnJson(
  MapperSection section,
  Map<String, dynamic> doc, {
  MapperTrace? trace,
}) {
  final space = _selectJsonForm(section, doc);
  if (space == null) return null;
  return _Run(section, space, trace).execute();
}

/// §480 — исполнить секцию на тексте INI (`.conf`).
///
/// Третий вход движка. От [runSection] отличается разбором входа: текст
/// раскладывается адаптером `ini` по диалекту, объявленному САМОЙ СЕКЦИЕЙ
/// (`ini_dialect`), а не правилами, зашитыми в движок. Всё остальное —
/// формы, `detect`, записи, оба прохода, метка — общее.
///
/// [nameHint] — имя, которое предлагает ВЫЗЫВАЮЩИЙ (имя файла при импорте,
/// тег записи хранения, поле Tag редактора). INI тега не несёт, и цепочка
/// метки у него длиннее, чем у ссылки: источник-комментарий → подсказка →
/// шаблон фолбэка. Подсказка приходит параметром, а не источником текста,
/// потому что в самом документе её нет; секция адресует её объявленным
/// именем `hint` в `label.source`, то есть место подсказки в цепочке остаётся
/// данными.
EngineResult? runSectionOnIni(
  MapperSection section,
  String text, {
  String? nameHint,
  MapperTrace? trace,
}) {
  final space = _selectIniForm(section, text);
  if (space == null) return null;
  final parsed = parseIniSpace(text, section.iniDialect ?? const IniDialect());
  return _Run(section, space, trace, nameHint: nameHint)
      .execute(inputCodes: parsed.codes);
}

/// Форма для входа INI: `detect` формы судится предикатами `ini` над УЖЕ
/// разобранным пространством — язык предикатов один на оба уровня (§2 НОРМЫ).
SourceSpace? _selectIniForm(MapperSection section, String text) {
  final dialect = section.iniDialect ?? const IniDialect();
  final parsed = parseIniSpace(text, dialect);
  final forms = section.forms.isEmpty
      ? const [MapperForm(id: 'ini', space: 'ini')]
      : section.forms;
  for (final form in forms) {
    if (!detectMatchesIni(form.detect, parsed.space)) continue;
    return SourceSpace(formId: form.id, ini: parsed.space);
  }
  return null;
}

/// Выбрать форму (P1) и построить пространство источников.
///
/// Формы пробуются ПО ПОРЯДКУ, первая, чей `detect` сработал, выигрывает;
/// `detect.default` — ветка «всё остальное».
SourceSpace? _selectForm(MapperSection section, String text) {
  final forms = section.forms.isEmpty
      ? const [MapperForm(id: 'url', space: 'url')]
      : section.forms;
  for (final form in forms) {
    if (!formMatchesText(form.detect, text)) continue;
    // `forms[].decode` — оболочка источника: тело после схемы бывает целиком
    // base64 (перекодированные подписки). Декодер работает над ПЭЙЛОАДОМ, а
    // схему возвращает на место: написание схемы — источник (`scheme_sets`,
    // `label_fallback`), и потерять его нельзя.
    final decoded = _applyFormDecode(form, text);
    if (decoded == null) continue;
    switch (form.space) {
      case 'url':
        final space = lexUri(decoded, formId: form.id);
        if (space == null) continue;
        // `forms[].decode` с ОБЛАСТЬЮ (§0.10 FROZEN) — декодер накрывает не
        // весь текст, а названный кусок, и применяется ПОСЛЕ лексера: текст
        // уже разложен на части, часть декодируется, части собираются назад.
        // Область нужна потому, что base64 у одной схемы накрывает РАЗНЫЕ
        // куски ссылки в разных формах (только userinfo либо весь authority),
        // а метка `#…` в обеих формах остаётся открытым текстом снаружи —
        // декодер «на весь текст» ломает и ту, и другую.
        // Область `authority` у ссылочной формы накрывает ВЕСЬ пэйлоад, и
        // раскрыть её обязан декодер ДО лексера: сам base64 законно несёт
        // `?` и `/` (алфавит std), а лексер, увидев их в ещё закрытом тексте,
        // отрезал бы по ним путь и query — «хвост» уехал бы в никуда, а
        // authority пришёл бы обрезанным. Так устроена всякая форма, где под
        // оболочкой лежит ссылка с параметрами (`…@host:port?a=1&b=2`).
        //
        // `userinfo` так раскрыть нельзя: там декодируется КУСОК внутри
        // authority, и границы его знает только лексер — эта ветка ниже.
        final unwrapped = _applyScopedDecodeToPayload(form, decoded);
        if (unwrapped == null) continue;
        if (unwrapped != decoded) {
          final relexed = lexUri(unwrapped, formId: form.id);
          if (relexed != null) return relexed;
          continue;
        }
        final scoped = _applyScopedDecode(form, space);
        if (scoped != null) return scoped;
      case 'json':
        // §480 — ТЕКСТОВАЯ форма с объектным пространством: оболочка формы
        // (`decode`) раскрывает текст до JSON, и дальше запись адресует его
        // json-путём, как у объектного входа. Без этого текстовый вход и
        // объектный разошлись бы двумя ветками кода при одной грамматике.
        //
        // Предикат `detect.json` формы судится ПО РАЗОБРАННОМУ значению, а
        // разобрать его можно только здесь: до `decode` текст ещё в оболочке.
        // Поэтому форма отсеивается в два приёма — текстовой частью выражения
        // выше и объектной здесь.
        //
        // Шаг с ОБЛАСТЬЮ у объектного пространства исполняется ЗДЕСЬ, а не
        // лексером: разбирать оболочку как ссылку незачем — под ней лежит
        // объект. Область у такой формы всегда накрывает пэйлоад целиком
        // (`authority` контейнера — это и есть весь текст после схемы), и
        // декодирование сводится к тому же шагу над пэйлоадом.
        final unwrapped = _applyScopedDecodeToPayload(form, decoded);
        if (unwrapped == null) continue;
        final doc = _decodeFormJson(form, unwrapped);
        if (doc == null) continue;
        if (!detectMatchesJson(form.detect, doc)) continue;
        return SourceSpace(
          formId: form.id,
          scheme: _splitScheme(decoded)?.scheme ?? '',
          json: doc,
          jsonBase: form.base,
          // ПЛОСКИЙ СЛОЙ контейнера (§0.10 НОРМЫ: «json — разбор объекта в
          // плоский слой»). Ключи ВЕРХНЕГО уровня становятся тем же
          // пространством имён, что query у ссылки, и общие блоки
          // (`tls#uri`, `transports#uri`) читают `sni`, `alpn`, `fp`, `path`
          // одним и тем же `source` на обеих формах.
          //
          // Иначе блок диалекта пришлось бы дублировать под каждый
          // контейнер: записи у них совпали бы до буквы, потому что
          // контейнер и назван так, чтобы повторять имена query.
          query: _flattenContainer(doc),
        );
      default:
        // Прочее пространство (`ini`) разбирается своим входом. Молча выдавать
        // пустое тело нельзя — это был бы узел из ничего, поэтому форма просто
        // не отвечает.
        continue;
    }
  }
  return null;
}

/// Форма для объектного входа: `detect` формы судится предикатами `json`
/// (§2 НОРМЫ — язык предикатов ОДИН на обоих уровнях).
SourceSpace? _selectJsonForm(MapperSection section, Map<String, dynamic> doc) {
  final forms = section.forms.isEmpty
      ? const [MapperForm(id: 'json', space: 'json')]
      : section.forms;
  for (final form in forms) {
    if (!detectMatchesJson(form.detect, doc)) continue;
    return SourceSpace(formId: form.id, json: doc, jsonBase: form.base);
  }
  return null;
}

/// Пэйлоад источника — то, что стоит ПОСЛЕ `<схема>://`. `detect` и `decode`
/// формы работают над ним: признак «тело целиком base64» о схеме ничего не
/// говорит, а декодер обязан её сохранить.
({String scheme, String payload})? _splitScheme(String text) {
  final i = text.indexOf('://');
  if (i <= 0) return null;
  return (scheme: text.substring(0, i), payload: text.substring(i + 3));
}

/// Исполнить `forms[].decode` над пэйлоадом; `null` — шаг не отработал, и
/// форма не отвечает (молча выдать пустое тело нельзя — это узел из ничего).
///
/// `{"reparse": "url"}` говорит, что декодированный текст — снова ссылка: он
/// возвращается со схемой на месте и разбирается лексером обычным порядком.
/// §480 W4 — ФРАГМЕНТ снимается до декода и возвращается после: имя узла
/// пишется СНАРУЖИ оболочки, а внутрь её уехала только запись. Не сними его —
/// и `#имя` попало бы в base64-декодер, оболочка не раскрылась бы вовсе.
///
/// Шаг `percent` — тоже W4: у формы, где base64 приезжает percent-экранированным
/// (панели пишут `=`-паддинг как `%3D`), порядок «percent, потом base64»
/// выразим только списком.
String? _applyFormDecode(MapperForm form, String text) {
  if (form.decode.isEmpty) return text;
  final split = _splitScheme(text);
  if (split == null) return text;
  var payload = split.payload;
  var fragment = '';
  final hash = payload.indexOf('#');
  if (hash >= 0) {
    fragment = payload.substring(hash);
    payload = payload.substring(0, hash);
  }
  for (final step in form.decode) {
    if (step == 'url') continue; // percent снимает сам лексер.
    // Шаг с ОБЛАСТЬЮ здесь пропускается: он исполняется после лексера
    // ([_applyScopedDecode]), когда известно, где кончается названный кусок.
    if (step is Map && step['scope'] != null && step['scope'] != 'all') {
      continue;
    }
    if (step == 'percent') {
      payload = percentDecodeOnce(payload, mode: DecodeMode.path);
      continue;
    }
    if (step is Map && step['decoder'] != null) {
      final d = step['decoder'];
      if (d == 'percent') {
        payload = percentDecodeOnce(payload, mode: DecodeMode.path);
      } else if (d == 'base64' || d == 'base64?' || d == 'base64url') {
        final decoded = _RunDecode.base64(payload.trim());
        if (decoded == null) {
          if (d == 'base64') return null;
          continue;
        }
        payload = decoded;
      }
      continue;
    }
    if (step == 'base64' || step == 'base64?') {
      final decoded = _RunDecode.base64(payload.trim());
      if (decoded == null) {
        if (step == 'base64') return null;
        continue;
      }
      payload = decoded;
      continue;
    }
    if (step is Map && step['reparse'] != null) continue;
    // Шаг `json` пространство не декодирует, а ОБЪЯВЛЯЕТ: разбор в объект —
    // дело [_decodeFormJson], который работает над тем же результатом. Здесь
    // шаг пропускается, чтобы текст доехал до него целым.
    if (step == 'json') continue;
  }
  return '${split.scheme}://$payload$fragment';
}

/// Декодер формы с областью `authority` — НАД ПЭЙЛОАДОМ, до лексера.
///
/// `authority` у формы, чья оболочка накрывает всё после схемы, — это не
/// «кусок ссылки», а ГРАНИЦА: схема и метка обязаны остаться снаружи
/// декодера, иначе оболочка не раскроется. Ровно это и делает
/// [_applyFormDecode], снимая схему и фрагмент, поэтому здесь остаётся
/// применить сам декодер к пэйлоаду.
///
/// Раскрывать ДО лексера обязательно в обоих пространствах:
///
/// - `json` — под оболочкой лежит объект, и лексеру там делать нечего;
/// - `url` — под оболочкой лежит ссылка, но сам base64 законно несёт `?` и
///   `/`, и лексер, увидев их в ещё закрытом тексте, отрезал бы по ним путь
///   и query.
///
/// `null` — обязательный декодер не отработал, и форма не отвечает.
String? _applyScopedDecodeToPayload(MapperForm form, String text) {
  final split = _splitScheme(text);
  if (split == null) return text;
  var payload = split.payload;
  var fragment = '';
  final hash = payload.indexOf('#');
  if (hash >= 0) {
    fragment = payload.substring(hash);
    payload = payload.substring(0, hash);
  }
  for (final step in form.decode) {
    if (step is! Map) continue;
    // Только `authority`: она и есть «весь пэйлоад». `userinfo` — кусок
    // ВНУТРИ authority, его границы знает лексер, и раскрывается он
    // [_applyScopedDecode] после разбора.
    if (step['scope'] != 'authority') continue;
    final decoder = step['decoder'];
    if (decoder == 'percent') {
      payload = percentDecodeOnce(payload, mode: DecodeMode.path);
      continue;
    }
    if (decoder == 'base64' || decoder == 'base64?' || decoder == 'base64url') {
      final decoded = _RunDecode.base64(payload.trim());
      if (decoded == null) {
        if (decoder == 'base64') return null;
        continue;
      }
      payload = decoded;
    }
  }
  return '${split.scheme}://$payload$fragment';
}

/// Декодер формы с ОБЛАСТЬЮ (§0.10 FROZEN): `scope: userinfo|authority`.
///
/// Применяется ПОСЛЕ лексера и пересобирает ссылку с декодированным куском,
/// после чего лексер проходит по ней ещё раз. Пересборка, а не правка полей
/// пространства, потому что декодированный authority приносит СВОЮ структуру:
/// `base64(method:password@host:port)` — это и userinfo, и хост, и порт
/// разом, и разбирать его обязан тот же лексер, а не второе место с теми же
/// правилами.
///
/// Query, path и fragment берутся из ВНЕШНЕГО текста: метка `#…` лежит
/// открытым текстом снаружи в обеих формах.
///
/// `null` — обязательный декодер не отработал, и форма не отвечает.
SourceSpace? _applyScopedDecode(MapperForm form, SourceSpace space) {
  var result = space;
  for (final step in form.decode) {
    if (step is! Map) continue;
    final scope = step['scope'];
    if (scope == null || scope == 'all') continue;
    final decoder = step['decoder'];
    final optional = decoder == 'base64?' || decoder == 'percent';

    String piece;
    switch (scope) {
      case 'userinfo':
        piece = result.userinfo;
      case 'authority':
        piece = result.authority;
      default:
        continue;
    }
    if (piece.isEmpty) continue;

    String? decoded;
    switch (decoder) {
      case 'base64':
      case 'base64?':
      case 'base64url':
        decoded = _RunDecode.base64(piece.trim());
      case 'percent':
        decoded = percentDecodeOnce(piece, mode: DecodeMode.path);
      default:
        continue;
    }
    if (decoded == null) {
      if (optional) continue;
      return null;
    }

    // Пересборка: декодированный кусок встаёт на своё место, остальное —
    // как было. Хвост (path/query/fragment) восстанавливается из полей
    // пространства, потому что лексер уже отделил его от authority.
    final tail = StringBuffer()
      ..write(result.path)
      ..write(result.query.pairs.isEmpty
          ? ''
          : '?${result.query.pairs.map((p) => '${p.$1}=${p.$2}').join('&')}')
      ..write(result.fragment.isEmpty ? '' : '#${result.fragment}');
    final authority = scope == 'userinfo'
        ? '$decoded@${result.authority.substring(result.authority.lastIndexOf('@') + 1)}'
        : decoded;
    final relexed = lexUri('${result.scheme}://$authority$tail',
        formId: result.formId);
    if (relexed == null) return null;
    result = relexed;
  }
  return result;
}

/// Ключи ВЕРХНЕГО уровня контейнера плоским слоем имён.
///
/// Скаляры только: вложенный объект и список адресуются `json.<путь>`, и
/// строкой их не представить — `'$v'` дал бы `{a: 1}` Dart-написанием, чужим
/// обеим сторонам.
///
/// `null` ключа и ОТСУТСТВИЕ ключа здесь неразличимы намеренно: панели шлют
/// `"scy": null` в значении «не задано», и корпус требует читать это как
/// отсутствие, а не как строку `null`.
QueryPairs _flattenContainer(Map<String, dynamic> doc) => QueryPairs([
      for (final e in doc.entries)
        if (e.value != null && e.value is! Map && e.value is! List)
          (e.key, '${e.value}'),
    ]);

/// §480 — разобрать результат `forms[].decode` текстовой формы с
/// `space: json` в объект.
///
/// Работает над ПЭЙЛОАДОМ: схему [_applyFormDecode] возвращает на место ради
/// `scheme_sets` и метки-фолбэка, но JSON-документу она чужая, и оставить её
/// значило бы не разобрать ни одного узла.
///
/// `null` — шаг `json` формой не объявлен, текст не JSON либо это не объект.
/// Во всех трёх случаях форма просто не отвечает.
Map<String, dynamic>? _decodeFormJson(MapperForm form, String decoded) {
  if (!form.decode.contains('json')) return null;
  var payload = _splitScheme(decoded)?.payload ?? decoded;
  // ФРАГМЕНТ отрезается: `_applyFormDecode` снял его перед декодером и вернул
  // на место (имя узла пишется СНАРУЖИ оболочки), но документу он чужой —
  // `{...}#MyNodeName` не JSON, и форма молча уступила бы место следующей.
  //
  // Значения он не теряет: у формы-контейнера имя узла лежит в самом объекте,
  // и `label.source` этой формы фрагмент не читает.
  final hash = payload.indexOf('#');
  if (hash >= 0) payload = payload.substring(0, hash);
  try {
    final parsed = jsonDecode(payload.trim());
    if (parsed is Map) return parsed.cast<String, dynamic>();
  } catch (_) {
    // Не JSON — пробуется следующая форма (у контейнерных схем она и есть
    // объявленный откат на текстовую запись).
  }
  return null;
}

/// Декодеры оболочки формы. Отдельный тип, чтобы не тащить статику в `_Run`.
abstract final class _RunDecode {
  /// Байты из base64 в любом из четырёх написаний; `null` — не base64.
  ///
  /// Декодер СВОЙ и ленивый, как `encoding/base64` у Go: `dart:convert`
  /// отвергает неканоническую форму (лишние биты в последнем символе,
  /// `…ccC=`), а D-030 требует именно её принимать — иначе живой ключ
  /// объявляется мусором. Канонизацию делает вызывающий, кодируя обратно.
  static List<int>? bytes(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'=+$'), '');
    if (trimmed.isEmpty) return null;
    final values = <int>[];
    for (final unit in trimmed.codeUnits) {
      final v = _b64Value(unit);
      if (v == null) return null;
      values.add(v);
    }
    // Один остаточный символ кодирует меньше байта — это не base64.
    final rem = values.length % 4;
    if (rem == 1) return null;

    final out = <int>[];
    var i = 0;
    while (i + 4 <= values.length) {
      final n = (values[i] << 18) |
          (values[i + 1] << 12) |
          (values[i + 2] << 6) |
          values[i + 3];
      out..add((n >> 16) & 0xFF)..add((n >> 8) & 0xFF)..add(n & 0xFF);
      i += 4;
    }
    if (rem == 2) {
      out.add(((values[i] << 2) | (values[i + 1] >> 4)) & 0xFF);
    } else if (rem == 3) {
      final n = (values[i] << 10) | (values[i + 1] << 4) | (values[i + 2] >> 2);
      out..add((n >> 8) & 0xFF)..add(n & 0xFF);
    }
    return out;
  }

  static int? _b64Value(int unit) {
    if (unit >= 0x41 && unit <= 0x5A) return unit - 0x41; // A-Z
    if (unit >= 0x61 && unit <= 0x7A) return unit - 0x61 + 26; // a-z
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30 + 52; // 0-9
    if (unit == 0x2B || unit == 0x2D) return 62; // + -
    if (unit == 0x2F || unit == 0x5F) return 63; // / _
    return null;
  }

  static String? base64(String raw) {
    try {
      var s = raw.replaceAll('-', '+').replaceAll('_', '/');
      final pad = s.length % 4;
      if (pad != 0) s = s.padRight(s.length + (4 - pad), '=');
      // Байты — UTF-8, и читать их обязаны как UTF-8. `String.fromCharCodes`
      // принимал каждый БАЙТ за символ latin-1, и любое не-ASCII имя узла
      // приезжало искажённым: «изPS» становилось «Ð¸Ð·PS». Малформед
      // допускается, а не бросается: мусорный байт в имени не стоит узлу
      // разбора целиком.
      return utf8.decode(_b64.decode(s), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// `detect` по ТЕКСТУ (уровень ссылки и уровень документа).
///
/// Вынесено наружу: тем же предикатом судится вид документа (W6), и второго
/// языка для документа норма (§2) не допускает — иначе сниффер формата
/// вернулся бы в код.
bool formMatchesText(Map<String, dynamic>? d, String text) {
  if (d == null || d['default'] == true) return true;
  // Предикаты по ТЕКСТУ адресуют пэйлоад: «тело целиком base64» — это про то,
  // что после схемы, и со схемой такое выражение не совпало бы никогда.
  final payload = _splitScheme(text)?.payload ?? text;
  final schemeIn = (d['scheme_in'] as List?)?.cast<String>();
  if (schemeIn != null) {
    final colon = text.indexOf(':');
    final scheme = colon > 0 ? text.substring(0, colon).toLowerCase() : '';
    if (!schemeIn.any((s) => s.toLowerCase() == scheme)) return false;
  }
  final re = d['regex'] as String?;
  if (re != null && !RegExp(re).hasMatch(payload)) return false;
  final txt = (d['text'] as Map?)?.cast<String, dynamic>();
  if (txt != null) {
    final prefix = txt['prefix_fold'] as String?;
    // Префикс сверяется и с пэйлоадом, и с ЦЕЛЫМ текстом: у формы ссылки
    // выражение адресует то, что после схемы, а у вида документа — сам
    // документ, и `vpn://` это его начало, а не начало пэйлоада.
    if (prefix != null) {
      final p = prefix.toLowerCase();
      if (!payload.toLowerCase().startsWith(p) &&
          !text.toLowerCase().startsWith(p)) {
        return false;
      }
    }
    final contains = txt['contains'] as String?;
    if (contains != null && !payload.contains(contains)) return false;
    // `prefix_trim` — первый НЕПРОБЕЛЬНЫЙ символ: `{`/`[` у JSON стоят после
    // произвольного отступа, и требовать их первым байтом значило бы
    // отвергать выровненный документ.
    final prefixTrim = txt['prefix_trim'] as String?;
    if (prefixTrim != null && !payload.trimLeft().startsWith(prefixTrim)) {
      return false;
    }
    // `min_len` — длина ПОСЛЕ снятия пробелов. Короткая строка из букв и
    // цифр проходит алфавит base64 случайно, и порог отсекает её без
    // отдельной ветки в коде.
    final minLen = (txt['min_len'] as num?)?.toInt();
    if (minLen != null && payload.replaceAll(RegExp(r'\s+'), '').length < minLen) {
      return false;
    }
  }
  // `ini.first_section_fold` — имя ПЕРВОЙ секции INI, без учёта регистра;
  // строки-комментарии до неё пропускаются (комментарий над `[Interface]`
  // законен и несёт имя узла, G7).
  final ini = (d['ini'] as Map?)?.cast<String, dynamic>();
  if (ini != null) {
    final want = (ini['first_section_fold'] as String?)?.toLowerCase();
    if (want != null && _firstIniSection(text)?.toLowerCase() != want) {
      return false;
    }
  }
  // Комбинаторы предиката: рекурсия по тому же выражению. Имя формы им не
  // нужно — предикат судит ТЕКСТ, а не форму, и с вынесением наружу
  // (`formMatchesText`) вложенное выражение адресуется напрямую.
  final not = d['not'];
  if (not is Map && formMatchesText(not.cast<String, dynamic>(), text)) {
    return false;
  }
  final all = d['all'];
  if (all is List) {
    for (final sub in all) {
      if (sub is! Map) continue;
      if (!formMatchesText(sub.cast<String, dynamic>(), text)) return false;
    }
  }
  final any = d['any'];
  if (any is List && any.isNotEmpty) {
    var hit = false;
    for (final sub in any) {
      if (sub is! Map) continue;
      if (formMatchesText(sub.cast<String, dynamic>(), text)) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  return true;
}

/// Имя первой секции INI (`[Interface]` → `Interface`); `null` — секций нет.
/// Комментарные и пустые строки до неё пропускаются.
String? _firstIniSection(String text) {
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('#') || l.startsWith('//') || l.startsWith(';')) continue;
    if (l.startsWith('[') && l.endsWith(']')) {
      return l.substring(1, l.length - 1).trim();
    }
    return null;
  }
  return null;
}

/// `detect.ini` по РАЗОБРАННОМУ пространству INI — тот же язык предикатов,
/// что и у текста, и у объекта (§2 НОРМЫ).
///
/// Предикаты:
///
/// - `sections: [<Имя>…]` — все названные секции в документе есть;
/// - `keys_any: [<Ключ>…]` — есть хотя бы ОДИН из названных ключей, в любой
///   секции. Имя без секции потому, что признак рода ставится КЛЮЧОМ, а не
///   его местом: один и тот же ключ опознаёт форму, где бы диалект его ни
///   держал;
/// - `keys_all: [<Ключ>…]` — есть все названные.
///
/// Имена регистронезависимы: пространство сложено в нижнем регистре, и
/// предикат опускает регистр перед сравнением.
bool detectMatchesIni(Map<String, dynamic>? d, Map<String, String> space) {
  if (d == null || d['default'] == true) return true;
  final ini = (d['ini'] as Map?)?.cast<String, dynamic>();
  if (ini == null) return d.isEmpty;

  bool hasKey(String key) {
    final want = key.toLowerCase();
    // Ключ адресуется либо целиком (`Interface.Jc`), либо одним именем — тогда
    // подходит любая секция.
    if (want.contains('.')) return space.containsKey(want);
    return space.keys.any((k) {
      final dot = k.lastIndexOf('.');
      return dot >= 0 && k.substring(dot + 1) == want;
    });
  }

  final sections = (ini['sections'] as List?)?.cast<String>();
  if (sections != null) {
    for (final s in sections) {
      final want = '${s.toLowerCase()}.';
      if (!space.keys.any((k) => k.startsWith(want))) return false;
    }
  }
  final keysAny = (ini['keys_any'] as List?)?.cast<String>();
  if (keysAny != null && keysAny.isNotEmpty && !keysAny.any(hasKey)) {
    return false;
  }
  final keysAll = (ini['keys_all'] as List?)?.cast<String>();
  if (keysAll != null && !keysAll.every(hasKey)) return false;
  return true;
}

/// `detect.json` по РАЗОБРАННОМУ значению — тот же язык предикатов, что и у
/// формы, и у вида документа (§2 НОРМЫ).
///
/// Предикаты (`PRIMITIVES.md` §1.2):
///
/// - `value_of: {<путь>: <значение>}` — точное равенство скаляра;
/// - `value_in: {<путь>: [<значения>]}` — вхождение в набор;
/// - `required_keys: [<путь>…]` — путь существует (значение любое, включая
///   пустое); прежнее написание `has_key` читается, но не пишется;
/// - `array_elem_any_keys: ["outbounds[].protocol", …]` — хотя бы у ОДНОГО
///   элемента массива есть этот путь. Массив назван явно (`[]` в пути), а не
///   угадывается: «первый элемент решает за весь массив» — ровно тот
///   рукописный сниффер, который волна снимает.
///
/// Несколько предикатов в одном `detect` — конъюнкция.
bool detectMatchesJson(Map<String, dynamic>? d, dynamic value) {
  if (d == null || d['default'] == true) return true;

  // Комбинаторы УРОВНЯ `detect` — там же, где они живут у предиката по
  // тексту, и это единственное их место (GRAMMAR_SYNC §1 №3): внутри `json`
  // своей копии `any`/`all`/`not` грамматика не заводит, иначе каждый
  // под-словарь обзаводится собственными тремя операторами и два написания
  // одного выражения расходятся на первой же ветке.
  //
  // Считаются ДО `json`: выражение вида `{"all": […], "not": {…}}` своего
  // ключа `json` не имеет вовсе, и без этого обхода ветка не срабатывала бы
  // никогда.
  final topAll = d['all'];
  if (topAll is List) {
    for (final sub in topAll) {
      if (sub is! Map) continue;
      if (!detectMatchesJson(sub.cast<String, dynamic>(), value)) return false;
    }
  }
  final topAny = d['any'];
  if (topAny is List && topAny.isNotEmpty) {
    var hit = false;
    for (final sub in topAny) {
      if (sub is! Map) continue;
      if (detectMatchesJson(sub.cast<String, dynamic>(), value)) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  final topNot = d['not'];
  if (topNot is Map &&
      detectMatchesJson(topNot.cast<String, dynamic>(), value)) {
    return false;
  }

  final j = (d['json'] as Map?)?.cast<String, dynamic>();
  if (j == null) {
    // Ключа `json` нет: выражение состояло из одних комбинаторов — они уже
    // сошлись выше. Пустое выражение истинно, чужое (текстовое) — нет.
    if (d.containsKey('json')) return false;
    final combinatorsOnly = d.keys.every(
      (k) => k == 'all' || k == 'any' || k == 'not',
    );
    return d.isEmpty || combinatorsOnly;
  }
  final valueOf = (j['value_of'] as Map?)?.cast<String, dynamic>();
  if (valueOf != null) {
    for (final e in valueOf.entries) {
      final actual = jsonPathValue(value, e.key);
      if (actual == null) return false;
      if (!_scalarEq(actual, e.value)) return false;
    }
  }
  final valueIn = (j['value_in'] as Map?)?.cast<String, dynamic>();
  if (valueIn != null) {
    for (final e in valueIn.entries) {
      final actual = jsonPathValue(value, e.key);
      if (actual == null) return false;
      final set = (e.value as List?) ?? const [];
      if (!set.any((v) => _scalarEq(actual, v))) return false;
    }
  }
  // `required_keys` — FROZEN-написание обеих сторон (GRAMMAR_SYNC §4 №7).
  // `has_key` — прежнее написание того же предиката: читается, но новые
  // секции его не пишут. Третьего имени у одного предиката не заводится.
  final hasKey = ((j['required_keys'] ?? j['has_key']) as List?)?.cast<String>();
  if (hasKey != null) {
    for (final path in hasKey) {
      if (jsonPathValue(value, path) == null) return false;
    }
  }
  final anyKeys = (j['array_elem_any_keys'] as List?)?.cast<String>();
  if (anyKeys != null) {
    for (final path in anyKeys) {
      if (!_anyElemHas(value, path)) return false;
    }
  }
  final type = j['type'] as String?;
  if (type != null && !_isJsonType(value, type)) return false;

  // `type_of: {<путь>: object|array|string|number}` — ФОРМА значения по
  // пути. Нужна там, где мусорный ТИП поля делает элемент нечитаемым
  // целиком: `streamSettings: "none"` это не «транспорта нет», а битая
  // запись, и собрать из неё рабочий узел без транспорта и TLS значило бы
  // выдать узел, которого провайдер не присылал. Отсутствующий путь условию
  // НЕ противоречит: ключа может не быть вовсе.
  final typeOf = (j['type_of'] as Map?)?.cast<String, dynamic>();
  if (typeOf != null) {
    for (final e in typeOf.entries) {
      final actual = jsonPathValue(value, e.key);
      if (actual == null) continue;
      if (!_isJsonType(actual, '${e.value}')) return false;
    }
  }

  // Комбинаторы — те же, что у текстового предиката: одно выражение обязано
  // читаться одинаково на обоих уровнях (§2 НОРМЫ).
  final any = j['any'];
  if (any is List && any.isNotEmpty) {
    var hit = false;
    for (final sub in any) {
      if (sub is! Map) continue;
      if (detectMatchesJson(sub.cast<String, dynamic>(), value)) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  final all = j['all'];
  if (all is List) {
    for (final sub in all) {
      if (sub is! Map) continue;
      if (!detectMatchesJson(sub.cast<String, dynamic>(), value)) return false;
    }
  }
  final not = j['not'];
  if (not is Map && detectMatchesJson(not.cast<String, dynamic>(), value)) {
    return false;
  }
  return true;
}

bool _isJsonType(dynamic value, String type) => switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'number' => value is num,
      _ => false,
    };

/// `[].outbounds[].protocol` — хотя бы у одного элемента каждого названного
/// массива есть остаток пути.
///
/// Массивов в пути бывает НЕСКОЛЬКО (массив конфигов, у каждого свой
/// `outbounds`), поэтому обход рекурсивный. Пустой путь слева от `[]`
/// означает «сам корень — массив».
bool _anyElemHas(dynamic root, String path) {
  final marker = path.indexOf('[]');
  if (marker < 0) return jsonPathValue(root, path) != null;
  final arrayPath = path.substring(0, marker);
  final rest = path.substring(marker + 2).replaceFirst(RegExp(r'^\.'), '');
  final arr = arrayPath.isEmpty ? root : jsonPathValue(root, arrayPath);
  if (arr is! List) return false;
  for (final el in arr) {
    if (rest.isEmpty) return true;
    if (_anyElemHas(el, rest)) return true;
  }
  return false;
}

bool _scalarEq(dynamic actual, dynamic expected) {
  if (actual is bool || expected is bool) return actual == expected;
  if (actual is num && expected is num) return actual == expected;
  return actual.toString() == expected.toString();
}

/// Значение по точечному пути; числовой сегмент индексирует массив.
///
/// Массив НЕ приводится к строке (§4 НОРМЫ): запись, которой нужен не
/// скаляр, берёт значение как есть (`list`, `coerce`, `flatten`). Склейка
/// массива в строку — источник живого дефекта у Go (Q133-16).
dynamic jsonPathValue(dynamic root, String path) {
  dynamic cur = root;
  for (final seg in path.split('.')) {
    if (seg.isEmpty) continue;
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

/// Нормализаторы, работающие над СПИСКОМ: применяются после разреза значения
/// по `list.sep`, а не над исходной строкой.
const Set<String> _kListNormalizers = {'port_range_spec', 'cidr_prefix'};

/// Беззнаковое целое: у диапазонных полей знака не бывает, а `int.tryParse`
/// принял бы `-5` числом.
final RegExp _kUintRe = RegExp(r'^\d+$');

/// ПЛАН СЕКЦИИ — то, что не зависит от узла и потому считается ОДИН РАЗ.
///
/// Рекомендация НОРМЫ («предкомпиляция при загрузке, а не интерпретация на
/// лету») и главная статья цены слоя: раскладка записей на проходы A/B и
/// сортировка по `priority` считались на КАЖДОМ узле, хотя секция между
/// узлами не меняется. На подписке в 2000 узлов это 2000 одинаковых сортировок
/// одного и того же списка.
///
/// План кэшируется по ЭКЗЕМПЛЯРУ секции ([_planCache]): загрузчик отдаёт один
/// и тот же объект, пока реестр не перезагрузили, а перезагрузка даёт новый
/// экземпляр — и новый план вместе с ним, без ручной инвалидации. Ключ —
/// сама секция, а не её имя: два плана для одной секции разошлись бы молча.
final class _SectionPlan {
  _SectionPlan(MapperSection section)
      : selectors = _pass(section, selector: true),
        dependents = _pass(section, selector: false),
        declared = _declaredOf(section);

  /// Записи прохода A (`selector: true`) в нормативном порядке.
  final List<MapperParam> selectors;

  /// Записи прохода B — все остальные, в том же порядке.
  final List<MapperParam> dependents;

  /// Оба прохода подряд: стадии после них (`default_from`, `required`) идут
  /// по ВСЕМ записям в том же нормативном порядке.
  late final List<MapperParam> all = [...selectors, ...dependents];

  /// Все написания, ОБЪЯВЛЕННЫЕ таблицей: имя записи, её `aliases` и имена в
  /// `source` (`query.<имя>`).
  ///
  /// Считается по таблице, а не по факту чтения (норма §8): запись,
  /// не применившаяся по `when`, объявленной быть не перестаёт. Иначе `eh=`
  /// без `ed=` и любой параметр чужого транспорта давали бы info о
  /// «неизвестном параметре» на ровном месте — а это ровно то молчание
  /// наоборот, ради которого затеяна кампания.
  final Set<String> declared;

  /// Стабильная сортировка по `priority` с индексом ОБЪЯВЛЕНИЯ как
  /// тай-брейком (норма §7: порядок объявления нормативен).
  static List<MapperParam> _pass(MapperSection s, {required bool selector}) {
    final all = s.params.values.toList();
    // Индекс объявления — по МЕСТУ в таблице, а не по ИМЕНИ записи: имя у
    // записи короткое (`path`), и одноимённых в секции столько, сколько
    // транспортов её включили (`ws.path`, `http.path`, `xhttp.path`). Пока
    // индекс считался по имени, все они получали позицию ПОСЛЕДНЕЙ, и
    // порядок объявления — нормативный по §7 — рассыпался: запись с
    // уникальным именем обгоняла ту, от которой зависела. Живой случай:
    // плоское поле early data исполнялось раньше записи пути, чей хвост
    // обязан был его перебить, и хвост молча проигрывал (§320).
    final picked = [
      for (var i = 0; i < all.length; i++)
        if (all[i].selector == selector) i,
    ];
    picked.sort((a, b) {
      final pa = all[a].priority ?? 0;
      final pb = all[b].priority ?? 0;
      if (pa != pb) return pa.compareTo(pb);
      return a.compareTo(b);
    });
    return [for (final i in picked) all[i]];
  }

  static Set<String> _declaredOf(MapperSection s) {
    final out = <String>{};
    for (final p in s.params.values) {
      for (final sp in p.spellings) {
        out.add(sp.toLowerCase());
      }
      // Норма §10.3: имя из `source` объявлено НАРАВНЕ с именем записи —
      // запись читает `query.<name>`, и `<name>` бывает не равно её имени.
      for (final src in [
        ...p.source,
        for (final l in p.sourceByForm.values) ...l,
      ]) {
        if (src.startsWith('query.')) {
          out.add(src.substring('query.'.length).toLowerCase());
        }
      }
    }
    return out;
  }
}

/// Кэш планов по экземпляру секции. `Expando` — чтобы план жил ровно столько,
/// сколько живёт секция, и не держал её от сборки после перезагрузки реестра.
final Expando<_SectionPlan> _planCache = Expando<_SectionPlan>('mapper plan');

/// Точечный путь, разложенный на сегменты ОДИН РАЗ.
///
/// `_put`/`_read`/`_erase` резали строку на каждом обращении, а путей в
/// секции конечное число и известны они при загрузке. Кэш статический и общий
/// по той же причине, что кэш регулярок: один и тот же путь приходит от
/// разных записей и с каждого узла подписки.
final Map<String, List<String>> _segCache = {};

List<String> _segments(String path) => _segCache[path] ??= path.split('.');

/// Исполнение одной записи: состояние живёт ровно на время разбора.
final class _Run {
  _Run(this.section, this.space, this._trace, {this.nameHint})
      : _plan = _planCache[section] ??= _SectionPlan(section);

  /// План секции: проходы и множество объявленных — посчитаны один раз.
  final _SectionPlan _plan;

  /// Имя, предложенное ВЫЗЫВАЮЩИМ: источник `hint` в `label.source`. В самом
  /// документе его нет, поэтому оно приходит параметром, а МЕСТО его в
  /// цепочке метки остаётся данными.
  final String? nameHint;

  /// Коллектор трассы; `null` — трасса не собирается, и ни одна строка не
  /// строится (приложение «ТРАССА»: коллектор не стоит ничего, когда
  /// выключен).
  final MapperTrace? _trace;

  /// Имя маппера для трассы: `<тип тела>.<вид источника>.<форма>`.
  String get _mapperId =>
      '${section.singboxType}.${section.kind}'
      '${space.formId.isEmpty ? '' : '.${space.formId}'}';

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

  /// Порт по умолчанию, названный `scheme_sets` текущего написания схемы
  /// (служебный ключ `$default_port`). Применяется вместе с `defaults`.
  dynamic _schemeDefaultPort;

  /// `on_no_match: {action: drop_node}` — узла нет вовсе. Отличается от
  /// «тело пустое»: секция сказала, что такой записи у нас нет Spec'а.
  bool _dropNode = false;

  /// Наложенные слои по имени: `extra` → плоская карта ключей слоя.
  final Map<String, QueryPairs> _overlays = {};

  /// `flatten` (FROZEN, P15): вложенный объект, поднятый в СВОЙ слой.
  ///
  /// Слой кладётся в [_overlays] под именем, которое `flatten` и назвал
  /// (`extra`, `xmux`), и дальше читается обычным `source` с этим
  /// префиксом. Отдельный слой, а не правка документа на месте (как у Go),
  /// по двум причинам:
  ///
  /// 1. документ элемента едет дальше как `rawSource` узла — исходник
  ///    провайдера байт в байт, — и дописать в него ключи значило бы
  ///    показать человеку не то, что он прислал;
  /// 2. и главное: кто из двух написаний побеждает, обязана решать САМА
  ///    ЗАПИСЬ порядком своих источников (PRIMITIVES §0.9). У xhttp это
  ///    решение РАЗНОЕ: у обычных полей сильнее вложенный слой (SPEC 002
  ///    §1.5), а у базовой тройки `mode`/`path`/`host` — плоский, причём
  ///    даже будучи пустым (D-097: `SplitHTTPConfig.Build` безусловно
  ///    затирает `extra` внешними значениями). Подъём «в плоский слой»
  ///    принял бы это решение за запись и одинаково для всех ключей.
  ///
  /// Пустое значение слоя = «слой промолчал» (правило `empty: absent`
  /// движка), поэтому непустое плоское поле переживает пустое одноимённое
  /// в слое — §410, регрессия v2.21.0.
  final Set<String> _flattened = {};

  /// [inputCodes] — коды, которые поставил САМ РАЗБОР входа, а не запись
  /// таблицы: у INI это «вторая `[Peer]` отброшена». Ни одна запись о них не
  /// узнает — ключи отброшенной секции до пространства не доехали вовсе.
  EngineResult? execute({List<String> inputCodes = const []}) {
    // §480 — ПЕРВАЯ СТРОКА ТРАССЫ: какая секция и какая ФОРМА взяли элемент.
    //
    // Пишется здесь, а не у каждого входа, потому что вход у движка не один:
    // ссылка, объект и текст INI сходятся в этом методе, и строка «что
    // опознано» обязана быть у всех трёх одинаковой — иначе механическая
    // сверка Go↔Dart ловила бы ложное расхождение на самом первом событии.
    // Форма названа `val`, потому что именно её выбрал `detect`: у входа с
    // несколькими формами это и есть первое решение движка.
    _trace?.add(
      stage: TraceStage.elemDetect,
      mapper: _mapperId,
      entry: r'$form',
      src: section.kind,
      val: space.formId,
      act: TraceAct.keep,
    );
    for (final code in inputCodes) {
      warnings.add(NodeWarning.byCode(code, path: '', value: ''));
    }
    body['type'] = section.singboxType;

    // Слои (`overlays[]`) строятся ДО записей: запись адресует их обычным
    // `source` с префиксом имени, и к моменту её исполнения слой обязан быть.
    _buildOverlays();

    // 1. `scheme_sets` — написание схемы НЕСЁТ ТЕЛО: у части схем цифра или
    // суффикс в написании это дискриминатор версии либо транспорта, а не
    // алиас, и присваивания берутся прямо из него.
    // Ключ `"*"` — присваивания, общие для ВСЕХ написаний схемы. Нужен там,
    // где свойство безусловно и источника у него не будет вовсе: у QUIC-схем
    // TLS включён всегда, параметра `security` в ссылке нет, и выразить это
    // записью нечем. Общий набор кладётся ПЕРВЫМ, чтобы присваивания
    // конкретного написания могли его переопределить.
    final schemeAll = section.schemeSets['*'];
    if (schemeAll is Map) _applySets(schemeAll.cast<String, dynamic>(), null);

    final schemeSet = _lookupFold(section.schemeSets, space.scheme);
    if (schemeSet is Map) _applySets(schemeSet.cast<String, dynamic>(), null);

    // Адрес НЕ подставляется движком: секция объявляет его записями
    // (`server` ← `host`, `server_port` ← `port`) наравне с прочими. Иначе у
    // схем, где адрес лежит не в authority (endpoint-схемы, json-формы),
    // пришлось бы заводить исключение в коде.

    // 3. userinfo (P2).
    if (!_applyUserinfo()) return null;

    // 4–5. Два прохода: сперва селекторы, потом зависимые.
    for (final p in _plan.selectors) {
      _applyParam(p);
      if (_dropNode) return null;
    }
    for (final p in _plan.dependents) {
      _applyParam(p);
      if (_dropNode) return null;
    }

    // 6. Заполнение пустоты объявленными источниками.
    for (final p in _plan.all) {
      _applyDefaults(p);
    }

    // 6b. `defaults` СЕКЦИИ — норма §10.1: после ОБОИХ проходов и только в
    // путь, который никто не занял. Ни `priority`, ни `merge` к ним не
    // применяются: они не участвуют в конкуренции, а заполняют оставшееся.
    //
    // Порядок важен: напиши дефолтный порт раньше записей — он победил бы
    // явный порт из ссылки, потому что пишется первым. Формулировка «после
    // проходов, только в пустое» предпочтительнее «с очень большим
    // priority»: она не зависит от выбора магического числа и не ломается,
    // если запись объявит `merge: overwrite`.
    for (final e in section.defaults.entries) {
      // `$`-ключ — служебная запись (проза `impl` рядом со значением), а не
      // путь тела: то же соглашение, что у `$`-записей таблицы.
      if (e.key.startsWith(DraftNames.serviceParamPrefix)) continue;
      if (_read(e.key) != null) {
        _trace?.add(
          stage: TraceStage.defaults,
          mapper: _mapperId,
          entry: r'$defaults',
          val: e.value,
          path: e.key,
          act: TraceAct.skip,
          why: TraceWhy.byDefault,
        );
        continue;
      }
      _put(e.key, e.value);
      _trace?.add(
        stage: TraceStage.defaults,
        mapper: _mapperId,
        entry: r'$defaults',
        val: e.value,
        path: e.key,
        act: TraceAct.write,
        why: TraceWhy.byDefault,
      );
    }
    // `$default_port` написания схемы — там же и по тому же правилу; он
    // сильнее `defaults` секции только потому, что конкретнее: секция одна на
    // все написания, а он назван для одного.
    if (_schemeDefaultPort != null && _read('server_port') == null) {
      _put('server_port', _schemeDefaultPort);
    }

    // Обязательные записи: их отсутствие — это «узла нет».
    for (final p in _plan.all) {
      if (!p.required) continue;
      // Пути, которые запись обязана наполнить. Обычно один (`maps_to`), но у
      // записи со `split_into` целевых путей несколько, и `maps_to` у неё
      // может не быть вовсе: «адрес обязателен» значит «хоть одно семейство
      // доехало», а не «оба».
      final paths = p.splitInto.isNotEmpty
          ? p.splitInto.keys.toList()
          : (p.mapsTo == null ? const <String>[] : [p.mapsTo!]);
      if (paths.isEmpty) continue;
      final any = paths.any((path) {
        final v = _read(path);
        return v != null && !(v is String && v.isEmpty);
      });
      if (!any) return null;
    }

    // 7. Неизвестные параметры источника.
    _reportUnknown();

    final label = _label();
    _trace?.add(
      stage: TraceStage.label,
      mapper: _mapperId,
      entry: r'$label',
      val: label,
      act: label.isEmpty ? TraceAct.skip : TraceAct.write,
      why: label.isEmpty ? TraceWhy.empty : TraceWhy.none,
    );

    // Последняя строка трассы — итог: тело (ключи в том порядке, в каком их
    // положил движок), метка и вход. По ней сверка видит не только КАК
    // получилось, но и ЧТО получилось.
    _trace?.add(
      stage: TraceStage.result,
      mapper: _mapperId,
      entry: r'$result',
      val: {
        'body': body,
        'label': label,
        'body_source': section.bodySource,
      },
      act: TraceAct.keep,
    );

    return EngineResult(
      body: body,
      label: label,
      warnings: warnings,
      extensionFields: extensionFields,
      wsEarlyDataHeaderImplicit: _wsEarlyDataHeaderImplicit,
      tagScheme: section.label.fallbackScheme,
      bodySource: section.bodySource,
      tagAddress: _tagAddress(),
      kinds: _kinds(),
    );
  }

  /// Рода узла, объявленные ВХОДОМ (`kind_when`, G1).
  ///
  /// Предикат судится по источникам, а не по телу: вход мог попросить подвид
  /// протокола и не донести ни одного годного поля — тело такого узла от
  /// базового неотличимо, а правило рода от этого не отменяется.
  Set<String> _kinds() {
    if (section.kindWhen.isEmpty) return const {};
    final out = <String>{};
    for (final e in section.kindWhen.entries) {
      final cond = (e.value as Map?)?.cast<String, dynamic>();
      if (cond != null && _whenHolds(cond)) out.add(e.key);
    }
    return out;
  }

  /// Адрес для тега-фолбэка, когда он лежит НЕ в корне тела.
  ///
  /// `null` — адрес там, где его ищут по умолчанию (`server`/`server_port`),
  /// и вызывающему подсказывать нечего.
  (String, int)? _tagAddress() {
    final sPath = section.label.fallbackServerPath;
    if (sPath == null) return null;
    final server = _read(sPath);
    if (server == null) return null;
    final pPath = section.label.fallbackPortPath;
    final port = pPath == null ? null : _read(pPath);
    return ('$server', port is num ? port.toInt() : 0);
  }

  /// Записи в порядке исполнения: `priority` (меньше = раньше), при равенстве
  /// — порядок объявления в секции (G3, FROZEN).

  /// Построить наложенные пространства (FROZEN `overlays[]`).
  ///
  /// Текст слоя достаётся объявленным `source`, проходит объявленный
  /// `decode`, разбирается как JSON-объект (вложенный слой чужого диалекта
  /// им и является) и укладывается плоско. `flatten` поднимает члены
  /// названных вложенных объектов на тот же уровень.
  ///
  /// Слой НЕ сливается с query: кто из двух побеждает, решает сама запись
  /// порядком своих источников — у части полей сильнее слой, у части плоский
  /// слой, причём даже будучи пустым.
  void _buildOverlays() {
    for (final o in section.overlays) {
      if (o.name.isEmpty) continue;
      String? text;
      for (final src in o.source) {
        final v = _readSourceBare(src);
        if (v is String && v.isNotEmpty) {
          text = v;
          break;
        }
      }
      if (text == null) continue;
      for (final step in o.decode) {
        switch (step) {
          case 'percent':
            text = percentDecodeOnce(text!, mode: DecodeMode.query);
          case 'base64':
          case 'base64?':
            final decoded = _tryBase64(text!);
            if (decoded != null) {
              text = decoded;
            } else if (step == 'base64') {
              text = null;
            }
        }
        if (text == null) break;
      }
      if (text == null) continue;
      Object? parsed;
      try {
        parsed = jsonDecode(text);
      } catch (_) {
        continue;
      }
      if (parsed is! Map) continue;

      final pairs = <(String, String)>[];
      void put(String k, Object? v) {
        if (v == null || v is Map || v is List) return;
        pairs.add((k, '$v'));
      }

      for (final e in parsed.cast<String, dynamic>().entries) {
        if (o.flatten.contains(e.key) && e.value is Map) {
          for (final f in (e.value as Map).cast<String, dynamic>().entries) {
            put(f.key, f.value);
          }
        } else {
          put(e.key, e.value);
        }
      }
      _overlays[o.name] = QueryPairs(pairs);
    }
  }

  /// `flatten` (FROZEN, P15): поднять члены названных вложенных объектов на
  /// уровень объекта-хозяина.
  ///
  /// Хозяин ищется по ЦЕПОЧКЕ источников записи — первый найденный объект и
  /// побеждает: один и тот же вложенный слой чужой диалект пишет под разными
  /// именами (`xhttpSettings` ∥ `splithttpSettings`), и запись объявляет оба
  /// написания обычным списком, а не двумя копиями таблицы.
  ///
  /// Поднятое кладётся в ОТДЕЛЬНЫЙ слой [_jsonLifted] под полным путём: у
  /// документа он читается вторым, поэтому существующий ключ хозяина
  /// поднятым не перекрывается (D-097).
  void _applyFlatten(MapperParam p) {
    for (final src in _sourcesOf(p)) {
      if (!src.startsWith('json.')) continue;
      final path = _resolveBase(src.substring('json.'.length));
      final owner = jsonPathValue(space.json, path);
      if (owner is! Map) continue;
      for (final name in p.flatten) {
        if (!_flattened.add(name)) continue;
        // Имя ищется у хозяина, а если его там нет — в УЖЕ поднятом слое:
        // у xhttp `xmux` лежит ВНУТРИ `extra`, и до подъёма `extra` такого
        // ключа у хозяина нет вовсе. Порядок имён в `flatten` поэтому
        // нормативен — ровно как у Go, где второе имя ищется в уже
        // правленом объекте.
        // Объект слоя бывает в ДВУХ местах разом: `xmux` лежит и у хозяина,
        // и внутри `extra`. Порядок тот же, что у прочих полей: сперва
        // вложенный слой, потом плоский, и решает его первое непустое
        // значение — слой это набор пар, а не один ключ.
        final sources = <Map>[
          if (_overlayRaw[name] is Map) _overlayRaw[name]! as Map,
          if (owner[name] is Map) owner[name] as Map,
        ];
        if (sources.isEmpty) continue;
        final pairs = <(String, String)>[];
        for (final inner in sources) {
          for (final e in inner.cast<String, dynamic>().entries) {
            final v = e.value;
            if (v == null) continue;
            if (v is Map || v is List) {
              // Вложенный объект слоя сам может быть назван в `flatten`
              // следующим именем — значение придерживается для него.
              _overlayRaw.putIfAbsent(e.key, () => v);
              continue;
            }
            pairs.add((e.key, _scalar(v)));
          }
        }
        // Пустое значение слоя = «слой промолчал»: непустое одноимённое из
        // второго места сильнее. Без этого `extra.xmux.maxConcurrency: ""`
        // затирал бы заданное поле хозяина — §410, регрессия v2.21.0.
        final nonEmpty = {
          for (final p in pairs)
            if (p.$2.trim().isNotEmpty) p.$1.toLowerCase(),
        };
        _overlays[name] = QueryPairs([
          for (final p in pairs)
            if (p.$2.trim().isNotEmpty || !nonEmpty.contains(p.$1.toLowerCase()))
              p,
        ]);
      }
      // Хозяин найден — прочие написания того же слоя не разбираются:
      // цепочка источников это «первый непустой», а не «все сразу».
      return;
    }
  }

  /// Вложенные объекты, встреченные внутри слоя: следующее имя `flatten`
  /// ищет свой объект и здесь (`extra.xmux`).
  final Map<String, dynamic> _overlayRaw = {};

  /// Скаляр слоя строкой. Числа печатаются БЕЗ экспоненты и без хвоста
  /// `.0` (PRIMITIVES §0.9): `30.0` в JSON означает то же, что `30`, а
  /// `1e+06` в теле — мусор.
  static String _scalar(Object v) {
    if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return '$v';
  }

  /// Источники записи для текущей формы, плоско.
  Iterable<String> _sourcesOf(MapperParam p) =>
      p.sourceByForm[space.formId] ?? p.source;

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

    if (raw.isEmpty) {
      // `required` у userinfo судит ОБОЛОЧКУ: ссылка без него — не узел этой
      // схемы. Объявлен здесь, а не у записи, потому что поля, которые
      // userinfo наполняет, приходят позициями `into`, и записи под ними у
      // части схем нет вовсе.
      if (u.required) return false;
      if (u.into.isNotEmpty) return true;
    }

    final sep = u.splitSep;
    if (sep == null || !raw.contains(sep)) {
      // Разделителя нет: значение целиком идёт в ОДНО поле, и поле это
      // называет `single_into` — ЯВНО, записью в секции.
      //
      // Неявное правило «одинокий userinfo → первое имя `into`» сведение
      // грамматики отвергло (GRAMMAR_SYNC §1 №15, 19.09.2026): оно верно не
      // для всех диалектов и молча даёт неверный ответ там, где конвенция
      // протокола другая — у одной из схем `into` перечисляет имя и пароль, а
      // одинокий userinfo означает именно ПАРОЛЬ, то есть ВТОРОЕ имя. Поэтому
      // секции ОБЪЯВЛЯЮТ поле сами, и черновики волны это уже делают.
      //
      // Умолчание СНЯТО (контракт 1.1.25): лаунчер проставил `single_into`
      // всем 14 секциям с `userinfo`, включая те, где оно совпадает с
      // `into[0]`, и завёл линтер на явное написание. Разница между
      // «совпало» и «никто не смотрел» видна только в тексте секции, и
      // догадка здесь её бы снова стёрла. Секция без `single_into` теперь
      // одинокий userinfo НЕ читает вовсе — это красное, а не тихий разбор
      // в поле, которое никто не называл.
      //
      // `userinfo.pass` пространства источников заполняется только когда
      // значение действительно уехало в ПОСЛЕДНЕЕ имя: иначе запись с
      // `source: "userinfo.pass"` прочитала бы первый компонент.
      final single = u.singleInto;
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
    if (!_whenHolds(p.when)) {
      _trace?.add(
        stage: TraceStage.field,
        mapper: _mapperId,
        entry: p.name,
        src: p.source.isEmpty ? '-' : p.source.first,
        path: p.mapsTo,
        act: TraceAct.skip,
        why: TraceWhy.whenFalse,
      );
      // `on_when_false` — значение во входе БЫЛО, но структурное правило не
      // дало ему доехать до тела. Спрашиваем источник ТОЛЬКО ради кода и
      // только когда запись его назвала: иначе запись, чьё условие ложно на
      // каждом втором узле, шумела бы впустую. Чтение — без отметки
      // «прочитано» (§10.2): подавленный параметр остаётся тем, чем был.
      final code = p.onWhenFalse['code'] as String?;
      if (code != null) {
        final probe = _valueOfBare(p);
        if (probe != null && !(probe is String && probe.isEmpty)) {
          warnings.add(NodeWarning.byCode(code,
              path: p.name, value: probe is String ? probe.trim() : '$probe'));
        }
      }
      return;
    }

    // `flatten` (FROZEN, P15) — члены названных вложенных объектов
    // поднимаются на уровень объекта-хозяина, и дальше их читают ОБЫЧНЫЕ
    // записи своим `source`. Исполняется до чтения значения самой записи:
    // у служебной записи (`$`-префикс) вся работа в этом и состоит, своего
    // `maps_to` у неё нет.
    if (p.flatten.isNotEmpty) _applyFlatten(p);

    var raw = _valueOf(p);
    if (raw == null) {
      // `default_when: {absent: true, value: …}` — «не сказано» ЕСТЬ
      // значение, и дальше запись исполняется как обычная. Без этого
      // селектор рода узла (`version` у форка Xray, где 2 подразумевается)
      // не отработал бы на конфиге, который версии не пишет вовсе.
      if (p.defaultWhen['absent'] == true && p.defaultWhen['value'] != null) {
        raw = p.defaultWhen['value'];
      } else {
        // Параметра нет. `implies` не срабатывает (он от НАЛИЧИЯ), `sets` — у
        // ключа `""`, если секция его объявила: так выражается «пусто тоже
        // значение» (`security` без параметра включает TLS).
        final absentSet = p.sets[''];
        if (absentSet is Map && p.sets.containsKey('')) {
          _applySets(absentSet.cast<String, dynamic>(), p);
        }
        return;
      }
    }

    // `on_len_gt` — у источника-МАССИВА больше `n` элементов. Лишние
    // отбрасываются и сегодня (Q133-18), но молча; запись даёт коду место,
    // не трогая поведения.
    if (p.onLenGt.isNotEmpty && raw is List) {
      final n = (p.onLenGt['n'] as num?)?.toInt() ?? 1;
      final code = p.onLenGt['code'] as String?;
      if (raw.length > n && code != null) {
        warnings.add(NodeWarning.byCode(code, path: p.name, value: '${raw.length}'));
      }
      // Служебная запись массива в тело не едет: она только считает.
      if (p.mapsToPresent && p.mapsTo == null) return;
    }

    var value = raw;

    // `on_invalid.action: "default_from"` — значение ЕСТЬ, но не годится как
    // источник, и запись обязана вести себя так, будто его не было: дальше
    // сработает её же `default_from`.
    //
    // Это НЕ суждение о значении (его судит санитайзер), а выбор ИСТОЧНИКА:
    // предикат смотрит на написание, а не на смысл. Так эвристика SNI
    // («имя без точки и двоеточия адресом быть не может») перестаёт быть
    // веткой в коде и становится строкой таблицы — причём только у тех схем,
    // которые её объявили.
    if (p.onInvalid['action'] == 'default_from' && value is String) {
      final cond = (p.onInvalid['when'] as Map?)?.cast<String, dynamic>();
      final probe = cond == null ? null : cond['value'];
      if (probe != null && _matches(value, probe)) return;
    }

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
    //
    // Скалярные применяются здесь, над строкой. Списочные
    // (`port_range_spec`, `cidr_prefix`) — ПОСЛЕ `_coerceType`, когда список
    // уже разрезан: до него значение ещё одна строка с разделителями.
    // `range_order` меняет и ТИП значения (`"5"` → 5), поэтому идёт мимо
    // строкового [_normalize].
    final norm = p.normalize;
    if (norm != null && value is String) {
      if (norm.startsWith('range_order')) {
        final swap = norm.endsWith('swap');
        value = _normalizeRange(value, swap: swap);
        if (value == null) {
          _applyOnInvalid(p, raw is String ? raw : '$raw');
          return;
        }
      } else if (!_kListNormalizers.contains(norm)) {
        value = _normalize(value, norm);
      }
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
          ? _mapValue(p.valueMap, value,
              caseSensitive: p.valueMapCase == 'sensitive')
          : (matched: false, value: value);
      if (!(off.matched && off.value == null)) {
        _applyOnPresent(p, value is String ? value : '$value');
      }
      _applyImplies(p);
      return;
    }

    // `extract` ПО ЭЛЕМЕНТАМ списка с группами `$key`/`$value` — объект
    // произвольной формы (заголовки).
    //
    // Отдельного примитива под заголовки нет намеренно: пара «имя: значение»
    // выражается той же регуляркой, что и всякая другая раскладка, а
    // `list.sep` говорит, чем элементы разделены. Ключи объекта задаёт сам
    // источник, поэтому перечислить их в `into` нельзя — их называют
    // служебные имена групп `$key` и `$value`.
    if (p.extract != null &&
        p.list != null &&
        p.type == 'object' &&
        value is String) {
      _applyExtractItems(p, value);
      return;
    }

    // `extract` — одно значение по нескольким путям.
    if (p.extract != null && value is String) {
      _applyExtract(p, value);
      return;
    }


    // `value_map` — перевод значений диалекта. `null` = «ключа нет».
    if (p.valueMap.isNotEmpty && value is String) {
      final mapped = _mapValue(p.valueMap, value,
          caseSensitive: p.valueMapCase == 'sensitive');
      if (mapped.matched) {
        if (mapped.value == null) {
          // Значение переведено в «ключа нет»: `sets` того же значения при
          // этом ОСТАЁТСЯ в силе (у `flow` так и устроено).
          _applyValueSets(p, value);
          _applyImplies(p);
          return;
        }
        value = mapped.value;
      } else if (p.sets.isEmpty && p.onNoMatch.isNotEmpty) {
        // Значение не попало ни в одно написание таблицы. У записи БЕЗ `sets`
        // (там `on_no_match` уже занят, см. ниже) это «мусор»: закрытый набор
        // написаний тем и отличается от свободного значения, что всё вне его —
        // ошибка автора ссылки, и молчать о ней нельзя.
        if (p.onNoMatch['action'] == 'drop_node') return;
        _applyOnNoMatch(p, value);
        _applyImplies(p);
        return;
      }
    }

    // `sets` по значению — набор присваиваний вместо/вместе с `maps_to`.
    final hadSets = _applyValueSets(p, raw is String ? raw : '$raw');

    // `on_no_match` — значение не попало ни в один ключ `sets`. У селектора
    // рода записи (`version` у форка Xray) это «узла нет»: своего Spec для
    // другого значения у нас не существует.
    if (!hadSets && p.sets.isNotEmpty && p.onNoMatch.isNotEmpty) {
      if (p.onNoMatch['action'] == 'drop_node') {
        _dropNode = true;
        return;
      }
    }

    // Приведение типа (`type`) — форма, а не суждение.
    var typed = _coerceType(p, value);

    // `list.item: "int"`, а разрез числами не стал — ВТОРАЯ ФОРМА записи того
    // же списка: байты в base64. Так WARP пишет `client_id` (три байта), а наш
    // round-trip — десятичной тройкой; тело у обеих форм одно.
    //
    // Проверяется ДО отказа по `null`: у второй формы первый разрез не даёт
    // ничего, и ранний выход съел бы её молча. Это разбор ФОРМЫ, а не
    // суждение — длину списка и границы байтов судит санитайзер по `len` и
    // `format` поля.
    final lspec = p.list;
    if (lspec != null && lspec.item == 'int' && raw is String) {
      final gotInts = typed is List && typed.isNotEmpty;
      if (!gotInts) {
        final bytes = _RunDecode.bytes(raw.trim());
        if (bytes != null && bytes.isNotEmpty) typed = bytes;
      }
    }

    if (typed == null) {
      // `on_invalid.action: "keep"` — значение к объявленной форме не
      // приводится, и запись ПРОСИТ пропустить его в тело КАК ПРИШЛО.
      // Снять его здесь значило бы судить: годность («неотрицательное целое»)
      // объявлена у поля тела своим `on_invalid` с кодом, и санитайзер
      // отбракует значение сам, назвав причину. Молчаливое снятие в маппере
      // лишило бы узел и значения, и объяснения.
      if (p.onInvalid['action'] == 'keep') {
        typed = value;
      } else {
        _applyOnInvalid(p, raw is String ? raw : '$raw');
        _applyImplies(p);
        return;
      }
    }

    // Списочные нормализаторы — над уже разрезанным списком.
    if (norm != null && _kListNormalizers.contains(norm) && typed is List) {
      typed = _normalizeList(typed, norm);
    }


    // `split_into` — один список РАЗБРАСЫВАЕТСЯ по нескольким путям по
    // предикату на элементе: ядро держит адреса туннеля двумя отдельными
    // полями, по одному на семейство, а ссылка пишет их одним списком.
    // `maps_to` у такой записи может не быть вовсе — целевые пути называет
    // сам `split_into`.
    if (p.splitInto.isNotEmpty && typed is List) {
      _applySplitInto(p, typed);
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
    // `on_implies_written` — код за то, что `implies` И ВПРАВДУ дописал
    // значение, которого во входе не было. Это не то же, что «у записи есть
    // implies»: при занятом пути присваивание проигрывает владельцу, и
    // сообщать не о чем. Поэтому смотрим на тело ДО и ПОСЛЕ, а не на факт
    // вызова.
    final code = p.onImpliesWritten['code'] as String?;
    final before = code == null
        ? null
        : {for (final k in p.implies.keys) k: _read(k)};
    _applySets(p.implies, p);
    if (code != null) {
      for (final e in before!.entries) {
        final now = _read(e.key);
        if (now != null && now != e.value) {
          warnings.add(NodeWarning.byCode(code, path: e.key, value: '$now'));
          break;
        }
      }
    }
    if (p.implicit) _wsEarlyDataHeaderImplicit = true;
  }

  /// Присваивания из `sets`/`implies`/`scheme_sets`.
  ///
  /// **G2 (FROZEN): `null` в присваивании СНИМАЕТ путь.** Это не то же, что
  /// «не писать»: флаг «не отправлять SNI» обязан УБРАТЬ уже поставленное
  /// имя сервера, а не промолчать.
  void _applySets(Map<String, dynamic> sets, MapperParam? p) {
    for (final e in sets.entries) {
      // `$default_port` — СЛУЖЕБНЫЙ ключ `scheme_sets`: телом он не является,
      // а называет порт по умолчанию для ЭТОГО написания схемы (у одной схемы
      // их бывает несколько, и дефолт у них разный). Поэтому он и не может
      // лежать в `defaults` секции — та одна на все написания.
      //
      // Применяется НЕ здесь, а вместе с `defaults` (норма §10.1): после
      // обоих проходов и только в путь, который никто не занял. Напиши его
      // сразу — он победил бы явный порт из ссылки, потому что `scheme_sets`
      // исполняется первым.
      if (e.key == r'$default_port') {
        if (e.value != null) _schemeDefaultPort = e.value;
        continue;
      }
      if (e.value == null) {
        _erase(e.key);
      } else {
        _write(e.key, _substituteServiceValue(e.value), p);
      }
    }
  }

  /// Служебные подстановки в значениях `sets`/`scheme_sets`.
  ///
  /// `$host` — адрес из источника. Нужен там, где присваивание схемы обязано
  /// сослаться на значение, которого в момент записи ещё нет в теле: имя
  /// сервера для TLS у схем, где TLS включает сама схема, а не параметр.
  /// Без подстановки `"$host"` уехал бы в тело литералом.
  Object? _substituteServiceValue(Object? v) {
    if (v is! String) return v;
    switch (v) {
      case r'$host':
        return space.host;
      default:
        return v;
    }
  }

  /// `extract` ПО ЭЛЕМЕНТАМ списка: объект, ключи которого называет источник.
  ///
  /// `list.sep` режет значение на элементы, регулярка раскладывает каждый на
  /// группы, а служебные имена `$key` и `$value` в `into` говорят, какая
  /// группа даёт имя ключа, а какая — его значение. Перечислить такие ключи в
  /// `into` нельзя: их не знает никто, кроме самой ссылки.
  ///
  /// Негодный элемент пропускается, остальные живут (`on_item_invalid`), а
  /// код ставится ОДИН раз на узел — о первом отброшенном.
  void _applyExtractItems(MapperParam p, String value) {
    final spec = p.extract!;
    final re = _regex(spec.re);
    String? keyGroup;
    String? valueGroup;
    for (final e in spec.into.entries) {
      final target = e.value;
      if (target == r'$key') keyGroup = e.key;
      if (target == r'$value') valueGroup = e.key;
    }
    if (keyGroup == null) return;

    final out = <String, dynamic>{};
    var reported = false;
    for (final part in value.split(p.list!.sep)) {
      if (part.trim().isEmpty) continue;
      final m = re.firstMatch(part);
      final k = m?.namedGroup(keyGroup);
      if (m == null || k == null || k.isEmpty) {
        final code = p.onItemInvalid['code'] as String?;
        if (code != null && !reported) {
          reported = true;
          warnings.add(
            NodeWarning.byCode(code, path: p.name, value: part.trim()),
          );
        }
        continue;
      }
      out[k] = valueGroup == null ? '' : (m.namedGroup(valueGroup) ?? '');
    }
    if (out.isEmpty) return;
    // **G4 (`sort_keys`)** — порядок ключей входит в тело, то есть в
    // identity. `_coerceType` здесь не зовётся: у записи объявлен `list`, и
    // он увёл бы готовый объект в списочную ветку — `list` в такой записи
    // говорит лишь, ЧЕМ разделены элементы источника, а формой результата
    // распоряжается `type: object`.
    final result = p.sortKeys
        ? <String, dynamic>{
            for (final k in out.keys.toList()..sort()) k: out[k],
          }
        : out;
    if (p.mapsTo != null) _write(p.mapsTo!, result, p);
    _applyImplies(p);
  }

  void _applyExtract(MapperParam p, String value) {
    final spec = p.extract!;
    final m = _regex(spec.re).firstMatch(value);
    if (m == null) {
      // `on_no_match: {action: take_all}` — регулярка не разложила значение, и
      // объявленный ответ на это «взять его ЦЕЛИКОМ в названный путь», а не
      // потерять. G7: `Endpoint = 2001:db8::1:51820` — голый IPv6, где порт
      // от адреса неотличим (§219), и адресом становится вся строка, а порт
      // берётся из `defaults` той же ветки.
      if (p.onNoMatch['action'] != 'take_all') return;
      final into = p.onNoMatch['into'] as String?;
      if (into == null) return;
      _write(into, value, p);
      final defaults = (p.onNoMatch['defaults'] as Map?)?.cast<String, dynamic>();
      if (defaults != null) {
        for (final e in defaults.entries) {
          if (_read(e.key) == null) _put(e.key, e.value);
        }
      }
      _applyImplies(p);
      return;
    }

    // `on_present` у записи с `extract` — код о том, что значение уехало в
    // тело НЕ буквально. Ставится только когда регулярка действительно
    // что-то разложила сверх первой группы: иначе путь без хвоста получал бы
    // код о преобразовании, которого не было.
    var converted = false;
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
        dynamic typed = t['type'] == 'int' ? int.tryParse(group.trim()) : group;
        if (typed == null) continue;
        // `int` с неположительным значением — это «ed не задан», а не ноль:
        // режим включает только `max_early_data > 0`.
        if (typed is int && typed <= 0) continue;
        // `normalize` у ЧЛЕНА `into`: одна группа регулярки бывает списком со
        // своей формой записи (хвост multi-port `,20000-30000` — это список
        // диапазонов, а не скаляр). Без этого запись пришлось бы дробить на
        // две, и порядок слияния списка стал бы неуправляемым.
        // `prepend_group` — член `into` склеивается с ДРУГОЙ группой той же
        // регулярки. Нужен там, где одно значение источника читается дважды в
        // разной нарезке: первый порт multi-port спецификации едет числом в
        // `server_port`, а ВСЯ спецификация вместе с ним — списком диапазонов
        // в `server_ports`. Без склейки пришлось бы либо дублировать группу в
        // регулярке, либо заводить вторую запись с тем же источником, и
        // порядок слияния списка стал бы неуправляемым.
        final prependFrom = t['prepend_group'] as String?;
        if (prependFrom != null && typed is String) {
          String? head;
          try {
            head = m.namedGroup(prependFrom);
          } catch (_) {
            head = null;
          }
          if (head != null) typed = '$head$typed';
        }
        final memberNorm = t['normalize'] as String?;
        if (memberNorm != null && typed is String) {
          if (_kListNormalizers.contains(memberNorm)) {
            final sep = (t['sep'] as String?) ?? ',';
            typed = _normalizeList(
              typed.split(sep).where((s) => s.trim().isNotEmpty).toList(),
              memberNorm,
            );
            if ((typed as List).isEmpty) continue;
          } else if (memberNorm.startsWith('range_order')) {
            typed = _normalizeRange(typed, swap: memberNorm.endsWith('swap'));
            if (typed == null) continue;
          } else {
            typed = _normalize(typed, memberNorm);
          }
        }
        _write(path, typed, p);
        // Разложилось не только в первую группу — значение уехало в тело не
        // буквально, и это и есть «преобразование».
        converted = true;
        _convertedValue = '$typed';
        // `code` у ЧЛЕНА `into` — код именно за этот разбор, а не за запись
        // целиком: хвост пути разложился по двум полям, и сказать об этом
        // может только тот член, который его поймал. Записи с `on_present`
        // здесь не нужно: путь без хвоста кода не получает.
        _memberCode ??= t['code'] as String?;
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

    if (converted) {
      final mc = _memberCode;
      _memberCode = null;
      if (mc != null) {
        warnings
            .add(NodeWarning.byCode(mc, path: p.name, value: _convertedValue));
      } else {
        _applyOnPresent(p, _convertedValue);
      }
    }
  }

  /// Код, объявленный ЧЛЕНОМ `extract.into` текущего разбора.
  String? _memberCode;


  /// Значение для кода преобразования: то, ЧТО получилось, а не что пришло.
  String _convertedValue = '';

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

  /// `split_into` — разбросать элементы списка по путям тела.
  ///
  /// Ключ — путь тела, значение — `{when: {item: <предикат>}, take: "first"}`.
  /// `take: "first"` берёт первый подошедший элемент, иначе в путь едет весь
  /// подсписок. Предикат смотрит на ЭЛЕМЕНТ, а не на тело: семейство адреса
  /// видно по самому адресу.
  void _applySplitInto(MapperParam p, List<dynamic> items) {
    for (final e in p.splitInto.entries) {
      final spec = (e.value as Map?)?.cast<String, dynamic>();
      if (spec == null) continue;
      final cond = (spec['when'] as Map?)?.cast<String, dynamic>();
      final probe = cond == null ? null : cond['item'];
      final hits = [
        for (final it in items)
          if (probe == null || _matches(it, probe)) it,
      ];
      if (hits.isEmpty) continue;
      _write(e.key, spec['take'] == 'first' ? hits.first : hits, p);
    }
  }

  /// `on_no_match` — значение не нашлось в закрытом наборе написаний.
  void _applyOnNoMatch(MapperParam p, String raw) {
    final code = p.onNoMatch['code'] as String?;
    if (code == null) return;
    warnings.add(NodeWarning.byCode(code, path: p.name, value: raw.trim()));
  }

  /// `on_invalid` — значение не приводится к объявленной форме.
  ///
  /// Само СНЯТИЕ уже случилось (значение не записано); здесь только код, и
  /// только когда запись его назвала. Молчание — не умолчание движка, а
  /// объявленное решение: эталон второй стороны на части полей молчит, и
  /// поставь движок код сам, узел получил бы его там, где корпус ждёт тишины.
  void _applyOnInvalid(MapperParam p, String raw) {
    final code = p.onInvalid['code'] as String?;
    if (code == null) return;
    warnings.add(NodeWarning.byCode(code, path: p.name, value: raw.trim()));
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
      // userinfo percent-декодируется ПО ПРАВИЛАМ ЗАПИСИ, как и query: у поля
      // base64-формата `+` обязан остаться собой. Иначе `%2F`-энкоденный ключ
      // с плюсом внутри терял плюс, а ключ — 32 байта, и узел пропадал.
      case 'userinfo':
        return _decodeQueryValue(space.userinfo, p);
      case 'userinfo.user':
        final u = space.userinfoUser;
        return u == null ? null : _decodeQueryValue(u, p);
      case 'userinfo.pass':
        final pw = space.userinfoPass;
        return pw == null ? null : _decodeQueryValue(pw, p);
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
      final path = _resolveBase(src.substring('json.'.length));
      _consumeJson(path);
      return jsonPathValue(space.json, path);
    }
    if (src.startsWith('ini.')) {
      return space.ini?[src.substring('ini.'.length).toLowerCase()];
    }
    // Наложенный слой: `<имя слоя>.<ключ>`. Значение слоя уже разобрано и
    // декодировано, второй percent-декод ему не нужен.
    final dot = src.indexOf('.');
    if (dot > 0) {
      final layer = _overlays[src.substring(0, dot)];
      if (layer != null) return layer.get(src.substring(dot + 1));
    }
    return null;
  }

  /// Подставить якорь формы: `$base.address` → `settings.vnext.0.address`.
  ///
  /// Форма без `base` оставляет путь как есть — запись в такой секции
  /// адресует документ от корня.
  String _resolveBase(String path) {
    if (!path.contains(DraftNames.baseAnchor)) return path;
    final base = space.jsonBase ?? '';
    final out = path.replaceAll(DraftNames.baseAnchor, base);
    // Пустой якорь оставил бы ведущую точку (`.address`).
    return out.startsWith('.') ? out.substring(1) : out;
  }

  /// Отметить путь ПРОЧИТАННЫМ: верхний сегмент и полный путь.
  ///
  /// Верхний нужен, потому что `json_field_unknown` судит ключи ВЕРХНЕГО
  /// уровня элемента: запись, читающая `settings.vnext.0.address`, объявляет
  /// весь `settings` прочитанным — перечислять каждый лист диалекта значило
  /// бы держать вторую копию схемы входа.
  void _consumeJson(String path) {
    _consumed.add('json.$path'.toLowerCase());
    final dot = path.indexOf('.');
    _consumed.add('json.${dot < 0 ? path : path.substring(0, dot)}'
        .toLowerCase());
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
    // `format: "pem"` (§0.4a, D133-15) — «+» читается ПО-РАЗНОМУ в разных
    // частях одного значения, и одним режимом это не выражается.
    //
    // В теле ключа «+» — данные base64, и пробел там ломает ключ. В строках
    // `-----BEGIN …-----` / `-----END …-----` он, наоборот, кодирует ПРОБЕЛ:
    // слова заголовка разделены им, и литеральный «+» сделал бы заголовок
    // невалидным. Поэтому percent снимается один раз path-семантикой (весь
    // «+» литерален), а потом «+» возвращается пробелом ровно внутри
    // заголовочных строк.
    if (p.format == 'pem') {
      final decoded = percentDecodeOnce(raw, mode: DecodeMode.path);
      return decoded
          .split('\n')
          .map((line) {
            final t = line.trimLeft();
            return t.startsWith('-----') ? line.replaceAll('+', ' ') : line;
          })
          .join('\n');
    }
    return percentDecodeOnce(
      raw,
      mode: p.plusLiteral || pathMode ? DecodeMode.path : DecodeMode.query,
    );
  }

  void _consumeSpelling(String name) {
    _consumed.add(name.toLowerCase());
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
        // `body.<путь>` — дефолт из УЖЕ ПОСТРОЕННОГО тела. Нужен там, где
        // источника у поля нет вовсе: у объектного входа адрес лежит под
        // якорем формы, и общий блок (tls) его пути не знает — знать его
        // значило бы завести в общем блоке запись про конкретный диалект.
        final v = src.startsWith('body.')
            ? _read(src.substring('body.'.length))
            : _readSource(src, p);
        if (v == null) continue;
        if (v is String && v.isEmpty) continue;
        // ФОРМА значения у отката та же, что у самого поля: путь, куда едет
        // список, списком и заполняется. Без этого откат клал бы в него
        // скаляр, и одно и то же поле приезжало разной формы в зависимости
        // от того, назвал его автор ссылки или оно взялось умолчанием.
        _write(path, p.coerceScalarToList && v is! List ? [v] : v, p);
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
      // Третий источник дефолта — `value_map[""]`: «пусто» и «не сказано»
      // диалект называет одним значением, и объявлять его дважды (в
      // `value_map` для пустой строки и ещё раз в `defaults`) значило бы
      // завести два места, которые разъедутся.
      final v = p.defaultWhen['value'] ??
          section.defaults[path] ??
          p.valueMap[''];
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
      // `any_set` — ДИЗЪЮНКЦИЯ по источникам: держится, если ХОТЯ БЫ ОДИН из
      // перечисленных адресов что-то несёт. Имя взято у существующего
      // атрибута реестра (`when.any_set` в правилах тела), чтобы у одного
      // смысла не завелось второго написания; остальные ключи `when`
      // по-прежнему конъюнкция.
      // `$impl` и прочая проза с `$`-префиксом — не предикат, а пояснение
      // рядом с условием (DRAFT-соглашение §0.7: `$` помечает запись, которая
      // в исполнение не идёт). `$type` и `$form` — исключения, они разобраны
      // ниже по именам.
      if (key.startsWith(r'$') && key != r'$type' && key != r'$form') continue;
      if (key == 'any_set') {
        final names = (e.value as List?)?.cast<String>() ?? const <String>[];
        if (!names.any((n) => _readSourceBare(n) != null)) return false;
        continue;
      }
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

  /// Значение записи по её `source`, БЕЗ отметки «прочитано».
  ///
  /// Нужно ровно там, где значение спрашивают ради КОДА, а не ради тела:
  /// запись, подавленная условием, параметр не потребляет, и множество §8 от
  /// такого вопроса меняться не должно (§10.2).
  dynamic _valueOfBare(MapperParam p) {
    final sources = p.sourceByForm.isNotEmpty
        ? (p.sourceByForm[space.formId] ?? const <String>[])
        : p.source;
    for (final src in sources) {
      final v = _readSourceBare(src);
      if (v == null) continue;
      if (v is String && v.isEmpty && p.empty != 'significant') continue;
      return v;
    }
    return null;
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
      // Имя, предложенное вызывающим: источника в документе у него нет, но
      // МЕСТО его в цепочке объявляет секция, как у всякого источника.
      case 'hint':
        return nameHint;
    }
    if (src.startsWith('json.')) {
      return jsonPathValue(
          space.json, _resolveBase(src.substring('json.'.length)));
    }
    if (src.startsWith('ini.')) {
      return space.ini?[src.substring('ini.'.length).toLowerCase()];
    }
    final dot = src.indexOf('.');
    if (dot > 0) {
      final layer = _overlays[src.substring(0, dot)];
      if (layer != null) return layer.get(src.substring(dot + 1));
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
      // Числовое сравнение: диалект, где ЗНАК значения несёт смысл
      // («любое отрицательное = выключено совсем»), выразить набором
      // значений нельзя — их бесконечно много.
      if (m.containsKey('lt') || m.containsKey('gt')) {
        final n = actual is num
            ? actual.toDouble()
            : double.tryParse('${actual ?? ''}'.trim());
        if (n == null) return false;
        final lt = (m['lt'] as num?)?.toDouble();
        final gt = (m['gt'] as num?)?.toDouble();
        if (lt != null && !(n < lt)) return false;
        if (gt != null && !(n > gt)) return false;
        return true;
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
    String value, {
    bool caseSensitive = false,
  }) {
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
    // `value_map_case: "sensitive"` — регистр ЗНАЧИМ. Общее правило обратное
    // (живые списки шлют `NONE`), но там, где ядро сравнивает свой литерал
    // точно, регистронезависимое попадание проглатывало бы негодное значение
    // как «ключа нет» и молча понижало защиту: значение обязано доехать до
    // тела и быть отвергнутым санитайзером.
    if (caseSensitive) return (matched: false, value: value);
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
      // Длительность ГОЛЫМИ СЕКУНДАМИ (`30`→`30s`) объявляется не типом, а
      // нормализатором `duration_bare_seconds` (§0.3): вторым именем для той
      // же операции грамматика не обзаводится (GRAMMAR_SYNC §1 №8). Разница
      // была только в месте объявления — `type` против `normalize`, — и две
      // дороги к одному результату расходятся на первой же схеме.
      case 'bool':
      case 'bool_spelled':
        // Общий набор написаний истины (§4 FROZEN): 1 | true | yes. Одно
        // правило на все булевы параметры всех схем — у лаунчера сегодня их
        // три, и `yes` работает не везде.
        final s = '$value'.trim().toLowerCase();
        final truthy = s == '1' || s == 'true' || s == 'yes';
        // Ложь = «не просили»: ключ не появляется вовсе.
        return truthy ? true : null;
      case 'duration':
        // Форму значения (`30s`, `1m30s`) судит санитайзер по реестру, как и
        // у всех прочих полей: маппер её только переносит.
        return '$value'.trim();
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
      // Любой из четырёх вариантов base64 (std/url-safe × с паддингом и без)
      // приводится к КАНОНУ — std с паддингом.
      //
      // Это нормализация, а не суждение, и снять её нельзя: `…ccC=` и `…ccA=`
      // декодируют в одни и те же байты, но уезжают в конфиг по-разному, то
      // есть одна нода даёт два identity-хеша (D-030). Годность (длину) судит
      // санитайзер по `format` поля, поэтому здесь не проверяется ничего:
      // не-base64 возвращается как пришёл и снимается правилом реестра.
      case 'base64_std':
        final swapped = value.trim().replaceAll('-', '+').replaceAll('_', '/');
        final decoded = _RunDecode.bytes(swapped);
        return decoded == null ? value : _b64.encode(decoded);
      case 'duration_bare_seconds':
        final n = int.tryParse(value.trim());
        return n == null ? value : '${n}s';
      default:
        return value;
    }
  }

  /// Нормализаторы, работающие над СПИСКОМ, а не над скаляром: их результат —
  /// список, и применяются они после [_coerceType].
  ///
  /// Оба — форма записи, не суждение: негодные значения уезжают в карту и
  /// судятся санитайзером.
  static List<dynamic> _normalizeList(List<dynamic> items, String name) {
    switch (name) {
      // `"1000-2000"` → `"1000:2000"`, одиночный порт → пара `"N:N"`. Ядру
      // нужно ДВОЕТОЧИЕ: дефис даёт фатал «bad port range».
      case 'port_range_spec':
        return [
          for (final raw in items)
            if ('$raw'.trim().isNotEmpty)
              () {
                final seg = '$raw'.trim().replaceAll('-', ':');
                return seg.contains(':') ? seg : '$seg:$seg';
              }(),
        ];
      // Голый адрес получает префикс: `/32` у v4, `/128` у v6.
      case 'cidr_prefix':
        return [
          for (final raw in items)
            if ('$raw'.trim().isNotEmpty)
              () {
                final a = '$raw'.trim();
                if (a.contains('/')) return a;
                return a.contains(':') ? '$a/128' : '$a/32';
              }(),
        ];
      default:
        return items;
    }
  }

  /// Пара `N-M`: `swap` переставляет перевёрнутые границы, `strict` оставляет
  /// как есть. Одиночное число возвращается числом (type-fidelity).
  ///
  /// Два режима у одного нормализатора, потому что смысл у диапазонов разный:
  /// magic headers — та же пара в другом написании (без нормализации одна нода
  /// даёт два identity-хеша), а перевёрнутый тайминг — опечатка, которую
  /// человек должен увидеть.
  static dynamic _normalizeRange(String value, {required bool swap}) {
    final v = value.trim();
    if (v.isEmpty) return null;
    // Только цифры: знака у этих полей не бывает, а `int.tryParse` принял бы
    // `-5` числом, и отрицательное значение уехало бы в тело — там его снял бы
    // санитайзер, но уже ОБЩИМ кодом, потеряв имя поля.
    if (!_kUintRe.hasMatch(v)) {
      final dash = v.indexOf('-');
      if (dash <= 0) return null;
      final lo = _kUintRe.hasMatch(v.substring(0, dash).trim())
          ? int.tryParse(v.substring(0, dash).trim())
          : null;
      final hi = _kUintRe.hasMatch(v.substring(dash + 1).trim())
          ? int.tryParse(v.substring(dash + 1).trim())
          : null;
      if (lo == null || hi == null) return null;
      if (hi < lo) return swap ? '$hi-$lo' : null;
      return '$lo-$hi';
    }
    final single = int.tryParse(v);
    if (single != null) return single;
    final dash = v.indexOf('-');
    if (dash <= 0) return null;
    final lo = int.tryParse(v.substring(0, dash).trim());
    final hi = int.tryParse(v.substring(dash + 1).trim());
    if (lo == null || hi == null) return null;
    if (hi < lo) return swap ? '$hi-$lo' : null;
    return '$lo-$hi';
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
      if (merge == 'keep_first' && occupied <= prio) {
        _trace?.add(
          stage: TraceStage.field,
          mapper: _mapperId,
          entry: p?.name ?? r'$sets',
          val: value,
          path: path,
          act: TraceAct.skip,
          why: TraceWhy.lowerPriority(_writtenByName[path] ?? '-'),
        );
        return;
      }
      // `append`/`prepend` — СЛИЯНИЕ списков, а не замена: две записи вправе
      // наполнять один путь (порты из authority и из query — один список
      // `server_ports`, и порядок в нём нормативен).
      if (merge == 'append' || merge == 'prepend') {
        final was = _read(path);
        if (was is List) {
          final add = value is List ? value : [value];
          final merged = merge == 'append'
              ? [...was, ...add]
              : [...add, ...was];
          _writtenBy[path] = prio;
          _put(path, merged);
          return;
        }
      }
    }
    final was = occupied != null;
    _writtenBy[path] = prio;
    _writtenByName[path] = p?.name ?? r'$sets';
    _put(path, value);
    _trace?.add(
      stage: TraceStage.field,
      mapper: _mapperId,
      entry: p?.name ?? r'$sets',
      val: value,
      path: path,
      act: was ? TraceAct.override : TraceAct.write,
    );
  }

  /// Кто занял путь — для `why: lower_priority:<entry>` в трассе.
  final Map<String, String> _writtenByName = {};

  void _writeIfAbsent(String path, dynamic value, MapperParam? p) {
    if (value == null || _read(path) != null) return;
    _write(path, value, p);
  }

  /// **G2** — снять путь целиком (`sets: {path: null}`).
  void _erase(String path) {
    _trace?.add(
      stage: TraceStage.sets,
      mapper: _mapperId,
      entry: r'$sets',
      path: path,
      act: TraceAct.remove,
    );
    final segs = _segments(path);
    Map<String, dynamic>? cur = body;
    for (var i = 0; i < segs.length - 1; i++) {
      final seg = segs[i];
      // `имя[]` — первый элемент массива (см. [_put]).
      if (seg.endsWith('[]')) {
        final list = cur![seg.substring(0, seg.length - 2)];
        if (list is! List || list.isEmpty || list.first is! Map) return;
        cur = (list.first as Map).cast<String, dynamic>();
        continue;
      }
      final next = cur![seg];
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
    final segs = _segments(path);
    var cur = body;
    for (var i = 0; i < segs.length - 1; i++) {
      final seg = segs[i];
      // Сегмент `имя[]` — ЭЛЕМЕНТ МАССИВА: так запись адресует поле вложенной
      // записи у схем уровня `endpoint`, где адреса сервера в корне тела нет
      // вовсе. Ссылка несёт строго один такой элемент (это свойство ФОРМЫ
      // источника, а не схемы), поэтому массив заводится из одной карты и
      // дальше наполняется ею же.
      if (seg.endsWith('[]')) {
        final key = seg.substring(0, seg.length - 2);
        final existing = cur[key];
        if (existing is List && existing.isNotEmpty &&
            existing.first is Map<String, dynamic>) {
          cur = existing.first as Map<String, dynamic>;
        } else {
          final fresh = <String, dynamic>{};
          cur[key] = [fresh];
          cur = fresh;
        }
        continue;
      }
      final next = cur[seg];
      if (next is Map<String, dynamic>) {
        cur = next;
      } else {
        final fresh = <String, dynamic>{};
        cur[seg] = fresh;
        cur = fresh;
      }
    }
    cur[segs.last] = value;
  }

  dynamic _read(String path) {
    dynamic cur = body;
    for (final seg in _segments(path)) {
      if (cur is! Map) return null;
      // `имя[]` — первый элемент массива (см. [_put]).
      if (seg.endsWith('[]')) {
        final list = cur[seg.substring(0, seg.length - 2)];
        if (list is! List || list.isEmpty) return null;
        cur = list.first;
        continue;
      }
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
    // Источники метки: карта по формам сильнее плоского списка (§480 — у
    // входа с двумя формами имя лежит в разных местах). Формы, которой в
    // карте нет, метка не положена вовсе, и это не умолчание, а объявление:
    // фрагмент у контейнерной формы не читается ни одной записью.
    final byForm = section.label.sourceByForm;
    final sources = byForm.isNotEmpty
        ? (byForm[space.formId] ?? const <String>[])
        : section.label.source;

    // Звено цепочки считается ответившим по ПОСЛЕ-нормализационному значению.
    // Иначе пробельное имя (`nameHint: "  "`) занимало бы место в цепочке и
    // глушило следующие звенья: `trim` превратил бы его в пустую строку уже
    // после выбора, и узел остался бы вовсе без имени.
    for (final src in sources) {
      final v = _readSourceBare(src);
      // Метка бывает НЕ СТРОКОЙ: в контейнере чужого диалекта `ps` приезжает
      // числом ровно так же, как `port`. Отбрасывать её за это значило бы
      // переименовать живой узел в фолбэк.
      final s = v is String ? v : (v == null ? '' : '$v');
      if (s.isEmpty) continue;
      // Одинокий `/` — это ПУСТОЙ путь, а не имя. Ссылка, где за хостом сразу
      // идёт строка запроса (`…@host/?a=1`), несёт этот разделитель и больше
      // ничего: назвать им узел значит выдать пунктуацию за имя, которого
      // автор не давал. Звено цепочки при этом не отвечает, и метку отдаёт
      // следующее звено или фолбэк, а не сам символ.
      if (src == 'path' && s == '/') continue;
      final label = _normalizeLabel(s, fromFragment: src == 'fragment');
      if (label.isNotEmpty) return label;
    }
    // Шаблон фолбэка БЕЗ подстановок — готовое имя, а не форма адреса. Такой
    // шаблон исполняется ЗДЕСЬ: он ни от тела, ни от схемы не зависит, а общий
    // тег-фолбэк вызывающего построил бы `<тип>-<адрес>-<порт>` и переименовал
    // бы живые узлы. Шаблон С подстановками остаётся вызывающему: адрес он
    // берёт из тела.
    final tpl = section.label.fallbackTemplate;
    if (tpl != null && !tpl.contains('{')) return tpl;
    return '';
  }

  /// Объявленная нормализация метки (G8), одна на все звенья цепочки.
  ///
  /// Percent снимается ТОЛЬКО с фрагмента: экранирование — свойство ссылки, а
  /// не значения. В контейнере `ps` лежит готовой строкой, и лишний проход
  /// съел бы у имени законный `%` (`50%25` стал бы `50%`). Во фрагменте же
  /// декод идёт с path-семантикой: `+` там литерален (form-encoding во
  /// фрагменте не действует).
  String _normalizeLabel(String raw, {bool fromFragment = true}) {
    var label =
        fromFragment ? percentDecodeOnce(raw, mode: DecodeMode.path) : raw;
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
      if (_declared.contains(name.toLowerCase())) continue;
      // Тот же ключ, объявленный ПУТЁМ ОБЪЕКТА. Контейнерная форма
      // раскладывается лексером плоским слоем имён, и эта ветка обходит его
      // наравне со строкой запроса — а объявлен такой ключ записью вида
      // `json.<имя>`, до которой плоский набор `_declared` не достаёт.
      // Без этих двух строк неизвестными объявлялись адрес, порт,
      // идентификатор и имя узла контейнера, то есть ровно те ключи, из
      // которых узел и собран (корпус rich_v0).
      if (_declaredJson.contains(name.toLowerCase())) continue;
      if (_labelKeys.contains(name.toLowerCase())) continue;
      // `unknown_key.ignore` — объявление секции, а не свойство одного входа:
      // ключ, названный там, молчит с какой бы стороны его ни судили. Ветка
      // объектного входа сверялась с ним всегда, эта — нет, и у контейнерной
      // формы, которая раскладывается плоским слоем имён, тот же самый ключ
      // получал разный приговор в зависимости от ветки.
      if (section.ignoredKeys.contains(name)) continue;
      warnings.add(RegistryWarning(code: code, path: name, value: ''));
      _trace?.add(
        stage: TraceStage.unknown,
        mapper: _mapperId,
        entry: name,
        src: 'query.$name',
        act: TraceAct.skip,
        why: TraceWhy.notDeclared,
      );
    }

    // Объектный вход: судятся ключи ВЕРХНЕГО уровня элемента. Их конечное
    // число, они и есть диалект, а перечислять каждый лист значило бы
    // держать вторую копию схемы входа рядом с `body.fields`.
    //
    // `action: keep` (sing-box) кладёт неопознанный ключ в тело: чужой ключ
    // может быть расширением форка, выбрасывать его нельзя. `drop` (xray)
    // не кладёт — диалект Xray в тело ядра не едет ни одним именем.
    final json = space.json;
    if (json == null) return;
    for (final e in json.entries) {
      if (_consumed.contains('json.${e.key}'.toLowerCase())) continue;
      if (section.ignoredKeys.contains(e.key)) continue;
      // Тот же ключ, ПРОЧИТАННЫЙ ПЛОСКИМ ИМЕНЕМ. Контейнерная форма
      // раскладывается лексером плоским слоем имён, и запись, объявленная
      // как `query.<имя>`, читает его оттуда: отметка о чтении ложится
      // плоским написанием (`_consumeSpelling`), а не путём `json.<имя>`.
      // Без этой строки ветка судила ключ по одному лишь `json.`-написанию и
      // объявляла неизвестными ровно те ключи, значения которых уже стоят в
      // теле, — у корпуса rich_v0 это путь и заголовок Host ws-транспорта.
      // При `action: keep` они вдобавок уезжали в тело вторым, чужим полем.
      if (_consumed.contains(e.key.toLowerCase())) continue;
      // Ключ, ОБЪЯВЛЕННЫЙ источником МЕТКИ. Метка читается позже этой ветки
      // (`_label()` зовётся после `_reportUnknown()`), поэтому отметкой о
      // чтении её ключ закрыть нельзя — только объявлением. Так и правильнее:
      // норма §8 считает объявленным то, что объявила секция, а не то, что
      // удалось прочитать, — иначе пустое имя делало бы свой ключ
      // неизвестным. Без этой строки ключ имени узла у контейнерной формы
      // попадал в неизвестные и при `action: keep` уезжал в тело (rich_v0).
      if (_labelKeys.contains(e.key.toLowerCase())) continue;
      warnings.add(RegistryWarning(code: code, path: e.key, value: ''));
      if (section.unknownKeyAction == 'keep' && !body.containsKey(e.key)) {
        body[e.key] = e.value;
      }
    }
  }

  /// Все написания, ОБЪЯВЛЕННЫЕ таблицей: имя записи, её `aliases` и имена в
  /// `source` (`query.<имя>`).
  ///
  /// Считается по таблице, а не по факту чтения (норма §8): запись,
  /// не применившаяся по `when`, объявленной быть не перестаёт. Иначе
  /// `eh=` без `ed=` и любой параметр чужого транспорта давали бы info о
  /// «неизвестном параметре» на ровном месте — а это ровно то молчание
  /// наоборот, ради которого затеяна кампания.
  late final Set<String> _declared = () {
    final out = <String>{};
    for (final p in section.params.values) {
      for (final s in p.spellings) {
        out.add(s.toLowerCase());
      }
      final sources = [
        ...p.source,
        for (final l in p.sourceByForm.values) ...l,
      ];
      for (final src in sources) {
        if (src.startsWith('query.')) {
          out.add(src.substring('query.'.length).toLowerCase());
        }
      }
    }
    // Параметр, НЕСУЩИЙ наложенный слой, объявлен самим слоем: `overlays[]`
    // называет его своим `source`, и читают его записи под именем слоя
    // (`extra.mode`), а не плоским `query.extra`. Без этой ветки набор видел
    // только адресатов, а носитель оставался «никем не объявленным» и уезжал
    // в `uri_param_unknown` — у корпуса это все шесть кейсов `xhttp_extra_*`,
    // включая тот, где слой битый и записей не даёт вовсе.
    for (final o in section.overlays) {
      for (final src in o.source) {
        if (src.startsWith('query.')) {
          out.add(src.substring('query.'.length).toLowerCase());
        }
      }
    }
    return out;
  }();

  /// То же, что [_declared], но для ОБЪЕКТНОГО входа: имена верхнего уровня,
  /// объявленные таблицей через `json.<имя>`.
  ///
  /// Держится отдельным набором, а не общим с query: пространства имён у
  /// входов разные, и ключ, объявленный только в строке запроса, не делает
  /// одноимённый ключ объекта прочитанным. Учитываются и `source` по ФОРМАМ:
  /// у входа с двумя формами запись живёт в одной из них, а судить ключ
  /// приходится до выбора формы.
  ///
  /// Путь режется до верхнего сегмента (`json.foo`, но не `json.foo.bar`):
  /// ветка судит ровно верхний уровень, а вложенный лист ключом верхнего
  /// уровня не является — иначе запись, читающая лист, молча признавала бы
  /// объявленной всю ветку документа над ним.
  late final Set<String> _declaredJson = () {
    final out = <String>{};
    for (final p in section.params.values) {
      final sources = [
        ...p.source,
        for (final l in p.sourceByForm.values) ...l,
      ];
      for (final src in sources) {
        if (!src.startsWith('json.')) continue;
        final rest = src.substring('json.'.length);
        final dot = rest.indexOf('.');
        out.add((dot < 0 ? rest : rest.substring(0, dot)).toLowerCase());
      }
    }
    return out;
  }();

  /// Ключи ВЕРХНЕГО уровня объектного входа, объявленные источником МЕТКИ.
  ///
  /// Берутся все формы, а не только текущая: набор считается по секции, и
  /// ключ, из которого имя берёт соседняя форма, чужим диалектом не
  /// становится. Путь режется до верхнего сегмента — ветка судит ровно
  /// верхний уровень.
  late final Set<String> _labelKeys = () {
    final out = <String>{};
    final byForm = section.label.sourceByForm;
    final sources = [
      ...section.label.source,
      for (final l in byForm.values) ...l,
    ];
    for (final src in sources) {
      if (!src.startsWith('json.')) continue;
      final rest = src.substring('json.'.length);
      final dot = rest.indexOf('.');
      out.add((dot < 0 ? rest : rest.substring(0, dot)).toLowerCase());
    }
    return out;
  }();

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

  static String? _tryBase64(String raw) => _RunDecode.base64(raw);
}

const _b64 = Base64Codec();
