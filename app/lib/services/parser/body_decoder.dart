import 'dart:convert';
import 'dart:math';

import 'amnezia_link.dart';
import 'engine/document.dart';
import 'engine/section_loader.dart';
import 'uri_utils.dart';

/// Результат декодирования тела подписки (§3.2 спеки 026).
/// Sealed — парсер делает exhaustive switch по результату.
sealed class DecodedBody {
  const DecodedBody();
}

final class UriLines extends DecodedBody {
  final List<String> lines;

  /// §219 — диагностический счётчик пропущенных comment-строк. В проде не
  /// читается; служит наблюдаемым выходом для проверки инварианта парсера
  /// в тестах (body_decoder_test). Оставлен намеренно, не write-only мусор.
  final int skippedComments;
  const UriLines(this.lines, this.skippedComments);
}

final class IniConfig extends DecodedBody {
  final String text;
  const IniConfig(this.text);
}

/// §110 — Amnezia `vpn://`-ссылка: по одному WG/AWG INI-тексту на
/// контейнер (см. `amnezia_link.dart`).
final class AmneziaConfig extends DecodedBody {
  final List<String> iniTexts;
  const AmneziaConfig(this.iniTexts);
}

final class JsonConfig extends DecodedBody {
  final Object value;

  /// §480/§482 — ВЕТКА, которой опознан документ: `kind` называет вид,
  /// `elements` — где лежат элементы (обход ведёт `parse_all`), `mapper` —
  /// вид источника элемента.
  ///
  /// Ветка едет ЦЕЛИКОМ и у запасного пути тоже (`_detectLegacySource`):
  /// второго имени вида — перечисления форм в коде — больше нет, и
  /// потребителю незачем знать, откуда взялось опознание.
  final DocumentSource source;

  const JsonConfig(this.value, this.source);
}

final class DecodeFailure extends DecodedBody {
  final String reason;
  final String? sample;
  const DecodeFailure(this.reason, [this.sample]);
}

/// §482 — имена видов источника, у которых есть СВОЁ поведение в коде.
///
/// Перечислением видов этот класс не является: виды объявляет реестр, и
/// незнакомое имя обязано вести себя как «узлов нет», а не ронять разбор.
/// Здесь лежат только те имена, на которые потребитель отвечает по-разному
/// (превью вставки, вырезание `tailscale`-записей), — чтобы одна и та же
/// строка не переписывалась в четырёх файлах.
abstract final class SourceKind {
  /// §480 Д-3 — ЧЕТЫРЕ вида Xray. Обёртка документа их различает, а диалект
  /// — нет: обход элементов идёт по `elements` ветки, и потребителю (превью
  /// буфера) все четыре отвечают одинаково. Перечислены именно потому, что
  /// молчащий на трёх из них `switch` вернул бы «вид неизвестен» документу,
  /// который ветка реестра уже опознала.
  ///
  /// Массив автономных Xray-конфигов (элементы с `outbounds`).
  static const xrayConfigArray = 'xray_config_array';

  /// Полный Xray-конфиг: `{"outbounds":[{"protocol":…},…],…}`.
  static const xrayConfig = 'xray_config';

  /// Одиночный Xray-outbound: `{"protocol":"vless",…}`.
  static const xrayOutbound = 'xray_outbound';

  /// Массив Xray-outbound'ов: `[{"protocol":"vless",…},…]`.
  static const xrayOutboundArray = 'xray_outbound_array';

  /// Одиночный sing-box outbound: `{"type":"vless",…}`.
  static const singboxOutbound = 'singbox_outbound';

  /// Массив sing-box outbound'ов: `[{"type":"vless",…},…]`.
  static const singboxOutboundArray = 'singbox_outbound_array';

  /// Полный sing-box конфиг: `{"log":…,"outbounds":[…],"route":…}`.
  static const singboxConfig = 'singbox_config';

  /// Массив автономных sing-box конфигов (подписка пер-узел).
  static const singboxConfigArray = 'singbox_config_array';

