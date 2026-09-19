import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/ini_parser.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 волна W4 — hysteria2 / tuic / masque / wireguard и INI на движке
/// секций. Снимок «до переезда» обязан сойтись кейс в кейс.
///
/// Устроен так же, как пилот trojan (`engine_trojan_pilot_test.dart`), и по
/// той же причине отдельно от общего снимка: там кейсы проверяются вместе со
/// всеми схемами и молчат о том, ЧЕМ разобраны, а здесь гейт называет запись
/// секции.
///
/// Гейт — ЗЕРКАЛО `assets/contract`: каталога `app/contract` на CI нет вовсе.
const _registryRoot = 'assets/contract';
const _draftRoot = 'assets/contract_draft';

/// **Дельты 480 волны W4.** Каждая — «было → стало» по кейсу фикстуры;
/// остальное расхождение чинится в секции или в движке, а не здесь.
const Map<String, String> _delta480 = {
  // delta480-1 · D133-11 — список по запятой.
  'hysteria2/b480:pinsha256_pair':
      'delta480-1: было пусто (значение с запятой не читалось), '
          'стало ["a","b"] в certificate_public_key_sha256',
  // delta480-2 · D133-7 — «+» у base64-поля литерален.
  'masque/b480:publickey_raw_plus':
      'delta480-2: было "gBCQ…" (сырой «+» стал пробелом и ключ потерял '
          'первый символ), стало "+gBCQ…"',
  // delta480-3 · D133-7 — тот же корень, но узел РОНЯЛО целиком.
  'wireguard/b480:publickey_raw_plus':
      'delta480-3: было — узла нет вовсе (ключ «не base64»), стало — узел '
          'живёт с ключом "+gBCQ…"',
  'wireguard/b480:privatekey_raw_plus_query':
      'delta480-3: было — узла нет вовсе, стало — узел живёт с ключом "+wBB…"',
  'wireguard/b480:presharedkey_raw_plus':
      'delta480-3: было — узла нет вовсе, стало — узел живёт с psk "+QBF…"',
  // delta480-7 — алиас `preshared_key` у ССЫЛКИ (у INI это delta480-4).
  'wireguard/corpus:uri_psk_keepalive':
      'delta480-7: `preshared_key` в ссылке молча терялся (читалось только '
          '`presharedkey`), хотя реестр объявляет алиас; стало — читается',
};

