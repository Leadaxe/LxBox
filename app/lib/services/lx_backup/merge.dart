part of '../lx_backup.dart';

/// LX Backup, стадия 6: слияние файла с локальным состоянием (подписки, серверы,
/// автогруппы, цепочки, перенумерация оси правил).

/// Результат слияния подписок файла с локальным состоянием
/// ([mergeBackupSubscriptions]).
typedef BackupSubscriptionMerge = ({
  /// Списки источников после слияния (порядок локальных сохранён, новые — в
  /// хвосте, в порядке файла).
  List<ServerList> lists,

  /// URL подписки → её индекс в [lists]. Нужен последующим секциям импорта.
  Map<String, int> byUrl,

  /// Сколько записей файла реально применилось.
  int applied,

  /// §438 — `id` подписки в файле → `id` подписки здесь. Ссылки `hops[]` и
  /// `detour` на узел подписки идут по этой карте (BACKUP.md §6).
  Map<String, String> ids,

  /// §438 — `id` заведённой подписки → её место в файле: слияние узлов
  /// ставит новые источники всех видов в порядке файла.
  Map<String, int> added,

  /// §439 — `id` подписки здесь → общий `detour` из файла 1.0 (`null` — снять
  /// свой). Тег конфига из ссылки получает слияние узлов, когда известна карта
  /// контейнеров ([mergeBackupServers], `sourceDetours`). Подписок 0.x в
  /// карте нет: их ссылка остаётся своей.
  Map<String, NodeLink?> detours,
});

/// §438 — `id` записи файла для НОВОЙ записи: берётся, если он есть, не занят
/// и годится в идентификатор, иначе свежий (BACKUP.md §9 п. 8: два источника
/// с одним `id` дали бы двух владельцев одной адресации). Форма ограничена:
/// `id` приходит из чужого файла, а в состоянии он служит ключом.
String _adoptSourceId(String fileId, Set<String> taken) {
  final id = fileId.isNotEmpty &&
          _sourceIdShape.hasMatch(fileId) &&
          !taken.contains(fileId)
      ? fileId
      : newUuidV4();
  taken.add(id);
  return id;
}

final RegExp _sourceIdShape = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// §393 B6/B10 + §401 (П1) — слияние `subscriptions[]` файла с локальными
/// источниками. Чистая функция: состояние читает и пишет вызывающий.
///
/// Идентичность записи — URL: он и есть идентичность подписки на обеих
/// сторонах контракта.
///
/// **Совпавшая по URL запись ОБНОВЛЯЕТСЯ настройками из файла.** Бэкап — это
/// сериализация состояния (BACKUP_PRINCIPLES П1), и восстановленное состояние
/// обязано быть неотличимо от настроенного руками. Раньше совпавшая запись
/// получала только доливку disabled-отметок, поэтому восстановление СВОЕГО ЖЕ
/// файла на том же устройстве не возвращало ни `identity`, ни префикс тегов:
/// пользователь видел «импорт прошёл» и настроек на месте не находил.
///
/// Исключение ровно одно — **disabled-отметки ОБЪЕДИНЯЮТСЯ**, а не
/// замещаются (§4 BACKUP.md): отметка, которой в файле нет, могла быть
/// поставлена уже после экспорта, и молча включать такой узел нельзя.
///
/// §438 — у записи формата 1.0 ([LxSubscription.fullSettings]) отсутствие
/// интервала обновления значит умолчание, а не «оставь своё»: формат несёт
/// настройки подписки целиком (BACKUP.md §9 п. 1). Новая подписка берёт `id`
/// из файла, если он свободен.
///
/// Локальные подписки, которых в файле нет, НЕ удаляются: импорт — слияние,
/// а полная замена раздела была бы другим решением.
///
/// Новая подписка добавляется БЕЗ узлов: тело приедет обычным обновлением.
BackupSubscriptionMerge mergeBackupSubscriptions(
  List<ServerList> lists,
  List<LxSubscription> incoming,
) {
  final byUrl = <String, int>{
    for (var i = 0; i < lists.length; i++)
      if (lists[i] is SubscriptionServers)
        (lists[i] as SubscriptionServers).url: i,
  };
  final merged = lists.toList();
  final takenIds = <String>{for (final l in merged) l.id};
  final ids = <String, String>{};
  final added = <String, int>{};
  final detours = <String, NodeLink?>{};
  var applied = 0;

  DateTime at(int unixSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true);

  for (final sub in incoming) {
    if (sub.url.isEmpty) continue;
    final idx = byUrl[sub.url];
    if (idx != null) {
      final existing = merged[idx] as SubscriptionServers;
      // Хеш, которого у нас нет, добавляется; свой не перетирается.
      final add = <String, DateTime>{
        for (final e in sub.disabled.entries)
          if (!existing.disabledHashes.containsKey(e.key)) e.key: at(e.value),
      };
      // Как у disabled: ключа, которого у нас нет, добавляем. core_rejected
      // сюда не доезжает — санитизация §489 срезает его до кодека.
      final addW = <String, List<StoredWarning>>{
        for (final e in sub.nodeWarnings.entries)
          if (!existing.nodeWarnings.containsKey(e.key)) e.key: e.value,
      };
      merged[idx] = existing.copyWith(
        disabledHashes: {...existing.disabledHashes, ...add},
        nodeWarnings: {...existing.nodeWarnings, ...addW},
        // Пустое имя в файле именем не является — своё не затираем.
        name: sub.label.isNotEmpty ? sub.label : null,
        tagPrefix: sub.tagPrefix,
        updateIntervalHours: sub.updateIntervalHours ??
            (sub.fullSettings ? _defaultUpdateIntervalHours : null),
        enabled: sub.enabled,
        // `identity` — слепок целиком: объекта в файле НЕТ значит «настройка
        // сброшена в дефолт», а не «оставь как было». Иначе состояние без
        // override'а не переносилось бы вовсе.
        identity: sub.identity,
        clearIdentity: sub.identity == null,
        // §439 Л2 — объявленные настройки LxBox: приехали — применяются, нет
        // в файле — свои (сторона их не носит). Ссылку detour ставит слияние
        // узлов по [detours].
        detourPolicy: sub.detourPolicy?.copyWith(
            overrideDetour: existing.detourPolicy.overrideDetour),
        importRules: sub.importRules,
        importRulesEnabled: sub.importRulesEnabled,
        onUpdateAction: sub.onUpdateAction,
        // Фича 565 фаза B — свёртка: запись 1.0 несёт её целиком (нет
        // объекта — не свёрнута), 0.x про неё не знает — своя остаётся.
        replace: sub.replace,
        clearReplace: sub.fullSettings && sub.replace == null,
      );
      if (sub.id.isNotEmpty) ids[sub.id] = existing.id;
      if (sub.fullSettings) detours[existing.id] = sub.detour;
      applied++;
      continue;
    }

    merged.add(SubscriptionServers(
      id: _adoptSourceId(sub.id, takenIds),
      name: sub.label,
      enabled: sub.enabled,
      tagPrefix: sub.tagPrefix,
      detourPolicy: sub.detourPolicy ?? DetourPolicy.defaults,
      tls: sub.tls ?? TlsPolicy.none,
      url: sub.url,
      updateIntervalHours:
          sub.updateIntervalHours ?? _defaultUpdateIntervalHours,
      // §401 (D-083) — per-source identity: чем подписка представляется
      // провайдеру. Провайдеры ВЕТВЯТ выдачу по UA, и без переноса та же
      // ссылка отдала бы на новой машине другой набор узлов.
      identity: sub.identity,
      disabledHashes: {
        for (final e in sub.disabled.entries) e.key: at(e.value),
      },
      nodeWarnings: sub.nodeWarnings,
      importRules: sub.importRules ?? const [],
      importRulesEnabled: sub.importRulesEnabled ?? true,
      onUpdateAction: sub.onUpdateAction ?? SubscriptionOnUpdateAction.rebuild,
      replace: sub.replace,
    ));
    byUrl[sub.url] = merged.length - 1;
    if (sub.id.isNotEmpty) ids[sub.id] = merged.last.id;
    if (sub.detour != null) detours[merged.last.id] = sub.detour;
    added[merged.last.id] = sub.position;
    applied++;
  }

  return (
    lists: merged,
    byUrl: byUrl,
    applied: applied,
    ids: ids,
    added: added,
    detours: detours,
  );
}

