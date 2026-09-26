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

  // §562 — ДИСПЕТЧЕР СХЕМ ССЫЛКИ: написание схемы → тип тела читается из
  // реестра (`scheme_in` секций и `aliases` протоколов). Литерал схемы в
  // диспетчере — это возврат локальной копии правила реестра, которую §562
  // снял (таблица схем, набор схем, `switch` по написаниям).
  //
  // Проверяются СТРОКОВЫЕ ЛИТЕРАЛЫ, а не весь текст: у диспетчера законные
  // идентификаторы с именем схемы (`parseWireguardUri`, экспорты
  // `uri_parsers/<схема>_parser.dart`) — это парсеры, а не правило выбора.
  //
  // §566 — покрытие расширено на загрузку реестра (`registry.dart`: состав
  // `registry/protocols/` из каталога), распознавание ввода
  // (`input_helpers.dart`) и весь каталог `uri_parsers/` (обёрток по схеме
  // там больше нет). Разрешённые исключения — [allowed], каждое с причиной.
  test('в диспетчере схем ссылки нет литералов схем (§562, §566)', () {
    final files = [
      'lib/services/parser/uri_parsers.dart',
      'lib/services/parser/mappers/uri_pipeline.dart',
      'lib/services/contract/registry.dart',
      'lib/services/subscription/input_helpers.dart',
      for (final f in Directory('lib/services/parser/uri_parsers')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        f.path,
    ];
    // Файл → литералы, которые в нём законны, с причиной.
    const allowed = <String, Map<String, String>>{
      'lib/services/subscription/input_helpers.dart': {
        // Транспорт СКАЧИВАНИЯ подписки, а не схема узла: реестр такого
        // набора не объявляет (source_kinds.json опознаёт уже скачанное
        // тело). Запрос лаунчеру — «Нерешённое» задачи 566.
        'http://': 'isSubscriptionUrl',
        'https://': 'isSubscriptionUrl',
      },
    };
    const spellings = [
      ...forbidden,
      'ss', 'hy', 'hy2', 'wg', 'awg', 'amneziawg',
      'socks4', 'socks4a', 'socks5',
      'naive+https', 'naive+quic',
      'proxy-http', 'proxy-https', 'proxy+http', 'proxy+https',
      'vpn', 'incy', 'happ',
      'http', 'https', 'chain', 'group', 'tailscale',
    ];
    final literal = RegExp(r"'([^'\\]*)'" '|' r'"([^"\\]*)"');
    final hits = <String>[];
    for (final path in files) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: 'нет файла $path');
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        if (code.startsWith('//')) continue;
        // Род узла (`kind_when` секции), а не написание схемы: запасной
        // потолок mtu без реестра читает его из карты маппера.
        if (line.contains('mapping.kinds.contains(')) continue;
        for (final m in literal.allMatches(line)) {
          final v = (m.group(1) ?? m.group(2) ?? '').toLowerCase();
          final bare =
              v.endsWith('://') ? v.substring(0, v.length - 3) : v;
          if (allowed[path]?.containsKey(v) ?? false) continue;
          if (spellings.contains(bare)) {
            hits.add('$path:${i + 1}: «$v» — ${line.trim()}');
          }
        }
      }
    }
    expect(hits, isEmpty,
        reason: 'написание схемы ведёт реестр (`scheme_in`, `aliases`, '
            '`scheme_sets`, `emit.form_from`), а не диспетчер.\n'
            '${hits.join('\n')}');
  });
}
