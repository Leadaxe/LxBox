import '../../../controllers/subscription_controller.dart';
import '../../../models/codec/node_link_record.dart';
import '../../../models/codec/source_record.dart';
import '../../../models/import_rule.dart';
import '../../../models/node_warning.dart';
import '../../../models/server_list.dart';
import '../../contract/registry_warning.dart';
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
    // §439 (D-112) — ссылка на узел `{folder_id?, tag}`, нет — null.
    'override_detour': nodeLinkToRecordOrNull(e.overrideDetour),
    'detour_policy': {
      'register_detour_servers': e.registerDetourServers,
      'register_detour_in_auto': e.registerDetourInAuto,
      'use_detour_servers': e.useDetourServers,
      'override_detour': nodeLinkToRecordOrNull(e.overrideDetour),
    },
    // §346 — настройки, живущие только у SubscriptionServers. У UserServer /
    // FolderServers полей нет (их никто не фетчит) — ключи не кладём вовсе,
    // чтобы `null` не читался как «Default identity» у записи, где режима нет.
    // §435 — секции одиночного узла (контракт ## 13), read-only, как
    // хранятся (с плейсхолдерами `@self`). У подписки/папки ключа нет.
    if (list is UserServer) 'sections': list.sections?.toJson(),
    // Фича 478 — `raw` одиночного узла под `reveal=true`. Раньше сырое тело
    // отдавал только член папки (`serializeFolderMember`), и проверить, что
    // именно лежит у одиночной записи, снаружи было нечем — при разборе
    // ссылки это ровно то, что нужно сличить. Несёт credentials, поэтому
    // симметрично папке: только под `reveal` (скраббер `/state/storage`).
    if (list is UserServer && reveal) 'raw': list.rawBody,
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

/// Фича 478 — предупреждения разбора одного узла для `?warnings=true`.
///
/// Почему это API, а не экран: предупреждения вычисляются при разборе и на
/// узле не хранятся, а экран показывает уже отрендеренную строку по активной
/// локали. Проверять же надо резолв КОДА и подстановки — поэтому здесь и код,
/// и severity, и оба текста реестра пиненным английским: ответ не должен
/// зависеть от языка устройства.
///
/// `path`/`value` есть у кодов реестра ([RegistryWarning]); у классов, чей
/// текст живёт в приложении, их нет — там `null`, а `text_en` даёт [renderEn].
/// Общий интерфейс — [NodeWarning], поэтому перевод классов на
/// `RegistryWarning` форму ответа не двигает: у переведённого кода просто
/// появляются `path`/`value`.
/// §500 — причина отбраковки одиночного ввода (`addFromInput`).
Map<String, Object?> serializeParseDrop(RegistryWarning w) {
  final code = w.code;
  final value = maskRegistrySecretValue(w.path, w.value);
  return {
    'code': code,
    'path': w.path,
    'value': value,
    'title_en': registryTitle(code, RegistryLang.en,
        path: w.path, value: value, params: w.params),
  };
}

Map<String, Object?> serializeNodeWarning(NodeWarning w) {
  final reg = w is RegistryWarning ? w : null;
  final code = reg?.code;
  return {
    'code': code,
    'severity': w.severity.name,
    'path': reg?.path,
    'value': reg?.value,
    if (reg != null && reg.params.isNotEmpty) 'params': {...reg.params},
    // Заголовок есть только у кодов реестра — у классов приложения его нет,
    // и выдумывать его из текста нельзя.
    //
    // Д-2 (эмулятор 19.09.2026) — `path`/`value` передаются НАРАВНЕ с
    // `params`: реестр объявил их неявными (`text_params_implicit`), и
    // заголовки их зовут (`awg_header_invalid` → «magic header {path} not
    // applied»). Без них в ответ уезжал незаполненный плейсхолдер.
    'title_en': code == null
        ? null
        : registryTitle(code, RegistryLang.en,
            path: reg!.path, value: reg.value, params: reg.params),
    // Текст — всегда: у кода реестра из реестра, у класса приложения его
    // собственный пиненный английский.
    'text_en': w.renderEn(),
  };
}

/// §494 — `origin_kind` / `source_kind` записи для `?warnings=true`.
Map<String, String> entrySourceKinds(SubscriptionEntry e) {
  final raw = entryRawText(e);
  if (raw.isEmpty) {
    return const {'origin_kind': '', 'source_kind': ''};
  }
  return {
    'origin_kind': originKindOf(raw),
    'source_kind': sourceKindOf(raw),
  };
}

/// Текст источника записи для классификации вида (§455/§480).
String entryRawText(SubscriptionEntry e) {
  final list = e.list;
  return switch (list) {
    UserServer() => list.rawBody,
    SubscriptionServers() => list.url.isNotEmpty
        ? list.url
        : (list.nodes.isNotEmpty ? list.nodes.first.rawSource : ''),
    FolderServers() =>
        list.memberRaws.isNotEmpty ? list.memberRaws.first : '',
  };
}

/// Фича 478 / §494 — предупреждения по узлам записи: `tag` → список.
/// Все узлы присутствуют; у узла без предупреждений — пустой список.
Map<String, Object?> serializeEntryWarnings(SubscriptionEntry e) {
  final byTag = <String, Object?>{};
  for (final n in e.list.nodes) {
    byTag[n.tag] = [for (final w in n.warnings) serializeNodeWarning(w)];
  }
  return byTag;
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
      // §237 — личный detour; §439 — ссылка `{folder_id?, tag}`, нет — null.
      'detour': nodeLinkToRecordOrNull(m.detour),
      'tag': m.node?.tag,
      'protocol': m.node?.protocol,
      'broken': m.node == null,
      if (reveal) 'raw': m.raw,
      'sections': m.sections?.toJson(), // §435 — read-only
    };
