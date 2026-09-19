import 'dart:convert';

import '../../models/codec/source_record.dart';
import '../../models/node_spec.dart';

/// §455 — тело узла для конфига, когда источник записи написан В ФОРМЕ ЯДРА
/// (вид источника `singbox_*`): объект источника дословно, а не `emit()`
/// модели. Правило лаунчера (ручной объект `config_json` allowlist не
/// проходит) и решение владельца 17.09.2026: человек написал sing-box-объект
/// сам — в ядро он уходит как есть, гейты модели на нём выключены, ворота —
/// `CheckConfig` на Save.
///
/// Д-1 (эмулятор 19.09.2026) — признак «источник JSON» этому правилу НЕ
/// годится: `origin.kind: json` стоит у любого JSON-объекта, в том числе у
/// Xray-outbound'а (`protocol`/`settings`/`streamSettings`). Дословно он
/// уезжал в `outbounds[]` чужим диалектом, и ядро отвергало ВЕСЬ конфиг —
/// `unknown outbound type:` без имени узла, так что и выключить его было
/// нечем. Судит теперь вид источника движка ([sourceIsSingbox]); Xray идёт
/// через модель (маппер → санитайзер), как и его массив `outbounds[]`.
///
/// [containerRaw] — `origin.raw` записи (`UserServer.rawBody`) или члена
/// папки (`FolderMember.raw`); [node] — разобранный узел, чей `rawSource`
/// (§454) — его оригинальный outbound и для голого тела, и для документа с
/// `sections`, и для целого конфига с одним узлом.
///
/// `null` — узел идёт через модель: источник не sing-box (ссылка, INI, Xray),
/// группа, или объект не собрался (не должно случаться: `rawSource` пишет
/// парсер).
///
/// `detour` тела снимается: detour решает сборка (политика, личный detour
/// члена, родная цепочка) — так же, как у модельного узла. `tag` без тела —
/// тег модели; дальше префикс контейнера и `allocateTag`, как у всех.
Map<String, dynamic>? verbatimBodyOf(String containerRaw, NodeSpec node) {
  if (node is AutoSelectSpec) return null;
  if (!sourceIsSingbox(containerRaw)) return null;
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
