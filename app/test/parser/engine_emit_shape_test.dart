import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// Типы тела ссылочных схем. Здесь этот список законен: тест не входит в
/// пакет движка, и греп-страж имён схем его не судит.
const _types = <String>[
  'trojan', 'socks', 'tuic', 'hysteria2', 'masque', 'ssh', 'anytls',
  'shadowsocks', 'http', 'naive', 'vless', 'vmess', 'wireguard',
];

/// §480 W8 — СТРАЖ ВИДА ССЫЛКИ: `toUri()` совпадает со снимком
/// `emit_before480.json` БАЙТ В БАЙТ, кроме перечисленных ниже кейсов.
///
/// Зачем отдельно от круга. Круг (`engine_emit_roundtrip_test.dart`) судит
/// СМЫСЛ: тело, разобранное из нашей же ссылки, обязано совпасть с исходным.
/// Этого мало. `toUri()` у нас ОДНОВРЕМЕННО:
///
/// - форма хранения ручного узла (`rawSource` перезаписывается при
///   пересохранении), и смена написания молча переписывает то, что человек
///   когда-то вставил сам;
/// - то, что уезжает по кнопке **Copy link** в v2rayN, v2rayNG, NekoBox,
///   Hiddify и Shadowrocket. Круг у чужого клиента свой, и написание, которое
///   разбираем мы, он может не прочитать вовсе — либо прочитать ИНАЧЕ.
///   Опущенный `security=tls` у vless круг проходит (наш разбор поднимет TLS
///   умолчанием), а у Xray-клиента умолчание `none`: тот же узел встаёт БЕЗ
///   шифрования.
///
/// Отсюда правило владельца: **сегодняшние ссылки не меняются без строки в
/// `DELTAS.md`**. Страж его и держит: любое новое отличие от снимка валит
/// тест, пока его не назвали здесь причиной.
///
/// Эталон — снимок РУКОПИСНОГО эмита, снятый до его удаления
/// (`emit_before480.json`, ключ `uri_before`). Вход — та же старая ссылка:
/// разбираем её и собираем заново. Так сравниваются ДВА НАПИСАНИЯ ОДНОГО
/// тела, а не два разных тела.
void main() {
  setUpAll(loadEngineSections);

  /// Разрешённые отличия: схема → кейс → причина.
  ///
  /// Список ЗАКРЫТЫЙ и поимённый: класс отличия («у vless теперь иначе»)
  /// здесь не объявляется, потому что классом прикрывается и то, чего не
  /// заметили. Каждая строка — либо ПОЧИНКА ПОТЕРИ (поле, которое тело несёт,
  /// а рукописный эмит не писал), либо кодирование, названное нормой волны.
  const allowed = <String, Map<String, String>>{
    'tuic': {
      'b480:disable_sni_with_sni': 'ПОЧИНКА ПОТЕРИ: рукописный эмит не писал '
          'disable_sni и вместе с ним ронял sni. Кейс заведён волной '
          '(префикс b480:), снимок «до» показывает ссылку БЕЗ обоих полей.',
      'b480:disable_sni_without_sni': 'то же, что выше: sni приезжает из '
          'адреса узла, и без него ссылка теряла имя сервера.',
    },
    'vless': {
      'b480:pbk_encoded_plus': 'Д-6, НАПИСАНИЕ КЛЮЧА: pbk приводится к форме '
          'ядра (RawURL, url-safe без паддинга). std-алфавит («+», «/», «=») '
          'ядро не декодирует — «decode public_key: illegal base64 data» '
          'роняет ВЕСЬ конфиг, а не одну ноду. Ключ тот же побайтно, сменилось '
          'только написание, и уезжает по Copy link теперь то, что читают и '
          'ядро, и чужие клиенты (RawURL — канон x25519-ключа REALITY).',
      'raw_headertype_http': 'ПОЧИНКА ПОТЕРИ: transport.path тела («/») '
          'рукописный эмит у http-транспорта не писал.',
      'userinfo_raw_space': 'то же: transport.path («/») не писался.',
      'xhttp_uplink_header_placement_adds_packet_up': 'ПОЧИНКА ПОТЕРИ: '
          'transport.mode тела (packet-up) не писался.',
      'xhttp_uplink_header_placement_reset': 'ПОЧИНКА ПОТЕРИ наоборот: '
          'uplinkDataPlacement при mode=stream-up в тело НЕ читается (запись '
          'блока стоит под when), и рукописный эмит писал в ссылку поле, '
          'которого в теле нет. Новый эмит пишет только то, что несёт тело.',
    },
    'vmess': {
      'legacy_cleartext_userinfo': 'headers.Host тела (ws) равен адресу узла, '
          'и рукописный эмит писал ключ `host` пустым — поле тела терялось.',
    },
    // §514 / контракт 1.1.50 (D133-54, Q133-74) — `keep_empty_tail`, решение
    // владельца 24.09.2026: обе стороны исполняют флаг. У socks4 пароля нет ПО
    // ПРОТОКОЛУ, но разделитель клиенты пишут ВСЕГДА, и его отсутствие часть из
    // них читает как «имени нет» — то есть уводит userid в другой слот. Флаг
    // реестр объявлял и прежде (`protocols/socks.json`, `emit.userinfo
    // .keep_empty_tail`), исполнял его только лаунчер (снимок
    // `socks/socks4_userid` = `socks4://useridonly:@example-1.com:1080`), и
    // расхождение держалось ровно этим стражем. Меняется ТОЛЬКО написание
    // хвоста: тело, identity и набор полей те же — что и подтверждают соседние
    // кейсы схемы, оставшиеся зелёными.
    'socks': {
      'b480:socks4_no_fragment': 'KEEP_EMPTY_TAIL: `userid1@` → `userid1:@`.',
      'b480:socks4_userid': 'то же, с меткой.',
      'b480:socks4a_no_fragment': 'то же у socks4a — версия та же, 4.',
      'b480:socks4a_userid': 'то же, с меткой.',
    },
  };

  Map<String, Map<String, dynamic>> cases(String scheme) {
    final f = File('test/fixtures/$scheme/emit_before480.json');
    if (!f.existsSync()) return const {};
    final raw = (jsonDecode(f.readAsStringSync()) as Map)['cases'] as Map?;
    if (raw == null) return const {};
    return raw.cast<String, dynamic>().map(
          (k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()),
        );
  }

  final schemes = Directory('test/fixtures')
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .where((s) => File('test/fixtures/$s/emit_before480.json').existsSync())
      .toList()
    ..sort();

  test('§480 W8 · линтер: каждое emit.names — написание, которое запись ЧИТАЕТ',
      () {
    // Норма грамматики: выходное написание выбирается ИЗ написаний записи
    // (имя, алиасы, query-источники). Имя вне набора — ссылка, которую мы
    // сами не разберём, и эмит откатится к канону МОЛЧА: линтер говорит об
    // этом вслух.
    final bad = <String>[];
    for (final type in _types) {
      final section = MapperSections.I.sectionFor('uri', type);
      final names = section?.emit?[EmitNames.names];
      if (names is! Map) continue;
      for (final e in names.entries) {
        final record = '${e.key}';
        // Запись адресуется своим ИМЕНЕМ, а не ключом словаря: записи общих
        // блоков лежат под составным ключом (`tls.insecure`), а `emit.names`
        // и `_nameOf` знают запись по `name`.
        final p = section!.params.values
            .where((v) => v.name == record)
            .firstOrNull;
        if (p == null) {
          bad.add('$type: emit.names адресует запись «$record», которой в '
              'секции нет');
          continue;
        }
        final want = '${e.value}';
        if (!readableNames(p).contains(want)) {
          bad.add('$type.$record: написание «$want» запись не читает — '
              'её написания ${readableNames(p).toList()}');
        }
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  group('§480 W8 · вид ссылки = снимок рукописного эмита', () {
    for (final scheme in schemes) {
      test('$scheme: Copy link не сменил написание', () {
        final ok = allowed[scheme] ?? const <String, String>{};
        final all = ok.containsKey('*');
        final unexpected = <String>[];
        final stale = {...ok.keys}..remove('*');
        var checked = 0;

        for (final c in cases(scheme).entries) {
          final was = c.value['uri_before'] as String?;
          if (was == null) continue;
          checked++;
          final spec = parseUri(was);
          expect(spec, isNotNull,
              reason: '${c.key}: старая ссылка перестала разбираться\n  $was');
          final now = spec!.toUri();
          if (now == was) continue;
          stale.remove(c.key);
          if (all || ok.containsKey(c.key)) continue;
          unexpected.add('${c.key}\n'
              '  было:  $was\n'
              '  стало: $now');
        }

        expect(checked, greaterThan(0),
            reason: 'снимок пуст — страж ничего не сторожит');
        expect(unexpected, isEmpty,
            reason: 'вид ссылки сменился у кейсов, которых нет в списке '
                'разрешённых отличий. Так меняются сохранённые rawSource '
                'ручных узлов и то, что уезжает по Copy link в чужие '
                'клиенты. Либо почините написание, либо назовите отличие в '
                '`allowed` с причиной — и строкой в DELTAS.md:\n'
                '${unexpected.join('\n')}');
        expect(stale, isEmpty,
            reason: 'эти кейсы разрешены, но отличия у них больше нет — '
                'строку пора снять, иначе список прикрывает будущую поломку: '
                '${stale.join(", ")}');
      });
    }
  });
}
