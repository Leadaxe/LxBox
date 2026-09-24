import '../../../controllers/subscription_controller.dart';
import '../../../models/codec/node_link_record.dart';
import '../../../models/codec/source_record.dart';
import '../../../models/import_rule.dart';
import '../../../models/node_warning.dart';
import '../../../models/server_list.dart';
import '../../../models/source_chain.dart';
import '../../../models/source_entry.dart';
import '../../contract/registry_warning.dart';
import '../../node_link_address.dart';
import '../../url_mask.dart';

export '../../url_mask.dart' show maskSubscriptionUrl;

/// §524 — ЗАПИСЬ ОБЩЕГО СПИСКА для `GET /subs`: контейнер, цепочка или
/// нечитаемая запись — в порядке `sources[]`, том же, что видит пользователь.
///
/// До §524 `/subs` отдавал только контейнеры, и смешанный порядок диска этим
/// API нельзя было ни прочитать, ни выразить: цепочки жили в отдельном
/// `/chains`. Теперь список один — `/chains` остался для ПРАВКИ маршрута
/// (позиции, strip, rewrite), а состав и порядок видны здесь.
///
/// Ключ порядка — `source_key` (`id:<uuid>` / `chain:<tag>`): его принимает
/// `POST /subs/reorder`. Цепочка несёт `kind: "SourceChain"` — рядом с
/// `SubscriptionServers`/`UserServer`/`FolderServers`, потому что род записи
/// читается одним полем.
Map<String, Object?> serializeSourceEntry(
  SourceEntry entry, {
  required bool reveal,
  SubscriptionEntry? liveEntry,
}) =>
    switch (entry) {
      ContainerEntry() => {
          'source_key': entry.sourceKey,
          ...serializeSubEntry(liveEntry!, reveal: reveal),
        },
      ChainEntry(:final chain) => _serializeChainAsSource(entry, chain),
      OpaqueEntry() => {
          'source_key': entry.sourceKey,
          'kind': 'Unreadable',
          // §141 P1.8c — запись, которую кодек не читает: показываем только
          // то, что есть. Её `kind` с диска — единственная зацепка.
          'record_kind': entry.kind,
          'enabled': false,
        },
    };

/// Цепочка как запись общего списка. Маршрут (позиции, strip, rewrite) здесь
/// НЕ разворачивается — это `/chains/{tag}`; `/subs` отвечает за состав и
/// порядок списка.
Map<String, Object?> _serializeChainAsSource(
        ChainEntry entry, SourceChain chain) =>
    {
      'source_key': entry.sourceKey,
      'id': chain.tag, // у цепочки идентичность — тег (§509)
      'kind': 'SourceChain',
      'title': chain.displayLabel,
      'enabled': chain.enabled,
      // §520 — счётчик узлов записи: у цепочки это её позиции.
      'nodes_count': chain.hops.length,
      'hops_count': chain.hops.length,
    };

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
///
/// §520 — ключ это СЫРОЙ ТЕГ УЗЛА В КОНТЕЙНЕРЕ ([containerRawTags],
/// NODE_LINK §2.2), а не `NodeSpec.tag`. Провайдер вправе звать узлы
/// одинаково (§310 — все `proxy`; дубль `vpn://`↔`amneziawg://` под одним
/// именем), и на сыром `n.tag` карта схлопывалась last-write-wins: у 12
/// узлов-тёзок ответ отдавал 8 записей, предупреждения ранних дублей молча
/// пропадали, а `nodes_count` при этом оставался верен — счётчик расходился
/// со списком, хотя комментарий обещал «все узлы присутствуют».
///
/// Источник истины выбран [containerRawTags], а не уникализатор сборки
/// (`build_config.dart` `allocateTag`, суффиксы `-1`/`-2`): адрес сборки
/// живёт только внутри конфига, знает про `tag_prefix` и меняется от состава
/// остальных источников, тогда как `containerRawTags` — тот же модуль
/// адресов, которым уже ключуются `nodeWarnings` в хранении
/// (`sourceNodeIdentities`), экран деталей записи, probe и ссылки
/// `{folder_id?, tag}`. Значит ключ этого ответа совпадает с тем, чем узел
/// адресуют `nodes[]`, `/nodes/link?tag=` и `switch-node`, а не расходится
/// с ними на суффиксе.
///
/// Форма ответа не двигается: тот же JSON-объект «тег → список». У записи
/// без тёзок каждый ключ дословно равен прежнему `n.tag`; различаются только
/// тёзки — ровно как в списке узлов (`X`, `X-2`, `X-3`).
///
/// Безымянный узел адреса не имеет ([containerRawTags] его не отдаёт) — под
/// пустой ключ такие узлы схлопнулись бы обратно, поэтому им выдаётся
/// позиционный ключ `#<index>`: узел в ответе присутствует, но ключ не
/// притворяется адресом, по которому его можно позвать.
///
/// Состав узлов оставлен прежним — `e.list.nodes`, тот же список, что считает
/// `nodes_count`. Брать здесь [containerNodes] нельзя: у папки он включает
/// выключенных членов, которых `nodes` (фильтр `enabled && parsed`) не видит,
/// и ответ стал бы шире счётчика — ровно та расходимость, которую §520
/// закрывает. Карта адресов ключуется по ссылке узла, поэтому шире своего
/// входа она безвредна.
Map<String, Object?> serializeEntryWarnings(SubscriptionEntry e) {
  final rawTags = containerRawTags(e.list);
  final byTag = <String, Object?>{};
  final nodes = e.list.nodes;
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    // У подписки [containerRawTags] уникализирует сам, и этот виток не
    // срабатывает. У ПАПКИ адрес члена — тег как есть, и тёзкам его делить
    // норма (NODE_LINK §2.2, у ссылки побеждает первый), так что ключ пришлось
    // бы схлопнуть — а это та же потеря. Суффикс ставим ТОЛЬКО на фактической
    // коллизии, и это ИНДЕКС УЗЛА в списке (`X#3`), а не порядковый номер
    // тёзки: индекс адресует член папки в `/folders/*` (`serializeFolderMember`
    // отдаёт его полем `index`), поэтому по такому ключу узел ещё и находится.
    // Разделитель `#` тот же, что у безымянного, и в уникализации источника
    // (`-2`/`-3`) не встречается — ключ-адрес от ключа-заплатки отличим.
    final key = rawTags[n] ?? '#$i';
    byTag[byTag.containsKey(key) ? '$key#$i' : key] = [
      for (final w in n.warnings) serializeNodeWarning(w),
    ];
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
