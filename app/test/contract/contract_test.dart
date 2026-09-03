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
const _endpointSchemes = {'wireguard'};

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
  TuicCongestionInvalidWarning: 'tuic_congestion_invalid',
  AwgHeaderInvalidWarning: 'awg_header_invalid',
  MasqueVhttpInvalidWarning: 'masque_vhttp_invalid',
  AnyTlsMinIdleInvalidWarning: 'anytls_min_idle_invalid',
  PacketEncodingUnknownWarning: 'packet_encoding_unknown',
  // §404 / D-085 — недостижимый `dialerProxy` роняет владельца целиком;
  // причина уезжает в `dropped[]` конверта (corpus/README, D-088).
  DialerProxyUnusableWarning: 'dialer_proxy_unusable',
};

/// Код warning'а по классу — общий для URI- и body-раннеров.
String? warningCodeOf(NodeWarning w) => _warningCodes[w.runtimeType];

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

  // CANON §6 — конверт несёт КОДЫ, и каждый код в списке ровно один раз:
  // зеркало Go `ParsedNode.AddWarning` (configtypes/types.go:548), который
  // отбрасывает повтор. Dart-предупреждения при этом остаются пофакторными
  // (два битых AWG-заголовка = два разных сообщения пользователю), но код
  // деградации у них общий.
  final codes = <String>[];
  for (final w in spec.warnings) {
    final code = _warningCodes[w.runtimeType];
    if (code != null && !codes.contains(code)) codes.add(code);
  }
  if (codes.isNotEmpty) node['warnings'] = codes;

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
bool _equalCanon(Map<String, dynamic> a, Map<String, dynamic> b) {
  return _canonEncode(a) == _canonEncode(b);
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