  /// §482 — своей ветки в реестре НЕТ: её убрал GRAMMAR_SYNC, у лаунчера её
  /// заменяет `on_unrecognized`, которого движок ещё не исполняет. Имя живёт
  /// на запасном пути, чтобы «ноль узлов» не подменилось на «список ссылок
  /// из одной строки JSON» (фича 480, раздел 7c).
  static const clashYaml = 'clash_yaml';

  /// JSON, не похожий ни на одну форму. Узлов не даёт.
  static const unknown = 'unknown';
}

/// §482 — виды источника ЗАПАСНОГО пути (реестр не загружен).
///
/// `kind`, `mapper` и `elements` списаны с одноимённых веток реестра, и
/// расхождение ловит линтер `document_registry_test`: разъехавшийся
/// `elements` дал бы на запасном пути другой обход элементов — то есть
/// другой состав подписки — и сказал бы об этом только пользователь.
///
/// `clash_yaml` и `unknown` своих веток в реестре не имеют (см. [SourceKind]):
/// маппера у них нет, узлов они не дают.
const kFallbackDocumentSources = <DocumentSource>[
  DocumentSource(
    kind: SourceKind.xrayConfigArray,
    mapper: 'xray',
    elements: '[].outbounds[]',
  ),
  DocumentSource(
    kind: SourceKind.singboxConfigArray,
    mapper: 'singbox',
    elements: '[].outbounds[]',
  ),
  DocumentSource(
    kind: SourceKind.singboxOutboundArray,
    mapper: 'singbox',
    elements: '[]',
  ),
  DocumentSource(
    kind: SourceKind.singboxOutbound,
    mapper: 'singbox',
    elements: r'$self',
  ),
  DocumentSource(
    kind: SourceKind.singboxConfig,
    mapper: 'singbox',
    elements: 'outbounds[]+endpoints[]',
  ),
  DocumentSource(kind: SourceKind.clashYaml),
  DocumentSource(kind: SourceKind.unknown),
];

DocumentSource _fallback(String kind) =>
    kFallbackDocumentSources.firstWhere((s) => s.kind == kind);

/// Декодирует body подписки. Не throws.
///
/// §480 W6 — ВИД ИСТОЧНИКА ОПОЗНАЁТ РЕЕСТР
/// (`contract_draft/source_kinds.json`,
/// движок `engine/document.dart`): порядок веток, предикаты и глубина
/// распаковки объявлены данными, а не ветвями здесь. Рукописный порядок
/// («сперва `vpn://`, потом эвристика base64, потом `{`/`[`, потом
/// `[Interface]`, иначе строки») сохранён в данных буква в букву — он
/// нормативен, и его правка это правка JSON плюс синк, а не код в двух
/// приложениях.
///
/// Оболочки остаются КОДОМ (`decodeAmneziaLink`, base64+UTF-8): `qCompress`
/// и zlib предикатами не выражаются. Но вызываются они по ИМЕНИ из
/// `unwrap`, а не веткой в снифере — так же устроено у лаунчера.
///
/// Реестр не загружен (юнит-тест без `loadDrafts`) — работает прежний
/// рукописный порядок: [_classifyLegacy]. Опознание документа, в отличие от
/// разбора узла, обязано работать и без реестра: на нём стоит вся вставка из
/// буфера, и молчаливый отказ выглядел бы как «подписка пустая».
DecodedBody decode(String body) {
  final original = body.trimRight();
  if (original.isEmpty) return const DecodeFailure('empty body');

  final registry = MapperSections.I.documents;
  if (registry == null) return _classifyLegacy(original);

  final match = registry.detect(original, unwrappers: _kUnwrappers);
  if (match == null) {
    return DecodeFailure(
        'no parseable content', original.substring(0, min(original.length, 80)));
  }

  // §110 — распаковщик оболочки Amnezia отдаёт INI-тексты, а не текст:
  // контейнеров в ссылке бывает несколько, и «текстом» их не выразить.
  if (match.source.unwrap == _kAmneziaUnwrap) {
    return decodeAmneziaLink(original);
  }

  return _classifyByKind(match);
}

