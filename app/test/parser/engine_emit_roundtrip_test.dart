import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W7 — КРУГ `parse(emit(body))` по фикстурам всех схем.
///
/// Критерий (а) волны: тело, собранное в ссылку новым эмиттером и разобранное
/// обратно, обязано совпасть с исходным БАЙТ В БАЙТ, включая порядок ключей.
/// Текст ссылки при этом сравнивать не с чем и не нужно — вид ссылки волна
/// меняет намеренно; проверяется СОХРАННОСТЬ СМЫСЛА, а не написание.
///
/// Эталон — фикстуры «до» (`pipeline_identity_before.json`), снятые прежним
/// путём: они не переписываются волной ни на кейс.
///
/// Гейт — ЗЕРКАЛО `assets/contract`: каталога `app/contract` на CI нет вовсе.
const _registryRoot = 'assets/contract';
const _draftRoot = 'assets/contract_draft';

/// Схема фикстуры → тип тела (он же имя секции). Здесь этот словарь законен:
/// тест не входит в пакет движка, и греп-страж его не судит.
const _types = <String, String>{
  'trojan': 'trojan',
  'socks': 'socks',
  'tuic': 'tuic',
  'hysteria2': 'hysteria2',
  'masque': 'masque',
  'ssh': 'ssh',
  'anytls': 'anytls',
  'shadowsocks': 'shadowsocks',
  'http': 'http',
  'naive': 'naive',
  'vless': 'vless',
  'vmess': 'vmess',
  'wireguard': 'wireguard',
};

Map<String, Map<String, dynamic>> _cases(String scheme, String file) {
  final f = File('test/fixtures/$scheme/$file');
  if (!f.existsSync()) return const {};
  final raw = jsonDecode(f.readAsStringSync()) as Map;
  final cases = (raw['cases'] as Map?)?.cast<String, dynamic>();
  if (cases == null) return const {};
  return cases.map(
    (k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()),
  );
}

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(() async {
    if (!mirrored) return;
    if (!ContractRegistry.I.isLoaded) {
      await ContractRegistry.I.loadFromDirectory(_registryRoot);
    }
    await MapperSections.I.loadDrafts(dir: _draftRoot, files: kDraftFiles);
  });

  group('§480 W7 · круг parse(emit(body))', () {
    for (final e in _types.entries) {
      final scheme = e.key;
      final type = e.value;

      test('$scheme: тело переживает сборку ссылки и обратный разбор', () {
        final section = MapperSections.I.sectionFor('uri', type);
        expect(section, isNotNull, reason: 'секции нет — движок не работает');
        if (!sectionEmits(section!)) {
          // Секция обратного хода не объявила: схема остаётся на рукописном
          // эмите до своей волны, и это законное состояние, а не провал.
          return;
        }

        final diffs = <String>[];
        for (final c in _cases(scheme, 'pipeline_identity_before.json').entries) {
          final body = c.value['body'];
          if (body is! Map) continue; // отбракованные кейсы круга не имеют
          final want = body.cast<String, dynamic>();
          final tag = c.value['tag'] as String? ?? '';

          final emitted = emitViaSection(section, want, tag);
          if (emitted == null) {
            diffs.add('${c.key}: эмиттер не собрал ссылку');
            continue;
          }

          // Сверка идёт через ПОЛНЫЙ конвейер: фикстура «до» снята моделью
          // (`spec.emit`), и порядок ключей в ней канонический — тот самый,
          // по которому считается identity. Сравнивать с сырой картой маппера
          // значило бы сверять разные слои.
          final spec = parseUri(emitted.uri);
          if (spec == null) {
            diffs.add('${c.key}: своя же ссылка не разобралась\n'
                '  ссылка: ${emitted.uri}');
            continue;
          }

          final got = jsonEncode(spec.emit(TemplateVars.empty).map);
          final expected = jsonEncode(want);
          if (got != expected) {
            diffs.add('${c.key}: тело разошлось на круге\n'
                '  ссылка: ${emitted.uri}\n'
                '  ждали:  $expected\n'
                '  вышло:  $got');
            continue;
          }
          if (tag.isNotEmpty && spec.tag != tag) {
            diffs.add('${c.key}: тег «${spec.tag}» вместо «$tag»');
          }
          final identity = c.value['identity'] as String?;
          if (identity != null && legacyNodeIdentityHash(spec) != identity) {
            diffs.add('${c.key}: identity разошлась на круге');
          }
          if (emitted.lost.isNotEmpty) {
            diffs.add('${c.key}: НЕобъявленная потеря путей '
                '${emitted.lost.join(", ")} — круг рвётся молча\n'
                '  ссылка: ${emitted.uri}');
          }
        }
        expect(diffs, isEmpty, reason: diffs.join('\n'));
      }, skip: skip);

      test('$scheme: СТАРАЯ ссылка рукописного эмита читается ТАК ЖЕ, как '
          'читалась', () {
        final diffs = <String>[];
        for (final c in _cases(scheme, 'emit_before480.json').entries) {
          final old = c.value['uri_before'] as String?;
          if (old == null) continue;

          final spec = parseUri(old);
          if (spec == null) {
            diffs.add('${c.key}: старая ссылка перестала разбираться\n'
                '  ссылка: $old');
            continue;
          }

          // Эталон — тело, которое эта ССЫЛКА давала раньше, а НЕ тело
          // исходного узла. Разница между ними — потеря РУКОПИСНОГО эмита:
          // он не умел писать `plugin`, `pinSHA256`, `disable_sni`, ронял
          // `?ed=` в хвосте пути, и узел, пересохранённый через `toUri()`,
          // терял эти поля молча. Требовать здесь исходное тело значило бы
          // требовать, чтобы новый разбор ВОССТАНОВИЛ то, чего в тексте
          // ссылки нет вовсе.
          //
          // Проверяется поэтому СТАБИЛЬНОСТЬ ЧТЕНИЯ: сохранённый `rawSource`
          // ручного узла обязан читаться в то же тело, что и до волны, —
          // тег и identity не двигаются.
          final wasBody = c.value['body_of_old_uri'];
          if (wasBody == null) continue;
          final got = jsonEncode(spec.emit(TemplateVars.empty).map);
          final expected = jsonEncode(wasBody);
          if (got != expected) {
            diffs.add('${c.key}: старая ссылка стала читаться иначе\n'
                '  ссылка: $old\n'
                '  ждали:  $expected\n'
                '  вышло:  $got');
          }
        }
        expect(diffs, isEmpty,
            reason: 'это сохранённые rawSource ручных узлов — они обязаны '
                'читаться как прежде:\n${diffs.join('\n')}');
      }, skip: skip);
    }
  });
}
