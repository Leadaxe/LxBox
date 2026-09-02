import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §283 — выключенная нода подписки не эмитится в конфиг (но остаётся в
/// `nodes` для UI), её warnings не сыпятся в emitWarnings.
///
/// §400 (контракт 0.10.0) — КЛЮЧ ОТМЕТКИ ЭТО ТЕГ, уникализированный внутри
/// источника, а не контент-хеш. Отсюда три следствия, которые эти тесты и
/// фиксируют: отметка переживает ротацию адреса под тем же именем; тёзки
/// `X`/`X-2` — разные узлы и гасятся раздельно; безымянный узел
/// идентичности не имеет, и выключить его per-node нельзя.
///
/// Инвариант фильтрации: карта идентичностей считается от ПОЛНОГО списка
/// узлов источника, включая уже выключенные. Иначе выключение узла
/// переименовало бы следующего тёзку (`X-2` → `X`) и сняло отметку уже с
/// него.
class _FakeCtx implements EmitContext {
  // §272/§322 — глобальный passive_check; этим тестам он не важен.
  @override
  bool get passiveCheck => false;

  final entries = <SingboxEntry>[];
  final selectorTags = <String>[];
  final autoTags = <String>[];
  final _seen = <String>{};

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  String allocateTag(String baseTag) {
    var t = baseTag;
    var i = 1;
    while (!_seen.add(t)) {
      t = '$baseTag-${i++}';
    }
    return t;
  }

  @override
  void addEntry(SingboxEntry entry) => entries.add(entry);

  @override
  void addToSelectorTagList(SingboxEntry entry) => selectorTags.add(entry.tag);

  @override
  void addToAutoList(SingboxEntry entry) => autoTags.add(entry.tag);

  @override
  final RuleSetRegistry ruleSets =
      RuleSetRegistry(initialRuleSets: const [], initialRules: const []);
}

void main() {
  const uriA = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#A';
  const uriB = 'vless://u2@h2.com:443?type=ws&security=tls&sni=h2.com#B';

  SubscriptionServers sub(Map<String, DateTime> disabled) =>
      SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: disabled,
        nodes: [parseUri(uriA)!, parseUri(uriB)!],
      );

  group('ServerListBuild §283 filter', () {
    test('выключенная нода не эмитится; вторая и selector целы', () {
      final list = sub({'A': DateTime.utc(2026, 7, 18)});

      final ctx = _FakeCtx();
      list.build(ctx);

      expect(ctx.entries.map((e) => e.tag), ['B']);
      expect(ctx.selectorTags, ['B']);
      expect(ctx.autoTags, ['B']);
      expect(list.nodes, hasLength(2), reason: 'nodes для UI не тронуты');
    });

    test('отметка переживает reparse: ключ не привязан к инстансу', () {
      // Отметка записана по одному инстансу NodeSpec, фильтр отработал по
      // другому (reparse на загрузке/refresh). Ключ — имя узла, а не object.
      final list = sub({'A': DateTime.utc(2026, 7, 18)});
      final ctx = _FakeCtx();
      list.build(ctx);
      expect(ctx.entries.map((e) => e.tag), ['B']);
    });

    test('§400 отметка переживает РОТАЦИЮ адреса под тем же именем', () {
      // Главная причина смены модели: провайдер вправе поменять сервер под
      // тем же именем (ротация IP, смена группы). Контент-хеш считал это
      // появлением нового узла и молча снимал отметку.
      final rotated = SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: {'A': DateTime.utc(2026, 7, 18)},
        nodes: [
          parseUri('vless://u1@ROTATED.com:9443'
              '?type=ws&security=tls&sni=rotated.com#A')!,
          parseUri(uriB)!,
        ],
      );
      final ctx = _FakeCtx();
      rotated.build(ctx);
      expect(ctx.entries.map((e) => e.tag), ['B'],
          reason: 'адрес сменился, имя нет — узел тот же, отметка на месте');
    });

    test('§400 ПЕРЕИМЕНОВАНИЕ отметку теряет — имя и есть идентичность', () {
      // Обратная сторона обмена (IDENTITY.md §1.2), названная явно: раньше
      // переименование отметку сохраняло. Тест фиксирует именно потерю,
      // чтобы обмен не «починили» обратно по недосмотру.
      final renamed = SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: {'A': DateTime.utc(2026, 7, 18)},
        nodes: [
          parseUri('vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com'
              '#A%20renamed')!,
          parseUri(uriB)!,
        ],
      );
      final ctx = _FakeCtx();
      renamed.build(ctx);
      expect(ctx.entries.map((e) => e.tag), ['A renamed', 'B']);
    });

    test('§400 тёзки X / X-2 гасятся РАЗДЕЛЬНО', () {
      // Дубли одного сервера под одним именем — разные узлы. Раньше их
      // гасил один toggle (общий контент-хеш).
      const twinA = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#X';
      const twinB = 'vless://u9@h9.com:443?type=ws&security=tls&sni=h9.com#X';
      SubscriptionServers twins(Map<String, DateTime> disabled) =>
          SubscriptionServers(
            id: 's1',
            name: 'S',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            url: 'https://example.com/sub',
            disabledHashes: disabled,
            nodes: [parseUri(twinA)!, parseUri(twinB)!],
          );

      final first = _FakeCtx();
      twins({'X': DateTime.utc(2026, 7, 18)}).build(first);
      expect(first.entries, hasLength(1),
          reason: 'погас только первый тёзка');

      final second = _FakeCtx();
      twins({'X-2': DateTime.utc(2026, 7, 18)}).build(second);
      expect(second.entries, hasLength(1),
          reason: 'отметка на X-2 гасит ВТОРОГО тёзку, не первого');

      // Ключевое: погашены РАЗНЫЕ узлы. Теги эмиссии совпадают (уникализацию
      // вешает EmitContext), поэтому сверяем по адресу сервера.
      expect(first.entries.single.map['server'],
          isNot(second.entries.single.map['server']));
    });

    test('§400 инвариант: выключение тёзки не сдвигает нумерацию соседа', () {
      // Карта считается от ПОЛНОГО списка, включая выключенные. Считай её
      // после фильтра — `X-2` стал бы `X`, и отметка сняла бы уже его.
      const twinA = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#X';
      const twinB = 'vless://u9@h9.com:443?type=ws&security=tls&sni=h9.com#X';
      final ctx = _FakeCtx();
      SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: {
          'X': DateTime.utc(2026, 7, 18),
          'X-2': DateTime.utc(2026, 7, 18),
        },
        nodes: [parseUri(twinA)!, parseUri(twinB)!],
      ).build(ctx);
      expect(ctx.entries, isEmpty,
          reason: 'обе отметки обязаны совпасть с обоими узлами');
    });

    test('без отметок эмитится всё', () {
      final ctx = _FakeCtx();
      sub(const {}).build(ctx);
      expect(ctx.entries.map((e) => e.tag), ['A', 'B']);
    });
  });

  group('buildConfig §283 интеграция (фильтр + warnings-зеркало)', () {
    final template = WizardTemplate(
      parserConfig: ParserConfigBlock(),
      groupTemplates: GroupTemplates(
        direction: DirectionTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {'url': 'https://x', 'interval': '30s'},
        ),
        defaultDirections: [
          DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
        ],
      ),
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
        'route': {'rules': []},
      },
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

    test('нода вне конфига, её warning вне emitWarnings', () async {
      // insecure=1 → InsecureTlsWarning на обеих нодах.
      const wa = 'vless://u1@h1.com:443?security=tls&sni=h1.com&insecure=1#A';
      const wb = 'vless://u2@h2.com:443?security=tls&sni=h2.com&insecure=1#B';
      final list = SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: {'A': DateTime.utc(2026, 7, 18)},
        nodes: [parseUri(wa)!, parseUri(wb)!],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      final tags = (result.config['outbounds'] as List)
          .map((o) => (o as Map)['tag'])
          .toList();
      expect(tags, isNot(contains('A')));
      expect(tags, contains('B'));

      final vpn1 = (result.config['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'vpn-1') as Map;
      expect(vpn1['outbounds'], isNot(contains('A')));

      expect(result.emitWarnings.where((w) => w.startsWith('A:')), isEmpty,
          reason: 'warnings выключенной ноды не сыпем (зеркало фильтра)');
      expect(result.emitWarnings.where((w) => w.startsWith('B:')), isNotEmpty);
    });
  });
}
