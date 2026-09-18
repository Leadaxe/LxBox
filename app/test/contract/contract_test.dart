import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

// Конформанс-раннер общего корпуса контракта (SPEC 103, фаза 1), сторона
// LxBox. Аналог core/config/contract_test.go в singbox-launcher — гоняет тот
// же корпус contract/corpus/uri/**/*.uri через parseUri() и сравнивает
// результат с ожиданием корпуса.
//
// ИСТОЧНИК ОЖИДАНИЯ — ОБЩИЙ `<case>.expected.json`. Он нормативен для ОБЕИХ
// сторон (contract/README.md §2): именно поэтому изменение канона у лаунчера
// обязано доехать до нас красным тестом. `<case>.expected.lxbox.json`
// читается ТОЛЬКО если существует, и означает задокументированное by-design
// различие — три законных класса перечислены в contract/docs/IDENTITY.md §4a.
//
// Раньше раннер читал исключительно override и скипал кейс без него. Это
// давало обратный эффект: чтобы тест вообще шёл, к каждому кейсу клали копию
// базы, и 257 из 281 override'а были побайтовыми дублями, которые ничего не
// проверяли и глушили расхождения. Аудит 25.08 (контракт 0.8.0) их снёс.
//
// Регенерация ожиданий LxBox:
//
//   cd app && UPDATE_CONTRACT=1 flutter test test/contract/
//
// ВНИМАНИЕ: регенерация пишет ТОЛЬКО override и только там, где он уже есть
// либо где результат реально расходится с базой — новые бесхозные копии не
// создаются. Дифф идёт в PR с ревью (contract/README.md §2).

/// Корень скопированного контракта — кладёт tool/sync_contract.sh.
const _contractRoot = 'contract';

/// Соответствие имени каталога корпуса (= scheme из registry/protocols/*.json,
/// contract/docs/CANON.md §1) типу kind в конверте. Все схемы вне карты —
/// обычный outbound; wireguard — endpoint (CANON §1, registry: kind=endpoint).
const _endpointSchemes = {'wireguard', 'tailscale'}; // §435 — tailscale тоже endpoint

/// Имя стороны в поле `extension` реестра/ожиданий (corpus/README «Отбраковки
/// и meta.extension»). Чужой extension = схемы у нас нет.
const _thisSide = 'lxbox';

/// Схемы, объявленные реестром расширением ЧУЖОЙ стороны
/// (`registry/protocols/<scheme>.json` → `"extension"`).
///
/// Каталог корпуса такой схемы пропускается ЦЕЛИКОМ: у LxBox нет парсера
/// hysteria v1, и каждая его фикстура падала бы «нода не разобралась» —
/// шум, который прятал бы настоящие расхождения. Пропуск идёт от РЕЕСТРА,
/// а не от списка в тесте: появится вторая desktop-only схема — раннер
/// узнает о ней сам, без правки кода.
Set<String> _foreignExtensionSchemes() {
  final dir = Directory('$_contractRoot/registry/protocols');
  if (!dir.existsSync()) return const {};
  final out = <String>{};
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    final data = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    final ext = data['extension'];
    if (ext is String && ext.isNotEmpty && ext != _thisSide) {
      out.add(data['scheme'] as String? ??
          f.uri.pathSegments.last.replaceFirst('.json', ''));
    }
  }
  return out;
}

/// Внутреннее имя протокола Dart → каноническое `scheme` контракта
/// (CANON §1: канон берётся из `registry/protocols/<scheme>.json` → поле
/// `scheme`). Расходится в одном месте: Dart зовёт протокол
/// `shadowsocks`, канон схемы — `ss`. Раньше разницу закрывали per-app
/// override'ы корпуса — но `scheme` определён контрактом одинаково для
/// обоих приложений, так что это была не by-design разница платформ, а
/// неканоничное имя в раннере.
const _canonScheme = <String, String>{
  'shadowsocks': 'ss',
};

