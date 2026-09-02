import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

// §393 C3–C5 — эмиссия источников-цепочек через НАСТОЯЩИЙ `buildConfig`.
//
// Корпус (`test/contract/direction_corpus_test.dart`) нормирует те же вещи со
// стороны контракта; здесь — случаи, которых в корпусе нет: ссылка ВПЕРЁД,
// вложенная цепочка не первой позицией, коллизия тега, выключенная цепочка,
// гейт версии ядра на самой сборке.

const _newCore = '1.14.0-lx.27-rc.6';
const _oldCore = '1.14.0-lx.27-rc.4';

void main() {
  group('§393 C3 — эмиссия цепочки узлом type:chain', () {
    test('порядок хопов = порядок ПАКЕТА, ключ ядра — outbounds', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'via-de', hops: ['DE', 'NL'])],
      );
      final chain = _byTag(r, 'via-de')!;
      expect(chain['type'], 'chain');
      // Первая позиция — ближайший к клиенту хоп. Перевёрнутый список дал бы
      // работающий, но ДРУГОЙ маршрут (SPEC 110 T3).
      expect(chain['outbounds'], ['DE', 'NL']);
    });

    test('цепочка — узел: её ловит фильтр Направления наравне с серверами',
        () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'via-de', hops: ['DE', 'NL'])],
        directions: [const Direction(tag: 'vpn-1', nodeFilter: 'via')],
      );
      expect(_byTag(r, 'vpn-1')!['outbounds'], ['via-de']);
    });

    test('цепочка эмитится ПЕРЕД группами Направлений', () async {
      final r = await _build(
        nodeTags: ['DE'],
        chains: [const SourceChain(tag: 'ch', hops: ['DE', 'direct-out'])],
        directions: [const Direction(tag: 'vpn-1')],
      );
      final tags = [
        for (final o in (r.config['outbounds'] as List))
          (o as Map)['tag'] as String,
      ];
      expect(tags.indexOf('ch'), lessThan(tags.indexOf('vpn-1')));
    });

    test('strip / strip_evasion / idle_timeout / rewrite доезжают в raw-объект',
        () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [
          const SourceChain(
            tag: 'tuned',
            hops: ['DE', 'NL'],
            idleTimeout: '10m',
            stripEvasion: false,
            strip: {kChainStripTlsUtls: true, kChainStripTlsFragment: false},
            rewrite: {
              'vless': {'packet_encoding': 'xudp'},
            },
          ),
        ],
      );
      final chain = _byTag(r, 'tuned')!;
      expect(chain['idle_timeout'], '10m');
      expect(chain['strip_evasion'], isFalse);
      expect(chain['strip'], {'tls.fragment': false, 'tls.utls': true});
      expect(chain['rewrite'], {
        'vless': {'packet_encoding': 'xudp'},
      });
    });

    test('умолчания в конфиг не пишутся', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'ch', hops: ['DE', 'NL'])],
      );
      final chain = _byTag(r, 'ch')!;
      expect(chain.containsKey('strip_evasion'), isFalse);
      expect(chain.containsKey('strip'), isFalse);
      expect(chain.containsKey('idle_timeout'), isFalse);
      expect(chain.containsKey('rewrite'), isFalse);
    });

    test('выключенная цепочка не эмитится и не шумит warning-ом', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [
          const SourceChain(tag: 'off', hops: ['DE', 'NL'], enabled: false)
        ],
      );
      expect(_byTag(r, 'off'), isNull);
      expect(r.emitWarnings, isEmpty);
    });
  });

  group('§393 C3 — порядок объявления и ссылка вперёд', () {
    test('ссылка на цепочку, объявленную ВЫШЕ, — законна (позиция 0)',
        () async {
      final r = await _build(
        nodeTags: ['DE', 'NL', 'SG'],
        chains: [
          const SourceChain(tag: 'inner', hops: ['DE', 'NL']),
          const SourceChain(tag: 'outer', hops: ['inner', 'SG']),
        ],
      );
      expect(_byTag(r, 'inner'), isNotNull);
      expect(_byTag(r, 'outer')!['outbounds'], ['inner', 'SG']);
      expect(r.emitWarnings, isEmpty);
    });

    test('ссылка ВПЕРЁД дропает цепочку целиком (антицикл держится порядком)',
        () async {
      // Порядок объявления — единственное, чем исключены циклы между
      // цепочками. Ссылка вниз неотличима от ссылки в никуда и обязана
      // деградировать так же.
      final r = await _build(
        nodeTags: ['DE', 'NL', 'SG'],
        chains: [
          const SourceChain(tag: 'outer', hops: ['inner', 'SG']),
          const SourceChain(tag: 'inner', hops: ['DE', 'NL']),
        ],
      );
      expect(_byTag(r, 'outer'), isNull, reason: 'ссылка вперёд не эмитится');
      expect(_byTag(r, 'inner'), isNotNull, reason: 'вторая цепочка невиновна');
      expect(r.emitWarnings.join('\n'), contains('was not found'));
      expect(r.emitWarnings.join('\n'), contains('declared above it'));
    });

    test('позиция в никуда дропает ЦЕПОЧКУ, а не одну позицию', () async {
      final r = await _build(
        nodeTags: ['DE'],
        chains: [const SourceChain(tag: 'broken', hops: ['DE', 'SG'])],
      );
      expect(_byTag(r, 'broken'), isNull);
      // Именно «целиком»: маршрут без хопа — другой маршрут.
      expect(r.emitWarnings.join('\n'),
          contains('A route without a hop is a different route'));
    });

    test('вложенная цепочка позицией ≥1 дропает цепочку', () async {
      // Инвариант ядра `protocol/chain/chain.go:279`: звено — это «узел через
      // предыдущую позицию», а цепочка не узел.
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [
          const SourceChain(tag: 'inner', hops: ['DE', 'NL']),
          const SourceChain(tag: 'outer', hops: ['DE', 'inner']),
        ],
      );
      expect(_byTag(r, 'outer'), isNull);
      expect(r.emitWarnings.join('\n'),
          contains('only as the first hop'));
    });

    test('коллизия тега с Направлением дропает цепочку, а не ломает конфиг',
        () async {
      // Два outbound'а с одним тегом — отказ ядра на ВЕСЬ конфиг.
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'vpn-1', hops: ['DE', 'NL'])],
        directions: [const Direction(tag: 'vpn-1')],
      );
      final vpn1 = _byTag(r, 'vpn-1')!;
      expect(vpn1['type'], 'selector', reason: 'Направление уцелело');
      expect(r.emitWarnings.join('\n'), contains('already taken'));
    });

    test('цепочка, нарушающая инвариант ядра, не эмитится (chain_invalid)',
        () async {
      final r = await _build(
        nodeTags: ['DE'],
        chains: [const SourceChain(tag: 'solo', hops: ['DE'])],
      );
      expect(_byTag(r, 'solo'), isNull);
      expect(r.emitWarnings.join('\n'), contains('at least two'));
    });
  });

  group('§393 C4 / T9 — Направление не берёт цепочку через себя', () {
    test('прямой случай [proxy-out, exit] при фильтре «всё»', () async {
      // Самый частый сценарий из всех (§393 L6): фильтр Направления ловит
      // цепочку, которая через это же Направление проходит.
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'via-de', hops: ['proxy-out', 'NL'])],
        directions: [const Direction(tag: 'proxy-out')],
      );
      expect(_byTag(r, 'via-de'), isNotNull, reason: 'сама цепочка жива');
      expect(_byTag(r, 'proxy-out')!['outbounds'], ['DE', 'NL']);
      expect(r.emitWarnings.join('\n'), contains('was left out of it'));
    });

    test('ТРАНЗИТИВНО: цепочка через цепочку через Направление', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL', 'SG'],
        chains: [
          const SourceChain(tag: 'inner', hops: ['proxy-out', 'NL']),
          const SourceChain(tag: 'outer', hops: ['inner', 'SG']),
        ],
        directions: [const Direction(tag: 'proxy-out')],
      );
      // Обе цепочки эмитированы, но ни одна не входит в proxy-out: outer
      // проходит через proxy-out ЧЕРЕЗ inner.
      expect(_byTag(r, 'inner'), isNotNull);
      expect(_byTag(r, 'outer'), isNotNull);
      expect(_byTag(r, 'proxy-out')!['outbounds'], ['DE', 'NL', 'SG']);
    });

    test('в ЧУЖОЕ Направление та же цепочка входит обычным узлом', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'via-de', hops: ['proxy-out', 'NL'])],
        directions: [
          const Direction(tag: 'proxy-out'),
          const Direction(tag: 'other', nodeFilter: 'via'),
        ],
      );
      expect(_byTag(r, 'other')!['outbounds'], ['via-de']);
    });

    test('вычет T9 НЕ винит фильтр Направления', () async {
      // Фильтр поймал ровно цепочку и отработал правильно; убрал её T9.
      // Сказать тут «node filter matched no nodes — Check its node filter»
      // значит отправить пользователя искать несуществующую опечатку вместо
      // настоящей причины, которая названа отдельной строкой про цикл.
      final r = await _build(
        nodeTags: ['DE'],
        chains: [const SourceChain(tag: 'via-de', hops: ['proxy-out', 'DE'])],
        directions: [
          const Direction(tag: 'proxy-out', nodeFilter: 'via')
        ],
      );
      expect(r.emitWarnings.join('\n'), isNot(contains('Check its node filter')));
      expect(r.directionsWithoutNodes, isEmpty,
          reason: 'SnackBar «Направления без узлов» тут был бы ложной тревогой');
      expect(r.emitWarnings.join('\n'), contains('was left out of it'));
    });

    test('фильтр, реально не поймавший ничего, по-прежнему предупреждает',
        () async {
      // Обратная сторона: гейт не должен заодно проглотить настоящую
      // болезнь §200/§274.
      final r = await _build(
        nodeTags: ['DE'],
        directions: [
          const Direction(tag: 'vpn-1', nodeFilter: 'nomatch')
        ],
      );
      expect(r.emitWarnings.join('\n'), contains('Check its node filter'));
      expect(r.directionsWithoutNodes, ['vpn-1']);
    });

    test('без цепочек состав Направления не меняется вовсе', () async {
      // Конфиги без цепочек обязаны собираться байт-в-байт как раньше.
      final r = await _build(nodeTags: ['DE', 'NL'], chains: []);
      expect(_byTag(r, 'vpn-1')!['outbounds'], ['DE', 'NL']);
      expect(r.emitWarnings, isEmpty);
    });
  });

  group('§393 C5 — гейт версии ядра живёт в СБОРКЕ', () {
    test('старое ядро: цепочка не эмитится, остальное собирается', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'ch', hops: ['DE', 'NL'])],
        directions: [const Direction(tag: 'vpn-1')],
        coreVersion: _oldCore,
      );
      expect(_byTag(r, 'ch'), isNull);
      expect(_byTag(r, 'vpn-1')!['outbounds'], ['DE', 'NL']);
      expect(r.emitWarnings.join('\n'),
          contains('does not know the "chain" outbound type'));
      expect(r.emitWarnings.join('\n'), contains(_oldCore));
    });

    test('новое ядро: цепочка эмитится', () async {
      final r = await _build(
        nodeTags: ['DE', 'NL'],
        chains: [const SourceChain(tag: 'ch', hops: ['DE', 'NL'])],
        coreVersion: _newCore,
      );
      expect(_byTag(r, 'ch'), isNotNull);
    });

    test('кривая строка версии — FAIL-OPEN, цепочка эмитится', () async {
      // Деградировать на догадке нельзя: это отняло бы рабочий маршрут.
      for (final v in const ['', 'unknown', '1.13.11']) {
        final r = await _build(
          nodeTags: ['DE', 'NL'],
          chains: [const SourceChain(tag: 'ch', hops: ['DE', 'NL'])],
          coreVersion: v,
        );
        expect(_byTag(r, 'ch'), isNotNull, reason: 'версия "$v"');
      }
    });
  });
}

