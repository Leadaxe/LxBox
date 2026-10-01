import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/screens/routing_screen/routing_screen_helpers.dart'
    show RoutingHelpers;

/// §601 — экран Routing не выключает правило из-за нескачанного набора:
/// снимок кэша (`_refreshSrsCache` → [RoutingHelpers.scanSrsCache]) правила не
/// переписывает, включённое правило без файла — состояние «ждёт скачивания».
void main() {
  final preset = SelectableRule(
    label: 'P',
    presetId: 'p',
    ruleSets: const [
      {'tag': 'geo', 'type': 'remote', 'url': 'https://example.invalid/g.srs'},
    ],
  );

  CustomRuleSrs srsRule({bool enabled = true}) => CustomRuleSrs(
        id: 'srs-1',
        name: 'S',
        srsUrl: 'https://example.invalid/s.srs',
        outbound: 'direct-out',
        enabled: enabled,
      );

  Future<bool> none(String _) async => false;
  Future<bool> nonePreset(String _, String _) async => false;

  test('включённые правила без файлов остаются включёнными', () async {
    final srs = srsRule();
    final pr = CustomRulePreset(name: 'P', presetId: 'p');
    final rules = <CustomRule>[srs, pr];

    final scan = await RoutingHelpers.scanSrsCache(rules,
        presetFor: (id) => id == 'p' ? preset : null,
        isCached: none,
        isPresetCached: nonePreset);

    expect(rules, hasLength(2));
    expect(identical(rules[0], srs), isTrue);
    expect(identical(rules[1], pr), isTrue);
    expect(rules.every((r) => r.enabled), isTrue);
    expect(scan.cached, isEmpty);
    // Нескачанный файл не сирота: prune его не тронет.
    expect(scan.activeDiskIds, containsAll(<String>{'srs-1', ...srs.cacheIds}));
    expect(scan.activeDiskIds, contains('preset__p__geo'));

    // Состояние 2 строки: включено, файла нет.
    expect(RoutingHelpers.waitingForDownload(srs, null, scan.cached), isTrue);
    expect(RoutingHelpers.waitingForDownload(pr, preset, scan.cached), isTrue);
  });

  test('файл есть → скачано, строка рабочая', () async {
    final srs = srsRule();
    final pr = CustomRulePreset(name: 'P', presetId: 'p');
    final scan = await RoutingHelpers.scanSrsCache([srs, pr],
        presetFor: (_) => preset,
        isCached: (_) async => true,
        isPresetCached: (_, _) async => true);

    expect(scan.cached, containsAll(<String>['srs-1', '${pr.id}|geo']));
    expect(RoutingHelpers.waitingForDownload(srs, null, scan.cached), isFalse);
    expect(RoutingHelpers.waitingForDownload(pr, preset, scan.cached), isFalse);
  });

  test('выключенное правило без файла — не «ждёт скачивания»', () {
    expect(
        RoutingHelpers.waitingForDownload(srsRule(enabled: false), null, {}),
        isFalse);
  });
}