/// Коды warnings из registry/warnings.json — по runtimeType Dart-класса
/// (CANON §6: коды, не отрендеренный текст). Список — зеркало
/// contract/registry/warnings.json (поле "dart"); классы без соответствия
/// в реестре в корпусе сейчас не встречаются.
const _warningCodes = <Type, String>{
  UnsupportedTransportWarning: 'transport_unsupported',
  UnsupportedProtocolWarning: 'protocol_unsupported',
  MissingFieldWarning: 'field_missing',
  DeprecatedFlowWarning: 'flow_deprecated',
  VisionWithTransportWarning: 'vision_with_transport',
  InsecureTlsWarning: 'tls_insecure',
  NaiveBuildTagWarning: 'naive_unavailable',
  UnknownFingerprintWarning: 'utls_fp_unknown',
  // D-119 (заменил D-104) — REALITY с явным отпечатком не из chrome-семейства
  // (SPEC 083 ядра); отпечаток не подменяется, только код на узле.
  RealityFingerprintWarning: 'reality_fp_not_chrome',
  XhttpParamResetWarning: 'xhttp_param_reset',
  // §416 — header-placement без режима: дописан mode: packet-up.
  XhttpModeForcedPacketUpWarning: 'xhttp_mode_forced_packet_up',
  EchIgnoredWarning: 'ech_ignored',
  UnknownObfsWarning: 'obfs_unknown',
  MissingObfsPasswordWarning: 'obfs_password_missing',
  DetourCycleBrokenWarning: 'detour_cycle_broken',
  DetourTargetMissingWarning: 'detour_target_missing',
  DetourToGroupWarning: 'detour_to_group',
  DetourChainTooDeepWarning: 'detour_chain_too_deep',
  SelectorAsAutoWarning: 'selector_as_auto',
  GroupMemberMissingWarning: 'group_member_missing',
  WsEarlyDataConvertedWarning: 'ws_early_data_converted',
  RealityShortIdInvalidWarning: 'reality_short_id_invalid',
  NaivePaddingIgnoredWarning: 'naive_padding_ignored',
  // D-105 — отброшенная пара naive extra-headers.
  NaiveExtraHeadersInvalidWarning: 'naive_extra_headers_invalid',
  TuicCongestionInvalidWarning: 'tuic_congestion_invalid',
  AwgHeaderInvalidWarning: 'awg_header_invalid',
  // §421 — AWG 3.x (SPEC 123): error-коды — причина drop, в конверт узла
  // не попадают (узел выброшен), но класс ↔ код зеркалятся для полноты.
  Awg3FieldInvalidWarning: 'awg3_field_invalid',
  Awg3HeaderKeyInvalidWarning: 'awg3_header_key_invalid',
  Awg3PaddingTooShortWarning: 'awg3_padding_too_short',
  Awg3RandomTrailersWideHeadersWarning: 'awg3_random_trailers_wide_headers',
  MasqueVhttpInvalidWarning: 'masque_vhttp_invalid',
  AnyTlsMinIdleInvalidWarning: 'anytls_min_idle_invalid',
  PacketEncodingUnknownWarning: 'packet_encoding_unknown',
  // §404 / D-085 — недостижимый `dialerProxy` роняет владельца целиком;
  // причина уезжает в `dropped[]` конверта (corpus/README, D-088).
  DialerProxyUnusableWarning: 'dialer_proxy_unusable',
};

/// Код warning'а — общий для URI- и body-раннеров.
///
/// §460 — предупреждения санитайзера реестра несут код ПОЛЕМ, а не типом
/// класса: класс на все коды реестра один.
String? warningCodeOf(NodeWarning w) =>
    w is RegistryWarning ? w.code : _warningCodes[w.runtimeType];

/// Путь поля для рукописных классов — ТОЛЬКО там, где поле класса и есть
/// путь (CANON §6: `path` обязателен у кодов уровня поля).
///
/// Приписывать путь классу, который его не знает, нельзя: раннер сверяет
/// `path` там, где ожидание его назвало, и выдуманное значение расходилось бы
/// с контрактом молча — хуже, чем честное отсутствие. Классы вне карты
/// отдают запись из одного `code`, и ожидания корпуса от них пути не требуют.
/// Путь `AwgHeaderInvalidWarning` сюда НЕ попадает намеренно: код ставится
/// пофакторно на каждый битый заголовок (`h1`…`h4` в одной ссылке — четыре
/// сообщения человеку), а конверт по контракту несёт одну запись без пути
/// (`awg_ranged_h_broken_dropped`: лаунчер зовёт `AddWarning` без поля).
/// Приписать здесь путь значило бы разбить одну запись на четыре.
String? _legacyWarningPath(NodeWarning w) => switch (w) {
      // Код уровня поля `flow`: путь назван в ожиданиях корпуса.
      DeprecatedFlowWarning() => 'flow',
      _ => null,
    };

