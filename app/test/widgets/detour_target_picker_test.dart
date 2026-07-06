import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/widgets/detour_target_picker.dart';

/// §248 — фильтрация канальной секции пикера цели detour
/// (pure-хелпер [visibleDetourChannels]): только enabled detour-каналы,
/// минус омонимы с bare-тегами распарсенных членов текущей папки
/// (включая выключенных членов — toggle не должен молча менять смысл ссылки).
void main() {
  const channels = [
    Channel(tag: 'vpn-1', label: 'Main'),
    Channel(tag: 'vpn-2', label: 'Relay', isDetour: true),
    Channel(tag: 'vpn-3', label: 'Off relay', isDetour: true, enabled: false),
  ];

  test('обычный канал скрыт, detour виден, disabled detour скрыт', () {
    final visible = visibleDetourChannels(channels, null);
    expect(visible.map((c) => c.tag), ['vpn-2']);
  });

  test('омоним скрыт в контексте папки, виден без неё', () {
    // Член-тёзка канала выключен — коллизия всё равно не создаётся:
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
    expect(visibleDetourChannels(channels, folder), isEmpty);
    // Без контекста папки тот же канал доступен.
    expect(visibleDetourChannels(channels, null).map((c) => c.tag), ['vpn-2']);
  });

  test('папка без тёзок каналы не прячет; битый член омонимом не считается',
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
    expect(visibleDetourChannels(channels, folder).map((c) => c.tag),
        ['vpn-2']);
  });
}