/// Умолчание интервала обновления подписки (`SubscriptionServers`).
const int _defaultUpdateIntervalHours = 24;

/// §438 — адрес узла в списке источников: индекс источника и индекс члена
/// папки (`-1` — сам источник, корневой узел).
typedef BackupNodeRef = ({int list, int member});

/// Результат слияния одиночных узлов и папок ([mergeBackupServers]).
typedef BackupServerMerge = ({
  /// Списки источников после слияния (порядок локальных сохранён, новые — в
  /// хвосте, в порядке файла).
  List<ServerList> lists,

  /// §511 m2 — заведённые импортом источники (подписки, серверы, папки):
  /// `id` здесь → место записи в `sources[]` файла.
  Map<String, int> added,

  /// Сколько записей файла реально применилось.
  int applied,

  /// §438 — `id` контейнера в файле → `id` здесь: папки этого слияния и
  /// подписки из [mergeBackupSubscriptions] (`sourceIds`). Совпавший
  /// контейнер держит локальный `id`, заведённый — `id` из файла (если
  /// свободен). По карте переводятся ссылки `hops[]`/`detour` (BACKUP.md §6).
  Map<String, String> folderIds,

  /// §438 — узлы, которые импорт принёс или узнал по телу: их секции идут в
  /// общую перенумерацию оси ([renumberBackupAxis]).
  List<BackupNodeRef> touched,

  /// §439 — ссылка файла → адрес здесь (NODE_LINK §7.2, §7.3): `folder_id`
  /// по карте контейнеров и тег, под которым лёг член; `{tag}` на члена
  /// контейнера — пара, если кандидат один (сперва среди узлов файла, затем
  /// среди узлов приёмника). [legacy] — файл 0.x: тег сверяется и с сырым
  /// тегом члена. Позиции цепочек переводит [resolveBackupChainHops].
  BackupLinkMapper linkOf,
});

/// §439 — перевод ссылки файла в адрес здесь ([BackupServerMerge.linkOf]).
typedef BackupLinkMapper = NodeLink Function(NodeLink link, {bool legacy});