/// Значение, вызвавшее код, — по той же логике, что и [_legacyWarningPath].
String? _legacyWarningValue(NodeWarning w) => switch (w) {
      DeprecatedFlowWarning(:final flow) => flow,
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

/// Читает URI из фикстуры: последняя непустая строка, не начинающаяся с '#'
/// (остальные строки — комментарии/источник, contract/corpus/README).
String? _readCorpusUri(File file) {
  final lines = file.readAsLinesSync();
  String? uri;
  for (final raw in lines) {
    final trimmed = raw.trimRight();
    if (trimmed.isEmpty) continue;
    if (trimmed.trimLeft().startsWith('#')) continue;
    uri = trimmed;
  }
  return uri;
}

/// Канонизирует один узел в форму contract/schema/node.schema.json (CANON §1-2).
Map<String, dynamic> _canonNode(NodeSpec spec) {
  final entry = _canonEntryMap(spec);

  final kind = spec.isGroup
      ? 'group'
      : (_endpointSchemes.contains(spec.protocol) ? 'endpoint' : 'outbound');

  final node = <String, dynamic>{
    'kind': kind,
    'scheme': _canonScheme[spec.protocol] ?? spec.protocol,
    if (spec.label.isNotEmpty) 'label': spec.label,
    'entry': entry,
  };

  if (spec.chained != null) {
    node['chain'] = [_canonNode(spec.chained!)];
  }

  // CANON §6 — конверт несёт объекты `{code, path?, value?}`, и каждая пара
  // `(code, path)` в списке ровно один раз: зеркало Go `ParsedNode.AddWarning`
  // (configtypes/types.go:548), который отбрасывает повтор. Dart-предупреждения
  // при этом остаются пофакторными (два битых AWG-заголовка = два разных
  // сообщения пользователю), но запись конверта у них одна на путь.
  final warnings = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final w in spec.warnings) {
    final rec = warningRecordOf(w);
    if (rec == null) continue;
    if (!seen.add('${rec['code']} ${rec['path'] ?? ''}')) continue;
    warnings.add(rec);
  }
  if (warnings.isNotEmpty) node['warnings'] = warnings;

  return node;
}

/// entry = spec.emit(TemplateVars.empty).map минус tag/detour (CANON §2.1-2.2),
/// рекурсивно приведённое к каноническим значениям.
Map<String, dynamic> _canonEntryMap(NodeSpec spec) {
  final SingboxEntry raw = spec.emit(TemplateVars.empty);
  final copy = Map<String, dynamic>.from(raw.map);
  copy.remove('tag');
  copy.remove('detour');
  return _canonValue(copy) as Map<String, dynamic>;
}

/// Рекурсивная канонизация значения: ключи map сортируются при сериализации
/// ([_canonEncode]), порядок списков сохраняется (CANON §2.3). Числа/bool уже
/// приходят типизированными из Dart — отдельного приведения float->int, в
/// отличие от Go-раннера (JSON round-trip через float64), не требуется.
Object? _canonValue(Object? v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, val) => out[k as String] = _canonValue(val));
    return out;
  }
  if (v is List) {
    return [for (final val in v) _canonValue(val)];
  }
  return v;
}

/// Сериализация по правилам CANON §2.3/2.6: ключи map отсортированы рекурсивно
/// (byte-order), компактный JSON. Escaping здесь не проблема — Dart's
/// `JsonEncoder` не HTML-экранирует `<`/`>`/`&` (в отличие от Go-энкодера по
/// умолчанию), так что CANON §2.7 (D-007) выполняется без дополнительных мер.
String _canonEncode(Object? v) => json.encode(_sortKeys(v));

