import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §125 F0.3 — миграция enabled_groups[] → directions[] (one-shot seed из template).
///
/// Harness идентичен settings_storage_test.dart: mock path_provider + изоляция
/// tmp-dir + resetCacheForTesting между прогонами.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  // §267 — group_templates: общий json-шаблон `channel` (direct+auto) для всех Направлений
  // + default_channels vpn-1/vpn-2/vpn-3 + auto-подгруппа. Все Направления одинаковы
  // (единый include), в отличие от старой per-group add_outbounds.
  GroupTemplates template() => GroupTemplates(
        direction: DirectionTemplate(
          include: const ['direct', 'auto'],
          options: const {'interrupt_exist_connections': true},
        ),
        auto: AutoTemplate(
          options: const {
            'url': 'https://cp.cloudflare.com/generate_204',
            'interval': '5m',
            'tolerance': 50,
          },
        ),
        defaultDirections: [
          DefaultDirection(tag: 'vpn-1', label: 'Главный', defaultEnabled: true),
          DefaultDirection(tag: 'vpn-2', label: 'Стриминг', defaultEnabled: false),
          DefaultDirection(tag: 'vpn-3', defaultEnabled: false),
        ],
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_directions_mig_');
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

  Future<void> seedFile(Map<String, dynamic> data) async {
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  test('fresh install: seed из template, enabled_groups пуст', () async {
    await seedFile({});
    await SettingsStorage.migrateDirectionsIfNeeded(template());

    final directions = await SettingsStorage.getDirections();
    // §267 — default_channels vpn-1/2/3 → 3 Направления (auto не Направление — подгруппа).
    expect(directions.map((c) => c.tag), ['vpn-1', 'vpn-2', 'vpn-3']);

    final vpn1 = directions.firstWhere((c) => c.tag == 'vpn-1');
    expect(vpn1.enabled, true); // vpn-1 форсим
    expect(vpn1.includeDirect, true); // direction.include ∋ direct
    expect(vpn1.auto, isNotNull); // direction.include ∋ auto → двойник
    expect(vpn1.auto!.url, 'https://cp.cloudflare.com/generate_204');
    expect(vpn1.auto!.idleTimeout, '30m');
    expect(vpn1.auto!.interruptExistConnections, false);
    expect(vpn1.interruptExistConnections, true);

    // §267 — все Направления собираются из общего json-шаблона `channel` (единый include),
    // поэтому includeDirect/auto одинаковы у всех; различаются только
    // tag/label/enabled из default_channels.
    final vpn2 = directions.firstWhere((c) => c.tag == 'vpn-2');
    expect(vpn2.enabled, false); // defaultEnabled false
    expect(vpn2.includeDirect, true);
    expect(vpn2.auto, isNotNull);

    final vpn3 = directions.firstWhere((c) => c.tag == 'vpn-3');
    expect(vpn3.includeDirect, true);
    expect(vpn3.defaultFilter, ''); // Решение 6
    expect(vpn3.nodeFilter, '');
  });

  test('enabled_groups задаёт enabled (не defaultEnabled)', () async {
    // юзер выключил vpn-1 (но миграция всё равно форсит), включил vpn-3
    await seedFile({
      'enabled_groups': ['vpn-3'],
    });
    await SettingsStorage.migrateDirectionsIfNeeded(template());

    final directions = await SettingsStorage.getDirections();
    expect(directions.firstWhere((c) => c.tag == 'vpn-1').enabled, true); // форс
    expect(directions.firstWhere((c) => c.tag == 'vpn-2').enabled, false);
    expect(directions.firstWhere((c) => c.tag == 'vpn-3').enabled, true);
  });

  test('идемпотентность: повторный вызов — no-op', () async {
    await seedFile({});
    await SettingsStorage.migrateDirectionsIfNeeded(template());
    final first = await SettingsStorage.getDirections();

    // юзер удалил Направление после миграции
    await SettingsStorage.setDirections(
        first.where((c) => c.tag != 'vpn-2').toList());
    // повторная миграция НЕ должна пересеять vpn-2
    await SettingsStorage.migrateDirectionsIfNeeded(template());

    final after = await SettingsStorage.getDirections();
    expect(after.map((c) => c.tag), ['vpn-1', 'vpn-3']);
  });

  test('✨auto с нерезолвенными @var-плейсхолдерами → дефолты (не падает)',
      () async {
    // Регресс: реальный template хранит сырые "@urltest_*"-плейсхолдеры в
    // preset.options (var-substitution идёт позже, в билдере). seedAuto не
    // должен делать `as num?`-каст строки "@urltest_tolerance" → краш миграции
    // → вечный прелоадер Routing (баг dev.91).
    final placeholderTemplate = GroupTemplates(
      direction: DirectionTemplate(include: const ['auto']),
      auto: AutoTemplate(
        options: const {
          'url': '@urltest_url',
          'interval': '@urltest_interval',
          'tolerance': '@urltest_tolerance', // СТРОКА-плейсхолдер!
        },
      ),
      defaultDirections: [DefaultDirection(tag: 'vpn-1')],
    );
    await seedFile({});
    await SettingsStorage.migrateDirectionsIfNeeded(placeholderTemplate);

    final directions = await SettingsStorage.getDirections();
    final vpn1 = directions.firstWhere((c) => c.tag == 'vpn-1');
    expect(vpn1.auto, isNotNull); // двойник засеян, не упал
    // §327 — плейсхолдеры → дефолты `DirectionAuto` (varDefaults здесь не
    // передан). Раньше тут стояли литералы из кода seed'а (5m/50), которые
    // разошлись с шаблоном; теперь единственный источник — сам класс.
    const fallback = DirectionAuto();
    expect(vpn1.auto!.url, fallback.url);
    expect(vpn1.auto!.interval, fallback.interval);
    expect(vpn1.auto!.tolerance, fallback.tolerance);
  });

  test('✨auto с tolerance числом-в-строке → парсится', () async {
    final t = GroupTemplates(
      direction: DirectionTemplate(include: const ['auto']),
      auto: AutoTemplate(
        options: const {'tolerance': '30'}, // число-в-строке
      ),
      defaultDirections: [DefaultDirection(tag: 'vpn-1')],
    );
    await seedFile({});
    await SettingsStorage.migrateDirectionsIfNeeded(t);
    final vpn1 = (await SettingsStorage.getDirections())
        .firstWhere((c) => c.tag == 'vpn-1');
    expect(vpn1.auto!.tolerance, 30);
  });

  test('directions уже есть → миграция no-op', () async {
    await seedFile({
      'channels': [
        {'tag': 'vpn-1', 'label': 'Custom', 'enabled': true},
      ],
    });
    await SettingsStorage.migrateDirectionsIfNeeded(template());

    final directions = await SettingsStorage.getDirections();
    expect(directions.length, 1);
    expect(directions.first.label, 'Custom'); // не перезаписано template'ом
  });

  group('CRUD после миграции', () {
    setUp(() async {
      await seedFile({});
      await SettingsStorage.migrateDirectionsIfNeeded(template());
    });

    test('addDirection — первый свободный vpn-N', () async {
      // vpn-1/2/3 заняты → vpn-4
      final ch = await SettingsStorage.addDirection(label: 'Новый');
      expect(ch.tag, 'vpn-4');
      expect(ch.label, 'Новый');
      expect((await SettingsStorage.getDirections()).length, 4);
    });

    test('§198 — addDirection без label → дефолт с кружком (VPN ④)', () async {
      // vpn-1/2/3 заняты → vpn-4 → «VPN ④».
      final ch = await SettingsStorage.addDirection();
      expect(ch.tag, 'vpn-4');
      expect(ch.label, 'VPN ④');
    });

    test('addDirection — лимит 10 throws', () async {
      for (var i = 4; i <= 10; i++) {
        await SettingsStorage.addDirection();
      }
      expect((await SettingsStorage.getDirections()).length, 10);
      expect(() => SettingsStorage.addDirection(), throwsStateError);
    });

    test('deleteDirection vpn-1 throws', () async {
      expect(() => SettingsStorage.deleteDirection('vpn-1'), throwsStateError);
    });

    test('deleteDirection переводит route_final → vpn-1', () async {
      await SettingsStorage.saveRouteFinal('vpn-2');
      await SettingsStorage.deleteDirection('vpn-2');
      expect(await SettingsStorage.getRouteFinal(), 'vpn-1');
      expect((await SettingsStorage.getDirections()).map((c) => c.tag),
          ['vpn-1', 'vpn-3']);
    });

    test('route_final на другое Направление не трогается', () async {
      await SettingsStorage.saveRouteFinal('vpn-3');
      await SettingsStorage.deleteDirection('vpn-2');
      expect(await SettingsStorage.getRouteFinal(), 'vpn-3');
    });

    test('updateDirection — несуществующий tag throws', () async {
      const ghost = Direction(tag: 'vpn-9', label: 'ghost');
      expect(() => SettingsStorage.updateDirection(ghost), throwsStateError);
    });
  });

  // §327 — в РЕАЛЬНОМ шаблоне `group_templates.auto.options` несёт
  // `@urltest_*`-плейсхолдеры (var-substitution идёт позже, в билдере). Раньше
  // на них срабатывали литералы в коде, и в Направления садились 50/5m вместо
  // шаблонных 30/15m. Дефолт обязан быть один — из `vars[].default_value`.
  group('§327 seed auto-Направления по @var-плейсхолдерам', () {
    GroupTemplates placeholderTemplate() => GroupTemplates(
          direction: DirectionTemplate(
            include: const ['direct', 'auto'],
            options: const {'interrupt_exist_connections': true},
          ),
          auto: AutoTemplate(
            options: const {
              'url': '@urltest_url',
              'interval': '@urltest_interval',
              'tolerance': '@urltest_tolerance',
            },
          ),
          defaultDirections: [
            DefaultDirection(tag: 'vpn-1', label: 'Main', defaultEnabled: true),
          ],
        );

    const varDefaults = {
      'urltest_url': 'https://example.test/generate_204',
      'urltest_interval': '15m',
      'urltest_tolerance': '30',
    };

    test('плейсхолдеры резолвятся в default_value шаблона', () async {
      await SettingsStorage.migrateDirectionsIfNeeded(
        placeholderTemplate(),
        varDefaults: varDefaults,
      );
      final auto = (await SettingsStorage.getDirections()).first.auto!;

      expect(auto.tolerance, 30); // было 50 из литерала
      expect(auto.interval, '15m'); // было '5m'
      expect(auto.url, 'https://example.test/generate_204');
    });

    test('без varDefaults — дефолты DirectionAuto, а не литералы', () async {
      // Var исчезла из шаблона: последний рубеж — дефолт самого класса.
      await SettingsStorage.migrateDirectionsIfNeeded(placeholderTemplate());
      final auto = (await SettingsStorage.getDirections()).first.auto!;
      const fallback = DirectionAuto();

      expect(auto.tolerance, fallback.tolerance);
      expect(auto.interval, fallback.interval);
      expect(auto.url, fallback.url);
    });

    test('явное значение в options побеждает default_value', () async {
      await SettingsStorage.migrateDirectionsIfNeeded(
        GroupTemplates(
          direction: DirectionTemplate(include: const ['direct', 'auto']),
          auto: AutoTemplate(
            options: const {'interval': '3m', 'tolerance': 77},
          ),
          defaultDirections: [DefaultDirection(tag: 'vpn-1', defaultEnabled: true)],
        ),
        varDefaults: varDefaults,
      );
      final auto = (await SettingsStorage.getDirections()).first.auto!;

      expect(auto.tolerance, 77);
      expect(auto.interval, '3m');
    });
  });
}
