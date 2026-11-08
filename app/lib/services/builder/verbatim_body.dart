import 'dart:convert';

import '../../models/source_dialect.dart';
import '../../models/node_spec.dart';

/// §455 — тело узла для конфига, когда источник записи написан В ФОРМЕ ЯДРА:
/// объект источника дословно, а не `emit()` модели. Правило лаунчера (ручной
/// объект `config_json` allowlist не проходит) и решение владельца
/// 17.09.2026: человек написал sing-box-объект сам — в ядро он уходит как
/// есть, гейты модели на нём выключены, ворота — `CheckConfig` на Save.
///
/// §722 (контракт 1.1.165, PARSING_PRINCIPLES §10.1 условие 3, §11 п.5) —
/// условие — ХРАНИМЫЙ вид записи [dialect] `== singbox`, а не нюх текста.
/// Узел `xray` дословным не бывает: его тело — перевод по реестру (маппер →
/// санитайзер); `uri` / `wg_ini` — тоже модель. Документ sing-box дословен
/// целиком: каждый узел записи (`rawSource` §454 — его оригинальный
/// outbound) уходит своим телом.
///
/// [dialect] — `UserServer.dialect` или `FolderMember.dialect`; [node] —
/// разобранный узел записи.
///
/// Дословно, когда: (1) контейнер — свой сервер или член папки (вызывающий
/// передаёт только их); (2) узел не группа автовыбора; (3) вид записи
/// `singbox`; (4) `rawSource` узла разбирается как JSON-объект.
///
/// `null` — узел идёт через модель.
///
/// `detour` тела снимается: detour решает сборка (политика, личный detour
/// члена, родная цепочка) — так же, как у модельного узла. `tag` без тела —
/// тег модели; дальше префикс контейнера и `allocateTag`, как у всех.
Map<String, dynamic>? verbatimBodyOf(SourceDialect dialect, NodeSpec node) {
  if (node is AutoSelectSpec) return null;
  if (dialect != SourceDialect.singbox) return null;
  final src = node.rawSource.trim();
  if (!src.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(src);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  // §595 — дословное тело минует `emit`, поэтому целое-дробью (`0.0`) здесь
  // приводится тем же правилом: ядро на int-полях дробь не принимает.
  final body = Map<String, dynamic>.from(
      integralDoublesToInt(decoded) as Map<dynamic, dynamic>);
  body.remove('detour');
  final tag = body['tag'];
  if (tag is! String || tag.isEmpty) body['tag'] = node.tag;
  return body;
}