/// §406 (D-095) — КАНОН ТЕЛА узла для дедупа при импорте.
///
/// Идентичности, кроме тела, у одиночной записи `servers[]` нет: `id`
/// локальный и в файле его не существует, `node_tag` вычисляется из тела.
/// Значит вопрос «этот узел у меня уже стоит?» решается сравнением тел — и
/// сравнивать их посимвольно нельзя: одна и та же нода, пересобранная другим
/// сериализатором, даёт другую строку и второй раз доливается в список.
///
/// Форма канона:
///
///  * **URI** — всё от первого `#` отрезается, затем `trim()`. Фрагмент это
///    ИМЯ узла, а не его тело: `vless://…#Berlin` и `vless://…#Берлин` — один
///    и тот же сервер под двумя подписями, и заводить его дважды не за что.
///  * **JSON-объект** — из верхнего уровня удаляются `tag` и `detour` (форма
///    identity-хеша, контракт D-007: `tag` — то же имя, `detour` — способ
///    дозвона, а не узел), остаток рекурсивно сортируется по ключам
///    ([deepSortKeys]) и печатается компактно. Перестановка ключей и разный
///    отступ больше не заводят двойника.
///  * **Многострочный текст** (WG-INI) — `trim()` как есть: `#` там начинает
///    комментарий строки, и отрезать по нему нельзя (BACKUP.md §9 п. 2). До
///    §438 текст резался по первому `#`, и конфиги с комментарием в начале
///    сливались в один.
///  * **Прочее** — `trim()` как есть.
///
/// §741 (контракт 1.1.172, BACKUP.md §9) — комментарии JSON-исходника
/// (`//`, `/* */`, `#`) снимаются ДО канонизации ([jsonSourceText]): тот же
/// узел с пометками в тексте и без них — одна запись. Ссылку и `.conf` эта
/// функция не меняет.
///
/// Одна и та же функция канонизирует и приехавшее тело, и локальный
/// `rawBody`: сравнение имеет смысл, только когда обе стороны приведены к
/// одной форме.
String canonicalNodeBody(String body) {
  final t = jsonSourceText(body.trim()).trim();
  if (t.startsWith('{')) {
    final map = _tryDecodeObject(t);
    if (map != null) {
      final stripped = Map<String, dynamic>.from(map)
        ..remove('tag')
        ..remove('detour');
      return jsonEncode(deepSortKeys(stripped));
    }
    return t;
  }
  // §722 (BACKUP.md §9) — JSON-массив (источник `singbox`/`xray` хранится в
  // своей форме) — тоже канонический JSON; `[Interface]` сюда не проходит.
  if (t.startsWith('[')) {
    try {
      final v = jsonDecode(t);
      if (v is List) return jsonEncode(deepSortKeys(v));
    } catch (_) {
      // Не JSON (INI) — ниже, как прежде.
    }
  }
  if (t.contains('\n')) return t;
  final hash = t.indexOf('#');
  return hash < 0 ? t : t.substring(0, hash).trim();
}

