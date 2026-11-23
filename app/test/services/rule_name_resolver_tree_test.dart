import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/rule_name_resolver.dart';

// §757 — опознавание правила-дерева в списке соединений. Строки — в форме
// `rule.String()` ядра (`route/rule/rule_abstract.go`,
// `rule_item_rule_set.go`): простое правило — условия через пробел, `invert`
// — `!(…)`, `logical` — листья через ` && ` / ` || `, наборы —
// `rule_set=<тег>` или `rule_set=[a b]`.

CustomRule _tree(String name, Map<String, dynamic> body) =>
    ruleFromRecord({'kind': 'inline', 'name': name, 'body': body},
            unknownAsVerbatim: true)
        .value!;

void main() {
  setUp(() => RuleNameResolver.I.clear());
  tearDown(() => RuleNameResolver.I.clear());

  String resolve(String s) => RuleNameResolver.I.resolve(s);

  test('правило с группами и наборами — по тегу набора листа', () {
    final r = _tree('Video', {
      'type': 'logical',
      'mode': 'and',
      'rules': [
        {
          'port': [443],
        },
        {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {
              'refs': ['https://example.com/rules/video.srs'],
            },
            {
              'domain_suffix': ['example-6.com'],
            },
          ],
        },
      ],
      'outbound': 'direct',
    });
    RuleNameResolver.I.setRules([r]);
    // §757 (контракт 1.1.182) — ссылка листа — `Video:<stem>`, inline-набор
    // листа 1.1 — `Video:inline:1.1`.
    expect(
      resolve('port=443 && rule_set=Video:video || '
          'rule_set=Video:inline:1.1 => route(direct)'),
      'Video',
    );
    expect(resolve('port=443 && rule_set=Video:video'), 'Video');
    expect(resolve('port=443 && rule_set=Video:inline:1.1'), 'Video');
  });

  test('srs-правило с inline-набором корня — по `имя:<stem>` и чистому `имя`',
      () {
    final r = _tree('Ai', {
      'refs': [
        'https://example.com/geosite-category-ai-!cn.srs',
        'https://example.com/geosite-google.srs',
      ],
      'domain_suffix': ['example-9.com'],
      'outbound': 'proxy',
    });
    RuleNameResolver.I.setRules([r]);
    expect(
      resolve('rule_set=[Ai:geosite-category-ai-!cn Ai:geosite-google Ai] '
          '=> route(proxy)'),
      'Ai',
    );
    expect(resolve('rule_set=Ai:geosite-google'), 'Ai');
  });

  test('тег с пробелом и разводом: Ads (2) не путается с Ads', () {
    final a = CustomRuleTree.flat(
      name: 'Ads',
      domains: const ['example-7.com'],
      outbound: 'direct',
    );
    final b = CustomRuleTree.flat(
      name: ' Ads ',
      srsUrls: const ['https://example.com/rules/ads.srs'],
      outbound: 'block',
    );
    RuleNameResolver.I.setRules([a, b]);
    expect(resolve('rule_set=Ads => route(direct)'), 'Ads');
    // Ссылка правила ` Ads ` — `Ads (2):ads` (база после развода + stem).
    expect(resolve('rule_set=Ads (2):ads => route(block)'), ' Ads ');
    expect(resolve('!(rule_set=[Ads (2):ads other])'), ' Ads ');
  });

  test('тег шаблона занят до правил пользователя — как в сборке', () {
    final template = WizardTemplate.fromJson({
      'config': {
        'route': {
          'rule_set': [
            {'tag': 'Ads', 'type': 'inline', 'rules': []},
          ],
        },
      },
      'selectable_rules': [],
    });
    final r = CustomRuleTree.flat(
      name: 'Ads',
      domains: const ['example-8.com'],
      outbound: 'direct',
    );
    RuleNameResolver.I.setRules([r], template: template);
    expect(resolve('rule_set=Ads (2)'), 'Ads');

    // Без шаблона база — `Ads`; `Ads (2)` — чужой тег, отдаётся как есть.
    RuleNameResolver.I.setRules([r]);
    expect(resolve('rule_set=Ads (2)'), 'Ads (2)');
  });

  test('правило с группами без наборов — все листья в строке ядра', () {
    final r = _tree('Apps', {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {
          'package_name': ['com.a'],
        },
        {
          'package_name': ['com.b'],
          'network_type': ['wifi'],
        },
      ],
      'outbound': 'direct',
    });
    RuleNameResolver.I.setRules([r]);
    expect(
      resolve('package_name=com.a || package_name=com.b network_type=wifi '
          '=> route(direct)'),
      'Apps',
    );
    // Один лист — не это правило.
    expect(resolve('package_name=com.a'), isNot('Apps'));
  });
}
