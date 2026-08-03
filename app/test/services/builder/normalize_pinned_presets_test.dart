import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/normalize_pinned_presets.dart';

void main() {
  group('normalizePinnedPresets (§264)', () {
    test('pinned-пресет поднимается из середины списка в начало', () {
      final rules = [
        _preset('fcm-push'),
        _preset('traffic-processing'),
        _preset('block-ads'),
      ];

      final out = normalizePinnedPresets(rules, _catalog(), _template());

      expect(_ids(out), ['traffic-processing', 'fcm-push', 'block-ads']);
    });

    test('относительный порядок не-pinned правил сохраняется', () {
      final rules = [
        _preset('block-ads'),
        _preset('fcm-push'),
        _preset('traffic-processing'),
        _preset('ru-direct'),
      ];

      final out = normalizePinnedPresets(rules, _catalog(), _template());

      expect(_ids(out),
          ['traffic-processing', 'block-ads', 'fcm-push', 'ru-direct']);
    });

    test('идемпотентна: повторный вызов ничего не меняет', () {
      final once = normalizePinnedPresets(
          [_preset('fcm-push'), _preset('traffic-processing')],
          _catalog(),
          _template());
      final twice = normalizePinnedPresets(once, _catalog(), _template());

      expect(_ids(twice), _ids(once));
    });

    test('несколько pinned сортируются по возрастанию ui.pinned', () {
      final catalog = [
        _pinnedSpec('traffic-processing', 0),
        _pinnedSpec('second-pinned', 1),
        _plainSpec('fcm-push'),
      ];
      final rules = [
        _preset('fcm-push'),
        _preset('second-pinned'),
        _preset('traffic-processing'),
      ];

      final out = normalizePinnedPresets(rules, catalog, _template());

      expect(_ids(out),
          ['traffic-processing', 'second-pinned', 'fcm-push']);
    });

    test('varsValues существующего pinned-пресета сохраняются (не seed поверх)',
        () {
      final rules = [
        _preset('fcm-push'),
        CustomRulePreset(
          name: 'Traffic Processing',
          presetId: 'traffic-processing',
          varsValues: const {'sniff_enabled': 'false'},
        ),
      ];

      final out = normalizePinnedPresets(rules, _catalog(), _template());

      final head = out.first as CustomRulePreset;
      expect(head.presetId, 'traffic-processing');
      expect(head.varsValues['sniff_enabled'], 'false');
    });
  });
}

List<String> _ids(List<CustomRule> rules) =>
    [for (final r in rules) r.presetId];

CustomRulePreset _preset(String id) =>
    CustomRulePreset(name: id, presetId: id, varsValues: const {});

/// Каталог: `traffic-processing` pinned:0, остальные обычные.
List<SelectableRule> _catalog() => [
      _pinnedSpec('traffic-processing', 0),
      _plainSpec('fcm-push'),
      _plainSpec('block-ads'),
      _plainSpec('ru-direct'),
    ];

SelectableRule _pinnedSpec(String id, int pinned) => SelectableRule(
      label: id,
      presetId: id,
      defaultEnabled: true,
      locked: true,
      pinned: pinned,
      vars: const [],
    );

SelectableRule _plainSpec(String id) => SelectableRule(
      label: id,
      presetId: id,
      vars: const [],
    );

WizardTemplate _template() => WizardTemplate.fromJson(const {
      'sections': [],
      'selectable_rules': [],
    });
