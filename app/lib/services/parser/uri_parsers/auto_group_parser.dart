import '../../../models/auto_select.dart';
import '../../../models/node_spec.dart';
import '../uri_utils.dart';

/// §322 — `autogroup://?include=…&mode=…#Label` → [AutoSelectSpec].
///
/// Схема синтетическая: узел автовыбора не соединение, а правило отбора среди
/// членов своего контейнера. URI существует ради единого механизма хранения
/// (`FolderMember.raw` → парсинг на загрузке), а не как переносимая ссылка.
///
NodeSpec? parseAutoGroup(String uri) {
  final parsed = autoGroupFromUri(uri);
  if (parsed == null) return null;

  final label = parsed.label.isEmpty ? 'Auto' : parsed.label;
  return AutoSelectSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'urltest', 'auto', 0),
    label: label,
    membership: parsed.membership,
    params: parsed.params,
    poolBadge: parsed.poolBadge,
  );
}
