import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/build_config.dart';

import '../../parser/engine_test_setup.dart';

/// §704 §2 — миксины в сборке: последним шагом, выключенный пропускается,
/// отказ — fatal-issue с `mixinId`.
void main() {
  setUpAll(loadEngineSections);

  final template = WizardTemplate(
    groupTemplates: GroupTemplates(
      direction: DirectionTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(options: const {'url': 'https://x', 'interval': '30s'}),
      defaultDirections: [
        DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
      ],
    ),
    vars: const [],
    varSections: const [],
    config: {
      'inbounds': [
        {'type': 'tun', 'tag': 'tun-in'},
      ],
      'outbounds': [
        {'tag': 'direct-out', 'type': 'direct'},
      ],
      'route': {
        'rules': [
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
      },
    },
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  Future<BuildResult> build(List<Mixin> mixins) => buildConfig(
        lists: const [],
        template: template,
        settings: BuildSettings(
          userVars: const {'clash_api': '127.0.0.1:9090'},
          enabledGroups: const {'vpn-1', kAutoOutboundTag},
          mixins: mixins,
        ),
      );

  final inbound = Mixin(
    name: 'DNS listener',
    target: 'inbounds',
    op: 'append',
    value: {
      'type': 'direct',
      'tag': 'dns-in',
      'listen': '127.0.0.1',
      'listen_port': 5353,
    },
  );
  final hijack = Mixin(
    name: 'Hijack DNS from dns-in',
    target: 'route.rules[action=hijack-dns]',
    op: 'before',
    value: {
      'inbound': ['dns-in'],
      'action': 'hijack-dns',
    },
  );

  test('без миксинов — configBeforeMixins нет', () async {
    final r = await build(const []);
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    expect(r.configBeforeMixins, isNull);
  });

  test('BuildSettings.mixins доходит до конфига (сценарий zomg)', () async {
    final r = await build([inbound, hijack]);
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    final tags = [for (final i in r.config['inbounds'] as List) i['tag']];
    expect(tags, ['tun-in', 'dns-in']);
    final rules = (r.config['route'] as Map)['rules'] as List;
    final at = rules.indexWhere((x) => x['protocol'] == 'dns');
    expect(rules[at - 1], {
      'inbound': ['dns-in'],
      'action': 'hijack-dns',
    });
    expect(r.configJson, contains('"dns-in"'));
    // База предпросмотра — без миксинов.
    final before = r.configBeforeMixins!;
    expect([for (final i in before['inbounds'] as List) i['tag']], ['tun-in']);
  });

  test('выключенный миксин пропускается', () async {
    final r = await build([inbound.copyWith(enabled: false)]);
    expect(r.validation.isOk, isTrue);
    expect([for (final i in r.config['inbounds'] as List) i['tag']],
        ['tun-in']);
  });

  test('отказ миксина — fatal-issue с mixinId, остальные применены', () async {
    final bad = Mixin(name: 'Drop Ads rule', target: 'route.rules[rule_set=Ads]',
        op: 'remove', value: true);
    final r = await build([inbound, bad]);
    expect(r.validation.hasFatal, isTrue);
    final issue = r.validation.fatal.whereType<MixinIssue>().single;
    expect(issue.mixinId, bad.id);
    expect(issue.reason, 'no match');
    expect(issue.renderEn(),
        'Mixin "Drop Ads rule": route.rules[rule_set=Ads]: no match');
    expect(FatalValidationException(r.validation.fatal).issues, contains(issue));
  });

  test('дубль тега — fatal', () async {
    final dup = Mixin(
        name: 'dup', target: 'outbounds', op: 'append',
        value: {'type': 'direct', 'tag': 'direct-out'});
    final r = await build([dup]);
    final issue = r.validation.fatal.whereType<MixinIssue>().single;
    expect(issue.renderEn(), 'Mixin "dup": duplicate tag "direct-out" in outbounds');
  });
}
