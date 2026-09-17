import 'dart:convert';

import '../../models/codec/source_record.dart';
import '../../models/node_spec.dart';

/// §455 — тело узла для конфига, когда источник записи — JSON (`origin.kind:
/// json`): объект источника дословно, а не `emit()` модели. Правило лаунчера
/// (ручной объект `config_json` allowlist не проходит) и решение владельца
/// 17.09.2026: человек написал sing-box-объект сам — в ядро он уходит как
/// есть, гейты модели на нём выключены, ворота — `CheckConfig` на Save.
///
/// [containerRaw] — `origin.raw` записи (`UserServer.rawBody`) или члена
/// папки (`FolderMember.raw`); [node] — разобранный узел, чей `rawSource`
/// (§454) — его оригинальный outbound и для голого тела, и для документа с
/// `sections`, и для целого конфига с одним узлом.
///
/// `null` — узел идёт через модель: источник не JSON (ссылка, INI), группа,
/// или объект не собрался (не должно случаться: `rawSource` пишет парсер).
///
/// `detour` тела снимается: detour решает сборка (политика, личный detour
/// члена, родная цепочка) — так же, как у модельного узла. `tag` без тела —
/// тег модели; дальше префикс контейнера и `allocateTag`, как у всех.
Map<String, dynamic>? verbatimBodyOf(String containerRaw, NodeSpec node) {
  if (node is AutoSelectSpec) return null;
  if (originKindOf(containerRaw) != 'json') return null;
  final src = node.rawSource.trim();
  if (!src.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(src);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final body = Map<String, dynamic>.from(decoded);
  body.remove('detour');
  final tag = body['tag'];
  if (tag is! String || tag.isEmpty) body['tag'] = node.tag;
  return body;
}
