/// Кодек записи цепочки `sources[]` контракта 1.0 (§439 §1.2): настройки
/// маршрута в `body` (канон `source_chain.schema.json` без позиций), позиции —
/// ссылками в `hops[]`, `label` — поле LxBox рядом.
///
/// Места в списке у записи нет: цепочки идут хвостом `sources[]`, порядок
/// записей и есть порядок цепочек (§439 п. 7).
///
/// Чтение терпимо, как у `source_record.dart`: позиция строкой читается
/// корневой ссылкой, незнакомые ключи — в [RecordRead.unknownKeys] путями
/// (`body.detour`, `body.strip.tls.foo`), прочитанное не дословно — в `notes`.
/// Пустая позиция и дубль не «чинятся»: их ловит `chainEmitError`.
library;

import '../../services/json_clone.dart' show deepCloneJson;
import '../record_codec.dart' show RecordRead;
import '../source_chain.dart';
import 'node_link_record.dart';

const String kSourceKindChain = 'chain';

const Set<String> _chainKeys = {'kind', 'tag', 'enabled', 'label', 'body', 'hops'};

const Set<String> _chainBodyKeys = {
  'type',
  'idle_timeout',
  'strip_evasion',
  'strip',
  'rewrite',
};

/// Цепочка LxBox → запись `sources[]`.
Map<String, dynamic> chainToRecord(SourceChain c) => {
      'kind': kSourceKindChain,
      'tag': c.tag,
      'enabled': c.enabled,
      if (c.label.isNotEmpty) 'label': c.label,
      'body': {
        'type': kChainOutboundType,
        if (c.idleTimeout.isNotEmpty) 'idle_timeout': c.idleTimeout,
        // Трёхзначность: null = умолчание ядра, ключа нет.
        if (c.stripEvasion != null) 'strip_evasion': c.stripEvasion,
        if (c.strip.isNotEmpty)
          'strip': {
            for (final key in kChainStripKeys)
              if (c.strip.containsKey(key)) key: c.strip[key],
          },
        if (c.rewrite.isNotEmpty) 'rewrite': deepCloneJson(c.rewrite),
      },
      'hops': [for (final h in c.hops) nodeLinkToRecord(linkOfModelTag(h))],
    };

/// Запись `sources[]` вида `chain` → цепочка LxBox. Без тега цепочка не
/// адресуема — отброс с причиной.
RecordRead<SourceChain> chainFromRecord(
  Map<String, dynamic> j, {
  List<String>? notes,
}) {
  final kind = j['kind'];
  if (kind != kSourceKindChain) {
    return RecordRead.drop('record kind "$kind" is not a chain');
  }
  final rawTag = j['tag'];
  // Тег — id цепочки: подрезается, как у legacy-чтения.
  final tag = rawTag is String ? rawTag.trim() : '';
  if (tag.isEmpty) return const RecordRead.drop('chain without tag');
  final where = 'chain "$tag"';

  final unknown = <String>[
    for (final k in j.keys)
      if (!_chainKeys.contains(k)) k,
  ];

  final rawBody = j['body'];
  if (rawBody != null && rawBody is! Map) {
    notes?.add('$where: body is not an object, chain settings are defaults');
  }
  final body = rawBody is Map ? rawBody : const <String, dynamic>{};
  for (final k in body.keys) {
    if (!_chainBodyKeys.contains(k)) unknown.add('body.$k');
  }
  final type = body['type'];
  if (type != null && type != kChainOutboundType) {
    notes?.add('$where: body.type "$type" is not "$kChainOutboundType"');
  }

  final strip = <String, bool>{};
  final rawStrip = body['strip'];
  if (rawStrip is Map) {
    for (final e in rawStrip.entries) {
      if (kChainStripKeys.contains(e.key) && e.value is bool) {
        strip['${e.key}'] = e.value as bool;
      } else {
        unknown.add('body.strip.${e.key}');
      }
    }
  }

  final hops = <String>[];
  final rawHops = j['hops'];
  if (rawHops is List) {
    for (var i = 0; i < rawHops.length; i++) {
      final link = nodeLinkFromRecord(rawHops[i]);
      if (link == null) {
        notes?.add('$where: hops[$i] is not a link, dropped');
        continue;
      }
      hops.add(modelTagOfLink(link, '$where: hops[$i]', notes));
    }
  }

  final rawRewrite = body['rewrite'];
  final idleTimeout = body['idle_timeout'];
  final stripEvasion = body['strip_evasion'];
  final label = j['label'];
  final enabled = j['enabled'];
  return RecordRead.ok(
    SourceChain(
      tag: tag,
      label: label is String ? label : '',
      enabled: enabled is bool ? enabled : true,
      hops: hops,
      idleTimeout: idleTimeout is String ? idleTimeout : '',
      stripEvasion: stripEvasion is bool ? stripEvasion : null,
      // Каталожный порядок ключей, как у записи.
      strip: {
        for (final key in kChainStripKeys)
          if (strip.containsKey(key)) key: strip[key]!,
      },
      rewrite: rawRewrite is Map
          ? (deepCloneJson(rawRewrite) as Map).cast<String, dynamic>()
          : const {},
    ),
    unknownKeys: unknown..sort(),
  );
}
