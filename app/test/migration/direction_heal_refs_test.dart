import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §125 F4.5 + §202 — лечение dangling direction-ссылок в STORAGE (не только в
/// выхлопе билдера). Когда Направление перестаёт быть валидной route-мишенью
/// (удалён ИЛИ выключен), `route_final` и custom-rule `outbound`, висящие на
/// его теге, должны немедленно схлопнуться в 'vpn-1' (неудаляемый fallback).
///
/// Harness идентичен directions_migration_test.dart: mock path_provider +
/// изоляция tmp-dir + resetCacheForTesting.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_heal_refs_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// Готовит storage с Направлениями vpn-1/vpn-3, route_final='vpn-3' и одним
  /// custom-rule, чей outbound='vpn-3'. resetCache, чтобы читалось с диска.
  Future<void> seedRefsOnVpn3() async {
    final data = {
      'directions_migrated': true,
      'directions': [
        Direction(tag: 'vpn-1', label: 'Main', enabled: true).toJson(),
        Direction(tag: 'vpn-3', label: 'Aux', enabled: true).toJson(),
      ],
      'route_final': 'vpn-3',
      'custom_rules': [
        CustomRuleInline(name: 'r1', domains: const ['x.com'], outbound: 'vpn-3')
            .toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<String> ruleOutbound() async {
    final rules = await SettingsStorage.getCustomRules();
    return rules.single.outbound;
  }

  test('delete Направления: route_final + rule outbound → vpn-1 (§125 F4.5)',
      () async {
    await seedRefsOnVpn3();
    expect(await SettingsStorage.getRouteFinal(), 'vpn-3');
    expect(await ruleOutbound(), 'vpn-3');

    await SettingsStorage.deleteDirection('vpn-3');

    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    expect(await ruleOutbound(), 'vpn-1');
  });

  test('disable Направления (§202): route_final + rule outbound → vpn-1 в storage',
      () async {
    await seedRefsOnVpn3();
    final vpn3 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');

    // Выключаем Направление — это делает его невалидной route-мишенью.
    await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));

    // Storage переписан (не только выхлоп билдера): ссылки на vpn-3 схлопнуты.
    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    expect(await ruleOutbound(), 'vpn-1');
    // Сам Направление остаётся в списке (disable ≠ delete).
    expect(
      (await SettingsStorage.getDirections()).map((c) => c.tag),
      containsAll(['vpn-1', 'vpn-3']),
    );
  });

  test('§202 — повторное включение НЕ воскрешает старую ссылку (Решение B)',
      () async {
    await seedRefsOnVpn3();
    final vpn3 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');

    await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));
    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');

    // Включаем обратно — route_final остаётся 'vpn-1', не возвращается на vpn-3.
    final vpn3off = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');
    await SettingsStorage.updateDirection(vpn3off.copyWith(enabled: true));

    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    expect(await ruleOutbound(), 'vpn-1');
  });

  test('§202 — выключение НЕ затрагивает ссылки на ДРУГИЕ Направления', () async {
    // route_final='vpn-1', rule outbound='vpn-1'; выключаем vpn-3 → ничего не
    // должно поменяться (heal матчит только выключаемый тег).
    final data = {
      'directions_migrated': true,
      'directions': [
        Direction(tag: 'vpn-1', label: 'Main', enabled: true).toJson(),
        Direction(tag: 'vpn-3', label: 'Aux', enabled: true).toJson(),
      ],
      'route_final': 'vpn-1',
      'custom_rules': [
        CustomRuleInline(name: 'r1', domains: const ['x.com'], outbound: 'vpn-1')
            .toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();

    final vpn3 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');
    await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));

    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    expect(await ruleOutbound(), 'vpn-1');
  });

  // ── Preset-правила (§248-дыра): outbound override живёт в
  // varsValues['outbound'], а не в поле `outbound` — heal обязан лечить и его,
  // иначе expandPreset эмитит route-правило на несуществующий тег → fatal
  // валидации (DanglingOutboundRef), VPN не стартует.

  /// Storage с Направлениями vpn-1/vpn-3 и одним preset-правилом, чей override
  /// указывает на vpn-3 (+второй var, который heal терять не должен).
  Future<void> seedPresetOverrideOnVpn3() async {
    final data = {
      'directions_migrated': true,
      'directions': [
        Direction(tag: 'vpn-1', label: 'Main', enabled: true).toJson(),
        Direction(tag: 'vpn-3', label: 'Aux', enabled: true).toJson(),
      ],
      'route_final': 'vpn-1',
      'custom_rules': [
        CustomRulePreset(
          name: 'Block Ads',
          presetId: 'block-ads',
          varsValues: const {'outbound': 'vpn-3', 'ruleset': 'ads-all'},
        ).toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<CustomRulePreset> presetRule() async {
    final rules = await SettingsStorage.getCustomRules();
    return rules.single as CustomRulePreset;
  }

  test('delete Направления: preset varsValues[outbound] → vpn-1', () async {
    await seedPresetOverrideOnVpn3();
    expect((await presetRule()).outbound, 'vpn-3');

    await SettingsStorage.deleteDirection('vpn-3');

    final healed = await presetRule();
    expect(healed.varsValues['outbound'], 'vpn-1');
    // Остальные user-vars heal не теряет.
    expect(healed.varsValues['ruleset'], 'ads-all');
  });

  test('disable Направления (§202): preset varsValues[outbound] → vpn-1', () async {
    await seedPresetOverrideOnVpn3();
    final vpn3 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');

    await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));

    expect((await presetRule()).varsValues['outbound'], 'vpn-1');
  });

  test('preset БЕЗ override: heal не подсовывает ключ outbound', () async {
    // Нет ключа 'outbound' → template-решение as is (spec §033); heal не
    // должен превращать «юзер не трогал пикер» в явный override на vpn-1.
    final data = {
      'directions_migrated': true,
      'directions': [
        Direction(tag: 'vpn-1', label: 'Main', enabled: true).toJson(),
        Direction(tag: 'vpn-3', label: 'Aux', enabled: true).toJson(),
      ],
      'route_final': 'vpn-1',
      'custom_rules': [
        CustomRulePreset(
          name: 'Block Ads',
          presetId: 'block-ads',
          varsValues: const {'ruleset': 'ads-all'},
        ).toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();

    await SettingsStorage.deleteDirection('vpn-3');

    final rule = await presetRule();
    expect(rule.varsValues.containsKey('outbound'), isFalse);
    expect(rule.varsValues['ruleset'], 'ads-all');
  });

  test('§202 — disabled → update без смены enabled НЕ перелечивает', () async {
    // Направление уже выключен; меняем у него label (enabled остаётся false). Heal
    // не должен запускаться повторно (wasEnabled=false).
    await seedRefsOnVpn3();
    final vpn3 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');
    await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));
    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');

    // Возвращаем route_final вручную на vpn-1 уже стоит; меняем label у
    // выключенного Направления — ничего не ломается, ссылки стабильны.
    final off = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-3');
    await SettingsStorage.updateDirection(off.copyWith(label: 'Renamed'));

    expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
    expect(
      (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-3')
          .label,
      'Renamed',
    );
  });

  // ─────────────────────────────────────────────────────────────────────
  // §393 A3 — ТРЕТИЙ род ссылки на Направление: `include[]` чужих Направлений.
  //
  // От rules и detours отличается тем, что живёт не в чужом storage-ключе, а
  // в САМОМ списке Направлений. Поэтому лечится ДО записи списка, одной
  // перезаписью, и по тому же паттерну §202: удаление лечит, выключение —
  // нет (оно обратимо, билдер деградирует лишь выхлоп).
  // ─────────────────────────────────────────────────────────────────────
  group('§393 A3 — heal include при удалении Направления', () {
    Future<void> seedIncludeChain() async {
      final data = {
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-2', label: 'Aux').toJson(),
          const Direction(tag: 'vpn-3', label: 'Third', include: ['vpn-2', 'vpn-1'])
              .toJson(),
        ],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();
    }

    Future<List<String>> includeOf(String tag) async =>
        (await SettingsStorage.getDirections())
            .firstWhere((c) => c.tag == tag)
            .include;

    test('delete vpn-2 → include=[vpn-1], счётчик includes==1', () async {
      await seedIncludeChain();
      final healed = await SettingsStorage.deleteDirection('vpn-2');
      expect(await includeOf('vpn-3'), ['vpn-1'],
          reason: 'осиротевший тег вычеркнут, порядок остальных сохранён');
      expect(healed.includes, 1);
      expect(healed.rules, 0);
      expect(healed.detours, 0);
    });

    test('disable vpn-2 → include НЕ тронут (выключение обратимо)', () async {
      await seedIncludeChain();
      final vpn2 = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-2');
      final healed =
          await SettingsStorage.updateDirection(vpn2.copyWith(enabled: false));
      expect(await includeOf('vpn-3'), ['vpn-2', 'vpn-1'],
          reason: 'цель на месте, форма покажет её снятым чекбоксом');
      expect(healed.includes, 0);
    });

    test('auto-двойник в include вычищается вместе с тегом', () async {
      // В `include` `<tag>-auto` невалиден и так (билдер сверяет с
      // эмитированными СЕЛЕКТОРАМИ), но Debug API и правленый бэкап записать
      // его туда могут — как и в rules-heal, где двойник проверяется.
      final data = {
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-2', label: 'Aux').toJson(),
          const Direction(
                  tag: 'vpn-3',
                  label: 'Third',
                  include: ['vpn-2', 'vpn-2-auto', 'vpn-1'])
              .toJson(),
        ],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      final healed = await SettingsStorage.deleteDirection('vpn-2');
      expect(await includeOf('vpn-3'), ['vpn-1']);
      expect(healed.includes, 2, reason: 'тег + его auto-двойник');
    });

    test('несколько Направлений ссылались — вылечены все, счётчик суммарный',
        () async {
      final data = {
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-2', label: 'Aux').toJson(),
          const Direction(tag: 'vpn-3', label: 'C', include: ['vpn-2']).toJson(),
          const Direction(tag: 'vpn-4', label: 'D', include: ['vpn-2', 'vpn-1'])
              .toJson(),
        ],
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      final healed = await SettingsStorage.deleteDirection('vpn-2');
      expect(await includeOf('vpn-3'), isEmpty);
      expect(await includeOf('vpn-4'), ['vpn-1']);
      expect(healed.includes, 2);
    });

    test('delete Направления, на которое никто не ссылался → includes==0',
        () async {
      await seedIncludeChain();
      final healed = await SettingsStorage.deleteDirection('vpn-3');
      expect(healed.includes, 0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // §408 — пятый род ссылки на тег Направления: ключ `ping_options.groups`.
  // ─────────────────────────────────────────────────────────────────────────
  group('§408 — ping_options.groups', () {
    /// Шаблон для миграции: те же три Направления, что в
    /// directions_migration_test.dart. Нужен только веткам, где миграция
    /// сеет состав; в ветке «directions уже есть» не читается.
    GroupTemplates template() => GroupTemplates(
          direction: DirectionTemplate(include: const ['direct']),
          auto: AutoTemplate(options: const {}),
          defaultDirections: [
            DefaultDirection(tag: 'vpn-1', label: 'Main', defaultEnabled: true),
            DefaultDirection(tag: 'vpn-2', label: 'Aux', defaultEnabled: false),
          ],
        );

    Future<void> seedPingGroups(
      Map<String, dynamic> pingGroups, {
      List<String> directions = const ['vpn-1', 'vpn-3'],
      bool migrated = true,
    }) async {
      final data = <String, dynamic>{
        if (migrated) 'directions_migrated': true,
        'directions': [
          for (final t in directions)
            Direction(tag: t, label: t, enabled: true).toJson(),
        ],
        'ping_options': {
          'url': 'https://global.example/generate_204',
          'timeout_ms': 9000,
          'groups': pingGroups,
        },
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();
    }

    /// Карта `groups` как она лежит НА ДИСКЕ (не из кеша) — heal обязан
    /// доезжать до файла тем же `_save()`, что и остальные четыре рода.
    Future<Map<String, dynamic>?> groupsOnDisk() async {
      final raw =
          jsonDecode(await File(mainPath()).readAsString()) as Map<String, dynamic>;
      final opts = raw['ping_options'] as Map<String, dynamic>?;
      return opts?['groups'] as Map<String, dynamic>?;
    }

    test('delete Направления снимает его ключ, чужой не трогает', () async {
      await seedPingGroups({
        'vpn-3': {'url': 'https://aux.example/204', 'timeout_ms': 3000},
        'vpn-1': {'timeout_ms': 1000},
      });

      await SettingsStorage.deleteDirection('vpn-3');

      final groups = await groupsOnDisk();
      expect(groups, isNotNull);
      expect(groups!.containsKey('vpn-3'), isFalse);
      expect(groups.containsKey('vpn-1'), isTrue);
      expect((groups['vpn-1'] as Map)['timeout_ms'], 1000);
      // Глобальные значения — не per-direction, delete их не касается.
      final opts = await SettingsStorage.getPingOptions();
      expect(opts['url'], 'https://global.example/generate_204');
      expect(opts['timeout_ms'], 9000);
    });

    test('delete снимает и ключ auto-двойника `<tag>-auto`', () async {
      await seedPingGroups({
        'vpn-3': {'url': 'https://aux.example/204'},
        'vpn-3-auto': {'url': 'https://twin.example/204'},
        'vpn-1': {'timeout_ms': 1000},
      });

      await SettingsStorage.deleteDirection('vpn-3');

      final groups = await groupsOnDisk();
      expect(groups!.keys, ['vpn-1']);
    });

    test('последний ключ ушёл → карта `groups` снимается целиком', () async {
      await seedPingGroups({
        'vpn-3': {'url': 'https://aux.example/204'},
      });

      await SettingsStorage.deleteDirection('vpn-3');

      final raw =
          jsonDecode(await File(mainPath()).readAsString()) as Map<String, dynamic>;
      final opts = raw['ping_options'] as Map<String, dynamic>;
      expect(opts.containsKey('groups'), isFalse);
      // Сама секция остаётся — в ней живут глобальные url/timeout.
      expect(opts['timeout_ms'], 9000);
    });

    test('disable Направления override НЕ трогает (обратимо, как include)',
        () async {
      await seedPingGroups({
        'vpn-3': {'url': 'https://aux.example/204'},
      });
      final vpn3 = (await SettingsStorage.getDirections())
          .firstWhere((c) => c.tag == 'vpn-3');

      await SettingsStorage.updateDirection(vpn3.copyWith(enabled: false));

      final groups = await groupsOnDisk();
      expect(groups!.containsKey('vpn-3'), isTrue);
    });

    test('миграция (ветка «directions уже есть») снимает сирот, живых не трогает',
        () async {
      // vpn-9 никогда не существовал в этом storage — предсуществующая сирота.
      await seedPingGroups({
        'vpn-1': {'timeout_ms': 1000},
        'vpn-3': {'url': 'https://aux.example/204'},
        'vpn-9': {'url': 'https://ghost.example/204'},
      });

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      final groups = await groupsOnDisk();
      expect(groups!.keys.toSet(), {'vpn-1', 'vpn-3'});
    });

    test('миграция считает живым и `<tag>-auto` живого Направления', () async {
      await seedPingGroups({
        'vpn-3': {'url': 'https://aux.example/204'},
        'vpn-3-auto': {'url': 'https://twin.example/204'},
        'vpn-9-auto': {'url': 'https://ghost.example/204'},
      });

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      final groups = await groupsOnDisk();
      expect(groups!.keys.toSet(), {'vpn-3', 'vpn-3-auto'});
    });

    test('миграция не трогает override выключенного Направления', () async {
      final data = <String, dynamic>{
        'directions_migrated': true,
        'directions': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-3', label: 'Aux', enabled: false).toJson(),
        ],
        'ping_options': {
          'groups': {
            'vpn-3': {'url': 'https://aux.example/204'},
          },
        },
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      final groups = await groupsOnDisk();
      expect(groups!.containsKey('vpn-3'), isTrue);
    });

    test('все ключи живые → файл не переписывается лишний раз', () async {
      await seedPingGroups({
        'vpn-1': {'timeout_ms': 1000},
      });
      final before = await File(mainPath()).readAsString();

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      expect(await File(mainPath()).readAsString(), before);
    });

    test('ветка «мигрировано-и-пусто»: Направлений нет → карта уходит целиком',
        () async {
      final data = <String, dynamic>{
        'directions_migrated': true,
        'ping_options': {
          'groups': {
            'vpn-3': {'url': 'https://aux.example/204'},
          },
        },
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      expect(await groupsOnDisk(), isNull);
    });

    test('ветка seed (чистая установка): сироты из восстановленного бэкапа',
        () async {
      final data = <String, dynamic>{
        'ping_options': {
          'groups': {
            'vpn-2': {'url': 'https://aux.example/204'},
            'vpn-9': {'url': 'https://ghost.example/204'},
          },
        },
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      // Seed заводит vpn-1/vpn-2 из шаблона — vpn-2 становится живым.
      await SettingsStorage.migrateDirectionsIfNeeded(template());

      final groups = await groupsOnDisk();
      expect(groups!.keys, ['vpn-2']);
    });

    test('ветка легаси-списка `channels`: сироты снимаются там же', () async {
      final data = <String, dynamic>{
        'channels': [
          const Direction(tag: 'vpn-1', label: 'Main').toJson(),
          const Direction(tag: 'vpn-3', label: 'Aux').toJson(),
        ],
        'ping_options': {
          'groups': {
            'vpn-3': {'url': 'https://aux.example/204'},
            'vpn-9': {'url': 'https://ghost.example/204'},
          },
        },
      };
      await File(mainPath()).writeAsString(jsonEncode(data));
      SettingsStorage.resetCacheForTesting();

      await SettingsStorage.migrateDirectionsIfNeeded(template());

      final groups = await groupsOnDisk();
      expect(groups!.keys, ['vpn-3']);
    });

    test('clearGroupPing по-прежнему снимает один ключ (§040 не сломан)',
        () async {
      await seedPingGroups({
        'vpn-1': {'timeout_ms': 1000},
        'vpn-3': {'url': 'https://aux.example/204'},
      });

      await SettingsStorage.clearGroupPing('vpn-3');

      final groups = await groupsOnDisk();
      expect(groups!.keys, ['vpn-1']);
    });
  });
}
