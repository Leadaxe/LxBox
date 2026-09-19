import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W4 — СВЕРКА переключённых на движок схем с эталоном «до переезда».
///
/// Эталон — те же снимки `test/fixtures/<схема>/pipeline_identity_before.json`,
/// что держит `before_480_identity_snapshot_test.dart`, и сверяется то же
/// самое: хеш identity, тег и тело БАЙТ В БАЙТ. Отличие одно — здесь идут ВСЕ
/// кейсы файла, а не только помеченные `b480:`: кейсы §472 сняты тем же
/// способом и так же нормативны, а после переключения схемы на движок их
/// обязан воспроизводить он.
///
/// **Тело сверяется ПОСЛЕ САНИТАЙЗЕРА.** `parseUri` — это весь конвейер
/// (движок → санитайзер по реестру → `parseSingboxEntry`), и снимки сняты
/// именно с него. Сверять выход одного движка значило бы сверяться не с тем,
/// что видит пользователь.
///
/// Гейт — ЗЕРКАЛО реестра `assets/contract`, как у снимка: вендоренной копии
/// `app/contract` на CI нет вовсе, и под её гейтом сверка молча пропускалась
/// бы ровно там, где нужнее всего.
const _registryRoot = 'assets/contract';

/// Схемы, переключённые на движок волной W4, и число кейсов их снимка.
/// Счётчик — страж от «снимок тихо похудел».
const Map<String, int> _switched = {
  'vless': 99,
  'socks': 17,
  'ssh': 13,
  'anytls': 13,
  'shadowsocks': 27,
  'http': 12,
  'naive': 19,
};

/// Схемы, ждущие СИНКА КОНТРАКТА: их секции движок берёт из реестра (он
/// первым в очереди загрузчика), а зеркало отстало от develop лаунчера,
/// где нужные записи уже есть.
///
/// Проверено подменой трёх файлов зеркала на версии с develop лаунчера:
/// сверка всех шести схем зелёная. Чего не хватает зеркалу 1.1.15:
///
/// - `anytls` — записи `fp` с `materialize_default` (дефолт отпечатка
///   `random`); без неё у узла пропадает блок `tls.utls`, а он в identity;
/// - `http` — `include: ["tls#uri", "tls#uri_with_host"]` вместо одного
///   `uri_with_host`: тот переопределяет ТОЛЬКО цепочку `sni`, и без первого
///   блока схема теряет `fp`, `alpn` и `insecure`;
/// - `naive` — строгого charset имени заголовка в `extract.re`; в зеркале
///   осталось `[^:]+`, которое принимает имя с пробелом, и битая пара не
///   отбраковывается.
///
/// Снять отсюда сразу, как синк доедет, — правки на нашей стороне не нужно.
/// Чинить подменой черновика нельзя: загрузчик предпочитает реестр, и
/// черновик этих схем сегодня не читается вовсе.
const Set<String> _awaitingContractSync = <String>{};

Map<String, Map<String, dynamic>> _cases(String scheme) {
  final raw = jsonDecode(
    File('test/fixtures/$scheme/pipeline_identity_before.json')
        .readAsStringSync(),
  ) as Map;
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
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  group('§480 W4 — схема на движке даёт прежние identity, тег и тело', () {
    for (final entry in _switched.entries) {
      final scheme = entry.key;
      test(scheme, () {
        final cases = _cases(scheme);
        expect(cases, hasLength(entry.value),
            reason: 'снимок $scheme изменился в размере: было ${entry.value}, '
                'стало ${cases.length}');

        final red = <String>[];
        for (final e in cases.entries) {
          final uri = e.value['uri'] as String;
          final want = e.value['identity'] as String?;
          final spec = parseUri(uri);

          if (want == null) {
            if (spec != null) red.add('${e.key}: СТАЛ разбираться');
            continue;
          }
          if (spec == null) {
            red.add('${e.key}: перестал разбираться');
            continue;
          }
          final got = legacyNodeIdentityHash(spec);
          if (got != want) {
            red.add('${e.key}: identity $got != $want');
          }
          // Тег и тело снимок §472 не несёт — там только хеш; сверяем их
          // там, где они записаны (кейсы `b480:` и весь файл trojan).
          if (e.value.containsKey('tag') && spec.tag != e.value['tag']) {
            red.add('${e.key}: тег "${spec.tag}" != "${e.value['tag']}"');
          }
          if (e.value.containsKey('body')) {
            final body = jsonEncode(spec.emit(TemplateVars.empty).map);
            final wantBody = jsonEncode(e.value['body']);
            if (body != wantBody) {
              red.add('${e.key}: тело\n  наше: $body\n  эталон: $wantBody');
            }

            // Пометка дельты ДВУСТОРОННЯЯ: кейс с сознательно изменённым
            // поведением обязан нести и новое ожидание, и прежнее, а тело —
            // совпасть с новым И отличаться от прежнего. Односторонняя
            // пометка протухает молча и с этого момента прикрывает регрессию
            // ровно там, где за поведением следят пристальнее всего.
            final delta = e.value['_delta480'] as String?;
            if (delta != null) {
              final before = e.value['_before480'] as Map?;
              if (before == null) {
                red.add('${e.key}: помечен дельтой, но прежних значений рядом '
                    'нет — «было → стало» обязано быть записано ($delta)');
              } else if (jsonEncode(before['body']) == body) {
                red.add('${e.key}: помечен дельтой, но тело не изменилось — '
                    'пометка протухла ($delta)');
              }
            }
          }
        }
        expect(red, isEmpty, reason: 'красные кейсы:\n${red.join('\n')}');
      },
          skip: skip ??
              (_awaitingContractSync.contains(scheme)
                  ? 'ждёт синка контракта: секция в зеркале отстала от '
                      'develop лаунчера (см. _awaitingContractSync)'
                  : null));
    }
  });
}
