import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §480 волна W4 — секции-мапперы hysteria2 / tuic / masque / wireguard и
/// INI, пока движок их ещё не исполняет.
///
/// Тест держит ФОРМУ секций: пока таблицы лежат данными, единственное, что
/// отличает «написано по замороженной грамматике» от «написано как
/// придумалось», — набор атрибутов и их значения. Когда движок придёт,
/// расхождение формы всплыло бы отказом загрузчика на старте разбора, то есть
/// у пользователя, а не здесь.
///
/// Эталон формы — исполняемые секции лаунчера (контракт 1.1.13, `trojan.json`
/// на `8cc6ac69`) и `PRIMITIVES.md` §0 (FROZEN-имена). Сверки по
/// `registry_mapper.schema.json` тут НЕТ намеренно: схема 1.1.13 отстаёт от
/// собственных данных — `trojan.json` лаунчера не проходит её на трёх местах
/// (`userinfo.impl`, `emit.param_order` строкой, `unknown_key.impl`).
/// Нормативны данные, и проверять секции схемой значило бы держать их в форме,
/// которой у эталона нет.
void main() {
  Map<String, dynamic> load(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

  Map<String, dynamic> section(String path, String kind) {
    final mappers = (load(path)['mappers'] as Map).cast<String, dynamic>();
    return (mappers[kind] as Map).cast<String, dynamic>();
  }

  /// Секции волны: путь файла → вид источника.
  const uriSections = <String, String>{
    'hysteria2': 'assets/contract_draft/uri/hysteria2.json',
    'tuic': 'assets/contract_draft/uri/tuic.json',
    'masque': 'assets/contract_draft/uri/masque.json',
    'wireguard': 'assets/contract_draft/uri/wireguard.json',
  };

  group('§480 W4 — форма секций uri', () {
    test('файлы читаются и несут ровно одну секцию mappers.uri', () {
      for (final e in uriSections.entries) {
        final mappers = (load(e.value)['mappers'] as Map).cast<String, dynamic>();
        expect(mappers.keys, ['uri'], reason: e.key);
      }
    });

    test('обязательные атрибуты секции на месте', () {
      for (final e in uriSections.entries) {
        final s = section(e.value, 'uri');
        expect(s['body_source'], 'uri', reason: e.key);
        expect(s['detect'], isA<Map>(), reason: e.key);
        expect(s['forms'], isA<List>(), reason: e.key);
        expect(s['params'], isA<Map>(), reason: e.key);
        expect(s['unknown_key'], isA<Map>(), reason: e.key);
        expect(s['label'], isA<Map>(), reason: e.key);
      }
    });

    test('ровно одна форма по умолчанию на секцию', () {
      for (final e in uriSections.entries) {
        final forms = (section(e.value, 'uri')['forms'] as List).cast<Map>();
        final defaults = forms.where(
          (f) => ((f['detect'] as Map?)?['default'] as bool?) ?? false,
        );
        expect(defaults.length, 1, reason: e.key);
      }
    });

    test('у каждой записи таблицы есть source — единственный способ получить '
        'значение (PRIMITIVES §1.1)', () {
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        for (final p in params.entries) {
          expect((p.value as Map)['source'], isNotNull,
              reason: '${e.key}.${p.key}');
        }
      }
    });

    test(r'служебная запись ($-префикс) не имеет maps_to (PRIMITIVES §0.7)',
        () {
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        for (final p in params.entries) {
          if (!p.key.startsWith(r'$')) continue;
          expect((p.value as Map)['maps_to'], isNull, reason: '${e.key}.${p.key}');
        }
      }
    });

    test('фолбэк тега — по ТИПУ ТЕЛА (DELTAS D133-6), и это уже наше '
        'поведение: awg:// даёт wireguard-…', () {
      for (final e in uriSections.entries) {
        final fb = ((section(e.value, 'uri')['label'] as Map)['fallback'] as Map);
        expect(fb['scheme_source'], 'singbox_type', reason: e.key);
        expect(fb['template'], '{scheme}-{server}-{server_port}', reason: e.key);
      }
    });

    test('эмит: param_order — ПРАВИЛО (алфавит), а не перечень', () {
      for (final e in uriSections.entries) {
        final emit = (section(e.value, 'uri')['emit'] as Map);
        expect(emit['param_order'], 'alphabetical', reason: e.key);
      }
    });

    test('общие блоки берутся у лаунчера через include, своих копий нет', () {
      // wireguard — единственная схема волны без TLS вовсе (endpoint).
      for (final k in const ['hysteria2', 'tuic', 'masque']) {
        final s = section(uriSections[k]!, 'uri');
        expect((s['include'] as List), contains('tls#uri'), reason: k);
      }
      for (final e in uriSections.entries) {
        final params = (section(e.value, 'uri')['params'] as Map).cast<String, dynamic>();
        // Записи общего блока (security/alpn/pbk/sid/fp) в секции схемы
        // дублироваться не должны — они приходят include'ом.
        for (final dup in const ['security', 'alpn', 'pbk', 'sid', 'fp']) {
          expect(params.containsKey(dup), isFalse, reason: '${e.key}.$dup');
        }
      }
    });

    test('base64-поля читают «+» буквально (DELTAS D133-7)', () {
      const base64Fields = <String, List<String>>{
        'masque': ['private_key', 'publickey'],
        'wireguard': [
          'privatekey',
          'publickey',
          'presharedkey',
          'headerprotectionkey',
        ],
      };
      for (final e in base64Fields.entries) {
        final params = (section(uriSections[e.key]!, 'uri')['params'] as Map)
            .cast<String, dynamic>();
        for (final f in e.value) {
          final de = (params[f] as Map)['decode_extra'] as Map?;
          expect(de?['plus_literal'], isTrue, reason: '${e.key}.$f');
        }
      }
    });

    test('tuic disable_sni СНИМАЕТ tls.server_name (G2: null в sets)', () {
      final p = (section(uriSections['tuic']!, 'uri')['params'] as Map)
          .cast<String, dynamic>();
      final sets = ((p['disable_sni'] as Map)['sets'] as Map)['true'] as Map;
      expect(sets.containsKey('tls.server_name'), isTrue);
      expect(sets['tls.server_name'], isNull);
    });

    test('masque материализует дефолты profile/vhttp/mtu: default реестра в '
        'тело не едет (CANON §2.4), а identity живых узлов на них стоит', () {
      final p = (section(uriSections['masque']!, 'uri')['params'] as Map)
          .cast<String, dynamic>();
      for (final f in const ['profile', 'vhttp', 'mtu']) {
        expect((p[f] as Map)['materialize_default'], isTrue, reason: f);
      }
      expect(((p['vhttp'] as Map)['default_when'] as Map)['value'], 'h3');
      expect(((p['mtu'] as Map)['default_when'] as Map)['value'], 1280);
      expect(((p['profile'] as Map)['default_when'] as Map)['value'], 'cloudflare');
    });

    test('hysteria2: multi-port читается из сырого порта, а не из port', () {
      final p = (section(uriSections['hysteria2']!, 'uri')['params'] as Map)
          .cast<String, dynamic>();
      final mp = p[r'$multiport'] as Map;
      expect(mp['source'], 'port_raw');
      expect(mp['selector'], isTrue);
      // Слияние authority + query: query дописывается следом.
      expect((p['mport'] as Map)['merge'], 'append');
      expect((p['mport'] as Map)['normalize'], 'port_range_spec');
    });

    test('wireguard: mtu переносится как есть — потолок и дефолт AWG судит '
        'реестр (§473)', () {
      final mtu = ((section(uriSections['wireguard']!, 'uri')['params'] as Map)
          .cast<String, dynamic>()['mtu'] as Map);
      expect(mtu['default_when'], isNull);
      expect(mtu.containsKey('materialize_default'), isFalse);
    });
  });

  group('§480 W4 — форма секции conf (INI)', () {
    const path = 'assets/contract_draft/conf/wireguard.json';

    test('секция объявляет источник тела wgconf и опознаётся по [Interface]', () {
      final s = section(path, 'conf');
      expect(s['body_source'], 'wgconf');
      expect(((s['detect'] as Map)['ini'] as Map)['sections'], ['Interface']);
      expect(s['emit'], isNull, reason: 'обратного хода у .conf нет');
    });

    test('все записи адресуют ini.<Section>.<Key> (одно пространство на '
        'awg://<base64 .conf> и на файл)', () {
      final params = (section(path, 'conf')['params'] as Map).cast<String, dynamic>();
      for (final p in params.entries) {
        final src = (p.value as Map)['source'];
        expect(src, isA<String>(), reason: p.key);
        expect((src as String).startsWith('ini.'), isTrue, reason: p.key);
      }
    });

    test('имя узла — из комментария под [Peer] (G7)', () {
      final label = section(path, 'conf')['label'] as Map;
      expect((label['source'] as List), contains(r'ini.$comment.Peer'));
    });

    test('Endpoint: голый IPv6 берётся адресом целиком, порт по умолчанию '
        '(§219 — отличить порт от адреса нечем)', () {
      final ep = ((section(path, 'conf')['params'] as Map)['endpoint'] as Map);
      final noMatch = ep['on_no_match'] as Map;
      expect(noMatch['action'], 'take_all');
      expect(noMatch['into'], 'peers[].address');
      expect((noMatch['defaults'] as Map)['peers[].port'], 51820);
    });

    test('читается только ПЕРВАЯ [Peer]; код повтора ждёт своего текста', () {
      final dialect = section(path, 'conf')['ini_dialect'] as Map;
      final peer = (dialect['sections'] as Map)['Peer'] as Map;
      expect(peer['repeat'], 'first_only');
      final onExtra = peer['on_extra'] as Map;
      expect(onExtra['code'], isNull, reason: 'текста у кода ещё нет');
      expect(onExtra[r'$code_pending'], 'wgconf_extra_peer_dropped');
      // Диалект записан дословно по сегодняшнему разбору; имя префиксов
      // комментария — по GRAMMAR_SYNC §0.11 (`line_comment_prefixes`).
      expect(dialect['key_case'], 'lower');
      expect(dialect['repeated_key'], 'last_wins');
      expect(dialect['inline_comments'], isFalse);
      expect(dialect['line_comment_prefixes'], ['#', ';']);
    });

    // §480 — код ОБЪЯВЛЕН, но не ставится: `wgconf_dns_ignored` приехал
    // секцией вперёд своего текста, а в `warnings.json` контракта его нет.
    // Имя лежит под `$code_pending` — вернуть его будет правкой одного ключа,
    // когда текст приедет синком. Запись обязана остаться в любом случае:
    // без неё `DNS` уехал бы в `uri_param_unknown`.
    test('Interface.DNS — лоссы by design; код ждёт своего текста', () {
      final dns = ((section(path, 'conf')['params'] as Map)['dns'] as Map);
      expect(dns['maps_to'], isNull);
      final onPresent = dns['on_present'] as Map;
      expect(onPresent['code'], isNull, reason: 'текста у кода ещё нет');
      expect(onPresent[r'$code_pending'], 'wgconf_dns_ignored');
    });

    test('delta480-4 — алиас preshared_key читается (сегодня теряется молча)',
        () {
      final psk =
          ((section(path, 'conf')['params'] as Map)['presharedkey'] as Map);
      expect((psk['aliases'] as List), contains('preshared_key'));
    });
  });

  group('§480 W4 — форма секции xray', () {
    const path = 'assets/contract_draft/xray/hysteria2.json';

    test('опознание по protocol: "hysteria"; версия выбирает тип тела', () {
      final s = section(path, 'xray');
      expect(((s['detect'] as Map)['json'] as Map)['value_of'],
          {'protocol': 'hysteria'});
      expect(s['body_source'], 'xray');
      expect(s['emit'], isNull);
      final version = (s['params'] as Map)['version'] as Map;
      expect(version['selector'], isTrue);
      expect((version['sets'] as Map)['2'], {'type': 'hysteria2'});
    });

    test(r'пути формы идут через якорь $base', () {
      final s = section(path, 'xray');
      expect((s['forms'] as List).first, containsPair('base', 'settings'));
      expect(((s['params'] as Map)['address'] as Map)['source'],
          r'json.$base.address');
    });
  });
}
