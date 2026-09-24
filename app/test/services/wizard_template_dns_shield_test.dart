import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §517 часть G — страж состава группы `dns_shield` в боевом шаблоне.
///
/// Было: в группе с `mode: "fastest"` рядом с DoH/DoT лежали четыре открытых
/// udp-сервера (`google_udp`, `cloudflare_udp`, `opendns_udp`, `yandex_udp`).
/// `fastest` шлёт запрос ВСЕМ членам сразу и берёт первый ответ — открытый
/// UDP без TLS-рукопожатия почти всегда выигрывает гонку, то есть пресет с
/// именем «shield» регулярно резолвил открытым текстом. Хуже: даже когда
/// побеждал шифрованный член, запрос по UDP всё равно уже был отправлен и
/// виден наблюдателю.
///
/// Стало: в группе только шифрованные транспорты (`https`/`tls`/`quic`).
/// Сами записи `*_udp` в `dns_options.servers` остались — на них ссылаются
/// другие места шаблона (`default_value` резолверов, подсказки), их удаление
/// не входит в задачу.
void main() {
  Map<String, dynamic> template() => jsonDecode(
        File('assets/wizard_template.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  /// Записи `dns_options.servers[].server` — база, всегда в сборке.
  Map<String, Map<String, dynamic>> baseServersByTag(Map<String, dynamic> tpl) {
    final out = <String, Map<String, dynamic>>{};
    for (final e in (tpl['dns_options'] as Map)['servers'] as List) {
      final s = (e as Map)['server'];
      if (s is Map && s['tag'] is String) {
        out[s['tag'] as String] = s.cast<String, dynamic>();
      }
    }
    return out;
  }

  /// База + серверы пресетов (`selectable_rules[].dns_servers[]`).
  ///
  /// Группа `dns_shield` из базы ссылается на `yandex_udp`/`yandex_dot`,
  /// которые объявлены в пресете `ru-direct` — это существовало до §517.
  /// При выключенном пресете §121 уносит его серверы, а битых членов группы
  /// подчищает сборка (см. `test/builder/dns_detour_fail_closed_test.dart`,
  /// «dns_shield без выпавшего члена»). Поэтому проверять тип транспорта надо
  /// по объединению двух областей, иначе член группы выглядит «необъявленным».
  Map<String, Map<String, dynamic>> allServersByTag(Map<String, dynamic> tpl) {
    final out = baseServersByTag(tpl);
    for (final r in (tpl['selectable_rules'] as List? ?? const [])) {
      for (final s in ((r as Map)['dns_servers'] as List? ?? const [])) {
        if (s is Map && s['tag'] is String) {
          out.putIfAbsent(s['tag'] as String, () => s.cast<String, dynamic>());
        }
      }
    }
    return out;
  }

  /// Шифрованные типы DNS-серверов sing-box: DoH / DoT / DoQ.
  const encrypted = {'https', 'tls', 'quic', 'h3'};

  test('в группе fastest пресета dns_shield нет открытых udp-серверов', () {
    final tpl = template();
    final byTag = allServersByTag(tpl);
    final shield = baseServersByTag(tpl)['dns_shield'];
    expect(shield, isNotNull, reason: 'группа dns_shield исчезла из шаблона');
    expect(shield!['mode'], 'fastest',
        reason: 'тест написан под гонку fastest; смена режима — пересмотреть');

    final members = (shield['servers'] as List).cast<String>();
    expect(members, isNotEmpty);

    final plain = <String>[];
    for (final tag in members) {
      final s = byTag[tag];
      expect(s, isNotNull, reason: 'член группы $tag не объявлен в шаблоне');
      if (!encrypted.contains(s!['type'])) plain.add('$tag (${s['type']})');
    }
    expect(plain, isEmpty,
        reason: 'открытый резолв в «щите»: при mode=fastest эти члены '
            'выигрывают гонку у DoH/DoT — $plain');
  });

  test('dns_shield покрывает четыре провайдера шифрованно', () {
    final members = ((baseServersByTag(template())['dns_shield']!)['servers']
            as List)
        .cast<String>()
        .toSet();
    // Замена четырём снятым udp-членам: у Google/Cloudflare/Yandex двойник
    // уже был в группе, для OpenDNS добавлен DoH (DoT они не предоставляют).
    for (final tag in [
      'google_doh',
      'google_dot',
      'cloudflare_dot',
      'opendns_doh',
      'quad9_doh',
      'yandex_dot',
    ]) {
      expect(members, contains(tag));
    }
  });

  test('opendns_doh — корректная запись DoH по образцу соседей', () {
    final s = baseServersByTag(template())['opendns_doh'];
    expect(s, isNotNull, reason: 'замена opendns_udp в группе не объявлена');
    expect(s!['type'], 'https');
    expect(s['server_port'], 443);
    expect(s['server'], '208.67.222.222');
    expect(s['path'], '/dns-query');
    expect((s['tls'] as Map)['enabled'], true);
    expect((s['tls'] as Map)['server_name'], 'dns.opendns.com');
  });

  test('записи *_udp остались объявлены (на них ссылаются другие места)', () {
    final byTag = allServersByTag(template());
    for (final tag in [
      'google_udp',
      'cloudflare_udp',
      'opendns_udp',
      'yandex_udp',
    ]) {
      expect(byTag[tag], isNotNull, reason: '$tag удалён — сломает ссылки');
      expect(byTag[tag]!['type'], 'udp');
    }
  });

  test('§527 каждый член dns_shield объявлен в БАЗОВЫХ dns_options.servers',
      () {
    // Страж от повторения дефекта §527. Теги, объявленные пресетом
    // (`selectable_rules[].dns_servers[]`), при сборке получают неймспейс
    // `<preset_id>:<tag>` (§103 C7, `namespacePresetTags`) — база на них
    // сослаться НЕ может: bare-тег не резолвится ни при включённом пресете,
    // ни при выключенном. Именно так `yandex_dot` молча выпадал из группы в
    // ОБОИХ состояниях (golden'ы rich_v0/avd_v0 несли предупреждение
    // `member 'yandex_dot' dropped (unknown)` и группу из 5 членов).
    // Поэтому проверять надо по базе, а НЕ по объединению с пресетами.
    final base = baseServersByTag(template());
    final members = (base['dns_shield']!['servers'] as List).cast<String>();
    final undeclared = members.where((t) => !base.containsKey(t)).toList();
    expect(undeclared, isEmpty,
        reason: 'член группы объявлен только в пресете — при сборке его тег '
            'получит префикс preset_id и bare-ссылка выпадет (unknown): '
            '$undeclared');
  });

  test('§527 yandex_dot — прямой DoT без detour', () {
    final s = baseServersByTag(template())['yandex_dot'];
    expect(s, isNotNull, reason: 'базовая запись yandex_dot исчезла');
    expect(s!['type'], 'tls');
    expect(s['server'], '77.88.8.8');
    expect(s['server_port'], 853);
    expect((s['tls'] as Map)['enabled'], true);
    // Нефильтрующий профиль Яндекса: 77.88.8.8 ↔ common.dot.dns.yandex.net
    // (safe.dot.dns.yandex.net — это 77.88.8.88, фильтрующий).
    expect((s['tls'] as Map)['server_name'], 'common.dot.dns.yandex.net');
    // Главное: под белыми списками туннель может не подняться, а резолв
    // обязан работать — поэтому прямой, без detour.
    expect(s.containsKey('detour'), isFalse,
        reason: 'detour у члена «щита» вернёт зависимость от туннеля');
  });

  test('quad9_doh сохраняет detour vpn-1 (§517: намеренно не трогаем)', () {
    // Единственный член группы с детуром. При mode=fastest это значит, что
    // члены идут разными путями и состав победителей зависит от того, поднят
    // ли vpn-1. Решение «ставить детур всем или никому» — за владельцем,
    // в §517 сознательно вне объёма; страж фиксирует текущее состояние.
    expect(baseServersByTag(template())['quad9_doh']!['detour'], 'vpn-1');
  });
}
