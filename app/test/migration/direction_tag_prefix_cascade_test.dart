import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/direction.dart';
import 'package:lxbox/screens/subscription_detail_screen/tag_prefix_cascade.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §393 A6 — каскад смены `tag_prefix` подписки/папки на regex-фильтры
/// Направлений НА УРОВНЕ STORAGE: однозначное вхождение обязано доехать до
/// диска (через `DirectionMutations`, не мимо), неоднозначное — остаться на
/// диске КАК БЫЛО и всплыть предупреждением.
///
/// Harness идентичен direction_heal_refs_test.dart: mock path_provider +
/// изоляция tmp-dir + resetCacheForTesting.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_prefix_cascade_');
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

  /// Storage с одним Направлением vpn-1 и заданными фильтрами.
  Future<void> seed({required String nodeFilter, String defaultFilter = ''}) async {
    final data = {
      'directions_migrated': true,
      'directions': [
        Direction(
          tag: 'vpn-1',
          nodeFilter: nodeFilter,
          defaultFilter: defaultFilter,
        ).toJson(),
      ],
    };
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<Direction> vpn1() async =>
      (await SettingsStorage.getDirections()).firstWhere((d) => d.tag == 'vpn-1');

  Future<TagPrefixCascadeOutcome> run(String oldP, String newP) async =>
      applyTagPrefixCascade(
        directions: await SettingsStorage.getDirections(),
        oldPrefix: oldP,
        newPrefix: newP,
      );

  test('литеральное вхождение: фильтр переписан В STORAGE', () async {
    await seed(nodeFilter: '^RU: ');

    final outcome = await run('RU:', 'DE:');

    expect(outcome.healed.map((d) => d.tag), ['vpn-1']);
    expect(outcome.ambiguous, isEmpty);
    // Главное: на диске новый фильтр, а не в памяти вызывающего.
    expect((await vpn1()).nodeFilter, '^DE: ');
  });

  test('оба фильтра Направления переписаны', () async {
    await seed(nodeFilter: '^RU: ', defaultFilter: 'RU: Berlin');

    await run('RU:', 'DE:');

    final d = await vpn1();
    expect(d.nodeFilter, '^DE: ');
    expect(d.defaultFilter, 'DE: Berlin');
  });

  test('metachar-конструкция: фильтр НЕ тронут, предупреждение возвращено',
      () async {
    await seed(nodeFilter: '^RU[:]');

    final outcome = await run('RU:', 'DE:');

    expect(outcome.healed, isEmpty);
    expect(outcome.ambiguous.map((d) => d.tag), ['vpn-1']);
    expect((await vpn1()).nodeFilter, '^RU[:]',
        reason: 'угадывать regex-конструкцию нельзя');
  });

  test('квантор внутри вхождения — тоже только предупреждение', () async {
    await seed(nodeFilter: 'RU:?');

    final outcome = await run('RU:', 'DE:');

    expect(outcome.healed, isEmpty);
    expect(outcome.ambiguous, hasLength(1));
    expect((await vpn1()).nodeFilter, 'RU:?');
  });

  test('без вхождений — тихо, storage не тронут', () async {
    await seed(nodeFilter: 'Frankfurt');

    final outcome = await run('RU:', 'DE:');

    expect(outcome.isEmpty, isTrue);
    expect(tagPrefixCascadeMessage(outcome), isNull);
    expect((await vpn1()).nodeFilter, 'Frankfurt');
  });

  test('пустой фильтр — тихо (Направление берёт все узлы, префикс ни при чём)',
      () async {
    await seed(nodeFilter: '');

    expect((await run('RU:', 'DE:')).isEmpty, isTrue);
  });

  test('половина Направления чинится, половина — предупреждение', () async {
    // nodeFilter литерален, defaultFilter — конструкция: обе половины правды
    // обязаны дойти до пользователя, а фильтры — разойтись по судьбе.
    await seed(nodeFilter: '^RU: ', defaultFilter: 'RU:?');

    final outcome = await run('RU:', 'DE:');

    expect(outcome.healed, hasLength(1));
    expect(outcome.ambiguous, hasLength(1));
    final d = await vpn1();
    expect(d.nodeFilter, '^DE: ');
    expect(d.defaultFilter, 'RU:?');
  });

  test('снятие префикса (новый пустой) — литерал вырезается', () async {
    await seed(nodeFilter: '^RU: x');

    await run('RU:', '');

    expect((await vpn1()).nodeFilter, '^ x');
  });

  test('пустой СТАРЫЙ префикс: каскада нет (иначе снесло бы все фильтры)',
      () async {
    await seed(nodeFilter: '^RU: ');

    expect((await run('', 'DE:')).isEmpty, isTrue);
    expect((await vpn1()).nodeFilter, '^RU: ');
  });
}
