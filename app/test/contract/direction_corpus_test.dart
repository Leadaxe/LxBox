import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

// Конформанс-раннер корпуса НАПРАВЛЕНИЙ (SPEC 104, §393 A5), сторона LxBox.
// Тот же корпус гоняет лаунчер — `core/config/contract_direction_test.go`.
//
// Проверяется то, что увидит ЯДРО: `<case>.direction.json` прогоняется через
// настоящий `buildConfig` (тот же путь, что боевая сборка), из готового
// `config['outbounds']` вынимаются ГРУППЫ, и они сверяются с
// `<case>.expected.json` — по составу И ПО ПОРЯДКУ. Промежуточные структуры
// раннер не трогает намеренно: иначе он начал бы жить своей жизнью и
// перестал бы ловить расхождение с ядром.
//
// Расхождение expected = модель Направления разъехалась между платформами.

const _contractRoot = 'contract';

// ── Что раннер сверяет, а что нет ───────────────────────────────────────────

/// Поля групп, которые НЕ принадлежат модели Направления и приходят из
/// ШАБЛОНА принимающего приложения. Корпус их не нормирует (README корпуса:
/// «Не проверяется `interrupt_exist_connections`: он приходит из шаблона, а
/// не из модели Направления, и у сторон шаблоны разные»), поэтому раннер
/// снимает их с ОБЕИХ сторон.
///
/// `passive_check` (§272) — та же природа: глобальная настройка приложения,
/// у лаунчера её нет вовсе. В корпусе не встречается, снимаем на будущее.
const _templateOnlyKeys = {'interrupt_exist_connections', 'passive_check'};

/// Поля urltest-двойника, у которых на мобиле ВСЕГДА есть значение по
/// умолчанию (`DirectionAuto` — не-nullable поля), а у лаунчера они
/// omitempty. Корпус сформирован Go-раннером, поэтому `auto: {}` даёт там
/// группу вовсе без `url`/`interval`/…, а Dart честно эмитит дефолты.
///
/// Политика сверки: поле проверяется, только если ожидание его НАЗЫВАЕТ.
/// Названное — сверяется строго (кейс `auto_twin_emitted_and_default`
/// нормирует `url`+`interval`, и они обязаны доехать); не названное —
/// снимается с полученного. Это не поблажка сборке: модель мобилы физически
/// не умеет «не иметь интервала», и требовать его отсутствия значило бы
/// требовать смены модели, чего корпус не просит.
const _autoDefaultKeys = {'url', 'interval', 'tolerance', 'idle_timeout'};

// ── Скипы ───────────────────────────────────────────────────────────────────

/// `fold_*` — SPEC 108, свёртка подписки в группу. Фаза E закрыта решением
/// оператора (24.08.2026): свёртки на мобиле НЕ БУДЕТ. Кейсы остаются в
/// общем корпусе ради лаунчера; для LxBox они не применимы навсегда, а не
/// «пока».
const _skipFold = 'na: свёртка подписки в группу (SPEC 108) на мобиле не '
    'нужна — фаза E закрыта решением оператора 24.08.2026';

/// Коды предупреждений корпуса → как их опознать в `emitWarnings` LxBox.
///
/// Реестр (`registry/warnings.json`) — нормативный словарь кодов, и там, где
/// у кода есть поле `dart` (класс `NodeWarning`), сверка идёт по классу
/// (так делает `contract_test.dart`). Но `emitWarnings` билдера — это не
/// `NodeWarning`, а готовые EN-строки уровня СБОРКИ: у Направлений своих
/// классов нет, и коды `direction_*` в реестре не объявлены вовсе. Поэтому
/// здесь — единственный доступный шов: предикат по строке.
///
/// Предикаты держатся за формулировку билдера, а не за подстроку общего
/// вида: «node filter matched no nodes» — это ровно та ветка
/// `_buildDirectionGroups`, что отвечает коду.
const _warningProbes = <String, bool Function(String)>{
  'direction_filter_matched_nothing': _isFilterMatchedNothing,
  // §393 C — коды цепочек. Предикаты держатся за ветку билдера, породившую
  // строку, а не за подстроку общего вида: иначе «chain» матчило бы любой
  // текст, где встретилось слово.
  'chain_unsupported_by_core': _isChainUnsupported,
  'chain_hop_missing': _isChainHopMissing,
  'chain_cycle_through_direction': _isChainCycleThroughDirection,
};

bool _isFilterMatchedNothing(String line) =>
    line.contains('node filter matched no nodes');

