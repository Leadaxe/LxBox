import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §393 D2 — каскад «источник удалён → из цепочек вычищается ЕГО ПОЗИЦИЯ».
///
/// Директива оператора 24.08. Проверяем РОД источника, а не одну точку кода:
/// одиночный сервер, подписка целиком, папка, Направление, другая цепочка —
/// у каждого свой путь удаления, и подключён должен быть каждый.
///
/// Отдельно закреплена ГРАНИЦА: пропажа узла при ОБНОВЛЕНИИ подписки heal НЕ
/// триггерит. Узел может вернуться следующим обновлением, и фоновое событие
/// не вправе молча резать маршруты, написанные руками, — там остаётся
/// деградация билдера `chain_hop_missing`.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_chain_heal_');
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

  String nodeRaw(String name) =>
      'vless://u-$name@h.com:443?type=ws&security=tls#$name';

  UserServer solo(String id, String nodeName) => UserServer(
        id: id,
        name: 'Solo $id',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        rawBody: nodeRaw(nodeName),
      );

  /// Пишем состояние прямо в файл: контроллер поднимается уже над ним, как в
  /// `detour_direction_resync_test`.
  Future<void> seed({
    required List<Map<String, dynamic>> lists,
    required List<SourceChain> chains,
    List<Direction> directions = const [Direction(tag: 'vpn-1')],
  }) async {
    await File(mainPath()).writeAsString(jsonEncode({
      'directions_migrated': true,
      'directions': [for (final d in directions) d.toJson()],
      'server_lists': lists,
      'chains': [for (final c in chains) c.toJson()],
    }));
    SettingsStorage.resetCacheForTesting();
  }

  Future<SubscriptionController> boot() async {
    final ctrl = SubscriptionController();
    await ctrl.init();
    await ctrl.rehydrationDone;
    return ctrl;
  }

  test('одиночный сервер удалён → позиция ушла, цепочка осталась', () async {
    await seed(
      lists: [solo('u1', 'alpha').toJson(), solo('u2', 'beta').toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['alpha', 'beta', 'vpn-1']),
      ],
    );
    final ctrl = await boot();
    await ctrl.removeAt(0);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.tag, 'route', reason: 'цепочка НЕ удалена каскадом');
    expect(chains.single.hops, ['beta', 'vpn-1']);
    expect(ctrl.lastChainPositionsRemoved, 1,
        reason: 'счётчик для snackbar — укорачивание маршрута заметно');
  });

  test('подписка целиком удалена → уходят позиции всех её узлов', () async {
    // Позиция ссылается на ТЕГ КОНФИГА: у подписки с префиксом это
    // «<префикс> <узел>». Узлы подписки на диск не пишутся (регидрация из
    // HTTP-кэша), поэтому ставим их прямо в живую запись контроллера — так же,
    // как их поставил бы фетч.
    final sub = SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: 'RU',
      detourPolicy: const DetourPolicy(),
      url: 'https://example.com/sub',
    );
    await seed(
      lists: [sub.toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['RU n1', 'vpn-1', 'direct-out']),
      ],
    );
    final ctrl = await boot();
    ctrl.entries.single.list.nodes
        .addAll(parseAll(decode(nodeRaw('n1'))));

    await ctrl.removeAt(0);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['vpn-1', 'direct-out']);
    expect(ctrl.lastChainPositionsRemoved, 1);
  });

  test('папка удалена вместе с серверами → уходят позиции её членов',
      () async {
    final folder = FolderServers(
      id: 'f1',
      name: 'Folder',
      enabled: true,
      tagPrefix: '',
      detourPolicy: const DetourPolicy(),
      members: [
        FolderMember(raw: nodeRaw('m1')),
      ],
    );
    await seed(
      lists: [folder.toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['m1', 'vpn-1', 'direct-out']),
      ],
    );
    final ctrl = await boot();
    await ctrl.deleteFolderAt(0, keepServers: false);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['vpn-1', 'direct-out']);
    expect(ctrl.lastChainPositionsRemoved, 1);
  });

  test('роспуск папки С СОХРАНЕНИЕМ серверов позиции на членов не трогает',
      () async {
    // Узлы остаются в конфиге одиночными серверами — позиция на них законна.
    final folder = FolderServers(
      id: 'f1',
      name: 'Folder',
      enabled: true,
      tagPrefix: '',
      detourPolicy: const DetourPolicy(),
      members: [
        FolderMember(raw: nodeRaw('m1')),
      ],
    );
    await seed(
      lists: [folder.toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['m1', 'vpn-1']),
      ],
    );
    final ctrl = await boot();
    await ctrl.deleteFolderAt(0, keepServers: true);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['m1', 'vpn-1']);
    expect(ctrl.lastChainPositionsRemoved, 0);
  });

  test('член папки удалён → его позиция уходит', () async {
    final folder = FolderServers(
      id: 'f1',
      name: 'Folder',
      enabled: true,
      tagPrefix: '',
      detourPolicy: const DetourPolicy(),
      members: [
        FolderMember(raw: nodeRaw('m1')),
        FolderMember(raw: nodeRaw('m2')),
      ],
    );
    await seed(
      lists: [folder.toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['m1', 'm2', 'vpn-1']),
      ],
    );
    final ctrl = await boot();
    await ctrl.removeMemberAt(0, 0);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['m2', 'vpn-1']);
    expect(ctrl.lastChainPositionsRemoved, 1);
  });

  test('Направление удалено → его позиция уходит, цепочка живёт', () async {
    await seed(
      lists: [solo('u1', 'alpha').toJson()],
      chains: const [
        SourceChain(tag: 'route', hops: ['alpha', 'vpn-2', 'vpn-1']),
      ],
      directions: const [
        Direction(tag: 'vpn-1'),
        Direction(tag: 'vpn-2'),
      ],
    );
    final ctrl = await boot();
    final healed = await DirectionMutations.delete('vpn-2', ctrl);

    expect(healed.chainPositions, 1,
        reason: 'счётчик едет вместе с rules/detours/includes');
    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['alpha', 'vpn-1']);
  });

  test('цепочка-позиция: удаление A вычищает A из B, B живёт (рекурсия)',
      () async {
    await seed(
      lists: [solo('u1', 'alpha').toJson()],
      chains: const [
        SourceChain(tag: 'A', hops: ['alpha', 'vpn-1']),
        SourceChain(tag: 'B', hops: ['A', 'alpha', 'vpn-1']),
      ],
    );
    await boot();
    final healed = await SettingsStorage.deleteChain('A');

    expect(healed.positions, 1);
    expect(healed.touched, ['B']);
    final chains = await SettingsStorage.getChains();
    expect(chains.map((c) => c.tag), ['B'],
        reason: 'каскад рекурсивен только через позиции, B не удаляется');
    expect(chains.single.hops, ['alpha', 'vpn-1']);
  });

  test('2-хоповая после heal остаётся в storage, но не эмитится', () async {
    await seed(
      lists: [solo('u1', 'alpha').toJson(), solo('u2', 'beta').toJson()],
      chains: const [
        SourceChain(tag: 'short', hops: ['alpha', 'beta']),
      ],
    );
    final ctrl = await boot();
    await ctrl.removeAt(0);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.tag, 'short',
        reason: 'данные пользователя не стираются — чинит руками');
    expect(chains.single.hops, ['beta']);
    expect(chainEmitError(chains.single), isNotEmpty,
        reason: 'одна позиция → существующая деградация, цепочка не эмитится');
  });

  test('3-хоповая после heal эмитится УКОРОЧЕННОЙ + счётчик', () async {
    await seed(
      lists: [solo('u1', 'alpha').toJson(), solo('u2', 'beta').toJson()],
      chains: const [
        SourceChain(tag: 'long', hops: ['alpha', 'beta', 'vpn-1']),
      ],
    );
    final ctrl = await boot();
    await ctrl.removeAt(0);

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['beta', 'vpn-1']);
    expect(chainEmitError(chains.single), isEmpty,
        reason: 'осознанное решение оператора: маршрут эмитится короче');
    expect(ctrl.lastChainPositionsRemoved, 1,
        reason: 'но пользователь ОБЯЗАН узнать');
  });

  test('ГРАНИЦА: обновление подписки НЕ вычищает позиции', () async {
    // Узел пропал из тела подписки — это ФОНОВОЕ событие, а не высказывание
    // пользователя про состав. Он может вернуться следующим обновлением.
    final sub = SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: '',
      detourPolicy: const DetourPolicy(),
      url: 'https://example.com/sub',
      nodes: [],
    );
    await seed(
      lists: [
        {
          ...sub.toJson(),
          'nodes': [
            {'tag': 'gone', 'type': 'vless', 'raw': nodeRaw('gone')},
          ],
        },
      ],
      chains: const [
        SourceChain(tag: 'route', hops: ['gone', 'vpn-1']),
      ],
    );
    final ctrl = await boot();

    // Пере-парсинг тела БЕЗ узла `gone` — путь обновления подписки.
    final entry = ctrl.entries.single;
    await ctrl.replaceList(
      0,
      (entry.list as SubscriptionServers).copyWith(nodes: []),
    );

    final chains = await SettingsStorage.getChains();
    expect(chains.single.hops, ['gone', 'vpn-1'],
        reason: 'позиция цела — узел может вернуться');
    expect(ctrl.lastChainPositionsRemoved, 0);
  });
}
