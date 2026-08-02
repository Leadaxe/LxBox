import '../../../controllers/subscription_controller.dart';
import '../../../models/import_rule.dart';
import '../../../models/server_list.dart';
import '../../url_mask.dart';

export '../../url_mask.dart' show maskSubscriptionUrl;

/// Одна запись подписки / пользовательского сервера для `/state/subs`.
Map<String, Object?> serializeSubEntry(
  SubscriptionEntry e, {
  required bool reveal,
}) {
  final list = e.list;
  final rawUrl = e.url;
  return {
    'id': e.id,
    'kind': switch (list) {
      SubscriptionServers() => 'SubscriptionServers',
      UserServer() => 'UserServer',
      FolderServers() => 'FolderServers', // §234
    },
    'url': reveal ? rawUrl : maskSubscriptionUrl(rawUrl),
    'title': e.name,
    'enabled': e.enabled,
    'tag_prefix': e.tagPrefix,
    'nodes_count': e.nodeCount,
    'last_update_at': e.lastUpdated?.toUtc().toIso8601String(),
    'last_update_status': e.lastUpdateStatus.name,
    'consecutive_fails': e.consecutiveFails,
    'update_interval_hours': e.updateIntervalHours,
    // Full detour policy (task 006 — per-server detour toggles).
    // `override_detour` оставлен top-level для backward-compat клиентов,
    // дополнительно группируем в nested object для полного view'а.
    'override_detour': e.overrideDetour,
    'detour_policy': {
      'register_detour_servers': e.registerDetourServers,
      'register_detour_in_auto': e.registerDetourInAuto,
      'use_detour_servers': e.useDetourServers,
      'override_detour': e.overrideDetour,
    },
    // §346 — настройки, живущие только у SubscriptionServers. У UserServer /
    // FolderServers полей нет (их никто не фетчит) — ключи не кладём вовсе,
    // чтобы `null` не читался как «Default identity» у записи, где режима нет.
    if (list is SubscriptionServers) ...{
      'on_update_action': list.onUpdateAction.name, // §323
      // §289 — null = режим Default (глобальная идентичность §118).
      // hwid не маскируем под reveal: это идентификатор устройства, а не
      // секрет провайдера (симметрия со скраббером /state/storage).
      'identity': list.identity?.toJson(),
      'import_rules_enabled': list.importRulesEnabled, // §302
      // Сам список — под-ресурс /subs/{id}/rules: у подписки правил может быть
      // много, а это общий листинг.
      'import_rules_count': list.importRules.length,
    },
  };
}

/// §346 — одно import-правило (§302) для `/subs/{id}/rules`. Shape — канонный
/// `ImportRule.toJson()` (через него же едут storage и backup), плюс два
/// вычисляемых поля для клиента:
///
/// - `index` — позиционный адрес для write'ов (у ImportRule нет id, как у
///   членов папки в §238); после DELETE/reorder съезжает.
/// - `usable` — правило пройдёт применение (§302 `isUsable`). `false` — не
///   ошибка: недособранное правило легально и в UI-редакторе.
Map<String, Object?> serializeImportRule(ImportRule r, int index) => {
      'index': index,
      'usable': r.isUsable,
      ...r.toJson(),
    };

/// §238 — folder-entry (§234) для `/folders/*`: базовый sub-entry shape +
/// created_at и члены. `raw` члена несёт credentials (URI/ключи, симметрия
/// со скраббером `/state/storage`) — отдаётся только под `reveal=true`.
Map<String, Object?> serializeFolderEntry(
  SubscriptionEntry e, {
  required bool reveal,
}) {
  final folder = e.list as FolderServers;
  return {
    ...serializeSubEntry(e, reveal: reveal),
    'created_at': folder.createdAt.toUtc().toIso8601String(),
    'members_count': folder.members.length,
    'disabled_count': folder.disabledCount,
    'members': [
      for (var i = 0; i < folder.members.length; i++)
        serializeFolderMember(folder.members[i], i, reveal: reveal),
    ],
  };
}

/// §238 — член папки. `index` — позиционный адрес для member-write'ов
/// (у FolderMember нет id); `broken` = raw не парсится (§234).
Map<String, Object?> serializeFolderMember(
  FolderMember m,
  int index, {
  required bool reveal,
}) =>
    {
      'index': index,
      'enabled': m.enabled,
      'detour': m.detour, // §237 — личный detour ('' = нет)
      'tag': m.node?.tag,
      'protocol': m.node?.protocol,
      'broken': m.node == null,
      if (reveal) 'raw': m.raw,
    };
