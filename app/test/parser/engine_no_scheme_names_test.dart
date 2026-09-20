import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §480 — ГРЕП-СТРАЖ: в пакете движка нет ни одного имени схемы.
///
/// Критерий 3 спеки и смысл всей кампании: движок общий для всех схем, и
/// правило схемы живёт в данных. Имя протокола, просочившееся в `engine/`, —
/// это ветка «если trojan, то…», то есть возврат к рукописному мапперу, но
/// спрятанный внутрь общего кода, где его труднее заметить.
///
/// Страж грубый нарочно: он ловит слово в ЛЮБОМ месте файла, включая
/// комментарий. Объяснять устройство движка на примере конкретной схемы
/// незачем — пример протухнет вместе с её секцией.
void main() {
  const forbidden = [
    'trojan',
    'vless',
    'vmess',
    'shadowsocks',
    'hysteria',
    'tuic',
    'socks',
    'naive',
    'anytls',
    'wireguard',
    'masque',
    'ssh',
  ];

  test('в lib/services/parser/engine/ нет имён схем', () {
    final dir = Directory('lib/services/parser/engine');
    expect(dir.existsSync(), isTrue, reason: 'пакет движка не найден');

    final hits = <String>[];
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final lower = lines[i].toLowerCase();
        for (final name in forbidden) {
          if (lower.contains(name)) {
            hits.add('${f.path}:${i + 1}: «$name» — ${lines[i].trim()}');
          }
        }
      }
    }

    expect(hits, isEmpty,
        reason: 'движок обязан быть общим: правило схемы живёт в секции '
            'реестра, а не в коде.\n${hits.join('\n')}');
  });
}