/// Вид источника → форма, которую ждёт разбор.
///
/// [DecodedBody] — граница волны: sealed-набор форм и весь `parse_all` за
/// ним не меняются, меняется ТОЛЬКО способ выбрать форму.
DecodedBody _classifyByKind(DocumentMatch match) {
  final text = match.text;
  switch (match.source.mapper) {
    case 'conf':
      return IniConfig(text);
    case 'xray':
    case 'singbox':
      final value = match.json ?? _tryJsonDecode(text);
      if (value == null) return _classifyLegacy(text);
      // §480 — ветка едет дальше ЦЕЛИКОМ: и обход элементов (`elements`), и
      // вид источника (`kind`) читаются прямо с неё.
      return JsonConfig(value, match.source);
    case 'uri':
      // Ветка «всё остальное» ловит и опознаваемый JSON, своей ветки в
      // реестре не имеющий: такой документ узлов не даёт, но форму ответа
      // обязан сохранить прежнюю — иначе «ноль узлов» подменяется на
      // «список ссылок из одной строки JSON». Разбор формы остаётся за
      // рукописным порядком до тех пор, пока `on_unrecognized` реестра не
      // исполняется движком.
      final head = text.trimLeft();
      if (head.startsWith('{') || head.startsWith('[')) {
        final value = _tryJsonDecode(text);
        if (value != null) return JsonConfig(value, _detectLegacySource(value));
      }
      return _uriLines(text, match.source.lineCommentPrefixes);
    case null:
      // Вид опознан, но узлов не даёт. Форма прежняя: разбор ответит нулём
      // узлов, как и до волны.
      final value = match.json ?? _tryJsonDecode(text);
      if (value == null) return _classifyLegacy(text);
      return JsonConfig(value, _detectLegacySource(value));
    default:
      return _classifyLegacy(text);
  }
}

Object? _tryJsonDecode(String text) {
  try {
    return jsonDecode(text.trim());
  } catch (_) {
    return null;
  }
}

/// Имя распаковщика Amnezia в реестре видов источника (FROZEN-написание
/// обеих сторон после сведения грамматики — GRAMMAR_SYNC §4 №11).
const _kAmneziaUnwrap = 'amnezia_vpn';

/// Именованные распаковщики оболочки: `unwrap` реестра → функция.
final Map<String, Unwrapper> _kUnwrappers = {
  // Оболочка Amnezia снимается своей функцией целиком (она отдаёт список
  // INI-текстов, а не текст) — здесь только признак «оболочка есть».
  _kAmneziaUnwrap: (text) => text,
  'base64_utf8': (text) {
    final noWs = text.replaceAll(RegExp(r'\s+'), '');
    final bytes = decodeBase64Safe(noWs);
    if (bytes == null || !_isLikelyUtf8(bytes)) return null;
    final decoded = utf8Lossy(bytes).trim();
    return decoded.isEmpty ? null : decoded;
  },
};

DecodedBody _uriLines(String text, List<String> commentPrefixes) {
  final lines = <String>[];
  var skipped = 0;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (commentPrefixes.any(l.startsWith)) {
      skipped++;
      continue;
    }
    lines.add(l);
  }
  if (lines.isEmpty) {
    return DecodeFailure(
        'no parseable content', text.substring(0, min(text.length, 80)));
  }
  return UriLines(lines, skipped);
}

/// Прежний рукописный порядок — запасной путь, когда реестра нет.
DecodedBody _classifyLegacy(String body) {
  final original = body.trimRight();
  if (original.isEmpty) return const DecodeFailure('empty body');

  if (original.trimLeft().startsWith('vpn://')) {
    return decodeAmneziaLink(original);
  }

  final trimmedNoWs = original.replaceAll(RegExp(r'\s+'), '');
  if (_looksLikeBase64(trimmedNoWs)) {
    final bytes = decodeBase64Safe(trimmedNoWs);
    if (bytes != null && _isLikelyUtf8(bytes)) {
      final decoded = utf8Lossy(bytes).trim();
      if (decoded.isNotEmpty && _isPlausiblePayload(decoded)) {
        return _classifyPlain(decoded);
      }
    }
  }

  return _classifyPlain(original);
}