Object? _sortKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    final out = <String, dynamic>{};
    for (final k in keys) {
      out[k] = _sortKeys(v[k]);
    }
    return out;
  }
  if (v is List) {
    return [for (final val in v) _sortKeys(val)];
  }
  return v;
}

/// Конверт целиком: {v, nodes[], dropped[]} (CANON §1). Порядок появления во
/// входе — здесь единственный узел на файл, так что этот пункт CANON §3
/// вырожден для URI-корпуса (в отличие от body-фикстур).
Map<String, dynamic> _buildEnvelope({
  List<Map<String, dynamic>> nodes = const [],
  List<Map<String, dynamic>> dropped = const [],
}) {
  return {
    'v': 1,
    'nodes': nodes,
    if (dropped.isNotEmpty) 'dropped': dropped,
  };
}

/// Pretty-print для файла (читаемость), сравнение всё равно идёт по значению
/// после канонизации ([_equalCanon]), не по байтам (CANON §7).
String _prettyPrint(Map<String, dynamic> envelope) {
  final canon = _sortKeys(envelope);
  const encoder = JsonEncoder.withIndent('  ');
  return '${encoder.convert(canon)}\n';
}

/// Сравнение конвертов по значению — компактная канонизированная форма
/// (сортировка ключей, сохранённый порядок списков), не байты файла.
///
/// `a` — наш результат, `b` — ожидание корпуса: порядок аргументов значим,
/// потому что объём сверки `warnings[]` задаёт ожидание ([_normalizeWarnings]).
bool _equalCanon(Map<String, dynamic> a, Map<String, dynamic> b) {
  final got = _deepCopy(a) as Map<String, dynamic>;
  final want = _deepCopy(b) as Map<String, dynamic>;
  _normalizeWarnings(got, want);
  _normalizeDrops(got, want);
  return _canonEncode(got) == _canonEncode(want);
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
void _normalizeDrops(Map<String, dynamic> got, Map<String, dynamic> want) {
  final gotDrops = _nodeList(got, 'dropped');
  final wantDrops = _nodeList(want, 'dropped');
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

/// Копия конверта под нормализацию: срезать поля в оригинале нельзя — тот же
/// конверт печатается в диагностике падения целиком.
Object? _deepCopy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key as String: _deepCopy(e.value),
    };
  }
  if (v is List) return [for (final e in v) _deepCopy(e)];
  return v;
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
void _normalizeWarnings(Map<String, dynamic> got, Map<String, dynamic> want) {
  final gotNodes = _nodeList(got, 'nodes');
  final wantNodes = _nodeList(want, 'nodes');
  for (var i = 0; i < gotNodes.length; i++) {
    _normalizeNodeWarnings(
        gotNodes[i], i < wantNodes.length ? wantNodes[i] : null);
  }
  // Ожидание тоже приводится к объектам — иначе строка `"tls_insecure"` и
  // объект `{code: tls_insecure}` разошлись бы формой записи.
  for (final wn in wantNodes) {
    _normalizeNodeWarnings(wn, null);
  }
}

void _normalizeNodeWarnings(
    Map<String, dynamic> node, Map<String, dynamic>? want) {
  final gotList = _warningObjects(node);
  final wantList = want == null ? null : _warningObjects(want);

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
  final gotHops = _nodeList(node, 'chain');
  final wantHops = want == null ? const <Map<String, dynamic>>[] : _nodeList(want, 'chain');
  for (var i = 0; i < gotHops.length; i++) {
    _normalizeNodeWarnings(
        gotHops[i], i < wantHops.length ? wantHops[i] : null);
  }
}