bool _isChainUnsupported(String line) =>
    line.contains('does not know the "chain" outbound type');

bool _isChainHopMissing(String line) =>
    line.contains('A route without a hop is a different route') ||
    line.contains('a route without a hop would be a different route');

bool _isChainCycleThroughDirection(String line) =>
    line.contains('was left out of it') || line.contains('were left out of it');

/// Коды, которые LxBox не умеет выдать в принципе (нет фичи). Встретив такой
/// код в ожиданиях НЕ-скипнутого кейса, раннер обязан упасть, а не молчать —
/// поэтому список пуст: всё, чего нет, лежит в chain_*/fold_*.
const _unsupportedCodes = <String>{};

/// Кейсы, у которых сверяются ТОЛЬКО предупреждения, а список групп — нет,
/// с обоснованием. Пустой список групп у такого кейса — следствие того, что
/// сборка ЛАУНЧЕРА не доходит до Направлений, а не свойство модели.
///
/// Не «поблажка»: раннер по-прежнему проверяет ровно то, ради чего кейс
/// заведён (README корпуса называет для `empty_pool_no_warning` одну
/// частность — «предупреждение выдаётся, только когда виноват отбор»), и
/// проверяет строго. Молчаливого прохода нет: причина названа здесь и
/// печатается в отчёте прогона.
const _groupsNotComparable = <String, String>{
  'empty_pool_no_warning':
      'ожидание groups:[] описывает АВАРИЮ СБОРКИ лаунчера, а не модель: при '
          'нулевом пуле GenerateOutboundsFromParserConfig возвращает ошибку '
          '«no nodes parsed from any source» (outbound_generator.go:1050), '
          'Go-раннер получает res==nil и печатает пустой список. У LxBox '
          'такого обрыва нет и быть не должно: buildConfig обязан отдать '
          'РАБОЧИЙ конфиг, а Направление — цель route.rules[].outbound, и его '
          'исчезновение сделало бы ссылку висячей. Мобила применяет ту же '
          'политику, которую корпус объявляет верной в empty_direction_blocks '
          '(§201/§274): [block, direct-out] с default=block. Сверяется то, '
          'ради чего кейс заведён (README корпуса:52) — отсутствие '
          'предупреждения.',
};

void main() {
  final root = Directory('$_contractRoot/corpus/direction');
  if (!root.existsSync()) {
    // contract/ — вендоренная копия (tool/sync_contract.sh), в git не идёт.
    test('корпус Направлений не синхронизирован', () {},
        skip: 'нет ${root.path} — запустите tool/sync_contract.sh');
    return;
  }

  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.direction.json'))
      .map((f) => f.path.substring(0, f.path.length - '.direction.json'.length))
      .toList()
    ..sort();

  if (cases.isEmpty) {
    // Пустой корпус = раннер, который всегда зелёный. Это отказ, а не skip.
    test('корпус Направлений пуст', () {
      fail('нет .direction.json в ${root.path}');
    });
    return;
  }

  group('contract corpus: Directions', () {
    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      // §393 C — `chain_*` больше не скипаются: цепочки реализованы
      // (C1–C5). `fold_*` скипнуты навсегда (фаза E закрыта).
      final skip = name.startsWith('fold_') ? _skipFold : null;

      test(name, () async {
        final input = jsonDecode(File('$base.direction.json').readAsStringSync())
            as Map<String, dynamic>;
        final expected =
            jsonDecode(File('$base.expected.json').readAsStringSync())
                as Map<String, dynamic>;
        await _runCase(name, input, expected);
      }, skip: skip);
    }
  });
}

