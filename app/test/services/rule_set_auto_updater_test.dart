import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/preset_rule_set.dart';
import 'package:lxbox/services/rule_set_auto_updater.dart';
import 'package:lxbox/services/rule_set_downloader.dart';

void main() {
  final now = DateTime(2026, 8, 3, 12);

  group('§366 shouldUpdatePure', () {
    test('нет метаданных → пора (кэш скачан до §366 либо вовсе не скачан)', () {
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: const RuleSetMeta(), intervalHours: 168, now: now),
        isTrue,
      );
    });

    test('TTL 0 = Never → не обновляем даже без метаданных', () {
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: const RuleSetMeta(), intervalHours: 0, now: now),
        isFalse,
      );
    });

    test('свежий кэш в пределах TTL → пропускаем', () {
      final meta =
          RuleSetMeta(lastUpdated: now.subtract(const Duration(days: 3)));
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: 168, now: now),
        isFalse,
      );
    });

    test('возраст ровно на границе TTL → пора', () {
      final meta =
          RuleSetMeta(lastUpdated: now.subtract(const Duration(hours: 168)));
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: 168, now: now),
        isTrue,
      );
    });

    test('один и тот же кэш: короткий TTL — пора, длинный — нет', () {
      final meta =
          RuleSetMeta(lastUpdated: now.subtract(const Duration(days: 10)));
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: 24, now: now),
        isTrue,
      );
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: 720, now: now),
        isFalse,
      );
    });

    test('неудачная последняя попытка не мешает: решает возраст успеха', () {
      // lastError стоит, но lastUpdated свежий — старый файл ещё актуален.
      final meta = RuleSetMeta(
        lastUpdated: now.subtract(const Duration(hours: 2)),
        lastAttempt: now,
        lastError: 'HTTP 404',
      );
      expect(
        RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: 168, now: now),
        isFalse,
      );
    });
  });

  group('§366 parseUpdateIntervalHours', () {
    test('формат sing-box: часы / дни / недели', () {
      expect(parseUpdateIntervalHours('168h'), 168);
      expect(parseUpdateIntervalHours('7d'), 168);
      expect(parseUpdateIntervalHours('1w'), 168);
      expect(parseUpdateIntervalHours('24h'), 24);
    });

    test('без единицы = часы; пробелы и регистр не мешают', () {
      expect(parseUpdateIntervalHours('168'), 168);
      expect(parseUpdateIntervalHours(' 24H '), 24);
    });

    test('единицы меньше часа округляются вверх, а не в 0', () {
      // Иначе "30m" молча означало бы «никогда».
      expect(parseUpdateIntervalHours('30m'), 1);
      expect(parseUpdateIntervalHours('90m'), 2);
      expect(parseUpdateIntervalHours('10s'), 1);
    });

    test('явный 0 = никогда', () {
      expect(parseUpdateIntervalHours('0'), 0);
      expect(parseUpdateIntervalHours('0h'), 0);
      expect(parseUpdateIntervalHours(0), 0);
    });

    test('отсутствие поля и мусор → дефолт (неделя)', () {
      expect(parseUpdateIntervalHours(null), kDefaultSrsTtlHours);
      expect(parseUpdateIntervalHours(''), kDefaultSrsTtlHours);
      expect(parseUpdateIntervalHours('soon'), kDefaultSrsTtlHours);
      expect(parseUpdateIntervalHours('1y'), kDefaultSrsTtlHours);
      expect(parseUpdateIntervalHours({'x': 1}), kDefaultSrsTtlHours);
    });

    test('число трактуется как часы', () {
      expect(parseUpdateIntervalHours(48), 48);
      expect(parseUpdateIntervalHours(1.2), 2, reason: 'округление вверх');
    });
  });

  group('§366 TTL в модели правила', () {
    test('дефолт — неделя, и он НЕ пишется в JSON', () {
      final r = CustomRuleSrs(name: 'x', srsUrl: 'http://a/b.srs');
      expect(r.updateIntervalHours, kDefaultSrsTtlHours);
      expect(r.toJson().containsKey('updateIntervalHours'), isFalse);
    });

    test('не-дефолтный TTL переживает round-trip', () {
      final r = CustomRuleSrs(
          name: 'x', srsUrl: 'http://a/b.srs', updateIntervalHours: 720);
      final back = CustomRuleSrs.fromJson(r.toJson());
      expect(back.updateIntervalHours, 720);
    });

    test('0 (Never) сохраняется, а не подменяется дефолтом', () {
      final r = CustomRuleSrs(
          name: 'x', srsUrl: 'http://a/b.srs', updateIntervalHours: 0);
      expect(r.toJson()['updateIntervalHours'], 0);
      expect(CustomRuleSrs.fromJson(r.toJson()).updateIntervalHours, 0);
    });

    test('старое правило без ключа читается как неделя', () {
      final back = CustomRuleSrs.fromJson({
        'id': 'abc',
        'name': 'old',
        'kind': 'srs',
        'srsUrl': 'http://a/b.srs',
      });
      expect(back.updateIntervalHours, kDefaultSrsTtlHours);
    });

    test('мусор в поле → дефолт', () {
      final back = CustomRuleSrs.fromJson({
        'id': 'abc',
        'name': 'bad',
        'kind': 'srs',
        'updateIntervalHours': -5,
      });
      expect(back.updateIntervalHours, kDefaultSrsTtlHours);
    });

    test('copyWith сохраняет TTL, если его не передали', () {
      final r = CustomRuleSrs(
          name: 'x', srsUrl: 'http://a/b.srs', updateIntervalHours: 336);
      expect(r.withEnabled(false).updateIntervalHours, 336);
    });
  });

  group('§366 TTL из шаблона пресета', () {
    SelectableRule presetWith(Map<String, dynamic> ruleSet) =>
        SelectableRule(label: 'P', presetId: 'p', ruleSets: [ruleSet]);

    test('update_interval из шаблона доезжает до PresetRemoteRuleSet', () {
      final rs = remoteRuleSetsOfPreset(presetWith({
        'tag': 'geoip-ru',
        'type': 'remote',
        'url': 'http://a/geoip.srs',
        'update_interval': '168h',
      }));
      expect(rs.single.updateIntervalHours, 168);
    });

    test('без update_interval — дефолт', () {
      final rs = remoteRuleSetsOfPreset(presetWith({
        'tag': 'ads',
        'type': 'remote',
        'url': 'http://a/ads.srs',
      }));
      expect(rs.single.updateIntervalHours, kDefaultSrsTtlHours);
    });

    test('inline-рулсеты не попадают в список (качать нечего)', () {
      final rs = remoteRuleSetsOfPreset(presetWith({
        'tag': 'inline',
        'type': 'inline',
        'rules': <dynamic>[],
      }));
      expect(rs, isEmpty);
    });
  });
}