/// §401 (D-08x) + §405 + §438 — слияние узлов и папок файла с локальными
/// источниками. Чистая функция: состояние читает и пишет вызывающий.
///
/// **Папки.** У 0.x папка — имя в поле `folder` записи `servers[]`: записи с
/// одинаковым именем становятся одной папкой, «одно имя = одна папка». У 1.0
/// папка — своя запись ([folders]) с `id`, и ключ слияния двухступенчатый
/// (BACKUP.md §9 п. 3): сперва папка с тем же `id` (та же папка, как бы её
/// ни переименовали), затем по имени как есть — но только среди папок,
/// существовавших ДО импорта. Папка, заведённая этим же импортом, по имени
/// не находится: иначе вторая папка-тёзка файла дописалась бы в первую.
/// Совпавшая папка держит свой `id` и имя, а настройки (`enabled`, префикс
/// тегов) берёт из файла; настройки папки 0.x не трогает — их там нет.
///
/// **Узлы.** Идентичность узла — его ТЕЛО, приведённое к канону
/// ([canonicalNodeBody]): корневые дедупятся против корневых, члены — в
/// пределах своей папки (один сервер в двух папках законен). §405 —
/// совпавшее по телу пропускается МОЛЧА и `applied` не растёт, иначе
/// повторный импорт одного файла удваивал бы список. Порядок членов —
/// порядок записей файла; новые встают в конец.
///
/// **Общий `detour` контейнера** (§439, BACKUP.md §9 пп. 1, 3): у папки 1.0
/// берётся из её записи, у подписки — из [sourceDetours]
/// ([mergeBackupSubscriptions]); тег конфига — по той же карте контейнеров,
/// что у ссылок узлов. Флаги политики detour, `ping_*` папки и префикс
/// одиночного узла — настройки LxBox: пока контракт их не объявил (Л2), в файл
/// они не едут и остаются своими; объявленные применяются, когда приехали.
BackupServerMerge mergeBackupServers(
  List<ServerList> lists,
  List<LxServer> incoming, {
  List<LxFolder> folders = const [],
  Map<String, String> sourceIds = const {},
  Map<String, int> addedSources = const {},
  Map<String, NodeLink?> sourceDetours = const {},
  Set<String> rootNames = const {},
}) {
  final merged = lists.toList();
  final takenIds = <String>{for (final l in merged) l.id};
  final stateDirs = StateDirNames.of(merged);
  var applied = 0;
  final touched = <BackupNodeRef>[];
  // Заведённые этим импортом источники → место в файле (подписки приходят
  // уже заведёнными из [mergeBackupSubscriptions]).
  final added = <String, int>{...addedSources};

  // Папки по обоим ключам: первая победившая. Имена папок, заведённых этим
  // импортом из записи 1.0, по имени не находятся.
  final folderById = <String, int>{};
  final folderByName = <String, int>{};
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is! FolderServers) continue;
    folderById.putIfAbsent(l.id, () => i);
    folderByName.putIfAbsent(l.name, () => i);
  }

  // Первый проход по папкам файла — сопоставление и `id` заводимых, ДО
  // вставки: ссылка `detour` вправе метить в папку, объявленную ниже узла, и
  // карта `id` должна быть полной к моменту разбора любого узла.
  final folderIds = <String, String>{};
  final matchedAt = <String, int>{};
  final plannedId = <String, String>{};
  final freshNames = <String>{};
  for (final f in folders) {
    int? at;
    if (f.id.isNotEmpty) at = folderById[f.id];
    if (at == null && !freshNames.contains(f.name)) at = folderByName[f.name];
    final String localId;
    if (at != null) {
      matchedAt[f.key] = at;
      localId = merged[at].id;
    } else {
      localId = _adoptSourceId(f.id, takenIds);
      plannedId[f.key] = localId;
      if (!folderByName.containsKey(f.name)) {
        folderByName[f.name] = -1; // заведётся этим импортом
        freshNames.add(f.name);
      }
    }
    if (f.id.isNotEmpty) folderIds[f.id] = localId;
  }

  // Карта контейнеров для ссылок: подписки (из их слияния) и папки файла.
  final linkIds = {...sourceIds, ...folderIds};

  // §439 — ссылки файла ставятся ПОСЛЕ слияния (NODE_LINK §7.2, §7.3): карта
  // папок, места, куда легли члены, и корень результата известны только
  // тогда. [count] — изменение ссылки считается применённым (у совпавшей
  // папки, чьи прочие настройки не изменились).
  final pendingLinks =
      <({int at, int member, NodeLink? link, bool count})>[];
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is! SubscriptionServers || !sourceDetours.containsKey(l.id)) continue;
    pendingLinks
        .add((at: i, member: -1, link: sourceDetours[l.id], count: false));
  }

  final singleBodies = <String, int>{};
  for (var i = 0; i < merged.length; i++) {
    final l = merged[i];
    if (l is UserServer) {
      singleBodies.putIfAbsent(canonicalNodeBody(l.rawBody), () => i);
    }
  }

  // Второй проход — ОДИН, в порядке файла: папка, её члены, корневые узлы.
  final folderPosition = {for (final f in folders) f.key: f.position};
  final events = <(int, int, int, Object)>[
    for (var i = 0; i < folders.length; i++)
      (folders[i].position, 0, i, folders[i]),
    for (var i = 0; i < incoming.length; i++)
      (
        incoming[i].folderRef.isNotEmpty
            ? (folderPosition[incoming[i].folderRef] ?? incoming[i].position)
            : incoming[i].position,
        1,
        i,
        incoming[i],
      ),
  ]..sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    });

  final folderAtKey = <String, int>{};
  // §439 N2 — куда легли члены папок файла (тег в файле → тег здесь) и
  // группы, чей состав переводится в адреса здесь после всех членов.
  final landings = <(int, String), String>{};
  final autoGroups = <_BackupAutoGroup>[];
  for (final (position, _, _, item) in events) {
    if (item is LxFolder) {
      final at = matchedAt[item.key];
      if (at != null) {
        final local = merged[at] as FolderServers;
        final policy = (item.detourPolicy ?? local.detourPolicy)
            .copyWith(overrideDetour: local.detourPolicy.overrideDetour);
        final pingUrl = item.pingUrl ?? local.pingUrl;
        final pingTimeoutMs = item.pingTimeoutMs ?? local.pingTimeoutMs;
        final changed = local.enabled != item.enabled ||
            local.tagPrefix != item.tagPrefix ||
            local.detourPolicy != policy ||
            local.pingUrl != pingUrl ||
            local.pingTimeoutMs != pingTimeoutMs ||
            local.replace != item.replace;
        if (changed) {
          merged[at] = local.copyWith(
            enabled: item.enabled,
            tagPrefix: item.tagPrefix,
            detourPolicy: policy,
            pingUrl: pingUrl,
            pingTimeoutMs: pingTimeoutMs,
            // Фича 565 фаза B — поле контракта: нет объекта — не свёрнута.
            replace: item.replace,
            clearReplace: item.replace == null,
          );
          applied++;
        }
        pendingLinks
            .add((at: at, member: -1, link: item.detour, count: !changed));
        folderAtKey[item.key] = at;
      } else {
        merged.add(FolderServers(
          id: plannedId[item.key]!,
          name: item.name,
          enabled: item.enabled,
          tagPrefix: item.tagPrefix,
          detourPolicy: item.detourPolicy ?? DetourPolicy.defaults,
          tls: item.tls ?? TlsPolicy.none,
          pingUrl: item.pingUrl,
          pingTimeoutMs: item.pingTimeoutMs,
          replace: item.replace,
        ));
        pendingLinks.add((
          at: merged.length - 1,
          member: -1,
          link: item.detour,
          count: false,
        ));
        folderAtKey[item.key] = merged.length - 1;
        if (folderByName[item.name] == -1) {
          folderByName[item.name] = merged.length - 1;
        }
        added[merged.last.id] = position;
        applied++;
      }
      continue;
    }

    final srv = item as LxServer;
    if (srv.autoGroup != null) {
      final at = srv.folderRef.isNotEmpty
          ? folderAtKey[srv.folderRef]
          : _folder0xAt(merged, srv, folderByName, takenIds, added, position);
      if (at == null) continue;
      applied += _mergeFolderAutoGroup(merged, at, srv, autoGroups);
      continue;
    }
    final body = srv.uri.isNotEmpty
        ? srv.uri
        : (srv.configJson == null ? '' : jsonEncode(srv.configJson));
    if (body.isEmpty) continue;

    if (srv.folderRef.isNotEmpty) {
      // Член папки 1.0: папка обработана раньше своих членов.
      final at = folderAtKey[srv.folderRef];
      if (at == null) continue;
      final count = (merged[at] as FolderServers).members.length;
      applied += _mergeFolderMember(
          merged, at, srv, body, NodeLink.none, touched,
          landings: landings, stateDirs: stateDirs);
      if ((merged[at] as FolderServers).members.length > count) {
        pendingLinks
            .add((at: at, member: count, link: srv.detour, count: false));
      }
      continue;
    }

    if (srv.folder.isEmpty) {
      final key = canonicalNodeBody(body);
      final hit = singleBodies[key];
      if (hit != null) {
        final local = merged[hit] as UserServer;
        // §439 Л2 — объявленные настройки LxBox узла: поле есть — замещает,
        // нет — своё остаётся. Ссылку detour совпавший узел держит.
        final flags = srv.detourPolicy
            ?.copyWith(overrideDetour: local.detourPolicy.overrideDetour);
        final side = (flags != null && flags != local.detourPolicy) ||
            (srv.tagPrefix != null && srv.tagPrefix != local.tagPrefix);
        // §578/§656 — поля записи: `true` из файла, своё не сбрасывается.
        final rec = srv.flagsOver(
          skip: local.skipTailscalePresets,
          local: local.allowLocal,
          lan: local.allowLan,
          gateway: local.allowGateway,
          ownRoutes: local.ownRoutes,
          commandsOff: local.disableTaildropCommands,
          autosaveOff: local.disableTaildropAutosave,
        );
        if (side || rec != null) {
          merged[hit] = local.copyWith(
            detourPolicy: flags,
            tagPrefix: srv.tagPrefix,
            skipTailscalePresets: rec?.skip,
            allowLocal: rec?.local,
            allowLan: rec?.lan,
            allowGateway: rec?.gateway,
            ownRoutes: rec?.ownRoutes,
            disableTaildropCommands: rec?.commandsOff,
            disableTaildropAutosave: rec?.autosaveOff,
          );
          applied++;
        }
        touched.add((list: hit, member: -1));
        continue;
      }
      merged.add(UserServer(
        id: _adoptSourceId(srv.id, takenIds),
        name: srv.name,
        enabled: srv.enabled,
        tagPrefix: srv.tagPrefix ?? '',
        detourPolicy: srv.detourPolicy ?? DetourPolicy.defaults,
        tls: srv.tls ?? TlsPolicy.none,
        origin: UserSource.manual,
        rawBody: body,
        dialect: srv.dialect, // §722; `null` — 0.x, вид от движка
        nodes: _namedNodes(body, srv.name), // §456
        // Фича 478 — прочие warnings записи; вердикт страховки срезан (§489).
        warnings: srv.warnings,
        // §578/§656 — поля записи из файла.
        skipTailscalePresets: srv.skipTailscalePresets,
        allowLocal: srv.allowLocal,
        allowLan: srv.allowLan,
        allowGateway: srv.allowGateway,
        ownRoutes: srv.ownRoutes,
        disableTaildropCommands: srv.disableTaildropCommands,
        disableTaildropAutosave: srv.disableTaildropAutosave,
        stateDirId: stateDirs.adopt(srv.stateDirId),
      ));
      pendingLinks.add((
        at: merged.length - 1,
        member: -1,
        link: srv.detour,
        count: false,
      ));
      singleBodies[key] = merged.length - 1;
      touched.add((list: merged.length - 1, member: -1));
      added[merged.last.id] = position;
      applied++;
      continue;
    }

    // Член папки 0.x: папка — имя.
    final at =
        _folder0xAt(merged, srv, folderByName, takenIds, added, position);
    applied += _mergeFolderMember(merged, at, srv, body, NodeLink.none, touched,
        landings: landings, stateDirs: stateDirs);
  }

  applied += _bindBackupAutoGroups(merged, autoGroups, linkIds, landings);

  final linkOf = _backupLinkMapper(
    merged: merged,
    incoming: incoming,
    folders: folders,
    folderAtKey: folderAtKey,
    folderByName: folderByName,
    ids: linkIds,
    landings: landings,
    rootNames: rootNames,
  );
  for (final p in pendingLinks) {
    final l = merged[p.at];
    final link = p.link == null ? NodeLink.none : linkOf(p.link!, at: p.at);
    if (p.member < 0) {
      if (l.detourPolicy.overrideDetour == link) continue;
      final policy = l.detourPolicy.copyWith(overrideDetour: link);
      merged[p.at] = switch (l) {
        SubscriptionServers s => s.copyWith(detourPolicy: policy),
        UserServer u => u.copyWith(detourPolicy: policy),
        FolderServers f => f.copyWith(detourPolicy: policy),
      };
      if (p.count) applied++;
    } else if (l is FolderServers && p.member < l.members.length) {
      if (l.members[p.member].detour == link) continue;
      merged[p.at] = l.copyWith(
        members: l.members.toList()
          ..[p.member] = l.members[p.member].copyWith(detour: link),
      );
    }
  }

  // Новые источники стоят в хвосте списка (подписки — первыми, их завело
  // слияние подписок); хвост упорядочивается по месту в файле, стабильно.
  final firstNew = merged.indexWhere((l) => added.containsKey(l.id));
  if (firstNew >= 0) {
    final order = [for (var i = firstNew; i < merged.length; i++) i]
      ..sort((a, b) {
        final byPos = added[merged[a].id]!.compareTo(added[merged[b].id]!);
        return byPos != 0 ? byPos : a.compareTo(b);
      });
    final remap = <int, int>{
      for (var k = 0; k < order.length; k++) order[k]: firstNew + k,
    };
    final tail = [for (final i in order) merged[i]];
    merged.replaceRange(firstNew, merged.length, tail);
    for (var t = 0; t < touched.length; t++) {
      final moved = remap[touched[t].list];
      if (moved != null) touched[t] = (list: moved, member: touched[t].member);
    }
  }

  return (
    lists: merged,
    added: added,
    applied: applied,
    folderIds: linkIds,
    touched: touched,
    linkOf: (NodeLink link, {bool legacy = false}) =>
        linkOf(link, legacy: legacy),
  );
}