Future<void> _runCase(
  String name,
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
) async {
  final doc = input['_'] as String? ?? '';
  final magic = (input['magic'] as Map?)?.cast<String, dynamic>() ?? const {};

  // `magic` — теги служебных опций ПРИНИМАЮЩЕГО конфига: у лаунчера
  // `block-out`, у мобилы `block` (`kBlockOutboundTag`). Корпус нормирует
  // СТРУКТУРУ, а не чужие имена, поэтому ожидание переводится в теги LxBox.
  final tagMap = <String, String>{
    if (magic['direct'] is String) magic['direct'] as String: kDirectOutboundTag,
    if (magic['block'] is String) magic['block'] as String: kBlockOutboundTag,
  };
  String local(String tag) => tagMap[tag] ?? tag;

  final nodeTags =
      ((input['node_tags'] as List?) ?? const []).cast<String>().toList();
  final groupTags =
      ((input['group_tags'] as List?) ?? const []).cast<String>().toSet();

  final directions = [
    for (final raw in ((input['directions'] as List?) ?? const []))
      _toDirection((raw as Map).cast<String, dynamic>()),
  ];

  // §393 C — источники-цепочки в порядке объявления (порядок нормативен:
  // ссылка позиции разрешена только на объявленную ВЫШЕ).
  final chains = [
    for (final raw in ((input['chains'] as List?) ?? const []))
      _toChain((raw as Map).cast<String, dynamic>()),
  ];
  // `core_supports_chain` — единственное свойство ОКРУЖЕНИЯ в корпусе
  // (README корпуса). У мобилы гейт идёт по версии ядра, поэтому false
  // переводится в заведомо старую версию, true/отсутствие — в актуальную.
  final coreSupportsChain = input['core_supports_chain'] as bool? ?? true;

  final result = await buildConfig(
    lists: nodeTags.isEmpty ? const [] : [_sourceFor(nodeTags, groupTags)],
    template: _template(),
    settings: BuildSettings(
      directions: directions,
      chains: chains,
      coreVersion:
          coreSupportsChain ? '1.14.0-lx.27-rc.6' : '1.14.0-lx.27-rc.4',
    ),
  );
  expect(result.validation.isOk, isTrue,
      reason: '$doc\nконфиг не проходит валидацию:\n'
          '${result.validation.issues.join('\n')}');

  // ── группы ────────────────────────────────────────────────────────────────
  final why = _groupsNotComparable[name];
  if (why == null) {
    final gotGroups = _groupsOf(result, nodeTags, groupTags);
    final wantGroups = [
      for (final g in ((expected['groups'] as List?) ?? const []))
        _localizeGroup((g as Map).cast<String, dynamic>(), local),
    ];

    // Порядок нормативен (README корпуса: «сначала auto-группа, потом само
    // Направление; внутри состава — сначала служебные опции и ссылки на
    // другие Направления, потом узлы в порядке конфига»), поэтому сравнение
    // — позиционное, а не по множеству.
    expect(_fmt(_stripUnnamedAutoDefaults(gotGroups, wantGroups)),
        _fmt(wantGroups),
        reason: doc);
  } else {
    // Кейс не остаётся без рубежа: сверяем то, что у мобилы ЕСТЬ вместо
    // аварии лаунчера, — Направление живо и уводит трафик в block, а не
    // исчезает (иначе `route.rules[].outbound` повиснет).
    final gotGroups = _groupsOf(result, nodeTags, groupTags);
    expect(_fmt(gotGroups), _fmt([
      for (final d in directions)
        if (d.enabled)
          {
            'tag': d.tag,
            'type': 'selector',
            'outbounds': [kBlockOutboundTag, kDirectOutboundTag],
            'default': kBlockOutboundTag,
          },
    ]), reason: '$doc\n\nсписок групп сверяется по правилу LxBox, не по '
        'ожиданию корпуса — $why');
  }

  // ── предупреждения ────────────────────────────────────────────────────────
  final wantCodes =
      ((expected['warnings'] as List?) ?? const []).cast<String>().toSet();
  for (final code in wantCodes) {
    expect(_unsupportedCodes.contains(code), isFalse,
        reason: '$doc\nкод "$code" объявлен неподдерживаемым, но кейс не '
            'скипнут — либо реализуйте, либо скипните кейс явно');
    final probe = _warningProbes[code];
    expect(probe, isNotNull,
        reason: '$doc\nкод "$code" не описан в _warningProbes раннера');
    expect(result.emitWarnings.any(probe!), isTrue,
        reason: '$doc\nожидалось предупреждение "$code", получено:\n'
            '${result.emitWarnings.join('\n')}');
  }
  // Обратная сторона: код, которого корпус НЕ ждёт, не должен возникать —
  // иначе «предупреждаем всегда» проходило бы корпус молча.
  for (final entry in _warningProbes.entries) {
    if (wantCodes.contains(entry.key)) continue;
    expect(result.emitWarnings.any(entry.value), isFalse,
        reason: '$doc\nлишнее предупреждение "${entry.key}":\n'
            '${result.emitWarnings.join('\n')}');
  }
}

// ── вход ────────────────────────────────────────────────────────────────────