DecodedBody _classifyPlain(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const DecodeFailure('empty after decode');

  // JSON branch
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final value = jsonDecode(trimmed);
      return JsonConfig(value, _detectLegacySource(value));
    } catch (_) {
      // Fall through to URI-lines detection.
    }
  }

  // INI branch
  if (_firstNonCommentLine(trimmed).trim().toLowerCase() == '[interface]' &&
      trimmed.contains('[Peer]')) {
    return IniConfig(trimmed);
  }

  // URI lines
  final lines = <String>[];
  var skipped = 0;
  for (final raw in trimmed.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('#') || l.startsWith('//') || l.startsWith(';')) {
      skipped++;
      continue;
    }
    lines.add(l);
  }
  if (lines.isEmpty) {
    return DecodeFailure(
        'no parseable content', trimmed.substring(0, min(trimmed.length, 80)));
  }
  return UriLines(lines, skipped);
}

bool _looksLikeBase64(String s) {
  if (s.length < 16) return false;
  final re = RegExp(r'^[A-Za-z0-9+/_=\-]+$');
  return re.hasMatch(s);
}

bool _isLikelyUtf8(List<int> bytes) {
  try {
    final s = utf8.decode(bytes);
    // Если > 20% управляющих байтов — скорее всего бинарь.
    var ctrl = 0;
    for (final r in s.runes) {
      if (r < 0x09 || (r > 0x0D && r < 0x20)) ctrl++;
    }
    return ctrl < (s.length * 0.2);
  } catch (_) {
    return false;
  }
}

bool _isPlausiblePayload(String s) {
  return s.contains('://') ||
      s.trimLeft().startsWith('{') ||
      s.trimLeft().startsWith('[') ||
      s.contains('[Interface]');
}

String _firstNonCommentLine(String s) {
  for (final raw in s.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l.startsWith('#') || l.startsWith('//') || l.startsWith(';')) continue;
    return l;
  }
  return '';
}

/// Вид источника рукописным порядком — запасной путь, когда реестра нет.
///
/// Отвечает ТОЙ ЖЕ формой, что реестр ([DocumentSource]): вид у документа
/// один, и зависеть он от того, загружен ли реестр, не должен — сверяет
/// `document_registry_test`.
DocumentSource _detectLegacySource(Object v) {
  if (v is List && v.isNotEmpty) {
    final first = v.first;
    if (first is Map && first['outbounds'] is List) {
      // §368 §7.1 — массив конфигов бывает и Xray, и sing-box: обе формы это
      // List элементов с `outbounds`. Различаем по содержимому массива —
      // элементы Xray несут `protocol`, sing-box `type`.
      return _fallback(_looksLikeSingboxOutbounds(first['outbounds'] as List)
          ? SourceKind.singboxConfigArray
          : SourceKind.xrayConfigArray);
    }
    // §368 — массив sing-box outbound'ов. Раньше падал в `unknown` (0 узлов на
    // всех путях, кроме вставки из буфера, где контроллер разбирал его сам).
    if (first is Map && first['type'] is String) {
      return _fallback(SourceKind.singboxOutboundArray);
    }
    return _fallback(SourceKind.unknown);
  }
  if (v is Map) {
    // `type` проверяем ПЕРВЫМ: одиночный `selector` несёт и `type`, и
    // `outbounds` — он outbound, а не конфиг.
    if (v['type'] is String) return _fallback(SourceKind.singboxOutbound);
    if (v['proxies'] is List) return _fallback(SourceKind.clashYaml);
    // §368 — полный конфиг. `endpoints` (sing-box ≥1.11) равноправен: конфиг
    // может состоять из одних WireGuard-узлов.
    if (v['outbounds'] is List || v['endpoints'] is List) {
      return _fallback(SourceKind.singboxConfig);
    }
  }
  return _fallback(SourceKind.unknown);
}

/// §368 §7.1 — чей это `outbounds[]`. Смотрим первый элемент-объект: `type` —
/// sing-box, `protocol` — Xray.
///
/// Ни того ни другого (или пустой массив) → **не** sing-box: ветка `xrayArray`
/// существует и работает, и менять её классификацию по неоднозначному входу
/// нельзя.
bool _looksLikeSingboxOutbounds(List outbounds) {
  for (final o in outbounds) {
    if (o is! Map) continue;
    if (o['type'] is String) return true;
    if (o['protocol'] is String) return false;
  }
  return false;
}
