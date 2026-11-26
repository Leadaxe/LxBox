/// Кодек записи цепочки `sources[]` контракта 1.0 (§439 §1.2): настройки
/// маршрута в `body` (канон `source_chain.schema.json` без позиций), позиции —
/// ссылками в `hops[]`, `label` — поле LxBox рядом.
///
/// Места в списке у записи нет: порядок записей `sources[]` и есть порядок
/// источников, цепочки стоят среди них (§509).
///
/// Чтение терпимо, как у `source_record.dart`: позиция строкой читается
/// корневой ссылкой, незнакомые ключи — в [RecordRead.unknownKeys] путями
/// (`body.detour`), прочитанное не дословно — в `notes`. §761 —
/// `body.idle_timeout`, `body.strip_evasion`, `body.strip` (записи и бэкапы до
/// ядра lx.37-rc.2) принимаются и молча отбрасываются (контракт 1.1.184).
/// Пустая позиция и дубль не «чинятся»: их ловит `chainEmitError`.
library;

import '../../services/json_clone.dart' show deepCloneJson;
import '../node_link.dart';
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
      'body': {
        'type': kChainOutboundType,
        if (c.rewrite.isNotEmpty) 'rewrite': deepCloneJson(c.rewrite),
      },
      'hops': [for (final h in c.hops) nodeLinkToRecord(h)],
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

  final hops = <NodeLink>[];
  final rawHops = j['hops'];
  if (rawHops is List) {
    for (var i = 0; i < rawHops.length; i++) {
      final link = nodeLinkFromRecord(rawHops[i]);
      if (link == null) {
        notes?.add('$where: hops[$i] is not a link, dropped');
        continue;
      }
      hops.add(link);
    }
  }

  final rawRewrite = body['rewrite'];
  final enabled = j['enabled'];
  return RecordRead.ok(
    SourceChain(
      tag: tag,
      enabled: enabled is bool ? enabled : true,
      hops: hops,
      rewrite: rawRewrite is Map
          ? (deepCloneJson(rawRewrite) as Map).cast<String, dynamic>()
          : const {},
    ),
    unknownKeys: unknown..sort(),
  );
}
