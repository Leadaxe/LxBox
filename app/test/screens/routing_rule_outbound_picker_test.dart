import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart';

/// §447 — outbound-пикер в тайле правила. У json-правила действие внутри тела
/// и `withOutbound` — no-op: пикер показывал первую опцию («direct») и ничего
/// не менял, в том числе у тела с `action: reject`. Inline-правило с reject
/// пикер держит (значение Reject).
void main() {
  SelectableRule preset(Map<String, dynamic> json) =>
      SelectableRule.fromJson(json);

  test('json-правило — без пикера', () {
    for (final body in [
      '{"domain":"a.test","action":"reject"}',
      '{"domain":"a.test","outbound":"vpn-1"}',
    ]) {
      expect(
        RoutingHelpers.showsOutboundPicker(
            CustomRuleJson(name: 'raw', json: body), null),
        isFalse,
        reason: body,
      );
    }
  });

  test('inline и srs — пикер есть, reject тоже', () {
    expect(
      RoutingHelpers.showsOutboundPicker(
          CustomRuleInline(
              name: 'ads', domains: ['a.test'], outbound: kOutboundReject),
          null),
      isTrue,
    );
    expect(
      RoutingHelpers.showsOutboundPicker(
          CustomRuleSrs(name: 'geo', srsUrl: 'https://example.invalid/x.srs'),
          null),
      isTrue,
    );
  });

  test('пресет: с var:outbound и «not found» — пикер, без var:outbound — нет',
      () {
    final withOutbound = preset({
      'preset_id': 'ru-inside',
      'ui': {'label': 'RU'},
      'vars': [
        {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
      ],
      'rule': {'domain_suffix': ['ru'], 'outbound': '@outbound'},
    });
    final rejectOnly = preset({
      'preset_id': 'block-ads',
      'ui': {'label': 'Block Ads'},
      'rule': {'domain': ['ads.test'], 'action': 'reject'},
    });
    CustomRule rule(String id) => CustomRulePreset(name: id, presetId: id);

    expect(RoutingHelpers.showsOutboundPicker(rule('ru-inside'), withOutbound),
        isTrue);
    expect(RoutingHelpers.showsOutboundPicker(rule('block-ads'), rejectOnly),
        isFalse);
    expect(RoutingHelpers.showsOutboundPicker(rule('gone'), null), isTrue);
  });
}