/// §439 — перевод ссылок файла в адреса здесь (NODE_LINK §7.2, §7.3), общий
/// для detour узлов и контейнеров и позиций цепочек.
///
/// - Пара с `folder_id` папки файла → `id` папки здесь и тег, под которым
///   лёг член ([landings]); S3 — финальный тег группы этой папки вместо
///   сырого при единственном кандидате. Прочий контейнер — по карте [ids],
///   нет в карте — как есть (разбирает сборка).
/// - `{tag}`, занятый корнем результата (одиночный сервер здесь, [rootNames]:
///   Направления, цепочки, служебные теги), не трогается.
/// - S1 — носитель в папке [at], тег — сырой тег члена этой папки (файла или
///   здесь): пара.
/// - Иначе тег сверяется с финальной формой «префикс + тег» членов папок
///   ФАЙЛА (у файла 0.x — и с сырым тегом), и только если там такого имени
///   нет — с членами контейнеров приёмника. Кандидат ровно один — пара;
///   несколько или ни одного — ссылка как есть, без предупреждения.
NodeLink Function(NodeLink link, {int? at, bool legacy}) _backupLinkMapper({
  required List<ServerList> merged,
  required List<LxServer> incoming,
  required List<LxFolder> folders,
  required Map<String, int> folderAtKey,
  required Map<String, int> folderByName,
  required Map<String, String> ids,
  required Map<(int, String), String> landings,
  required Set<String> rootNames,
}) {
  final atByFileId = <String, int>{
    for (final f in folders)
      if (f.id.isNotEmpty && folderAtKey[f.key] != null)
        f.id: folderAtKey[f.key]!,
  };
  final folderByKey = {for (final f in folders) f.key: f};
  // Корень результата — тот же список известных целей, что у правил и
  // `route.final` (D-117): объявленные имена плюс корневые узлы слияния.
  final rootTaken = <String>{...rootNames, ...lxImportRootNodeTags(merged)};

  // Члены папок файла: финальная форма и сырой тег → адреса здесь.
  final fileFinal = <String, Set<NodeLink>>{};
  final fileRaw = <String, Set<NodeLink>>{};
  final fileRawAt = <int, Set<String>>{};
  void addFile(int at, String prefix, String name) {
    if (name.isEmpty || at < 0 || at >= merged.length) return;
    final here =
        NodeLink(folderId: merged[at].id, tag: landings[(at, name)] ?? name);
    for (final form in _fileFinalForms(prefix, name)) {
      (fileFinal[form] ??= {}).add(here);
    }
    (fileRaw[name] ??= {}).add(here);
    (fileRawAt[at] ??= {}).add(name);
  }

  for (final srv in incoming) {
    final name = srv.autoGroup?.tag ?? srv.name;
    if (srv.folderRef.isNotEmpty) {
      final f = folderByKey[srv.folderRef];
      final at = folderAtKey[srv.folderRef];
      if (f != null && at != null) addFile(at, f.tagPrefix, name);
    } else if (srv.folder.isNotEmpty) {
      final at = folderByName[srv.folder];
      if (at != null) addFile(at, '', name);
    }
  }

  // Члены контейнеров приёмника (узлы подписок в хранении не лежат).
  final hereFinal = <String, Set<NodeLink>>{};
  final hereRaw = <String, Set<NodeLink>>{};
  for (final l in merged) {
    if (l is UserServer) continue;
    containerRawTags(l).forEach((_, raw) {
      final here = NodeLink(folderId: l.id, tag: raw);
      (hereFinal[containerFinalForm(l, raw)] ??= {}).add(here);
      (hereRaw[raw] ??= {}).add(here);
    });
  }

  return (NodeLink link, {int? at, bool legacy = false}) {
    if (link.isEmpty) return link;
    if (!link.isRoot) {
      final fileAt = atByFileId[link.folderId];
      if (fileAt != null) {
        final folder = merged[fileAt];
        final landed = landings[(fileAt, link.tag)];
        if (landed != null) return NodeLink(folderId: folder.id, tag: landed);
        final raw = containerRawTags(folder);
        final groupForms = <String, List<String>>{};
        raw.forEach((node, tag) {
          if (node.isGroup) {
            for (final form in _fileFinalForms(folder.tagPrefix, tag)) {
              (groupForms[form] ??= []).add(tag);
            }
          }
        });
        return lowerGroupFinalLink(
          NodeLink(folderId: folder.id, tag: link.tag),
          folder.id,
          raw.values.toSet(),
          groupForms,
        );
      }
      final local = ids[link.folderId];
      return local == null ? link : NodeLink(folderId: local, tag: link.tag);
    }
    final t = link.tag;
    if (rootTaken.contains(t)) return link;
    // S1 — сосед по папке носителя.
    if (at != null && at >= 0 && at < merged.length) {
      final carrier = merged[at];
      if (carrier is FolderServers) {
        if (fileRawAt[at]?.contains(t) ?? false) {
          return NodeLink(
              folderId: carrier.id, tag: landings[(at, t)] ?? t);
        }
        final lifted =
            liftSiblingLink(link, carrier.id, containerRawTagSet(carrier));
        if (!lifted.isRoot) return lifted;
      }
    }
    Set<NodeLink> hits(
      Map<String, Set<NodeLink>> byFinal,
      Map<String, Set<NodeLink>> byRaw,
    ) =>
        {...?byFinal[t], if (legacy) ...?byRaw[t]};
    final fromFile = hits(fileFinal, fileRaw);
    if (fromFile.isNotEmpty) {
      return fromFile.length == 1 ? fromFile.single : link;
    }
    final fromHere = hits(hereFinal, hereRaw);
    return fromHere.length == 1 ? fromHere.single : link;
  };
}