/// `warnings[]` узла как изменяемые карты, ПЕРЕПИСЫВАЯ строки-коды объектами
/// прямо в конверте: дальше сравниваются уже однородные значения.
List<Map<String, dynamic>> _warningObjects(Map<String, dynamic> node) {
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

/// Список объектов по ключу карты (`nodes`, `chain`).
List<Map<String, dynamic>> _nodeList(Map<String, dynamic> m, String key) {
  final list = m[key];
  if (list is! List) return const [];
  return [for (final e in list) if (e is Map<String, dynamic>) e];
}

void main() {
  // §UPDATE_CONTRACT — режим регенерации: переменная окружения вместо флага
  // `--update`, потому что `flutter test` не пробрасывает произвольные флаги
  // в тестовый бинарь так же прямолинейно, как `go test -run ... -update`.
  final updateGolden = Platform.environment['UPDATE_CONTRACT'] == '1';

  final root = Directory('$_contractRoot/corpus/uri');
  if (!root.existsSync()) {
    // contract/ — вендоренная копия (tool/sync_contract.sh), в git не идёт.
    test('корпус контракта не синхронизирован', () {}, skip:
        'нет $_contractRoot/corpus/uri — запустите tool/sync_contract.sh');
    return;
  }

  final cases = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.uri'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (cases.isEmpty) {
    test('корпус контракта пуст', () {}, skip: 'нет .uri файлов в $root');
    return;
  }

  final foreign = _foreignExtensionSchemes();

  group('Contract corpus (URI)', () {
    for (final file in cases) {
      final rel = file.path
          .substring(root.path.length)
          .replaceFirst(RegExp(r'^[/\\]'), '')
          .replaceAll(r'\', '/');
      final name = rel.substring(0, rel.length - '.uri'.length);
      final scheme = rel.split('/').first;
      final basePath = file.path.substring(0, file.path.length - '.uri'.length);
      final baseExpectedPath = '$basePath.expected.json';
      final overridePath = '$basePath.expected.lxbox.json';

      test(name, () {
        if (foreign.contains(scheme)) {
          // Схема — расширение чужой стороны (registry: extension != lxbox).
          // Парсера у нас нет по контракту, а не по недосмотру.
          markTestSkipped('$scheme — extension чужой стороны, парсера нет');
          return;
        }

        final uri = _readCorpusUri(file);
        if (uri == null) {
          fail('$rel: не найдена строка с URI');
        }

        Map<String, dynamic> envelope;
        NodeSpec? spec;
        try {
          spec = parseUri(uri);
        } catch (_) {
          spec = null;
        }

        if (spec == null) {
          // CANON §4: битая/нераспознанная нода → dropped, подписка живёт.
          envelope = _buildEnvelope(dropped: [
            {'ref': uri, 'reason': 'parse_error'},
          ]);
        } else {
          envelope = _buildEnvelope(nodes: [_canonNode(spec)]);
        }

        final overrideFile = File(overridePath);
        final baseFile = File(baseExpectedPath);

        if (updateGolden) {
          // Override переписывается, только если он уже заведён (значит,
          // различие задокументировано) ИЛИ результат действительно
          // расходится с общей базой. Иначе регенерация плодила бы копии —
          // ровно ту лавину, которую снёс аудит 0.8.0.
          if (overrideFile.existsSync()) {
            overrideFile.writeAsStringSync(_prettyPrint(envelope));
          } else if (baseFile.existsSync()) {
            final base = json.decode(baseFile.readAsStringSync())
                as Map<String, dynamic>;
            if (!_equalCanon(envelope, base)) {
              overrideFile.writeAsStringSync(_prettyPrint(envelope));
            }
          } else {
            overrideFile.writeAsStringSync(_prettyPrint(envelope));
          }
          return;
        }

        // Override — только для by-design различий (IDENTITY §4a); в норме
        // сверяемся с общим ожиданием, и правка канона у лаунчера доезжает
        // до нас красным тестом.
        final expectedFile =
            overrideFile.existsSync() ? overrideFile : baseFile;

        if (!expectedFile.existsSync()) {
          fail('$rel: нет ни ${baseFile.uri.pathSegments.last}, ни '
              'per-app override — кейс без ожидания не проверяет ничего');
        }

        final want = json.decode(expectedFile.readAsStringSync())
            as Map<String, dynamic>;
        if (!_equalCanon(envelope, want)) {
          fail(
            'расхождение с контрактом\n'
            '--- got ---\n${_prettyPrint(envelope)}'
            '--- want ---\n${_prettyPrint(want)}',
          );
        }
      });
    }
  });
}
