import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';
import 'package:lxbox/screens/home/widgets/node_list.dart';

/// §446 — `poolBadgeOf` зовётся из `itemBuilder` на каждую видимую строку
/// автовыбора каждый кадр, и раньше обходил ВСЕ узлы всех подписок. Теперь
/// между вызовами живёт срез spec'ов автовыбора. Проверяем, что кэш не
/// переживает смену состава подписок: иначе список показывал бы чужие значки.
void main() {
  setUp(resetPoolBadgeCache);
  tearDown(resetPoolBadgeCache);

  AutoSelectSpec auto(String tag, String badge) => AutoSelectSpec(
        id: tag,
        tag: tag,
        label: tag,
        poolBadge: badge,
      );

  UserServer listWith(List<NodeSpec> nodes) => UserServer(
        id: 'list-1',
        name: 'list-1',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        nodes: nodes,
      );

  SubscriptionController controllerWith(List<NodeSpec> nodes) {
    final c = SubscriptionController();
    c.debugSetEntries([SubscriptionEntry(list: listWith(nodes))]);
    return c;
  }

  test('до сборки значок берётся у spec с тем же показанным тегом', () {
    final c = controllerWith([auto('auto-de', '🇩🇪')]);
    expect(poolBadgeOf(c, 'auto-de'), '🇩🇪');
  });

  test('§675 — суффиксное совпадение больше не матчит чужую группу', () {
    final c = controllerWith([auto('de', '🇩🇪'), auto('auto-de', '🏳')]);
    expect(poolBadgeOf(c, 'auto-de'), '🏳');
    expect(poolBadgeOf(c, 'sub-1-auto-de'), kDefaultPoolBadge);
  });

  test('§675 — тег с суффиксом уникализации находится по карте сборки', () {
    final g = auto('Auto', '🇩🇪');
    final c = controllerWith([auto('Auto', '🏳'), g]);
    c.debugSetLastEmittedGroupMap({'Auto-1': g});
    expect(poolBadgeOf(c, 'Auto-1'), '🇩🇪');
  });

  test('тег без своего spec получает дефолт', () {
    final c = controllerWith([auto('auto-de', '🇩🇪')]);
    expect(poolBadgeOf(c, 'auto-nl'), kDefaultPoolBadge);
  });

  test('смена состава подписок инвалидирует кэш', () {
    final c = controllerWith([auto('auto-de', '🇩🇪')]);
    expect(poolBadgeOf(c, 'auto-de'), '🇩🇪');

    // Другой набор подписок: новый список узлов, новый значок у того же тега.
    c.debugSetEntries([
      SubscriptionEntry(list: listWith([auto('auto-de', '🇳🇱')])),
    ]);
    expect(poolBadgeOf(c, 'auto-de'), '🇳🇱');
  });

  test('пустые подписки — дефолт, кэш не залипает на прошлом составе', () {
    final c = controllerWith([auto('auto-de', '🇩🇪')]);
    expect(poolBadgeOf(c, 'auto-de'), '🇩🇪');

    c.debugSetEntries([]);
    expect(poolBadgeOf(c, 'auto-de'), kDefaultPoolBadge);
  });

  group('кэш regexp значков', () {
    test('повторный вызов с тем же паттерном даёт тот же результат', () {
      const labels = ['🇩🇪 Berlin', '🇳🇱 Amsterdam', '🇩🇪 Munich'];
      final first = poolBadges(labels, kDefaultPoolBadge);
      final second = poolBadges(labels, kDefaultPoolBadge);
      expect(first, '🇩🇪[2], 🇳🇱');
      expect(second, first);
    });

    test('битый паттерн кэшируется как «без значков», а не роняет UI', () {
      const labels = ['🇩🇪 Berlin'];
      expect(poolBadges(labels, '[unclosed'), '');
      expect(poolBadges(labels, '[unclosed'), '');
    });
  });
}