/// Финальные формы тега [raw] члена папки файла с префиксом модели [prefix]
/// для сопоставления ссылок файла (NODE_LINK §7.3, S3): форма LxBox
/// «префикс, пробел, тег» и форма контракта «префикс + тег» — у префикса
/// файла без хвостового пробела (`"d:"`) финальный тег стороны-экспортёра
/// `d:G`, а модель LxBox хранит `d:` и показывает `d: G` (§439 п. 9).
Set<String> _fileFinalForms(String prefix, String raw) => {
      TagResolver.displayTag(prefix, raw),
      if (prefix.isNotEmpty) '$prefix$raw',
    };

/// §456 — узлы нового своего сервера из файла: имя первого — `tag` записи.
List<NodeSpec> _namedNodes(String body, String name) {
  try {
    final nodes = [...parseAll(decode(body), own: true)];
    if (nodes.isNotEmpty) nodes.first.applyRecordName(name);
    return nodes;
  } catch (_) {
    return <NodeSpec>[];
  }
}

/// Член папки [folderAt]: дедуп по канону тела в пределах этой папки, новые
/// в конец. Возвращает, сколько применилось (0 — узнан, применять нечего).
int _mergeFolderMember(
  List<ServerList> merged,
  int folderAt,
  LxServer srv,
  String body,
  NodeLink detour,
  List<BackupNodeRef> touched, {
  Map<(int, String), String>? landings,
  StateDirNames? stateDirs,
}) {
  final folder = merged[folderAt] as FolderServers;
  final canon = canonicalNodeBody(body);
  final hit = folder.members.indexWhere((m) => canonicalNodeBody(m.raw) == canon);
  if (hit >= 0) {
    final here = folder.members[hit].node?.tag ?? '';
    if (srv.name.isNotEmpty && here.isNotEmpty) {
      landings?[(folderAt, srv.name)] = here;
    }
    touched.add((list: folderAt, member: hit));
    // §578/§656 — поля записи: `true` из файла; отсутствие своё не
    // сбрасывает.
    final own = folder.members[hit];
    final rec = srv.flagsOver(
      skip: own.skipTailscalePresets,
      local: own.allowLocal,
      lan: own.allowLan,
      gateway: own.allowGateway,
      ownRoutes: own.ownRoutes,
      commandsOff: own.disableTaildropCommands,
      autosaveOff: own.disableTaildropAutosave,
    );
    if (rec == null) return 0;
    final members = folder.members.toList();
    members[hit] = own.copyWith(
      skipTailscalePresets: rec.skip,
      allowLocal: rec.local,
      allowLan: rec.lan,
      allowGateway: rec.gateway,
      ownRoutes: rec.ownRoutes,
      disableTaildropCommands: rec.commandsOff,
      disableTaildropAutosave: rec.autosaveOff,
    );
    merged[folderAt] = folder.copyWith(members: members);
    return 1;
  }
  final member = FolderMember(
    raw: body,
    dialect: srv.dialect, // §722; `null` — 0.x, вид от движка
    nameHint: srv.name, // §456 — имя записи главнее имени из текста
    enabled: srv.enabled,
    // Фича 478 — прочие warnings записи; вердикт страховки срезан (§489).
    warnings: srv.warnings,
    detour: detour,
    // §578/§656 — поля записи из файла.
    skipTailscalePresets: srv.skipTailscalePresets,
    allowLocal: srv.allowLocal,
    allowLan: srv.allowLan,
    allowGateway: srv.allowGateway,
    ownRoutes: srv.ownRoutes,
    disableTaildropCommands: srv.disableTaildropCommands,
    disableTaildropAutosave: srv.disableTaildropAutosave,
    stateDirId: stateDirs?.adopt(srv.stateDirId) ?? srv.stateDirId,
    tls: srv.tls ?? TlsPolicy.none, // §636
  );
  final here = member.node?.tag ?? '';
  if (srv.name.isNotEmpty && here.isNotEmpty) {
    landings?[(folderAt, srv.name)] = here;
  }
  merged[folderAt] = folder.copyWith(members: [...folder.members, member]);
  touched.add((list: folderAt, member: folder.members.length));
  return 1;
}

