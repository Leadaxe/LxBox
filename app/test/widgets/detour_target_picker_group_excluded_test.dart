import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// 006-DETOUR_AND_BALANCE P12 — «группа никогда не цель detour и detour'а
/// не имеет»: узел автовыбора не предлагается в пикере цели ни в секции
/// свободных одиночек, ни среди членов папки (§322 — ротирующийся пул,
/// какой хоп сработает, решает ядро).
///
/// Mutation, под которую тест обязан упасть: фильтр `if (n.isGroup) continue`
/// снят у одной из двух секций пикера (`showDetourTargetPicker`,
/// `lib/widgets/detour_target_picker.dart`) — группа всплывает в списке.
void main() {
  testWidgets(
      'узел автовыбора не показан ни среди одиночек, ни среди членов папки',
      (tester) async {
    final regularFree = SocksSpec(
      id: 'free-regular',
      tag: 'regular-free',
      label: 'regular-free',
      server: 'h.example',
      port: 1080,
      rawSource: '',
    );
    final groupFree = AutoSelectSpec(
      id: 'free-group',
      tag: 'GroupFree',
      label: 'GroupFree',
    );
    final freeList = UserServer(
      id: 'list-free',
      name: 'Free list',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      nodes: [regularFree, groupFree],
    );

    final regularMember = SocksSpec(
      id: 'member-regular',
      tag: 'regular-member',
      label: 'regular-member',
      server: 'h2.example',
      port: 1081,
      rawSource: '',
    );
    final groupMember = AutoSelectSpec(
      id: 'member-group',
      tag: 'GroupMember',
      label: 'GroupMember',
    );
    final folder = FolderServers(
      id: 'folder-1',
      name: 'Folder',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(raw: '', node: regularMember),
        FolderMember.auto(groupMember),
      ],
    );

    final controller = SubscriptionController();
    controller.debugSetEntries([
      SubscriptionEntry(list: freeList),
      SubscriptionEntry(list: folder),
    ]);

    DetourTarget? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showDetourTargetPicker(
                context,
                controller: controller,
                currentFolder: folder,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Обычные узлы (не группы) в пикере есть — секции действительно
    // построены и раскрыты.
    expect(find.text('regular-free'), findsOneWidget);
    final folderTile = find.text('This folder (1)');
    expect(folderTile, findsOneWidget);
    await tester.tap(folderTile);
    await tester.pumpAndSettle();
    expect(find.text('regular-member'), findsOneWidget);

    // Группы не показаны нигде.
    expect(find.text('GroupFree'), findsNothing);
    expect(find.text('GroupMember'), findsNothing);

    // Сентинел «нет detour» закрывает сценарий без выбора.
    await tester.tap(find.text('None (direct)'));
    await tester.pumpAndSettle();
    expect(result, DetourTarget.none);
  });
}