/// Канон (`schema/direction.schema.json`) → модель LxBox. Это и есть
/// проверяемый шов: если маппинг перестанет быть однозначным, корпус
/// развалится раньше, чем расхождение доедет до пользователя.
Direction _toDirection(Map<String, dynamic> c) {
  final auto = c['auto'];
  return Direction(
    tag: c['tag'] as String? ?? '',
    enabled: c['enabled'] as bool? ?? true,
    includeDirect: c['include_direct'] as bool? ?? false,
    includeBlock: c['include_block'] as bool? ?? false,
    include: ((c['include'] as List?) ?? const []).cast<String>().toList(),
    nodeFilter: c['filter'] as String? ?? '',
    nodeFilterInvert: c['invert'] as bool? ?? false,
    defaultFilter: c['default'] as String? ?? '',
    interruptExistConnections:
        c['interrupt_exist_connections'] as bool? ?? true,
    auto: auto is Map ? _toAuto(auto.cast<String, dynamic>()) : null,
  );
}

/// Канон (`schema/source_chain.schema.json`) + `tag` корпуса → модель LxBox.
SourceChain _toChain(Map<String, dynamic> c) => SourceChain(
      tag: c['tag'] as String? ?? '',
      hops: ((c['hops'] as List?) ?? const []).cast<String>().toList(),
      idleTimeout: c['idle_timeout'] as String? ?? '',
      stripEvasion:
          c['strip_evasion'] is bool ? c['strip_evasion'] as bool : null,
      strip: {
        for (final e in ((c['strip'] as Map?) ?? const {}).entries)
          if (e.value is bool) e.key.toString(): e.value as bool,
      },
      rewrite: ((c['rewrite'] as Map?) ?? const {}).cast<String, dynamic>(),
    );

DirectionAuto _toAuto(Map<String, dynamic> a) {
  const d = DirectionAuto();
  final sticky = a['sticky_hash'] as List?;
  return DirectionAuto(
    url: a['url'] as String? ?? d.url,
    interval: a['interval'] as String? ?? d.interval,
    tolerance: (a['tolerance'] as num?)?.toInt() ?? d.tolerance,
    idleTimeout: a['idle_timeout'] as String? ?? d.idleTimeout,
    interruptExistConnections:
        a['interrupt_exist_connections'] as bool? ?? d.interruptExistConnections,
    mode: UrltestMode.fromWire(a['mode'] as String?),
    pool: (a['pool'] as num?)?.toInt() ?? d.pool,
    poolTolerance: (a['pool_tolerance'] as num?)?.toInt() ?? 0,
    stickyHash: sticky == null
        ? d.stickyHash
        : [
            for (final s in sticky.cast<String>())
              if (StickyHashKey.fromWire(s) != null) StickyHashKey.fromWire(s)!,
          ],
  );
}

/// Минимальный шаблон: служебные outbound'ы и пустой route. Направления
/// приходят целиком из `settings.directions`, поэтому `groupTemplates` пуст —
/// иначе билдер пошёл бы template-fallback'ом и собрал СВОИ Направления.
///
/// Служебных outbound'а ДВА, как в боевом `wizard_template.json`
/// (`magic_nodes.direct`/`magic_nodes.block`). Корпус переводит `block-out`
/// лаунчера в [kBlockOutboundTag] и ждёт его в составе (`include_block`,
/// block-fallback пустого Направления) — без ЗАПИСИ такой тег для
/// граф-санитайзера (§393 A4) призрак, ровно как и для `validator.dart`,
/// который строит `allTags` по фактическим outbounds/endpoints.
WizardTemplate _template() => WizardTemplate(
      parserConfig: ParserConfigBlock(),
      groupTemplates: GroupTemplates(),
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': kDirectOutboundTag, 'type': 'direct'},
          {'tag': kBlockOutboundTag, 'type': 'block'},
        ],
        'route': {'rules': <dynamic>[]},
      },
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

/// Источник кейса: узлы с ТОЧНО заданными итоговыми тегами (`tag_prefix`
/// пуст, дедуп не срабатывает — корпус даёт уникальные имена).
///
/// `group_tags` — «группа выбора подписки, пришедшая узлом из импортированного
/// sing-box-конфига» (README корпуса). У мобилы это [AutoSelectSpec]: тот же
/// водораздел (нет server/port, `type: urltest` в конфиге), и билдер отличает
/// её ровно по типу эмитированной записи.
UserServer _sourceFor(List<String> nodeTags, Set<String> groupTags) {
  final nodes = <NodeSpec>[];
  for (var i = 0; i < nodeTags.length; i++) {
    final tag = nodeTags[i];
    if (groupTags.contains(tag)) {
      // Состав пула — все обычные узлы кейса (`include: '.'` матчит любой
      // тег): непустой, иначе билдер группу не эмитит вовсе — пустой urltest
      // роняет старт ядра.
      nodes.add(AutoSelectSpec(
        id: 'g$i',
        tag: tag,
        label: tag,
        membership: const RuleMembers(include: '.'),
      ));
      continue;
    }
    final spec = parseUri('vless://u$i@h$i.example:443'
        '?type=ws&security=tls#${Uri.encodeComponent(tag)}');
    expect(spec, isNotNull, reason: 'не разобрался узел корпуса "$tag"');
    nodes.add(spec!);
  }
  return UserServer(
    id: 'corpus',
    name: 'corpus',
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
    origin: UserSource.paste,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    nodes: nodes,
  );
}

