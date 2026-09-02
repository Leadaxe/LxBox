import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// §252 — detourPathHops: разворот сохранённого detour-значения в цепочку
/// «как пакет пойдёт» — В ПОРЯДКЕ ПАКЕТА (глубочайший транспорт первым,
/// прямая цель последней). Контроллер без init — entries пуст, внешние одиночки в этих
/// кейсах не участвуют.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SelectorInfo.I.resetForTesting());
  tearDown(() => SelectorInfo.I.resetForTesting());

  String raw(String name) =>
      'vless://u-$name@h.com:443?type=ws&security=tls#$name';

  const relay = Direction(tag: 'vpn-4', isDetour: true);

  test('Направление — терминальный хоп с текущим выбором', () {
    SelectorInfo.I.setGroups({'vpn-4': '🇳🇱 Нидерланды'});
    final hops = detourPathHops('vpn-4',
        controller: SubscriptionController(), directions: const [relay]);
    expect(hops, ['⚙ vpn-4 (🇳🇱 Нидерланды)']);
  });

  test('интра-цепочка папки разворачивается до Направления', () {
    final folder = FolderServers(
      id: 'f',
      name: 'F',
      enabled: true,
      tagPrefix: 'p-',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(raw: raw('a'), detour: 'b'),
        FolderMember(raw: raw('b'), detour: 'vpn-4'),
      ],
    );
    final hops = detourPathHops('a',
        controller: SubscriptionController(),
        directions: const [relay],
        folder: folder);
    expect(hops, ['⚙ vpn-4', 'b', 'a']);
  });

  test('цикл в storage не виснет (visited-гейт)', () {
    final folder = FolderServers(
      id: 'f',
      name: 'F',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(raw: raw('a'), detour: 'b'),
        FolderMember(raw: raw('b'), detour: 'a'),
      ],
    );
    final hops = detourPathHops('a',
        controller: SubscriptionController(),
        directions: const [],
        folder: folder);
    expect(hops, ['b', 'a']);
  });

  test('неизвестная цель — один хоп как есть', () {
    final hops = detourPathHops('ghost-node',
        controller: SubscriptionController(), directions: const []);
    expect(hops, ['ghost-node']);
  });
}
