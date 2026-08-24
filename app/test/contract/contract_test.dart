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
// результат с <case>.expected.lxbox.json.
//
// Намеренно ОТДЕЛЬНЫЙ файл ожиданий (.expected.lxbox.json), а не
// <case>.expected.json — тот принадлежит лаунчеру (contract/docs/CANON.md
// §7, per-app override), Dart его не читает и не перезаписывает.
//
// Регенерация ожиданий LxBox:
//
//   cd app && UPDATE_CONTRACT=1 flutter test test/contract/
//
// Это ОСОЗНАННЫЙ шаг: expected нормативны для этой стороны, дифф идёт в PR
// с ревью (contract/README.md §2).

/// Корень скопированного контракта — кладёт tool/sync_contract.sh.
const _contractRoot = 'contract';

/// Соответствие имени каталога корпуса (= scheme из registry/protocols/*.json,
/// contract/docs/CANON.md §1) типу kind в конверте. Все схемы вне карты —
/// обычный outbound; wireguard — endpoint (CANON §1, registry: kind=endpoint).
const _endpointSchemes = {'wireguard'};

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
};

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
    'scheme': spec.protocol,
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

  group('Contract corpus (URI)', () {
    for (final file in cases) {
      final rel = file.path
          .substring(root.path.length)
          .replaceFirst(RegExp(r'^[/\\]'), '')
          .replaceAll(r'\', '/');
      final name = rel.substring(0, rel.length - '.uri'.length);
      final basePath = file.path.substring(0, file.path.length - '.uri'.length);
      final expectedPath = '$basePath.expected.lxbox.json';

      test(name, () {
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

        final expectedFile = File(expectedPath);

        if (updateGolden) {
          expectedFile.writeAsStringSync(_prettyPrint(envelope));
          return;
        }

        if (!expectedFile.existsSync()) {
          // Ожидание ещё не сгенерировано для стороны LxBox — не валим
          // прогон, честно пропускаем (регенерация: UPDATE_CONTRACT=1).
          markTestSkipped(
              'нет ${expectedFile.uri.pathSegments.last} — сгенерируйте UPDATE_CONTRACT=1');
          return;
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