// ── выход ───────────────────────────────────────────────────────────────────

/// Группы из готового конфига в порядке эмиссии. Узлы кейса (в т.ч. группа
/// подписки из `group_tags`) в ожидания не входят — корпус проверяет ГРУППЫ
/// Направлений, а узлы приходят входом.
List<Map<String, dynamic>> _groupsOf(
  BuildResult r,
  List<String> nodeTags,
  Set<String> groupTags,
) {
  final nodeTagSet = nodeTags.toSet();
  final out = <Map<String, dynamic>>[];
  for (final raw in (r.config['outbounds'] as List)) {
    final m = (raw as Map).cast<String, dynamic>();
    final tag = m['tag'] as String? ?? '';
    final type = m['type'] as String? ?? '';
    if (tag.isEmpty || nodeTagSet.contains(tag)) continue;
    // §393 C — цепочка попадает в ожидания корпуса наравне с группами:
    // `chain_packet_order` нормирует и её позицию в списке, и порядок хопов.
    if (type != 'selector' && type != 'urltest' && type != kChainOutboundType) {
      continue;
    }
    // Служебные outbound'ы шаблона (`direct-out`) — не группы, но на всякий
    // случай отсекаются типом выше.
    out.add({
      for (final e in m.entries)
        if (!_templateOnlyKeys.contains(e.key)) e.key: e.value,
    });
  }
  return out;
}

/// Ожидание в терминах LxBox: служебные теги переведены (`block-out`→`block`)
/// и там, и внутри `outbounds`/`default`.
Map<String, dynamic> _localizeGroup(
  Map<String, dynamic> g,
  String Function(String) local,
) {
  final out = <String, dynamic>{};
  g.forEach((k, v) {
    if (_templateOnlyKeys.contains(k)) return;
    if (k == 'default' && v is String) {
      out[k] = local(v);
    } else if (k == 'outbounds' && v is List) {
      out[k] = [for (final t in v.cast<String>()) local(t)];
    } else {
      out[k] = v;
    }
  });
  return out;
}

/// Снимает с ПОЛУЧЕННЫХ групп те urltest-поля дефолтов, которых ожидание не
/// называет (см. [_autoDefaultKeys]). Названное остаётся и сверяется строго.
List<Map<String, dynamic>> _stripUnnamedAutoDefaults(
  List<Map<String, dynamic>> got,
  List<Map<String, dynamic>> want,
) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < got.length; i++) {
    final g = got[i];
    if (g['type'] != 'urltest' || i >= want.length) {
      out.add(g);
      continue;
    }
    final w = want[i];
    out.add({
      for (final e in g.entries)
        if (!(_autoDefaultKeys.contains(e.key) && !w.containsKey(e.key)))
          e.key: e.value,
    });
  }
  return out;
}

/// Читаемый дифф И канонизация сразу: ключи map отсортированы РЕКУРСИВНО,
/// порядок списков и групп сохранён.
///
/// Порядок КЛЮЧЕЙ внутри группы не нормативен и нормативным быть не может:
/// Go-раннер сравнивает `json.MarshalIndent` от `map[string]interface{}`, а
/// Go сортирует ключи map — то есть порядок в самих `.expected.json`
/// (`tag, type, default, outbounds`) до сравнения не доживает и там. Тот же
/// приём, что в `contract_test.dart` (`_sortKeys`, CANON §2.3).
///
/// Порядок СПИСКОВ и порядок ГРУПП, наоборот, нормативны (README корпуса) и
/// сохраняются.
String _fmt(List<Map<String, dynamic>> groups) =>
    const JsonEncoder.withIndent('  ').convert(_sortKeys(groups));

Object? _sortKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sortKeys(v[k])};
  }
  if (v is List) return [for (final e in v) _sortKeys(e)];
  return v;
}
