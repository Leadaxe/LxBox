import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';

import '../parser/engine_test_setup.dart';

/// §439 §2.3 п. 8 — ссылки на узлы формы 2.23.2 (финальные теги строкой) →
/// NodeLink. Цель ссылки может быть выключена: сам одиночный сервер, папка
/// целиком, член папки. Такая ссылка не висячая — предупреждение только для
/// строки, которой нет ни в одном источнике (стенд волны E: из четырёх
/// «matches no node» три указывали на выключенные серверы).

String _uri(int n, String tag) =>
    'vless://11111111-1111-1111-1111-${n.toString().padLeft(12, '0')}'
    '@198.51.100.$n:443?type=ws&security=tls#$tag';

Map<String, dynamic> _server(
  String id,
  int n,
  String tag, {
  bool enabled = true,
  String? detour,
}) =>
    {
      'type': 'user',
      'id': id,
      'name': '',
      'enabled': enabled,
      'tag_prefix': '',
      'origin': 'paste',
      'created_at': '2026-01-01T00:00:00.000',
      'raw_body': _uri(n, tag),
      if (detour != null) 'detour_policy': {'override_detour': detour},
    };

Map<String, dynamic> _doc() => {
      'server_lists': [
        _server('srv-osaka', 1, 'Osaka'),
        _server('srv-home', 2, 'home-awg', enabled: false),
        _server('srv-warp', 3, 'warp-h2', enabled: false),
        _server('srv-a', 4, 'Alpha', detour: 'home-awg'),
        _server('srv-ghost', 5, 'Beta', detour: 'ghost'),
        {
          'type': 'folder',
          'id': 'fold-off',
          'name': 'Off',
          'enabled': false,
          'tag_prefix': '',
          'created_at': '2026-02-02T00:00:00.000',
          'detour_policy': {'override_detour': 'warp-h2'},
          'members': [
            // Тёзка включённого сервера: при включении папки сборка назвала
            // бы его `Osaka-1`.
            {'raw': _uri(6, 'Osaka'), 'enabled': true},
          ],
        },
        {
          'type': 'folder',
          'id': 'fold-on',
          'name': 'On',
          'enabled': true,
          'tag_prefix': '',
          'created_at': '2026-02-02T00:00:00.000',
          'members': [
            {'raw': _uri(7, 'Nagoya'), 'enabled': true},
            {'raw': _uri(8, 'Sapporo'), 'enabled': false},
          ],
        },
      ],
      'chains': [
        {
          'tag': 'chain-1',
          'hops': ['Osaka', 'home-awg', 'Osaka-1', 'Sapporo', 'ghost-2'],
        },
      ],
    };

List<Map<String, dynamic>> _sources(StorageMigrationResult r) =>
    (r.doc['sources'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _byId(StorageMigrationResult r, String id) =>
    _sources(r).firstWhere((s) => s['id'] == id);

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  test('detour на выключенный одиночный сервер — корневая ссылка без '
      'предупреждения', () {
    final r = migrateStorageDoc(_doc());
    expect(_byId(r, 'srv-a')['detour'], {'tag': 'home-awg'});
    expect(_byId(r, 'fold-off')['detour'], {'tag': 'warp-h2'});
    expect(r.warnings.where((w) => w.contains('home-awg')), isEmpty);
    expect(r.warnings.where((w) => w.contains('warp-h2')), isEmpty);
  });

  test('позиции цепочки: выключенный сервер — корень, узел выключенной папки '
      'и выключенный член папки — пара; тег при включении уникализирован '
      'той же сборкой', () {
    final r = migrateStorageDoc(_doc());
    final chain = _sources(r).firstWhere((s) => s['kind'] == 'chain');
    expect(chain['hops'], [
      {'tag': 'Osaka'},
      {'tag': 'home-awg'},
      {'folder_id': 'fold-off', 'tag': 'Osaka'},
      {'folder_id': 'fold-on', 'tag': 'Sapporo'},
      {'tag': 'ghost-2'},
    ]);
  });

  test('предупреждения — только висячие ссылки', () {
    final r = migrateStorageDoc(_doc());
    expect(r.warnings, hasLength(2), reason: r.warnings.join('\n'));
    expect(r.warnings[0], contains('detour "ghost" matches no node'));
    expect(r.warnings[1],
        contains('chain "chain-1": position 5 "ghost-2" matches no node'));
    expect(_byId(r, 'srv-ghost')['detour'], {'tag': 'ghost'});
    expect(r.info, contains('node links: 2 final tags → {folder_id, tag}'));
  });
}
