import 'dart:convert';
import 'dart:io';

import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/warning_codes.dart';

// §470 — общая часть двух конформанс-раннеров корпуса: URI
// (`contract_test.dart`) и тел подписки (`body_contract_test.dart`).
//
// Раньше правила записи `warnings[]` (CANON §6) и нормализация сравнения
// (CANON §7, зеркало Go `normalizeWarningsForCompare`) жили только в
// URI-раннере, а body-раннер предупреждения не сверял вовсе. Кейсы, чей смысл
// именно в кодах (`*_quic_tls_pair.body`, `outbound_array_tls_fields.body`),
// были зелёными независимо от поведения — §469 наткнулся на это случайно:
// гейт `forbidden_for` не ставил `value`, и не покраснел ни один тест.
//
// Копировать правила во второй раннер нельзя: они нормативны, и две копии
// разъехались бы на первом же бампе контракта. Поэтому — один файл на обоих.

/// Корень вендоренного контракта (кладёт `tool/sync_contract.sh`).
const kContractRoot = 'contract';

/// Путь поля для рукописных классов — ТОЛЬКО там, где поле класса и есть
/// путь (CANON §6: `path` обязателен у кодов уровня поля).
///
/// §472 шаг 1 — таблица переехала в lib
/// ([handwrittenWarningPath], `services/contract/warning_codes.dart`): у неё
/// появился второй потребитель, дедуп предупреждений при разборе. Здесь
/// остался только вызов — две копии разошлись бы на первом же новом классе,
/// ровно как это было бы с `kWarningCodes`.
String? _legacyWarningPath(NodeWarning w) => handwrittenWarningPath(w);

/// Значение, вызвавшее код, — по той же логике, что и [_legacyWarningPath].
///
/// `MissingObfsPasswordWarning` сюда НЕ попадает: его поле — тип обфускации,
/// а код про пароль, и значением он не является (ожидание корпуса `value`
/// у него не называет).
///
/// §472 шаг 9 — `AnyTlsMinIdleInvalidWarning`, `TuicCongestionInvalidWarning`
/// и `MasqueVhttpInvalidWarning` отсюда ушли вместе с классами: эти коды
/// теперь ставит санитайзер реестра (`RegistryWarning`), а он несёт значение
/// сам, веткой выше.
String? _legacyWarningValue(NodeWarning w) => switch (w) {
      DeprecatedFlowWarning(:final flow) => flow,
      PacketEncodingUnknownWarning(:final value) => value,
      UnknownFingerprintWarning(:final value) => value,
      RealityFingerprintWarning(:final value) => value,
      RealityShortIdInvalidWarning(:final value) => value,
      UnknownObfsWarning(:final value) => value,
      // §467 — у `placementRequiresPacketUp` значение пустое (код про
      // сочетание, не про значение), и пустое в конверт не пишется.
      XhttpParamResetWarning(:final value) => value,
      _ => null,
    };

/// Запись `warnings[]` конверта: `{code, path?, value?, params?}` (CANON §6).
///
/// Пустые поля не пишутся — их отсутствие нормативно, а `null` в конверте
/// схема не допускает. Класса без кода в реестре в конверте нет вовсе:
/// код — единственное, что контракт от записи требует безусловно.
Map<String, dynamic>? warningRecordOf(NodeWarning w) {
  final code = warningCodeOf(w);
  if (code == null) return null;

  final String? path;
  final String? value;
  final Map<String, String> params;
  if (w is RegistryWarning) {
    // Санитайзер реестра уже знает и путь, и значение (у `secret`-полей —
    // `***`, 24.1.4), выдумывать здесь нечего.
    path = w.path;
    value = w.value;
    params = w.params;
  } else {
    path = _legacyWarningPath(w);
    value = _legacyWarningValue(w);
    params = const {};
  }

  return <String, dynamic>{
    'code': code,
    if (path != null && path.isNotEmpty) 'path': path,
    if (value != null && value.isNotEmpty) 'value': value,
    if (params.isNotEmpty) 'params': params,
  };
}

/// §464 — ранг пути в `body.order` схемы протокола: по нему сортируется
/// `warnings[]` конверта (§24.7 п. 6).
///
/// Порядок читается ИЗ РЕЕСТРА, а не из таблицы в тесте: он нормативен для
/// обеих сторон, и своя копия разошлась бы с ним на первом же бампе
/// контракта. Файлы те же, что грузит `ContractRegistry`, но читаются здесь
/// напрямую — раннеру нужен один список ключей, а не биндинг Flutter.
///
/// Ключ сортировки — ПЕРВЫЙ сегмент пути (`tls.reality.short_id` → `tls`):
/// он и решает место кода в теле, а внутри одной ветки порядок разбора у
/// обеих сторон и так совпадает. Код без пути и путь вне схемы уходят в
/// конец — детерминированно и без выдумывания рангов.
final _bodyOrderCache = <String, List<String>>{};