/// §707 (контракт 1.1.160) — занятые имена `state_dir_id` хранимых узлов.
/// Новый узел импорта со своим именем держит его, если оно свободно; занятое
/// заменяется на `ts-` + 6 символов [a-z0-9]. Совпавший по телу узел сюда не
/// ходит: у него своё имя, файл его не трогает.
class StateDirNames {
  StateDirNames(this._taken, {Random? random})
      : _random = random ?? Random.secure();

  /// Имена всех хранимых узлов (корень и члены папок).
  factory StateDirNames.of(Iterable<ServerList> lists, {Random? random}) =>
      StateDirNames({
        for (final l in lists)
          if (l is UserServer && l.stateDirId.isNotEmpty)
            l.stateDirId
          else if (l is FolderServers)
            for (final m in l.members)
              if (m.stateDirId.isNotEmpty) m.stateDirId,
      }, random: random);

  final Set<String> _taken;
  final Random _random;

  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// Имя для нового узла: пусто → пусто (своим без поля не генерируется).
  String adopt(String name) {
    if (name.isEmpty) return '';
    var out = name;
    while (_taken.contains(out)) {
      out = 'ts-${String.fromCharCodes([
            for (var i = 0; i < 6; i++)
              _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
          ])}';
    }
    _taken.add(out);
    return out;
  }
}

/// Папка члена 0.x [srv] по имени; заведённая им же папка находится по
/// имени (иначе каждая запись с тем же `folder` заводила бы новую).
int _folder0xAt(
  List<ServerList> merged,
  LxServer srv,
  Map<String, int> folderByName,
  Set<String> takenIds,
  Map<String, int> added,
  int position,
) {
  final at = folderByName[srv.folder];
  if (at != null && at >= 0) return at;
  merged.add(FolderServers(
    id: _adoptSourceId('', takenIds),
    name: srv.folder,
    enabled: true,
    tagPrefix: '',
    detourPolicy: DetourPolicy.defaults,
  ));
  folderByName[srv.folder] = merged.length - 1;
  added[merged.last.id] = position;
  return merged.length - 1;
}

/// §439 N2 — член-группа файла, ждущий перевода состава в адреса здесь.
typedef _BackupAutoGroup = ({
  int folderAt,
  int member,
  LxServer srv,
  bool fresh,
});

/// Член-группа папки [folderAt]. Ссылочный член без тела ключуется тегом
/// (BACKUP.md §9 п. 3): группа с тем же тегом в папке — та же группа, её
/// значение берётся из файла; иначе новая встаёт в конец. Состав переводит
/// [_bindBackupAutoGroups]. Возвращает, сколько применилось сейчас.
int _mergeFolderAutoGroup(
  List<ServerList> merged,
  int folderAt,
  LxServer srv,
  List<_BackupAutoGroup> pending,
) {
  final folder = merged[folderAt] as FolderServers;
  final group = srv.autoGroup!;
  final hit = folder.members.indexWhere(
      (m) => m.node is AutoSelectSpec && m.node!.tag == group.tag);
  if (hit >= 0) {
    pending.add((folderAt: folderAt, member: hit, srv: srv, fresh: false));
    return 0;
  }
  merged[folderAt] = folder.copyWith(members: [
    ...folder.members,
    FolderMember.auto(group, enabled: srv.enabled, warnings: srv.warnings),
  ]);
  pending.add((
    folderAt: folderAt,
    member: folder.members.length,
    srv: srv,
    fresh: true,
  ));
  return 1;
}

