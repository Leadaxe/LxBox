import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/config_node.dart';
import 'package:lxbox/screens/home/widgets/node_list.dart';

/// §328 — предикат полноэкранного гайда «Add a server» на Home.
///
/// Корень бага: гайд гейтился по `configRaw.isEmpty` («нет файла»), а конфиг
/// становится непустым при нуле реальных серверов (bootstrap подписки с 0 нод,
/// Apply в настройках, удаление всех серверов) — после чего подсказка не
/// показывалась больше никогда.
void main() {
  group('§328 showAddServerGuide', () {
    test('свежая установка: нет конфига, нет entries → гайд', () {
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: true,
          configNodeCount: 0,
          anyServerNodes: false,
        ),
        isTrue,
      );
    });

    test('ГЛАВНЫЙ кейс: шаблонный конфиг без серверов → гайд', () {
      // Конфиг существует (direct/Направления/magic-ноды), payload-нод ноль —
      // старый предикат (`configRaw.isEmpty`) здесь молчал.
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: false,
          configNodeCount: 0,
          anyServerNodes: false,
        ),
        isTrue,
      );
    });

    test('конфиг с реальными нодами → без гайда', () {
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: false,
          configNodeCount: 3,
          anyServerNodes: true,
        ),
        isFalse,
      );
    });

    test('сырой импорт конфига без entries → без гайда', () {
      // Power-user: PUT /config либо clipboard-импорт — entries пустые,
      // но payload-ноды в конфиге есть. Гайд не должен спрятать Start.
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: false,
          configNodeCount: 2,
          anyServerNodes: false,
        ),
        isFalse,
      );
    });

    test('окно «сервер добавлен, конфиг ещё не пересобран» → без гайда', () {
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: false,
          configNodeCount: 0,
          anyServerNodes: true,
        ),
        isFalse,
      );
    });

    test('туннель up → никогда (у up-состояний свои плашки)', () {
      for (final configEmpty in [true, false]) {
        expect(
          showAddServerGuide(
            tunnelUp: true,
            configEmpty: configEmpty,
            configNodeCount: 0,
            anyServerNodes: false,
          ),
          isFalse,
          reason: 'configEmpty=$configEmpty',
        );
      }
    });

    test('preview-empty parity: configRaw подменён на пустой → гайд', () {
      // Debug API preview-empty-state подменяет только configRaw/nodes;
      // entries остаются реальными — ветка configEmpty обязана перекрывать.
      expect(
        showAddServerGuide(
          tunnelUp: false,
          configEmpty: true,
          configNodeCount: 0,
          anyServerNodes: true,
        ),
        isTrue,
      );
    });
  });

  group('§328 ParsedConfig.nodeCount — точка опоры предиката', () {
    test('шаблонный конфиг без серверов: только control-типы → 0', () {
      const raw = '''
      {"outbounds": [
        {"tag": "direct", "type": "direct"},
        {"tag": "vpn-1", "type": "selector", "outbounds": ["vpn-1-auto"]},
        {"tag": "vpn-1-auto", "type": "urltest", "outbounds": []},
        {"tag": "block", "type": "block"}
      ]}
      ''';
      expect(ParsedConfig.parse(raw).nodeCount, 0);
    });

    test('payload-нода считается', () {
      const raw = '''
      {"outbounds": [
        {"tag": "direct", "type": "direct"},
        {"tag": "srv", "type": "vless", "server": "h", "server_port": 443}
      ]}
      ''';
      expect(ParsedConfig.parse(raw).nodeCount, 1);
    });
  });
}
