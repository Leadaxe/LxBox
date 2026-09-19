import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/subscription_entry_tile.dart';
import 'package:lxbox/screens/subscriptions_screen/entry_warnings.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  ShadowsocksSpec ssNode() {
    final n = parseUri(
        'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#MySS')! as ShadowsocksSpec;
    return n;
  }

  SubscriptionEntry userEntry({
    required List<StoredWarning> warnings,
    bool enabled = false,
  }) {
    final node = ssNode();
    return SubscriptionEntry(
      list: UserServer(
        id: 'u1',
        name: '',
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: 'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#MySS',
        warnings: warnings,
        nodes: [node],
      ),
      nodeCount: 1,
    );
  }

  SubscriptionEntry subEntry() {
    final node = ssNode();
    final id = sourceNodeIdentities([node])[node]!;
    return SubscriptionEntry(
      list: SubscriptionServers(
        id: 'sub1',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        nodes: [node],
        disabledHashes: {id: DateTime.now()},
        nodeWarnings: {
          id: [StoredWarning.coreRejected('bad key length, required 32, got 5')],
        },
      ),
      nodeCount: 1,
    );
  }

  SubscriptionEntry folderEntry() {
    final node = ssNode();
    return SubscriptionEntry(
      list: FolderServers(
        id: 'f1',
        name: 'folder',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(
            raw: 'ss://YWVzLTI1Ni1nY206dGVzdA==@example.com:8388#MySS',
            enabled: false,
            warnings: [StoredWarning.coreRejected('bad key')],
            node: node,
          ),
        ],
      ),
      nodeCount: 1,
    );
  }

  Future<void> pumpTile(WidgetTester tester, SubscriptionEntry entry) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubscriptionEntryTile(
            entry: entry,
            dragIndex: 0,
            onToggle: () {},
            onLaunchUrl: (_) {},
            onLongPress: (_) {},
            onTap: (_) {},
          ),
        ),
      ));

  group('одиночный сервер в списке источников', () {
    testWidgets('с вердиктом — значок, причина вместо протокола, тап → карточка',
        (tester) async {
      const reason = 'bad key length, required 32, got 5';
      await pumpTile(tester, userEntry(warnings: [StoredWarning.coreRejected(reason)]));

      expect(find.textContaining('SHADOWSOCKS server'), findsNothing);
      expect(find.text(reason), findsOneWidget);
      expect(find.byType(NodeWarningRow), findsOneWidget);
      expect(find.byType(EntryWarningBadge), findsNothing,
          reason: 'счётчик — у подписки/папки, не у одиночного сервера');
      expect(find.text('Notifications'), findsNothing);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NodeWarningsSheet),
          matching: find.textContaining(reason),
        ),
        findsWidgets,
      );
    });

    testWidgets('без вердикта — подпись протокола, без строки предупреждения',
        (tester) async {
      await pumpTile(tester, userEntry(warnings: const []));

      expect(find.textContaining('SHADOWSOCKS server'), findsOneWidget);
      expect(find.byType(NodeWarningRow), findsNothing);
    });
  });

  group('строка подписки / папки', () {
    testWidgets('счётчик actionable при вердикте страховки у узла',
        (tester) async {
      await pumpTile(tester, subEntry());

      expect(find.byType(EntryWarningBadge), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(EntryWarningBadge), matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(EntryWarningBadge),
            matching: find.byIcon(Icons.error_outline)),
        findsOneWidget,
      );
    });

    testWidgets('папка со членом под вердиктом — тот же счётчик',
        (tester) async {
      await pumpTile(tester, folderEntry());

      expect(find.byType(EntryWarningBadge), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(EntryWarningBadge), matching: find.text('1')),
        findsOneWidget,
      );
    });
  });
}