/// §439 N2, NODE_LINK §7.2 — состав групп файла → адреса здесь: член своей
/// папки файла получает `id` папки здесь и тег, под которым член лёг
/// ([landings]); член чужого контейнера — `id` по карте [ids] (нет в карте —
/// как есть, разбирает сборка). Совпавшая группа, чьё значение не
/// изменилось, не считается применённой.
int _bindBackupAutoGroups(
  List<ServerList> merged,
  List<_BackupAutoGroup> pending,
  Map<String, String> ids,
  Map<(int, String), String> landings,
) {
  var applied = 0;
  for (final p in pending) {
    final folder = merged[p.folderAt] as FolderServers;
    var group = p.srv.autoGroup!;
    final membership = group.membership;
    if (membership is ExplicitMembers) {
      group = group.copyWith(
        membership: ExplicitMembers([
          for (final l in membership.members)
            if (l.isRoot || l.folderId == p.srv.folderRef)
              NodeLink(
                folderId: folder.id,
                tag: landings[(p.folderAt, l.tag)] ?? l.tag,
              )
            else
              NodeLink(folderId: ids[l.folderId] ?? l.folderId, tag: l.tag),
        ]),
      );
    }
    final member = FolderMember.auto(group,
        enabled: p.srv.enabled, warnings: p.srv.warnings);
    if (folder.members[p.member] == member) continue;
    merged[p.folderAt] = folder.copyWith(
      members: folder.members.toList()..[p.member] = member,
    );
    if (!p.fresh) applied++;
  }
  return applied;
}

/// §439 — позиции цепочек файла → ссылки здесь.
///
/// Хоп 1.0 — ссылка `{folder_id?, tag}` с сырым тегом (BACKUP.md §4, §6):
/// `folder_id` переводится по карте контейнеров, тег — туда, куда лёг член,
/// `{tag}` на члена контейнера поднимается до пары ([BackupServerMerge.linkOf],
/// NODE_LINK §7.3). Позиция 0.x — строка (финальный или сырой тег), читается
/// корневой ссылкой и поднимается тем же правилом с проверкой сырого тега.
/// Без [linkOf] переводится только `folder_id` по [folderIds]. Контейнера нет
/// ни в файле, ни здесь — ссылка ввозится как есть: недостижимую позицию
/// разбирает сборка (`chain_hop_missing`), а не импорт.
List<SourceChain> resolveBackupChainHops(
  LxBackupFile file,
  List<ServerList> lists,
  Map<String, String> folderIds, {
  BackupLinkMapper? linkOf,
}) {
  NodeLink map(NodeLink link, {required bool legacy}) => linkOf != null
      ? linkOf(link, legacy: legacy)
      : _remapLink(link, folderIds);

  return [
    for (final c in file.chains)
      if (file.chainHops[c.tag] case final links?)
        c.copyWith(hops: [for (final l in links) map(l, legacy: false)])
      else if (linkOf != null)
        c.copyWith(hops: [for (final l in c.hops) map(l, legacy: true)])
      else
        c,
  ];
}

/// §439 — `folder_id` ссылки файла → `id` контейнера здесь по карте [ids].
NodeLink _remapLink(NodeLink link, Map<String, String> ids) {
  if (link.isRoot) return link;
  final local = ids[link.folderId];
  return local == null ? link : NodeLink(folderId: local, tag: link.tag);
}

/// §438 — ось порядка импорта (BACKUP.md §9 п. 7): корневые правила [rules].
///
/// Номера у LxBox — свои, и относительный порядок обязан сохраниться; при
/// этом ось у сторон одна по раскладке шаблона (голова 0, пресеты 950–990,
/// пользовательская зона 1000–1100, широкие перехватчики 1110–1150), и
/// LxBox номер из файла сохраняет. Порядок правил от этого не меняется: он и
/// задан номерами, а при равных корневое правило стоит раньше узлового, как у
/// сборки. Перенумерация подряд от 1000 (так делает лаунчер) сохранила бы
/// порядок самого импорта, но у LxBox сломала бы то, что идёт после:
/// правило, добавленное руками, встаёт по `nextUserRuleNum` за максимум
/// пользовательской зоны — за бывшие перехватчики 1110+, — а пресет,
/// включённый позже со своим номером из шаблона (950–990), — перед бывшей
/// головой `traffic-processing`, и `sniff` перестаёт быть первым правилом.
/// v2.23.2 номера файла сохранял.
///
/// Крайние случаи (BACKUP.md §9 п. 7, форма лаунчера `5cbcc436`):
///
///  * **ни одно корневое правило не размечено** — номера не проставляются
///    вовсе, правила возвращаются как есть. Разметку даёт загрузка
///    (`markRuleOrder`): пресету — номер шаблона (голова 0, 950–990 …),
///    остальным — подряд от [kUserRuleNumStart]. Номера от 1000 всем подряд
///    поставили бы пресеты-перехватчики и голову `traffic-processing` за
///    пользовательскими правилами;
///  * **размечены не все** — неразмеченные корневые встают в хвост оси в
///    порядке файла (без номера разметка при загрузке поставила бы их поверх
///    размеченных), но не ниже [kUserRuleNumStart]: хвост файла с номерами
///    шаблона не уводит правило пользователя в зону пресетов.
///
/// Возвращает корневые правила в порядке оси; номера проставляются в тех же
/// объектах (как во всём §370).
List<CustomRule> renumberBackupAxis(List<CustomRule> rules) {
  if (rules.every((r) => r.orderNum == null)) return rules;

  var last = -1;
  void see(int? n) {
    if (n != null && n > last) last = n;
  }

  for (final r in rules) {
    see(r.orderNum);
  }
  var next = last + 1 < kUserRuleNumStart ? kUserRuleNumStart : last + 1;
  for (final r in rules) {
    r.orderNum ??= next++;
  }
  return sortRulesByAxis(rules);
}
