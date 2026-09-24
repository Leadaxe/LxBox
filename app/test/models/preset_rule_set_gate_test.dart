import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/preset_rule_set.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart'
    show RoutingHelpers;
import 'package:lxbox/services/builder/preset_expand.dart';

/// §534 — гейт `rule_set` пресета на пути скачивания/UI (`isRuleSetEnabledFor`,
/// `remoteRuleSetsOfPreset`) — та же семантика, что у билдера
/// (`fragmentGateSatisfied` + `presetVarsMap`): канонический `#enable` (§107) и
/// легаси `enabled` (§045), ref-переменная — из глобального словаря (§265).
void main() {
  const url = 'https://example.invalid/set.srs';

  Map<String, dynamic> remote(
    String tag, [
    Map<String, dynamic> gate = const {},
  ]) => {'tag': tag, 'type': 'remote', 'url': url, ...gate};

  WizardVar boolVar(String name, {String ref = ''}) =>
      WizardVar(name: name, type: 'bool', defaultValue: 'true', ref: ref);

  SelectableRule presetOf(
    List<Map<String, dynamic>> ruleSets, {
    List<WizardVar>? vars,
  }) => SelectableRule(
    label: 'P',
    presetId: 'p',
    ruleSets: ruleSets,
    vars: vars ?? [boolVar('x')],
  );

  CustomRulePreset ruleWith([Map<String, String> values = const {}]) =>
      CustomRulePreset(name: 'P', presetId: 'p', varsValues: values);

  /// Проверка сразу на обоих хелперах: `isRuleSetEnabledFor` и
  /// `remoteRuleSetsOfPreset` с `rule`; без `rule` набор в списке всегда
  /// (cleanup-путь трогает все кэши).
  void expectGate(
    Map<String, dynamic> rs,
    CustomRulePreset rule, {
    required bool enabled,
    SelectableRule? preset,
    Map<String, String> globalVars = const {},
  }) {
    final p = preset ?? presetOf([rs]);
    expect(
      isRuleSetEnabledFor(rs, p, rule, globalVars: globalVars),
      enabled,
      reason: 'isRuleSetEnabledFor',
    );
    final tags = remoteRuleSetsOfPreset(p, rule, globalVars).map((e) => e.tag);
    expect(
      tags.contains(rs['tag']),
      enabled,
      reason: 'remoteRuleSetsOfPreset(preset, rule)',
    );
    expect(
      remoteRuleSetsOfPreset(p).map((e) => e.tag),
      contains(rs['tag']),
      reason: 'remoteRuleSetsOfPreset(preset) — без rule фильтра нет',
    );
  }

  group('#enable (канон, §107)', () {
    final rs = remote('a', {
      '#enable': ['@x'],
    });

    test('bool-var снята → выключен', () {
      expectGate(rs, ruleWith({'x': 'false'}), enabled: false);
    });

    test('bool-var стоит → включён', () {
      expectGate(rs, ruleWith({'x': 'true'}), enabled: true);
    });

    test('записи в varsValues нет → дефолт true → включён', () {
      expectGate(rs, ruleWith(), enabled: true);
    });
  });

  group('легаси enabled (§045)', () {
    test('"@x" = false / true', () {
      final rs = remote('a', {'enabled': '@x'});
      expectGate(rs, ruleWith({'x': 'false'}), enabled: false);
      expectGate(rs, ruleWith({'x': 'true'}), enabled: true);
      expectGate(rs, ruleWith(), enabled: true);
    });

    test('bool false / true', () {
      expectGate(remote('a', {'enabled': false}), ruleWith(), enabled: false);
      expectGate(remote('a', {'enabled': true}), ruleWith(), enabled: true);
    });

    test('необъявленная переменная → выключен (семантика билдера)', () {
      // Смена поведения §534: прежний хелпер для необъявленной `@nope`
      // возвращал true (fallback 'true'), билдер — false (плейсхолдер не
      // подставился, это не "true"). Набор, который в конфиг не попадёт,
      // качать незачем — побеждает билдер.
      expectGate(remote('a', {'enabled': '@nope'}), ruleWith(), enabled: false);
    });
  });

  test('без гейта → включён', () {
    expectGate(remote('a'), ruleWith({'x': 'false'}), enabled: true);
  });

  test('обе формы: одна false → выключен (and)', () {
    final canonOff = remote('a', {
      'enabled': true,
      '#enable': ['@x'],
    });
    expectGate(canonOff, ruleWith({'x': 'false'}), enabled: false);

    final legacyOff = remote('b', {
      'enabled': false,
      '#enable': ['@x'],
    });
    expectGate(legacyOff, ruleWith({'x': 'true'}), enabled: false);

    final bothOn = remote('c', {
      'enabled': '@x',
      '#enable': ['@x'],
    });
    expectGate(bothOn, ruleWith({'x': 'true'}), enabled: true);
  });

  group('ref-var (§265)', () {
    final rs = remote('a', {
      '#enable': ['@r'],
    });
    final preset = presetOf([rs], vars: [boolVar('r', ref: 'resolve_enabled')]);

    test('значение из globalVars → включён', () {
      expectGate(
        rs,
        ruleWith(),
        preset: preset,
        globalVars: {'resolve_enabled': 'true'},
        enabled: true,
      );
    });

    test('globalVars пуст, значение в varsValues → выключен', () {
      // Значение ref-переменной живёт в глобальном userVars, varsValues
      // пресета для неё не читается — как у билдера.
      expectGate(rs, ruleWith({'r': 'true'}), preset: preset, enabled: false);
    });
  });

  group('presetVarsMap — ошибка required-var', () {
    test('тексты те же, что у expandPreset; первая ошибка побеждает', () {
      final preset = SelectableRule(
        label: 'P',
        presetId: 'p',
        vars: [
          WizardVar(name: 'a', type: 'text', defaultValue: ''),
          WizardVar(name: 'b', type: 'text', defaultValue: 'x'),
          boolVar('x'),
        ],
      );
      final unset = presetVarsMap(ruleWith(), preset);
      expect(unset.error, 'preset "p": required var "a" unset');
      expect(expandPreset(ruleWith(), preset).warnings, [unset.error]);

      final empty = presetVarsMap(ruleWith({'a': '', 'b': ''}), preset);
      expect(empty.error, 'preset "p": required var "a" set to empty');
      expect(expandPreset(ruleWith({'a': '', 'b': ''}), preset).warnings, [
        empty.error,
      ]);

      // Словарь собран целиком, гейт на пути скачивания видит остальные vars.
      expect(unset.vars, {'a': null, 'b': 'x', 'x': 'true'});
    });
  });

  group('RoutingHelpers.presetNeedsDownload', () {
    final preset = presetOf([
      remote('gated', {
        '#enable': ['@x'],
      }),
      remote('plain'),
    ]);

    test('выключенный гейтом и не скачанный набор иконку ☁ не требует', () {
      final rule = ruleWith({'x': 'false'});
      final cached = {RoutingHelpers.presetSrsKey(rule, 'plain')};
      expect(RoutingHelpers.presetNeedsDownload(rule, preset, cached), isFalse);
    });

    test('гейт включён — не скачанный набор требует ☁', () {
      final rule = ruleWith({'x': 'true'});
      final cached = {RoutingHelpers.presetSrsKey(rule, 'plain')};
      expect(RoutingHelpers.presetNeedsDownload(rule, preset, cached), isTrue);
    });
  });

  group('боевой шаблон: ru-direct (geoip-ru, ru-apps)', () {
    late SelectableRule ruDirect;

    setUpAll(() {
      final raw = File('assets/wizard_template.json').readAsStringSync();
      final tpl = WizardTemplate.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      ruDirect = tpl.selectableRules.firstWhere(
        (r) => r.presetId == 'ru-direct',
      );
    });

    test('путь скачивания и билдер видят один набор remote-наборов', () {
      final allRemote = remoteRuleSetsOfPreset(
        ruDirect,
      ).map((e) => e.tag).toSet();
      expect(allRemote, containsAll(['geoip-ru', 'ru-apps']));
      final srsPaths = {for (final t in allRemote) t: '/cache/$t.srs'};
      // Билдер неймспейсит теги пресета (`ru-direct:geoip-ru`, §103 C7) —
      // набор опознаём по подставленному локальному пути.
      final tagByPath = {for (final e in srsPaths.entries) e.value: e.key};

      for (final geo in ['true', 'false']) {
        for (final apps in ['true', 'false']) {
          final rule = CustomRulePreset(
            name: 'RU',
            presetId: 'ru-direct',
            varsValues: {'geoip_enabled': geo, 'apps_enabled': apps},
          );
          final download = remoteRuleSetsOfPreset(
            ruDirect,
            rule,
          ).map((e) => e.tag).toSet();
          final built = {
            for (final rs in expandPreset(
              rule,
              ruDirect,
              srsPaths: srsPaths,
            ).ruleSets)
              if (tagByPath.containsKey(rs['path'])) tagByPath[rs['path']]!,
          };
          final reason = 'geoip_enabled=$geo apps_enabled=$apps';
          expect(download, built, reason: reason);
          expect(download.contains('geoip-ru'), geo == 'true', reason: reason);
          expect(download.contains('ru-apps'), apps == 'true', reason: reason);
        }
      }
    });
  });
}