List<String> _bodyOrderFor(String scheme) => _bodyOrderCache.putIfAbsent(
      scheme,
      () {
        final f = File('$kContractRoot/registry/protocols/$scheme.json');
        if (!f.existsSync()) return const <String>[];
        final data = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
        final body = data['body'];
        if (body is! Map) return const <String>[];
        return ((body['order'] as List?) ?? const []).cast<String>();
      },
    );

void sortWarningsByBodyOrder(
    List<Map<String, dynamic>> warnings, String scheme) {
  if (warnings.length < 2) return;
  final order = _bodyOrderFor(scheme);
  if (order.isEmpty) return;
  int rank(Map<String, dynamic> w) {
    final path = w['path'];
    if (path is! String || path.isEmpty) return 1 << 20;
    final i = order.indexOf(path.split('.').first);
    return i < 0 ? 1 << 20 : i;
  }

  // Устойчивая сортировка: коды одной ветки остаются в порядке разбора.
  final indexed = [
    for (var i = 0; i < warnings.length; i++) (i, warnings[i]),
  ]..sort((a, b) {
      final d = rank(a.$2).compareTo(rank(b.$2));
      return d != 0 ? d : a.$1.compareTo(b.$1);
    });
  warnings
    ..clear()
    ..addAll(indexed.map((e) => e.$2));
}

/// `warnings[]` узла из его классов: дедуп по `(code, path)` и порядок
/// `body.order` реестра (CANON §6).
///
/// Конверт несёт объекты `{code, path?, value?}`, и каждая пара
/// `(code, path)` в списке ровно один раз: зеркало Go `ParsedNode.AddWarning`
/// (`configtypes/types.go`), который отбрасывает повтор. Dart-предупреждения
/// при этом остаются пофакторными (два битых AWG-заголовка = два разных
/// сообщения пользователю), но запись конверта у них одна на путь.
///
/// §464 (контракт W2d, §24.7 п. 6) — ПОРЯДОК списка = `body.order` реестра,
/// а не порядок разбора: только так коды сравнимы поэлементно, а не как
/// множество. У лаунчера он такой потому, что правила теперь ставит
/// санитайзер, идущий по схеме; у нас коды по-прежнему ставят парсеры (§460
/// W1 — реестр второй эшелон), и порядок восстанавливается здесь, по тому же
/// самому `order`.
List<Map<String, dynamic>> warningListOf(
    Iterable<NodeWarning> source, String scheme) {
  final warnings = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final w in source) {
    final rec = warningRecordOf(w);
    if (rec == null) continue;
    if (!seen.add('${rec['code']} ${rec['path'] ?? ''}')) continue;
    warnings.add(rec);
  }
  sortWarningsByBodyOrder(warnings, scheme);
  return warnings;
}

/// Приведение `warnings[]` обеих сторон к сравнимому виду (CANON §6, контракт
/// 1.1.0) — зеркало Go-раннера `normalizeWarningsForCompare`
/// (`core/config/contract_test.go`).
///
/// Нормативен ровно тот объём, который объявило ОЖИДАНИЕ:
///
///   - ожидание строкой  → сверяется только код (корпус до 1.1.0 и
///     by-design override'ы, написанные строками, продолжают работать);
///   - ожидание объектом → сверяются `code` и `path`/`value`, но каждое —
///     только если ожидание его назвало.
///
/// Иначе сторона, у которой путь ещё не проложен через санитайзер реестра
/// (§460 W2), падала бы на «лишнем» поле вместо настоящего расхождения кода.
void normalizeWarnings(Map<String, dynamic> got, Map<String, dynamic> want) {
  final gotNodes = nodeList(got, 'nodes');
  final wantNodes = nodeList(want, 'nodes');
  for (var i = 0; i < gotNodes.length; i++) {
    normalizeNodeWarnings(
        gotNodes[i], i < wantNodes.length ? wantNodes[i] : null);
  }
  // Ожидание тоже приводится к объектам — иначе строка `"tls_insecure"` и
  // объект `{code: tls_insecure}` разошлись бы формой записи.
  for (final wn in wantNodes) {
    normalizeNodeWarnings(wn, null);
  }
}

