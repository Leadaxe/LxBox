// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/handlers/rules.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §370 — `POST /rules/move` и синхронность Debug API с UI по оси `num`.
///
/// Ручка существует ради тестируемости порядка: без неё перестановку можно
/// проверить только тапами по экрану. Идёт тем же путём, что drag в UI
/// (`placeRuleAfter` + `sortRulesByNum` + персист), поэтому этот тест
/// одновременно покрывает и UI-механику.
///
/// Шаблон грузится настоящий (`rootBundle` в тестах читает реальные assets) —
/// значит проверяется фактическая раскладка §370 §2, а не синтетика.
void main() {
  late Directory tempDir;
  late DebugContext ctx;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('lxbox-rules-move');
    await Directory('${tempDir.path}/docs').create(recursive: true);
    await Directory('${tempDir.path}/support').create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    ctx = DebugContext(
      registry: DebugRegistry.I,
      appStartedAt: DateTime.utc(2026, 8, 4),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> axis() async {
    final rules = await SettingsStorage.getCustomRules();
    return [
      for (final r in rules)
        {'name': r.name, 'preset': r.presetId, 'num': r.orderNum}
    ];
  }

  Future<Map<String, dynamic>> move(String id, String? after) async {
    final res = await rulesHandler(
      DebugRequest.forTest(
        method: 'POST',
        path: '/rules/move',
        query: const {},
        body: utf8.encode(jsonEncode({'id': id, 'after': after})),
      ),
      ctx,
    );
    return (res as JsonResponse).body as Map<String, dynamic>;
  }

  Future<void> seed(List<CustomRule> rules) =>
      SettingsStorage.saveCustomRules(rules);

  test('move за целевым: свободный номер — соседи не двигаются', () async {
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    final b = CustomRuleInline(name: 'b')..orderNum = 1010;
    final c = CustomRuleInline(name: 'c')..orderNum = 1020;
    await seed([a, b, c]);

    final out = await move(c.id, a.id);

    expect(out['num'], 1001);
    final now = await axis();
    expect(now.map((e) => e['name']), ['a', 'c', 'b']);
    expect(now.firstWhere((e) => e['name'] == 'b')['num'], 1010,
        reason: 'want был свободен — сосед не двигается');
  });

  test('move в занятую точку: сдвигается сплошной блок, дальний не трогается',
      () async {
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    final b = CustomRuleInline(name: 'b')..orderNum = 1001;
    final c = CustomRuleInline(name: 'c')..orderNum = 1002;
    final far = CustomRuleInline(name: 'far')..orderNum = 1090;
    final moved = CustomRuleInline(name: 'moved')..orderNum = 1050;
    await seed([a, b, c, far, moved]);

    await move(moved.id, a.id);

    final now = await axis();
    Object? numOf(String n) =>
        now.firstWhere((e) => e['name'] == n)['num'];
    expect(numOf('moved'), 1001);
    expect(numOf('b'), 1002, reason: 'сплошной блок +1');
    expect(numOf('c'), 1003);
    expect(numOf('far'), 1090, reason: 'за дыркой — не трогаем');
  });

  test('move с after:null — правило уходит в начало пользовательской зоны',
      () async {
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    final moved = CustomRuleInline(name: 'moved')..orderNum = 1050;
    await seed([a, moved]);

    final out = await move(moved.id, null);

    expect(out['num'], 1000);
    final now = await axis();
    expect(now.map((e) => e['name']), ['moved', 'a']);
  });

  test('несортируемый пресет двигать нельзя — 400', () async {
    final head = CustomRulePreset(
        name: 'Traffic Processing', presetId: 'traffic-processing')
      ..orderNum = 0;
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    await seed([head, a]);

    expect(() => move(head.id, a.id), throwsA(isA<BadRequest>()));
  });

  test('несортируемый пресет не сдвигается, когда двигают других', () async {
    final head = CustomRulePreset(
        name: 'Traffic Processing', presetId: 'traffic-processing')
      ..orderNum = 0;
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    final b = CustomRuleInline(name: 'b')..orderNum = 1001;
    await seed([head, a, b]);

    await move(b.id, a.id);

    final now = await axis();
    expect(now.first['preset'], 'traffic-processing');
    expect(now.first['num'], 0);
  });

  test('неизвестный id → 404, after == id → 400', () async {
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    await seed([a]);

    expect(() => move('no-such-uuid', null), throwsA(isA<NotFound>()));
    expect(() => move(a.id, 'no-such-uuid'), throwsA(isA<NotFound>()));
    expect(() => move(a.id, a.id), throwsA(isA<BadRequest>()));
  });

  test('storage без num (до §370) размечается на первом move', () async {
    final a = CustomRuleInline(name: 'a'); // orderNum == null
    final b = CustomRuleInline(name: 'b');
    final c = CustomRuleInline(name: 'c');
    await seed([a, b, c]);
    expect((await SettingsStorage.getCustomRules()).first.orderNum, isNull);

    await move(c.id, a.id);

    final now = await axis();
    expect(now.every((e) => e['num'] != null), isTrue,
        reason: 'все размечены, а не только перемещённое');
    expect(now.map((e) => e['name']), ['a', 'c', 'b']);
  });

  test('порядок переживает перезагрузку storage (ось, а не массив)', () async {
    final a = CustomRuleInline(name: 'a')..orderNum = 1000;
    final b = CustomRuleInline(name: 'b')..orderNum = 1010;
    await seed([a, b]);
    await move(b.id, null);

    SettingsStorage.resetCacheForTesting();
    final reloaded = await SettingsStorage.getCustomRules();

    expect(reloaded.map((r) => r.name), ['b', 'a']);
    expect(reloaded.first.orderNum, 1000);
  });

  test('POST /rules проставляет num: пресет — шаблонный, inline — в зону',
      () async {
    Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
      final res = await rulesHandler(
        DebugRequest.forTest(
            method: 'POST',
            path: '/rules',
            query: const {},
            body: utf8.encode(jsonEncode(body))),
        ctx,
      );
      return (res as JsonResponse).body as Map<String, dynamic>;
    }

    final inline = await create({'name': 'user-1', 'kind': 'inline'});
    expect(inline['num'], 1000, reason: 'первое пользовательское — старт зоны');

    final preset =
        await create({'name': 'VoWiFi', 'kind': 'preset', 'preset_id': 'vowifi'});
    expect(preset['num'], 990, reason: 'шаблонный num из wizard_template.json');

    final now = await axis();
    expect(now.map((e) => e['name']), ['VoWiFi', 'user-1'],
        reason: 'пресет 990 встаёт ВЫШЕ пользовательского 1000');
  });

  test('GET /rules отдаёт num — API виден снаружи', () async {
    await seed([CustomRuleInline(name: 'a')..orderNum = 1042]);

    final res = await rulesHandler(
      DebugRequest.forTest(
          method: 'GET', path: '/rules', query: const {}, body: const []),
      ctx,
    );
    final list = (res as JsonResponse).body as List;

    expect((list.single as Map)['num'], 1042);
  });
}
