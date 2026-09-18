import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'corpus_warnings.dart';

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

/// §470 — корень контракта, правила записи `warnings[]` и нормализация
/// сравнения переехали в `corpus_warnings.dart`: те же правила нужны
/// body-раннеру, а две копии нормативного кода разошлись бы на первом же
/// бампе контракта.
const _contractRoot = kContractRoot;

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

// §460 W2a — таблица «класс → код» и `warningCodeOf` переехали в lib
// (`services/contract/warning_codes.dart`): второй их потребитель — дедуп
// предупреждений реестра при разборе, и держать две копии значило бы
// разойтись на первом же новом классе. Раннеры (этот и body-) импортируют
// имя оттуда. Предупреждения санитайзера несут код ПОЛЕМ, а не типом класса:
// класс на все коды реестра один.

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

  // §470 — правила записи `warnings[]` (CANON §6: дедуп по `(code, path)`,
  // порядок `body.order` реестра) живут в `corpus_warnings.dart`, общем с
  // body-раннером: они нормативны, и вторая копия разошлась бы с контрактом
  // на первом же бампе.
  final warnings = warningListOf(
      spec.warnings, _canonScheme[spec.protocol] ?? spec.protocol);
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
/// ([canonEncode]), порядок списков сохраняется (CANON §2.3). Числа/bool уже
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

/// Сравнение конвертов по значению — компактная канонизированная форма
/// (сортировка ключей, сохранённый порядок списков), не байты файла.
///
/// `a` — наш результат, `b` — ожидание корпуса: порядок аргументов значим,
/// потому что объём сверки `warnings[]` задаёт ожидание ([normalizeWarnings]).
bool _equalCanon(Map<String, dynamic> a, Map<String, dynamic> b) {
  final got = deepCopyEnvelope(a) as Map<String, dynamic>;
  final want = deepCopyEnvelope(b) as Map<String, dynamic>;
  normalizeWarnings(got, want);
  normalizeDrops(got, want);
  return canonEncode(got) == canonEncode(want);
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
    // §469 — реестр грузится и здесь. Правила, которые парсер берёт ИЗ
    // РЕЕСТРА (какие TLS-блоки схема запрещает и с каким кодом —
    // `forbiddenTlsBlockWarnings`), без него молчат, и раннер проверял бы
    // поведение, которого в приложении не бывает: `main()` грузит реестр до
    // `runApp`, то есть любой разбор в проде идёт с загруженным реестром.
    setUpAll(() async {
      if (Directory('$_contractRoot/registry').existsSync()) {
        await ContractRegistry.I.loadFromDirectory(_contractRoot);
      }
    });

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
            overrideFile.writeAsStringSync(prettyPrintEnvelope(envelope));
          } else if (baseFile.existsSync()) {
            final base = json.decode(baseFile.readAsStringSync())
                as Map<String, dynamic>;
            if (!_equalCanon(envelope, base)) {
              overrideFile.writeAsStringSync(prettyPrintEnvelope(envelope));
            }
          } else {
            overrideFile.writeAsStringSync(prettyPrintEnvelope(envelope));
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
            '--- got ---\n${prettyPrintEnvelope(envelope)}'
            '--- want ---\n${prettyPrintEnvelope(want)}',
          );
        }
      });
    }
  });
}
