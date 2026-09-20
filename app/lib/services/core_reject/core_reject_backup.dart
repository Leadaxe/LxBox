/// Фича 478 — вердикт страховки в бэкап не едет (решение владельца 19.09.2026).
///
/// Диагностические отметки — кэш, а не истина: в бэкап идут настройки, а не
/// выводы о них. Локальное хранилище не трогаем — здесь только запись и чтение файла.
library;

import '../../models/core_reject_verdict.dart';
import '../lx_backup_slice.dart';

/// Убирает `core_rejected` и выключение, поставленное страховкой. Человеческое
/// выключение (без вердикта) остаётся. Вызывается на экспорте и на импорте
/// (в т.ч. для старых файлов, где вердикты ещё были).
Map<String, dynamic> sanitizeCoreRejectInBackupRecord(
  Map<String, dynamic> record,
  BackupRecord kind,
) {
  switch (kind) {
    case BackupRecord.folder:
      final nodes = record['nodes'];
      if (nodes is! List) return record;
      return {
        ...record,
        'nodes': [
          for (final n in nodes)
            if (n is Map)
              sanitizeCoreRejectInBackupRecord(
                n.cast<String, dynamic>(),
                BackupRecord.folderNode,
              )
            else
              n,
        ],
      };
    case BackupRecord.subscription:
      return _sanitizeSubscriptionRecord(record);
    case BackupRecord.server:
    case BackupRecord.folderNode:
      return _sanitizeServerLikeRecord(record);
    default:
      return record;
  }
}

Map<String, dynamic> _sanitizeSubscriptionRecord(Map<String, dynamic> record) {
  final disabled = _stringKeyMap(record['disabled']);
  final warnings = _stringKeyMap(record['warnings']);

  final strippedDisabled = <String, dynamic>{};
  for (final e in disabled.entries) {
    final ws = storedWarningsFromJson(warnings[e.key]);
    if (!ws.any((w) => w.isCoreRejected)) strippedDisabled[e.key] = e.value;
  }

  final strippedWarnings = <String, dynamic>{};
  for (final e in warnings.entries) {
    final kept = _withoutCoreRejected(storedWarningsFromJson(e.value));
    if (kept.isNotEmpty) strippedWarnings[e.key] = storedWarningsToJson(kept);
  }

  final out = Map<String, dynamic>.from(record);
  _setOrRemove(out, 'disabled', strippedDisabled);
  _setOrRemove(out, 'warnings', strippedWarnings);
  return out;
}

Map<String, dynamic> _sanitizeServerLikeRecord(Map<String, dynamic> record) {
  final ws = storedWarningsFromJson(record['warnings']);
  final kept = _withoutCoreRejected(ws);
  final wasInsurance =
      record['enabled'] == false && ws.any((w) => w.isCoreRejected);

  final out = Map<String, dynamic>.from(record);
  if (wasInsurance) out['enabled'] = true;
  _setOrRemove(out, 'warnings', kept.isEmpty ? null : storedWarningsToJson(kept));
  return out;
}

List<StoredWarning> _withoutCoreRejected(List<StoredWarning> ws) =>
    [for (final w in ws) if (!w.isCoreRejected) w];

Map<String, dynamic> _stringKeyMap(Object? raw) {
  if (raw is! Map) return {};
  return {for (final e in raw.entries) e.key.toString(): e.value};
}

void _setOrRemove(Map<String, dynamic> out, String key, Object? value) {
  if (value == null || (value is Map && value.isEmpty)) {
    out.remove(key);
  } else {
    out[key] = value;
  }
}
