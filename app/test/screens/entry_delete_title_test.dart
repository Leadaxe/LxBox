import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscriptions_screen/entry_delete_title.dart';

/// §603 — удаление своего сервера спрашивало «Delete subscription?».
void main() {
  test('заголовок удаления зависит от типа записи', () {
    final server = UserServer(
      id: 'u1',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
    );
    final sub = SubscriptionServers(
      id: 's1',
      name: 's',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://x.example/sub',
    );
    expect(deleteEntryTitle(server), 'Delete server?');
    expect(deleteEntryTitle(sub), 'Delete subscription?');
  });
}
