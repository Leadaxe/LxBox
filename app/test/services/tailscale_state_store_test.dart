import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/tailscale_state/state_keys.dart';
import 'package:lxbox/services/tailscale_state/state_store.dart';

/// §445 — каталоги состояния узлов Tailscale: ключи узлов, индекс
/// `tailscale_state.json`, реестр (переименование, перенос, удаление),
/// сироты под живым и остановленным ядром, миграция каталогов 2.24.0,
/// наборы записей слотов Workspaces. Файловая система — temp на тест.
void main() {
  late Directory root;
  final store = TailscaleStateStore.I;
  var seq = 0;

  TailscaleSpec ts(String tag, {Map<String, dynamic> body = const {}}) =>
      TailscaleSpec(id: 'n${seq++}', tag: tag, label: tag, body: body);

  UserServer server(String id, NodeSpec node, {String prefix = ''}) =>
      UserServer(
        id: id,
        name: '',
        enabled: true,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        nodes: [node],
      );

  String tsRaw(String tag) =>
      jsonEncode({'type': 'tailscale', 'tag': tag, 'auth_key': 'k-$tag'});

  FolderServers folder(String id, List<String> tags,
          {String prefix = '', Set<int> disabled = const {}}) =>
      FolderServers(
        id: id,
        name: id,
        enabled: true,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        members: [
          for (var i = 0; i < tags.length; i++)
            FolderMember(raw: tsRaw(tags[i]), enabled: !disabled.contains(i)),
        ],
      );

  SubscriptionServers subscription(String id, List<NodeSpec> nodes) =>
      SubscriptionServers(
        id: id,
        name: id,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/$id',
        nodes: nodes,
      );

  Future<bool> stopped() async => true;
  Future<bool> live() async => false;

  Directory stateDir(String name) =>
      Directory('${root.path}/${TailscaleStateStore.dirName}/$name');

  Future<void> putState(String name) async {
    final d = stateDir(name);
    await d.create(recursive: true);
    await File('${d.path}/tailscaled.state').writeAsString('key-$name');
  }

  File indexFile() => File('${root.path}/${TailscaleStateStore.indexFileName}');

  Future<Map<String, dynamic>> index() async =>
      jsonDecode(await indexFile().readAsString()) as Map<String, dynamic>;

  Future<Map<NodeSpec, String>> build(
    List<ServerList> lists, {
    String slot = 'Default',
    Set<String>? slotNames,
    Future<bool> Function()? core,
  }) =>
      store.prepareForBuild(
        root: root.path,
        slot: slot,
        slotNames: slotNames ?? {slot},
        lists: lists,
        coreStopped: core ?? stopped,
      );

  Future<void> relink(
    List<ServerList> before,
    List<ServerList> after, {
    Map<NodeSpec, NodeSpec> renamed = const {},
    String slot = 'Default',
    Set<String>? slotNames,
    Future<bool> Function()? core,
  }) =>
      store.relink(
        root: root.path,
        slot: slot,
        slotNames: slotNames ?? {slot},
        before: before,
        after: after,
        renamed: renamed,
        coreStopped: core ?? stopped,
      );

  NodeSpec member(FolderServers f, int i) => f.members[i].node!;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lxbox_ts_state_');
  });

  tearDown(() async {
    try {
      if (root.existsSync()) await root.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('ключи узлов', () {
    test('сервер — id, член папки и узел подписки — id контейнера + сырой тег',
        () {
      final a = ts('home');
      final b = ts('home');
      final f = folder('F', ['x', 'x', 'y']);
      final sub = subscription('S', [ts('sub'), ts('sub')]);
      final srv = UserServer(
        id: 'U',
        name: '',
        enabled: true,
        tagPrefix: 'pr',
        detourPolicy: DetourPolicy.defaults,
        nodes: [a, b],
      );
      final scan = scanTailscaleStateNodes([srv, f, sub]);
      expect(scan.nodes.map((n) => n.key), [
        'U',
        'U#2',
        'F/x',
        'F/x#2',
        'F/y',
        'S/sub',
        'S/sub-2',
      ]);
      expect(scan.nodes.first.baseName, 'pr_home');
      expect(scan.unresolvedContainers, isEmpty);
    });

    test('явный state_directory ключа не получает; пустые контейнеры — '
        'неразобранные', () {
      final own = ts('own', body: {'state_directory': '/x/own'});
      final brokenFolder = FolderServers(
        id: 'F',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember(raw: 'not a node')],
      );
      final scan = scanTailscaleStateNodes([
        server('U', own),
        brokenFolder,
        subscription('S', const []),
      ]);
      expect(scan.nodes, isEmpty);
      expect(scan.explicitDirs, {'/x/own'});
      expect(scan.unresolvedContainers, {'F', 'S'});
    });

    test('diff: перенос, переименование, удаление, исчезнувший контейнер', () {
      final f1 = folder('F1', ['a', 'b']);
      final f2 = folder('F2', const []);
      final srv = server('U', ts('solo'));
      final moved = FolderServers(
        id: 'F2',
        name: 'F2',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [f1.members[0]],
      );
      final renamedMember = FolderMember(raw: tsRaw('b2'));
      final f1After = f1.copyWith(members: [renamedMember]);
      final d = diffTailscaleStateKeys(
        [f1, f2, srv],
        [f1After, moved],
        renamed: {member(f1, 1): renamedMember.node!},
      );
      expect(d.moves, {'F1/a': 'F2/a', 'F1/b': 'F1/b2'});
      expect(d.gone, {'U'});
      expect(d.goneContainers, {'U'});
    });
  });

  group('сборка и миграция', () {
    test('без узлов, индекса и каталогов на диск ничего не пишется', () async {
      final out = await build(const []);
      expect(out, isEmpty);
      expect(indexFile().existsSync(), isFalse);
    });

    test('новый узел: имя по финальной форме, запись в индексе, каталог не '
        'создаётся', () async {
      final node = ts('home ts');
      final out = await build([server('U', node, prefix: '🇩🇪')]);
      expect(out[node], '___home_ts');
      expect((await index())['slots'], {
        'Default': {'U': '___home_ts'},
      });
      expect(stateDir('___home_ts').existsSync(), isFalse);
    });

    test('имя занято сиротой на диске — суффикс, личность не наследуется',
        () async {
      await build([server('Z', ts('z'))]); // индекс создан до каталога
      await putState('home');
      final node = ts('home');
      final out = await build([server('U', node)], core: live);
      expect(out[node], 'home-1');
    });

    test('миграция: каталог 2.24.0 по финальному тегу подхватывается без '
        'переименования на диске', () async {
      await putState('pr_a');
      await putState('b');
      await putState('b-1');
      final f = folder('F', ['a'], prefix: 'pr');
      final s1 = server('U1', ts('b'));
      final s2 = server('U2', ts('b'));
      final out = await build([f, s1, s2], core: live);
      expect(out[member(f, 0)], 'pr_a');
      expect(out[s1.nodes.single], 'b');
      expect(out[s2.nodes.single], 'b-1');
      expect(
          File('${stateDir('pr_a').path}/tailscaled.state').readAsStringSync(),
          'key-pr_a');
    });

    test('миграция одноразовая: запись есть — старый каталог не забирается и '
        'уходит сиротой', () async {
      final node = ts('a');
      final lists = [server('U', node)];
      await build(lists, core: live); // запись 'a', каталога нет
      await putState('a'); // ядро создало
      await putState('old'); // чужой каталог 2.24.0 после создания индекса
      final renamed = server('U', ts('old'));
      final out = await build([renamed]);
      expect(out[renamed.nodes.single], 'a',
          reason: 'id сервера тот же — запись та же');
      expect(stateDir('old').existsSync(), isFalse);
      expect(stateDir('a').existsSync(), isTrue);
    });
  });

  group('операции над узлами', () {
    test('переименование одиночного сервера и смена префикса — каталог тот же',
        () async {
      final before = server('U', ts('home'), prefix: 'p');
      final name = (await build([before]))[before.nodes.single];
      await putState(name!);
      final after = server('U', ts('office'), prefix: 'q');
      await relink([before], [after],
          renamed: {before.nodes.single: after.nodes.single});
      expect((await build([after]))[after.nodes.single], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('смена префикса папки — каталог тот же', () async {
      final f = folder('F', ['a']);
      final name = (await build([f]))[member(f, 0)]!;
      await putState(name);
      final g = f.copyWith(tagPrefix: 'NEW');
      expect((await build([g]))[member(g, 0)], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('переименование члена — запись переходит на новый ключ, каталог тот '
        'же', () async {
      final f = folder('F', ['a']);
      final name = (await build([f]))[member(f, 0)]!;
      await putState(name);
      final m = FolderMember(raw: tsRaw('b'));
      final g = f.copyWith(members: [m]);
      await relink([f], [g], renamed: {member(f, 0): m.node!});
      expect((await index())['slots'], {
        'Default': {'F/b': name},
      });
      expect((await build([g]))[m.node!], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('перенос члена в другую папку — каталог тот же', () async {
      final f1 = folder('F1', ['a']);
      final f2 = folder('F2', ['z']);
      final names = await build([f1, f2]);
      final name = names[member(f1, 0)]!;
      await putState(name);
      final f1After = f1.copyWith(members: const []);
      final f2After = f2.copyWith(members: [...f2.members, f1.members[0]]);
      await relink([f1, f2], [f1After, f2After]);
      expect((await build([f1After, f2After]))[member(f1, 0)], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('перенос сервера в папку и вынос обратно — каталог тот же', () async {
      final srv = server('U', ts('a'));
      final name = (await build([srv]))[srv.nodes.single]!;
      await putState(name);
      final f = folder('F', ['a']);
      await relink([srv], [f], renamed: {srv.nodes.single: member(f, 0)});
      expect((await build([f]))[member(f, 0)], name);
      final back = server('U2', member(f, 0));
      final empty = f.copyWith(members: const []);
      await relink([f], [empty, back]);
      expect((await build([empty, back]))[member(f, 0)], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('перестановка тёзок — каталоги остаются за своими узлами', () async {
      final f = folder('F', ['a', 'a']);
      final names = await build([f]);
      final first = names[member(f, 0)]!;
      final second = names[member(f, 1)]!;
      expect(first, isNot(second));
      final g = f.copyWith(members: [f.members[1], f.members[0]]);
      await relink([f], [g]);
      final after = await build([g]);
      expect(after[member(f, 0)], first);
      expect(after[member(f, 1)], second);
    });

    test('выключение члена, папки и сервера — каталог не трогается', () async {
      final f = folder('F', ['a', 'b']);
      final srv = server('U', ts('s'));
      final names = await build([f, srv]);
      for (final n in names.values) {
        await putState(n);
      }
      final off = [
        folder('F', ['a', 'b'], disabled: {1}),
        srv.copyWith(enabled: false),
      ];
      // Узлы разобраны заново: ключи те же.
      final after = await build(off);
      expect(after.values.toSet(), names.values.toSet());
      for (final n in names.values) {
        expect(stateDir(n).existsSync(), isTrue, reason: n);
      }
      final folderOff = [f.copyWith(enabled: false), srv];
      await build(folderOff);
      for (final n in names.values) {
        expect(stateDir(n).existsSync(), isTrue, reason: n);
      }
    });

    test('удаление члена при остановленном ядре — каталог удалён', () async {
      final f = folder('F', ['a', 'b']);
      final names = await build([f]);
      final gone = names[member(f, 1)]!;
      await putState(gone);
      await putState(names[member(f, 0)]!);
      final g = f.copyWith(members: [f.members[0]]);
      await relink([f], [g]);
      expect(stateDir(gone).existsSync(), isFalse);
      expect(stateDir(names[member(f, 0)]!).existsSync(), isTrue);
    });

    test('удаление под живым ядром: запись снята сразу, каталог — при сборке '
        'с остановленным ядром; тёзка личность не наследует', () async {
      final f = folder('F', ['a']);
      final name = (await build([f]))[member(f, 0)]!;
      await putState(name);
      final empty = f.copyWith(members: const []);
      await relink([f], [empty], core: live);
      expect(stateDir(name).existsSync(), isTrue);
      expect(((await index())['slots'] as Map)['Default'], isEmpty);

      final again = empty.copyWith(members: [FolderMember(raw: tsRaw('a'))]);
      final fresh = (await build([again], core: live))[member(again, 0)];
      expect(fresh, isNot(name));
      expect(stateDir(name).existsSync(), isTrue, reason: 'ядро поднято');

      await build([again]);
      expect(stateDir(name).existsSync(), isFalse);
    });

    test('удаление папки и подписки целиком — каталоги удалены, в том числе '
        'неразобранных узлов подписки', () async {
      final f = folder('F', ['a']);
      final sub = subscription('S', [ts('x')]);
      final names = await build([f, sub]);
      for (final n in names.values) {
        await putState(n);
      }
      // Тело подписки пропало из кэша: узлов нет, записи держатся.
      final subEmpty = subscription('S', const []);
      await build([f, subEmpty]);
      expect(stateDir(names[sub.nodes.single]!).existsSync(), isTrue);

      await relink([f, subEmpty], const []);
      for (final n in names.values) {
        expect(stateDir(n).existsSync(), isFalse, reason: n);
      }
    });

    test('сирота: снимается при остановленном ядре с info, остаётся при '
        'поднятом; явный state_directory не трогается', () async {
      final own = ts('own', body: {
        'state_directory': '${root.path}/${TailscaleStateStore.dirName}/mine',
      });
      final lists = [server('U', ts('a')), server('O', own)];
      await build(lists);
      await putState('orphan');
      await putState('mine');
      await build(lists, core: live);
      expect(stateDir('orphan').existsSync(), isTrue);
      await build(lists);
      expect(stateDir('orphan').existsSync(), isFalse);
      expect(stateDir('mine').existsSync(), isTrue);
    });

    test('статус ядра не запрашивается, когда снимать нечего', () async {
      final lists = [server('U', ts('a'))];
      await build(lists);
      var asked = 0;
      await build(lists, core: () async {
        asked++;
        return true;
      });
      expect(asked, 0);
    });
  });

  group('Workspaces', () {
    const both = {'Home', 'Work'};

    test('два слота с одним тегом из разных источников — разные каталоги',
        () async {
      final home = server('H', ts('ts'));
      final work = server('W', ts('ts'));
      final h = await build([home], slot: 'Home', slotNames: both);
      final w = await build([work], slot: 'Work', slotNames: both);
      expect(h[home.nodes.single], isNot(w[work.nodes.single]));
    });

    test('Save as: записи копируются, каталоги общие; удаление узла в копии '
        'каталог оригинала не трогает', () async {
      final f = folder('F', ['a']);
      final name =
          (await build([f], slot: 'Home', slotNames: {'Home'}))[member(f, 0)]!;
      await putState(name);
      await store.forkSlot(
          root: root.path, from: 'Home', to: 'Work', slotNames: both);
      final copy = folder('F', ['a']);
      expect(
          (await build([copy], slot: 'Work', slotNames: both))[member(copy, 0)],
          name);

      final empty = copy.copyWith(members: const []);
      await relink([copy], [empty], slot: 'Work', slotNames: both);
      await build([empty], slot: 'Work', slotNames: both);
      expect(stateDir(name).existsSync(), isTrue);

      // Load Home: каталоги не трогаются, запись на месте.
      expect((await build([f], slot: 'Home', slotNames: both))[member(f, 0)],
          name);
    });

    test('переключение туда-обратно: сборка одного слота не стирает каталоги '
        'другого', () async {
      final home = server('H', ts('home'));
      final work = server('W', ts('work'));
      final h = (await build([home], slot: 'Home', slotNames: both))[
          home.nodes.single]!;
      final w = (await build([work], slot: 'Work', slotNames: both))[
          work.nodes.single]!;
      await putState(h);
      await putState(w);
      await build([home], slot: 'Home', slotNames: both);
      await build([work], slot: 'Work', slotNames: both);
      await build([home], slot: 'Home', slotNames: both);
      expect(stateDir(h).existsSync(), isTrue);
      expect(stateDir(w).existsSync(), isTrue);
    });

    test('Delete слота: его каталоги удалены, общие с другим слотом — нет',
        () async {
      final shared = server('S', ts('shared'));
      final own = server('O', ts('own'));
      final names = await build([shared, own], slot: 'Work', slotNames: both);
      for (final n in names.values) {
        await putState(n);
      }
      // Home — копия Work (Save as), из которой узел O потом удалён.
      await store.forkSlot(
          root: root.path, from: 'Work', to: 'Home', slotNames: both);
      await relink([shared, own], [shared], slot: 'Home', slotNames: both);
      expect(stateDir(names[own.nodes.single]!).existsSync(), isTrue,
          reason: 'на каталог O ещё ссылается Work');
      await store.dropSlot(root: root.path, name: 'Work', slotNames: {'Home'});
      expect(stateDir(names[own.nodes.single]!).existsSync(), isFalse);
      expect(stateDir(names[shared.nodes.single]!).existsSync(), isTrue);
    });

    test('Rename слота: набор записей под новым именем, каталоги те же',
        () async {
      final srv = server('U', ts('a'));
      final name = (await build([srv], slot: 'Work', slotNames: both))[
          srv.nodes.single]!;
      await putState(name);
      await store.renameSlot(root: root.path, from: 'Work', to: 'Job');
      final after =
          await build([srv], slot: 'Job', slotNames: {'Home', 'Job'});
      expect(after[srv.nodes.single], name);
      expect(stateDir(name).existsSync(), isTrue);
    });

    test('Save as поверх слота: каталоги прежнего набора без ссылок удалены',
        () async {
      final old = server('OLD', ts('old'));
      final names = await build([old], slot: 'Work', slotNames: both);
      await putState(names.values.single);
      final cur = server('CUR', ts('cur'));
      await build([cur], slot: 'Home', slotNames: both);
      await store.forkSlot(
          root: root.path, from: 'Home', to: 'Work', slotNames: both);
      expect(stateDir(names.values.single).existsSync(), isFalse);
    });

    test('слот без записей (сохранён до индекса) держит каталоги 2.24.0, пока '
        'не собран', () async {
      await putState('home');
      await putState('work');
      final home = server('H', ts('home'));
      final work = server('W', ts('work'));
      final h = await build([home], slot: 'Home', slotNames: both);
      expect(h[home.nodes.single], 'home');
      expect(stateDir('work').existsSync(), isTrue,
          reason: 'Work ещё без записей — его каталог не сирота');
      expect((await index())['legacy'], ['home', 'work']);

      final w = await build([work], slot: 'Work', slotNames: both);
      expect(w[work.nodes.single], 'work');
      expect((await index()).containsKey('legacy'), isFalse);
      expect(stateDir('home').existsSync(), isTrue);
    });

    test('первое Save as из «Default»: личность сцены остаётся, набор '
        '«Default» снимается при сборке', () async {
      final srv = server('U', ts('a'));
      final name = (await build([srv]))[srv.nodes.single]!;
      await putState(name);
      await store.forkSlot(
          root: root.path, from: 'Default', to: 'Home', slotNames: {'Home'});
      final out = await build([srv], slot: 'Home', slotNames: {'Home'});
      expect(out[srv.nodes.single], name);
      expect(((await index())['slots'] as Map).keys, ['Home']);
      expect(stateDir(name).existsSync(), isTrue);
    });
  });
}
