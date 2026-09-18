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

/// §480 — снимок «до переезда»: маппер ссылок станет движком от реестра, и
/// этот тест держит границу, по которой потом отличают «починили» от
/// «сломали».
///
/// Кейсы лежат в тех же файлах `test/fixtures/<схема>/
/// pipeline_identity_before.json`, что и снимки §472, под ключами с префиксом
/// `b480:` (у wireguard INI-кейсы — `ini:b480_*`). Разбирать их здесь, а не в
/// `<схема>_pipeline_invariants_test.dart`, приходится по ОДНОЙ причине:
/// те тесты гейтятся на вендоренную копию `app/contract/`, которой на CI нет
/// вовсе (она в `.gitignore`, `tool/sync_contract.sh` её кладёт только
/// локально) — под тем гейтом снимок молча пропускался бы именно там, где он
/// нужнее всего. Здесь гейт — ЗЕРКАЛО реестра `assets/contract`: оно лежит в
/// git, едет в APK, и снимок снят именно с него.
///
/// Значения сняты прогоном ТЕКУЩЕГО кода и записаны как есть, включая
/// заведомо плохие: сырой `+` в query приезжает пробелом, имена параметров в
/// другом регистре не читаются, часть узлов отбраковывается целиком. Снимок
/// описывает сегодняшнее поведение, а не желаемое, и «починка» такого кейса
/// обязана быть отдельным осознанным шагом фичи 480 с правкой этого файла.
const _registryRoot = 'assets/contract';

/// Схема → сколько кейсов `b480:` обязано быть в её файле. Страж от «снимок
/// тихо похудел»: без него выпавший кейс выглядел бы как зелёный тест.
const Map<String, int> _expected = {
  'trojan': 35, // весь файл; префикса у него нет — он заведён этой же задачей
  'shadowsocks': 7,
  'vless': 10,
  'hysteria2': 5,
  'tuic': 3,
  'ssh': 2,
  'socks': 8,
  'vmess': 3,
  'anytls': 1,
  'naive': 1,
  'http': 2,
  'masque': 2,
  'wireguard': 9, // 8 wireguard + 1 awg; INI считается отдельно
};

/// Сколько INI-кейсов `ini:b480_*` у wireguard.
const int _expectedIni = 5;

Map<String, Map<String, dynamic>> _cases(String scheme) {
  final f = File('test/fixtures/$scheme/pipeline_identity_before.json');
  final raw = jsonDecode(f.readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Кейсы снимка §480 у схемы. У trojan файл заведён целиком этой задачей, и
/// префикса на кейсах нет; у остальных снимок дописан в чужой файл и потому
/// помечен.
Map<String, Map<String, dynamic>> _before480(String scheme) {
  final all = _cases(scheme);
  if (scheme == 'trojan') return all;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('b480:')) e.key: e.value,
  };
}

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(() async {
    if (!mirrored) return;
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
    // §480 W1 — схемы, переехавшие на движок, без секций не разбираются
    // вовсе: запасного рукописного пути у них не осталось.
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§480 снимок «до переезда» — ссылки', () {
    for (final entry in _expected.entries) {
      final scheme = entry.key;
      test('$scheme: хеш, тег и тело каждого кейса на месте', () {
        final before = _before480(scheme);
        expect(before, hasLength(entry.value),
            reason: 'снимок $scheme изменился в размере: было ${entry.value}, '
                'стало ${before.length}. Кейс снимка не убирают молча — либо '
                'правьте счётчик вместе с фикстурой, либо верните кейс');

        for (final e in before.entries) {
          final uri = e.value['uri'] as String;
          final want = e.value['identity'] as String?;
          final spec = parseUri(uri);

          if (want == null) {
            // Отбраковка — тоже свойство: узел, которого сегодня нет,
            // появившись, влез бы в подписку новым.
            expect(e.value['dropped'], isTrue,
                reason: 'кейс ${e.key}: identity=null обязан нести dropped');
            expect(spec, isNull,
                reason: 'кейс ${e.key} СТАЛ разбираться. Если это и есть '
                    'починка — снимите значения заново и обновите фикстуру');
            continue;
          }

          expect(spec, isNotNull,
              reason: 'кейс ${e.key} перестал разбираться');
          expect(legacyNodeIdentityHash(spec!), want,
              reason: 'identity кейса ${e.key} изменилась: у пользователей '
                  'слетят выбор узла, отключения и цепочки');
          expect(spec.tag, e.value['tag'], reason: 'тег кейса ${e.key}');
          expect(jsonEncode(spec.emit(TemplateVars.empty).map),
              jsonEncode(e.value['body']),
              reason: 'тело кейса ${e.key} (эталоны сравниваются БАЙТ В БАЙТ, '
                  'включая порядок ключей)');
        }
      }, skip: skip);
    }
  });

  group('§480 снимок «до переезда» — INI', () {
    test('wireguard: INI-кейсы дают прежние хеш, тег и тело', () {
      final ini = {
        for (final e in _cases('wireguard').entries)
          if (e.key.startsWith('ini:b480_')) e.key: e.value,
      };
      expect(ini, hasLength(_expectedIni),
          reason: 'снимок INI изменился в размере');

      for (final e in ini.entries) {
        // Снимок снят с этим же hint: у кейсов нет суффикса `/nohint`,
        // которым остальные INI-кейсы файла просят разбор без подсказки.
        final spec = parseWireguardIni(e.value['ini'] as String,
            nameHint: 'file-hint');
        final want = e.value['identity'] as String?;
        if (want == null) {
          expect(e.value['dropped'], isTrue, reason: e.key);
          expect(spec, isNull, reason: 'кейс ${e.key} стал разбираться');
          continue;
        }
        expect(spec, isNotNull, reason: 'кейс ${e.key} перестал разбираться');
        expect(legacyNodeIdentityHash(spec!), want,
            reason: 'identity кейса ${e.key}');
        expect(spec.tag, e.value['tag'], reason: 'тег кейса ${e.key}');
        expect(spec.rawSource, e.value['ini'],
            reason: '§456 — источник INI-узла это сам INI, байт в байт');
        expect(jsonEncode(spec.emit(TemplateVars.empty).map),
            jsonEncode(e.value['body']),
            reason: 'тело кейса ${e.key}');
      }
    }, skip: skip);
  });
}