void normalizeNodeWarnings(
    Map<String, dynamic> node, Map<String, dynamic>? want) {
  final gotList = warningObjects(node);
  final wantList = want == null ? null : warningObjects(want);

  if (wantList != null) {
    for (var i = 0; i < gotList.length && i < wantList.length; i++) {
      // Лишняя запись у результата (i >= wantList.length) не срезается: это
      // расхождение, и прятать его нормализацией нельзя — пусть падает с
      // полным объектом.
      if (!wantList[i].containsKey('path')) gotList[i].remove('path');
      if (!wantList[i].containsKey('value')) gotList[i].remove('value');
      if (!wantList[i].containsKey('params')) gotList[i].remove('params');
    }
  }

  // Хопы цепочки несут свои warnings — тот же разбор, та же сверка.
  final gotHops = nodeList(node, 'chain');
  final wantHops =
      want == null ? const <Map<String, dynamic>>[] : nodeList(want, 'chain');
  for (var i = 0; i < gotHops.length; i++) {
    normalizeNodeWarnings(gotHops[i], i < wantHops.length ? wantHops[i] : null);
  }
}

/// `warnings[]` узла как изменяемые карты, ПЕРЕПИСЫВАЯ строки-коды объектами
/// прямо в конверте: дальше сравниваются уже однородные значения.
List<Map<String, dynamic>> warningObjects(Map<String, dynamic> node) {
  final list = node['warnings'];
  if (list is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    if (item is String) {
      final m = <String, dynamic>{'code': item};
      list[i] = m;
      out.add(m);
    } else if (item is Map<String, dynamic>) {
      out.add(item);
    }
  }
  return out;
}

/// D-088 — из `dropped[]` обеих сторон вычёркивается `reason`: это текст
/// СТОРОНЫ (у лаунчера формат ошибки Go, у нас свой), и побайтовая сверка
/// заставила бы копировать чужие строки. Нормативны `ref` и `code`; `code`
/// сверяется только там, где ожидание его объявило.
///
/// Зеркало Go `normalizeDropsForCompare` (`core/config/contract_test.go`).
/// Body-раннер это правило соблюдал с самого начала, URI-раннер — нет, и
/// `naive/empty_host_rejected` падал на одном лишь слове `parse_error`
/// против `emit_error`.
void normalizeDrops(Map<String, dynamic> got, Map<String, dynamic> want) {
  final gotDrops = nodeList(got, 'dropped');
  final wantDrops = nodeList(want, 'dropped');
  for (var i = 0; i < gotDrops.length; i++) {
    gotDrops[i].remove('reason');
    if (i >= wantDrops.length || !wantDrops[i].containsKey('code')) {
      gotDrops[i].remove('code');
    }
  }
  for (final d in wantDrops) {
    d.remove('reason');
  }
}

/// Список объектов по ключу карты (`nodes`, `chain`, `dropped`).
List<Map<String, dynamic>> nodeList(Map<String, dynamic> m, String key) {
  final list = m[key];
  if (list is! List) return const [];
  return [for (final e in list) if (e is Map<String, dynamic>) e];
}

/// Копия конверта под нормализацию: срезать поля в оригинале нельзя — тот же
/// конверт печатается в диагностике падения целиком.
Object? deepCopyEnvelope(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key as String: deepCopyEnvelope(e.value),
    };
  }
  if (v is List) return [for (final e in v) deepCopyEnvelope(e)];
  return v;
}

/// Сериализация по правилам CANON §2.3/2.6: ключи map отсортированы рекурсивно
/// (byte-order), компактный JSON. Escaping здесь не проблема — Dart's
/// `JsonEncoder` не HTML-экранирует `<`/`>`/`&` (в отличие от Go-энкодера по
/// умолчанию), так что CANON §2.7 (D-007) выполняется без дополнительных мер.
String canonEncode(Object? v) => json.encode(sortKeys(v));

Object? sortKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    final out = <String, dynamic>{};
    for (final k in keys) {
      out[k] = sortKeys(v[k]);
    }
    return out;
  }
  if (v is List) {
    return [for (final val in v) sortKeys(val)];
  }
  return v;
}

/// Pretty-print для диагностики и для файла ожидания (читаемость); сравнение
/// всё равно идёт по значению после канонизации, не по байтам (CANON §7).
String prettyPrintEnvelope(Map<String, dynamic> envelope) {
  final canon = sortKeys(envelope);
  const encoder = JsonEncoder.withIndent('  ');
  return '${encoder.convert(canon)}\n';
}
