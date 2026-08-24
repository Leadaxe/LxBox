import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// §248 — фильтрация Направления секции пикера цели detour
/// (pure-хелпер [visibleDetourDirections]): только enabled detour-Направления,
/// минус омонимы с bare-тегами распарсенных членов текущей папки
/// (включая выключенных членов — toggle не должен молча менять смысл ссылки).
void main() {
  const directions = [
    Direction(tag: 'vpn-1', label: 'Main'),
    Direction(tag: 'vpn-2', label: 'Relay', isDetour: true),
    Direction(tag: 'vpn-3', label: 'Off relay', isDetour: true, enabled: false),
  ];

  test('обычное Направление скрыто, detour виден, disabled detour скрыт', () {
    final visible = visibleDetourDirections(directions, null);
    expect(visible.map((c) => c.tag), ['vpn-2']);
  });

  test('омоним скрыт в контексте папки, виден без неё', () {
    // Член-тёзка Направления выключен — коллизия всё равно не создаётся:
    // достаточно включиться, чтобы ссылка молча сменила смысл.
    final folder = FolderServers(
      id: 'f1',
      name: 'Homonym',
      enabled: true,
      tagPrefix: 'hm-',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(
            raw: 'vless://u@h.com:443?type=ws&security=tls#vpn-2',
            enabled: false),
        FolderMember(raw: 'vless://u2@h2.com:443?type=ws&security=tls#node-b'),
      ],
    );
    expect(visibleDetourDirections(directions, folder), isEmpty);
    // Без контекста папки тот же Направление доступен.
    expect(visibleDetourDirections(directions, null).map((c) => c.tag), ['vpn-2']);
  });

  test('папка без тёзок Направления не прячет; битый член омонимом не считается',
      () {
    final folder = FolderServers(
      id: 'f1',
      name: 'F',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(raw: 'vless://u@h.com:443?type=ws&security=tls#Alpha'),
        // Битый raw → node null → bare-тега нет → не омоним.
        FolderMember(raw: 'garbage-not-a-config'),
      ],
    );
    expect(visibleDetourDirections(directions, folder).map((c) => c.tag),
        ['vpn-2']);
  });
}
