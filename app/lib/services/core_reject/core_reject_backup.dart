/// Фича 478 / контракт 1.1.67 (CANON §9.4, BACKUP.md §2) — `core_rejected`
/// при переносе бэкапом.
///
/// Запись — кэш вердикта конкретного ядра на конкретной машине, а не свойство
/// узла. Норма переноса (решение владельца 25.09.2026):
///
/// - экспорт пишет запись сервера и члена папки как есть, вместе с
///   `enabled: false`; узлы подписки едут картой `disabled{}` без причины
///   (формат не расширяется);
/// - импорт запись СНИМАЕТ, `enabled`/`disabled{}` берёт из файла как есть —
///   узел остаётся выключенным, импорт его не включает. Вердикт заново
///   вынесет ядро приёмника, когда человек включит узел.
///
/// Локальное хранилище не трогаем — здесь только запись и чтение файла.
library;

import '../../models/core_reject_verdict.dart';
import '../lx_backup_slice.dart';

/// Снимает `core_rejected` с записи источника. [forExport] — сторона
/// экспорта: сервер и член папки едут как есть, у подписки снимается только
/// причина (карта `warnings`), выключение остаётся. Выключение (`enabled`,
/// `disabled{}`) не трогается ни на одной стороне.
Map<String, dynamic> sanitizeCoreRejectInBackupRecord(
  Map<String, dynamic> record,
  BackupRecord kind, {
  bool forExport = false,
}) {
  switch (kind) {
    case BackupRecord.folder:
      if (forExport) return record;
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
      if (forExport) return record;
      return _sanitizeServerLikeRecord(record);
    default:
      return record;
  }
}

Map<String, dynamic> _sanitizeSubscriptionRecord(Map<String, dynamic> record) {
  final warnings = _stringKeyMap(record['warnings']);
  final strippedWarnings = <String, dynamic>{};
  for (final e in warnings.entries) {
    final kept = _withoutCoreRejected(storedWarningsFromJson(e.value));
    if (kept.isNotEmpty) strippedWarnings[e.key] = storedWarningsToJson(kept);
  }
  final out = Map<String, dynamic>.from(record);
  _setOrRemove(out, 'warnings', strippedWarnings);
  return out;
}

Map<String, dynamic> _sanitizeServerLikeRecord(Map<String, dynamic> record) {
  final kept = _withoutCoreRejected(storedWarningsFromJson(record['warnings']));
  final out = Map<String, dynamic>.from(record);
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
