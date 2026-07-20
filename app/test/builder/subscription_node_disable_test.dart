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
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §283 — выключенная нода подписки не эмитится в конфиг (но остаётся в
/// `nodes` для UI), её warnings не сыпятся в emitWarnings; хеш-фильтр
/// переживает reparse (свежие инстансы NodeSpec).
class _FakeCtx implements EmitContext {
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
      final hashA = nodeIdentityHash(parseUri(uriA)!);
      final list = sub({hashA: DateTime.utc(2026, 7, 18)});

      final ctx = _FakeCtx();
      list.build(ctx);

      expect(ctx.entries.map((e) => e.tag), ['B']);
      expect(ctx.selectorTags, ['B']);
      expect(ctx.autoTags, ['B']);
      expect(list.nodes, hasLength(2), reason: 'nodes для UI не тронуты');
    });

    test('хеш из СВЕЖЕГО парса того же URI фильтрует (стабильность)', () {
      // Отметка записана по одному инстансу NodeSpec, фильтр отработал по
      // другому (reparse на загрузке/refresh) — ключ контентный, не object.
      final list = sub({
        nodeIdentityHash(parseUri(uriA)!): DateTime.utc(2026, 7, 18),
      });
      final ctx = _FakeCtx();
      list.build(ctx);
      expect(ctx.entries.map((e) => e.tag), ['B']);
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
        channel: ChannelTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {'url': 'https://x', 'interval': '30s'},
        ),
        defaultChannels: [
          DefaultChannel(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
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
        disabledHashes: {
          nodeIdentityHash(parseUri(wa)!): DateTime.utc(2026, 7, 18),
        },
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