Map<String, Map<String, dynamic>> _cases(String scheme) {
  final f = File('test/fixtures/$scheme/pipeline_identity_before.json');
  final raw = jsonDecode(f.readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
    await MapperSections.I.loadDrafts(dir: _draftRoot, files: kDraftFiles);
  });

  /// Один протокол: все кейсы его фикстуры через `parseUri`.
  void checkScheme(String scheme, String singboxType) {
    test('$scheme: секция исполняема и загружена', () {
      expect(MapperSections.I.has('uri', singboxType), isTrue,
          reason: 'без секции движок не работает вовсе — рукописного '
              'запасного пути у переехавшей схемы не осталось');
    }, skip: skip);

    test('$scheme: снимок «до переезда» — identity, тег и тело байт в байт',
        () {
      final diffs = <String>[];
      for (final e in _cases(scheme).entries) {
        final uri = e.value['uri'] as String?;
        if (uri == null) continue; // INI-кейсы проверяются отдельно.
        final delta = _delta480['$scheme/${e.key}'];
        final spec = parseUri(uri);

        if (e.value['identity'] == null) {
          if (spec != null && delta == null) {
            diffs.add('${e.key}: был отбракован, а теперь разбирается');
          }
          continue;
        }
        if (spec == null) {
          diffs.add('${e.key}: перестал разбираться');
          continue;
        }

        final gotBody = jsonEncode(spec.emit(TemplateVars.empty).map);
        // Снимки §472 несут только identity: тело у них не снималось, и
        // сверять его не с чем. Хеш при этом считается по телу, поэтому
        // расхождение тела такой кейс всё равно ловит — через identity.
        if (e.value['body'] != null) {
          final wantBody = jsonEncode(e.value['body']);
          if (gotBody != wantBody) {
            diffs.add('${e.key}: тело разошлось\n'
                '  ждали: $wantBody\n'
                '  вышло: $gotBody');
            continue;
          }
        }
        if (legacyNodeIdentityHash(spec) != e.value['identity']) {
          diffs.add('${e.key}: identity разошлась\n  вышло: $gotBody');
          continue;
        }
        if (e.value['tag'] != null && spec.tag != e.value['tag']) {
          diffs.add('${e.key}: тег «${spec.tag}» вместо «${e.value['tag']}»');
          continue;
        }

        // Кейс, помеченный дельтой, обязан НЕСТИ прежние значения рядом и
        // действительно от них отличаться: иначе пометка протухла и
        // прикрывает собой будущую регрессию.
        if (delta == null) continue;
        final before = e.value['_before480'] as Map?;
        if (before == null) {
          diffs.add('${e.key}: помечен дельтой, но прежних значений в '
              'фикстуре нет — «было → стало» обязано быть записано ($delta)');
          continue;
        }
        if (jsonEncode(before['body']) == gotBody) {
          diffs.add('${e.key}: помечен дельтой, но тело не изменилось '
              '($delta)');
        }
      }
      expect(diffs, isEmpty,
          reason: 'расхождения вне списка дельт чинятся в секции или в '
              'движке, а не правкой фикстуры:\n${diffs.join('\n')}');
    }, skip: skip);
  }

  group('§480 W4', () {
    checkScheme('hysteria2', 'hysteria2');
    checkScheme('tuic', 'tuic');
    checkScheme('masque', 'masque');
    checkScheme('wireguard', 'wireguard');

    test('wireguard INI: кейсы ini:* дают прежние identity, тег и тело', () {
      final diffs = <String>[];
      for (final e in _cases('wireguard').entries) {
        final ini = e.value['ini'] as String?;
        if (ini == null) continue;
        // INI тега не несёт, имя ему даёт вызывающий. Снимок хранит подсказку
        // двумя способами, и оба надо прочитать:
        //
        // - кейсы `ini:<имя>/<подсказка>` — хвостом имени кейса (`nohint` =
        //   подсказки не было). Так снимались прогоны, где проверяется САМА
        //   цепочка имени;
        // - прочие (`warp_conf:*`) — подсказка равна ожидаемому тегу: там
        //   проверяется тело, а имя задаётся вызывающим и в снимке уже есть.
        final slash = e.key.lastIndexOf('/');
        final isIniCase = e.key.startsWith('ini:') && slash >= 0;
        final tail = isIniCase ? e.key.substring(slash + 1) : '';
        final hint = isIniCase
            ? (tail.isEmpty || tail == 'nohint' ? null : tail)
            : e.value['tag'] as String?;
        final spec = parseWireguardIni(ini, nameHint: hint);
        if (e.value['identity'] == null) {
          if (spec != null) diffs.add('${e.key}: был отбракован');
          continue;
        }
        if (spec == null) {
          diffs.add('${e.key}: перестал разбираться');
          continue;
        }
        final gotBody = jsonEncode(spec.emit(TemplateVars.empty).map);
        if (e.value['body'] != null) {
          final wantBody = jsonEncode(e.value['body']);
          if (gotBody != wantBody) {
            diffs.add('${e.key}: тело разошлось\n'
                '  ждали: $wantBody\n'
                '  вышло: $gotBody');
            continue;
          }
        }
        if (legacyNodeIdentityHash(spec) != e.value['identity']) {
          diffs.add('${e.key}: identity разошлась\n  вышло: $gotBody');
          continue;
        }
        if (e.value['tag'] != null && spec.tag != e.value['tag']) {
          diffs.add('${e.key}: тег «${spec.tag}» вместо «${e.value['tag']}»');
        }
      }
      expect(diffs, isEmpty, reason: diffs.join('\n'));
    }, skip: skip);
  });
}