// ── helpers ─────────────────────────────────────────────────────────────────

Future<BuildResult> _build({
  required List<String> nodeTags,
  List<SourceChain> chains = const [],
  List<Direction> directions = const [
    Direction(tag: 'vpn-1')
  ],
  String coreVersion = _newCore,
}) =>
    buildConfig(
      lists: [_source(nodeTags)],
      template: _template(),
      settings: BuildSettings(
        directions: directions,
        chains: chains,
        coreVersion: coreVersion,
      ),
    );

Map<String, dynamic>? _byTag(BuildResult r, String tag) {
  for (final o in (r.config['outbounds'] as List)) {
    final m = (o as Map).cast<String, dynamic>();
    if (m['tag'] == tag) return m;
  }
  return null;
}

/// Минимальный шаблон: служебные outbound'ы + пустой route. Направления
/// приходят целиком из настроек, поэтому `groupTemplates` пуст.
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

UserServer _source(List<String> tags) {
  final nodes = <NodeSpec>[];
  for (var i = 0; i < tags.length; i++) {
    final spec = parseUri('vless://u$i@h$i.example:443'
        '?type=ws&security=tls#${Uri.encodeComponent(tags[i])}');
    expect(spec, isNotNull, reason: 'не разобрался узел "${tags[i]}"');
    nodes.add(spec!);
  }
  return UserServer(
    id: 'src',
    name: 'src',
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
    origin: UserSource.paste,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    nodes: nodes,
  );
}
