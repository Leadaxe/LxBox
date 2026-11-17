part of '../subscription_controller.dart';

/// Операции над папками и их членами (§234 и далее), генератор WARP-узлов
/// (§284) и включение узлов подписки по одному. Вынесено `part`'ом из
/// `subscription_controller.dart` (задача 740) — та же библиотека и тот же
/// `SubscriptionController`, тела методов не менялись. Форма — миксин, а не
/// extension: контроллер подклассят в тестах, публичные методы должны
/// диспатчиться виртуально. Общие с контроллером поля/хелперы объявлены
/// абстрактно; реализацию даёт `SubscriptionController`. Публичные статики
/// доступны как `SubscriptionController.x` через однострочные делегаты в классе.
mixin _FolderOpsMixin on ChangeNotifier {
  // --- surface, предоставляемая SubscriptionController ---
  List<SubscriptionEntry> get _entries;
  set _busy(bool value);
  http.Client? get httpClientForTesting;
  List<ServerList> _lists();
  Future<void> _persist();
  Future<NodeLinkChange?> _relink(
    List<ServerList> before, {
    Map<NodeSpec, NodeSpec> renamed = const {},
    Set<String> goneContainers = const {},
    NodeLinkSubject? subject,
  });

  // ──────────────────────── §234 — Server folders ────────────────────────

  /// §456 — имя члена папки, хранимое полем записи: у INI-источника тег в
  /// тексте не лежит, у ссылки и JSON — лежит (пусто).
  static String memberNameHintFor(NodeSpec n) =>
      sourceDialectOf(n.rawSource) == SourceDialect.wgIni ? n.tag : '';

  /// §439 — члены-группы разобранного входа (sing-box-конфиг с
  /// `urltest`/`selector`) → члены `kind: auto` папки [folderId]. [added]
  /// выровнен с [nodes] 1:1. Ссылка группы на сырой тег члена входа
  /// (`sourceNodeRawTags`) становится парой `{id папки, тег узла члена}`;
  /// член, не ставший узлом папки, из состава уходит.
  static List<FolderMember> _bindAutoMembers(
    List<FolderMember> added,
    List<NodeSpec> nodes,
    String folderId,
  ) {
    if (nodes.length != added.length || !nodes.any((n) => n.isGroup)) {
      return added;
    }
    final rawTags = sourceNodeRawTags(nodes);
    final memberTag = <String, String>{};
    for (var i = 0; i < nodes.length; i++) {
      final raw = rawTags[nodes[i]];
      final tag = added[i].node?.tag ?? '';
      if (!nodes[i].isGroup && raw != null && tag.isNotEmpty) {
        memberTag[raw] = tag;
      }
    }
    return [
      for (var i = 0; i < added.length; i++)
        switch (nodes[i]) {
          final AutoSelectSpec g => FolderMember.auto(
              g.copyWith(
                membership: switch (g.membership) {
                  ExplicitMembers(:final members) => ExplicitMembers([
                      for (final l in members)
                        if (memberTag[l.tag] case final t?)
                          NodeLink(folderId: folderId, tag: t),
                    ]),
                  final RuleMembers m => m,
                },
              ),
              enabled: added[i].enabled,
            ),
          _ => added[i],
        },
    ];
  }

  /// §439 — член-группа, перенесённая в папку [toId]: её явный состав
  /// адресовал узлы папки [fromId], а группа не выходит за свой контейнер.
  /// Пары переезжают на новую папку с теми же тегами — как до §439 ключи
  /// состава искались среди членов папки, куда группа легла.
  static FolderMember _rehomeAutoMember(
      FolderMember m, String fromId, String toId) {
    final g = m.node;
    if (g is! AutoSelectSpec) return m;
    final membership = g.membership;
    if (membership is! ExplicitMembers) return m;
    return FolderMember.auto(
      g.copyWith(
        membership: ExplicitMembers([
          for (final l in membership.members)
            l.isRoot || l.folderId == fromId
                ? NodeLink(folderId: toId, tag: l.tag)
                : l,
        ]),
      ),
      enabled: m.enabled,
    );
  }

  /// Есть ли у raw собственное имя (URI-фрагмент `#name` / JSON `tag`).
  static bool _rawHasOwnName(String raw) {
    final t = raw.trim();
    if (t.startsWith('{')) return t.contains('"tag"');
    return !t.contains('\n') && t.contains('://') && t.contains('#');
  }

  /// Проставить имя в raw-фрагмент: URI → `#fragment`, JSON → `tag`.
  /// Многострочные формы (INI) остаются как есть — caller передаёт `toUri()`.
  /// §455 — публичный: экран узла ставит тег ссылке при Save вкладки Source.
  static String rawWithName(String raw, String name) {
    final t = raw.trim();
    if (t.startsWith('{')) {
      try {
        final m = jsonDecode(t);
        if (m is Map<String, dynamic>) {
          m['tag'] = name;
          return jsonEncode(m);
        }
      } catch (_) {}
      return raw;
    }
    if (t.contains('\n') || !t.contains('://')) return raw;
    final hash = t.indexOf('#');
    final base = hash >= 0 ? t.substring(0, hash) : t;
    return '$base#${Uri.encodeComponent(name)}';
  }

  /// Одиночный сервер из [member] (для ungroup / delete-с-выносом).
  /// §237 — личный detour члена переезжает в overrideDetour одиночного.
  static UserServer _memberToUserServer(FolderMember m) => UserServer(
        id: newUuidV4(),
        name: '',
        enabled: m.enabled,
        tagPrefix: '',
        detourPolicy: m.detour.isEmpty
            ? DetourPolicy.defaults
            : DetourPolicy.defaults.copyWith(overrideDetour: m.detour),
        // Узел тот же объект: реестр ссылок узнаёт в нём бывшего члена.
        origin: UserSource.manual,
        rawBody: m.raw,
        dialect: m.dialect, // §722 — вид едет с текстом
        // §578/§656 — поля записи едут с узлом.
        skipTailscalePresets: m.skipTailscalePresets,
        allowLocal: m.allowLocal,
        allowLan: m.allowLan,
        allowGateway: m.allowGateway,
        ownRoutes: m.ownRoutes,
        disableTaildropCommands: m.disableTaildropCommands, // §707 итер. 9
        disableTaildropAutosave: m.disableTaildropAutosave,
        stateDirId: m.stateDirId, // §707 1.1.160 — тот же узел, имя то же
        tls: m.tls, // §636 — узловая политика едет с узлом
        nodes: [if (m.node != null) m.node!],
      );

  /// Создать пустую папку.
  Future<void> addFolder(String name) async {
    _entries.add(SubscriptionEntry(
      list: FolderServers(
        id: newUuidV4(),
        name: name,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
      ),
      nodeCount: 0,
    ));
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder created: $name');
  }

  /// §284 — имя папки-генератора WARP-узлов. Повторный GENERATE её пересоздаёт.
  static const kScanFolderName = 'WARP GENERATOR';

  /// §284 — заметка о последней генерации (напр. почему пропал MASQUE).
  /// Показывается снеком в визарде. null = без замечаний.
  String? lastScanNote;

  /// §284 — WARP GENERATOR: собирает [seedCount] случайных узлов (Монте-Карло по
  /// {IP × port × protocol{AWG,h3,h2} × SNI × приманка}) поверх ОДНОЙ
  /// регистрации, кладёт в (пере)созданную папку «WARP GENERATOR». Пробы НЕ
  /// гоняет и мёртвые НЕ удаляет — пользователь сам тестирует штатной кнопкой
  /// Test в папке. Возвращает индекс папки в [entries] (для навигации) или null.
  ///
  /// [rng]/[client] инъектируются для тестов.
  Future<int?> generateWarp({
    int seedCount = 100,
    Random? rng,
    WarpClient? client,
    // §305 — override пула из JSON-окна эксперимента. null → bundled asset.
    ScanPool? poolOverride,
  }) async {
    lastScanNote = null;
    final pool = poolOverride ?? (await WarpEndpointPicker.load()).scan;
    if (pool == null) return null;

    // Аккаунты: кеш → или регистрация один раз (обоих типов — для смешанного
    //   посева). Кешированный аккаунт (ручной MASQUE §130) переиспользуем без
    //   реги. Регистрация может частично не удаться — используем что есть.
    final warp = client ?? WarpClient();
    ScanNodeBuilder builder;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      var warpAcc = await SettingsStorage.getWarpAccount();
      warpAcc ??= await _tryRegisterWarp(warp, now);
      var masqueAcc = await SettingsStorage.getMasqueAccount();
      masqueAcc ??= await _tryRegisterMasque(warp, now);
      if (warpAcc == null && masqueAcc == null) return null;
      // §313 — keepalive для WG/AWG-узлов берётся из того же пула, что CIDR/
      // порты/SNI (правится JSON-окном эксперимента без пересборки).
      builder = ScanNodeBuilder(
        warp: warpAcc,
        masque: masqueAcc,
        wgKeepalive: pool.wgKeepalive,
      );
    } finally {
      if (client == null) warp.close();
    }

    // Посев → URI-узлы (пропускаем протоколы без аккаунта) → папка.
    // §305 — v6-кандидаты только если в системе включён IPv6 (иначе мёртвы).
    final allowV6 =
        (await SettingsStorage.getVar('ipv6_enabled', 'false')).toLowerCase() ==
            'true';
    final gen = CandidateGenerator(pool, rng: rng, allowV6: allowV6);
    final seedUris = _candidatesToUris(gen.seed(seedCount), builder);
    if (seedUris.isEmpty) return null;
    return _recreateScanFolder(seedUris);
  }

  Future<WarpAccount?> _tryRegisterWarp(WarpClient warp, String now) async {
    try {
      final acc = await warp.register(nowIso8601: now);
      await SettingsStorage.setWarpAccount(acc);
      return acc;
    } catch (e) {
      AppLog.I.warning('generateWarp: WARP register failed: $e');
      return null;
    }
  }

  Future<MasqueAccount?> _tryRegisterMasque(WarpClient warp, String now) async {
    try {
      final acc = await warp.registerMasque(nowIso8601: now);
      await SettingsStorage.setMasqueAccount(acc);
      return acc;
    } catch (e) {
      AppLog.I.warning('generateWarp: MASQUE register failed: $e');
      lastScanNote = 'MASQUE (h3/h2) unavailable: registration failed — $e';
      return null;
    }
  }

  List<String> _candidatesToUris(List<ScanCandidate> cs, ScanNodeBuilder b) =>
      [for (final c in cs) b.uriFor(c)].whereType<String>().toList();

  /// Индекс папки «WARP GENERATOR» в [_entries] или null.
  int? _scanFolderIndex() {
    for (var i = 0; i < _entries.length; i++) {
      final l = _entries[i].list;
      if (l is FolderServers && l.name == kScanFolderName) return i;
    }
    return null;
  }

  /// §284 — DNS-независимый ping-URL для папки «WARP GENERATOR»: HTTP через сам
  /// тестируемый узел на IP-литерал (без резолва). Кладётся в саму папку
  /// (FolderServers.pingUrl) — Test в папке идёт по нему.
  static const kScanProbeUrl = 'https://1.1.1.1/cdn-cgi/trace';

  /// Пересоздаёт папку «WARP GENERATOR» с заданными узлами. Возвращает её индекс.
  /// Папка несёт свой ping-URL (IP, без DNS) в собственном объекте — при
  /// пересоздании/удалении опции уходят вместе с ней.
  Future<int> _recreateScanFolder(List<String> uris) async {
    final old = _scanFolderIndex();
    if (old != null) _entries.removeAt(old);
    _entries.add(SubscriptionEntry(
      list: FolderServers(
        id: newUuidV4(),
        name: kScanFolderName,
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [for (final u in uris) FolderMember(raw: u)],
        pingUrl: kScanProbeUrl,
        pingTimeoutMs: 3000,
      ),
      nodeCount: uris.length,
    ));
    await _persist();
    notifyListeners();
    return _entries.length - 1;
  }

  /// Удалить папку. [keepServers] = вынести членов одиночными серверами на
  /// место папки (порядок и per-member enabled сохраняются). Авто-узлы
  /// удаляются и при [keepServers]: текста у группы нет, одиночным сервером
  /// она стала бы пустой записью, а её пул — узлы этой папки.
  Future<void> deleteFolderAt(int index, {required bool keepServers}) async {
    if (index < 0 || index >= _entries.length) return;
    final list = _entries[index].list;
    if (list is! FolderServers) return;
    final before = _lists();
    _entries.removeAt(index);
    if (keepServers) {
      _entries.insertAll(
        index,
        list.members.where((m) => m.node?.isGroup != true).map((m) {
          final us = _memberToUserServer(m);
          return SubscriptionEntry(list: us, nodeCount: us.nodes.length);
        }),
      );
    }
    // §439 — при `keepServers` члены остаются одиночными серверами: ссылки
    // на них переписываются с пары на корневой адрес (D-113). Без
    // keepServers уходит вся папка — ссылки на её членов гаснут (D-114).
    await _relink(
      before,
      goneContainers: {if (!keepServers) list.id},
      subject: NodeLinkSubject.of(list),
    );
    await _persist();
    notifyListeners();
    AppLog.I.info(
        'Folder deleted: ${list.name} (${keepServers ? 'servers kept' : 'servers removed'})');
  }

  /// Добавить вход (paste / тело файла) в папку. Вход сплитится на членов
  /// 1:1 по нодам. [nameFallback] — имя для нод без собственного (имя
  /// файла); коллизии внутри вызова получают суффикс « 2», « 3»…
  /// Возвращает '' при успехе, иначе текст ошибки.
  Future<UiMsg?> addMembersToFolder(int index, String input,
      {String? nameFallback}) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);

    List<NodeSpec> nodes;
    // §506 — причины отбраковки записей: без них «серверов не найдено» не
    // отличалось от пустого ввода.
    final dropped = <NodeWarning>[];
    try {
      // §243 — INI-ноды получают имя файла прямо во фрагмент синтетического
      // URI (rawSource) — фолбэк-цикл ниже до них не дойдёт (_rawHasOwnName).
      nodes = parseAll(decode(input.trim()),
          nameHint: nameFallback, dropped: dropped);
    } catch (e) {
      return humanizeError(e);
    }
    if (nodes.isEmpty) {
      final sorted = maskSecretDropWarnings(sortedDropWarnings(dropped));
      if (sorted.isEmpty) return const ErrMsg(ErrKey.noServersFoundInInput);
      return ParseInputRejectedMsg(
        ErrKey.noServersFoundInInput,
        dropped: sorted,
        sourceLabel: inputSourceLabel(input),
      );
    }

    // §741 (контракт 1.1.172) — голое тело JSON с комментариями — один член
    // с текстом как набран: пометки автора остаются в его источнике. Прочие
    // формы — источник узла (§454), как прежде.
    String? typed;
    if (nodes.length == 1 && uncommentedJson(input.trim()) != null) {
      final c = classifySource(input);
      if (!c.wasArray &&
          c.items.length == 1 &&
          c.items.first.dialect.isJson &&
          !c.items.first.isDocument) {
        typed = c.items.first.text;
      }
    }

    final usedNames = <String>{};
    final added = <FolderMember>[];
    for (final n in nodes) {
      if (typed != null) {
        added.add(FolderMember(raw: typed, nameHint: memberNameHintFor(n)));
        continue;
      }
      // §456 — источник члена = источник узла как есть (§454); INI несёт имя
      // через `nameHint`, JSON — в теле. Фолбэк имени файла — только ссылке
      // без своего фрагмента. §439 — группе имя не раздаётся (`kind: auto`).
      var raw = n.rawSource;
      if (!n.isGroup &&
          nameFallback != null &&
          nameFallback.isNotEmpty &&
          sourceDialectOf(raw) == SourceDialect.uri &&
          !_rawHasOwnName(raw)) {
        var candidate = nameFallback;
        var i = 2;
        while (!usedNames.add(candidate)) {
          candidate = '$nameFallback ${i++}';
        }
        raw = rawWithName(raw, candidate);
      }
      added.add(FolderMember(raw: raw, nameHint: memberNameHintFor(n)));
    }
    added.setAll(0, _bindAutoMembers(added, nodes, folder.id));
    entry._replaceList(folder.copyWith(members: [...folder.members, ...added]));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder "${folder.name}": +${added.length} servers');
    return null;
  }

  /// Одноразовый импорт в папку по ссылке: fetch → parse → статичные члены.
  /// Снапшот: meta/auto-update не сохраняются, URL не хранится.
  Future<UiMsg?> addUrlSnapshotToFolder(int index, String url) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    if (entry.list is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    _busy = true;
    notifyListeners();
    try {
      final result = await parseFromSource(UrlSource(url.trim()),
          client: httpClientForTesting);
      if (result.nodes.isEmpty) {
        // §506 — причины из `dropped[]` разбора доезжают и сюда.
        final sorted = maskSecretDropWarnings(sortedDropWarnings(result.dropped));
        if (sorted.isEmpty) return const ErrMsg(ErrKey.noServersFoundAtUrl);
        return ParseInputRejectedMsg(
          ErrKey.noServersFoundAtUrl,
          dropped: sorted,
          sourceLabel: inputSourceLabel(url),
        );
      }
      // Guard после await: entry могли удалить/подменить.
      final cur = entry.list;
      if (cur is! FolderServers || !_entries.contains(entry)) {
        return const ErrMsg(ErrKey.folderNotFound);
      }
      final added = _bindAutoMembers(
          result.nodes
              .map((n) => FolderMember(
                  raw: n.rawSource,
                  nameHint: memberNameHintFor(n)))
              .toList(),
          result.nodes,
          cur.id);
      entry._replaceList(cur.copyWith(members: [...cur.members, ...added]));
      entry.nodeCount = entry.list.nodes.length;
      await _persist();
      AppLog.I.info(
          'Folder "${cur.name}": +${added.length} servers (URL snapshot)');
      return null;
    } catch (e) {
      return humanizeError(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// §283 — вкл/выкл одной ноды подписки. Ключ — идентичность узла (§400:
  /// тег, уникализированный внутри источника, node_hash.dart): переживает
  /// refresh/рестарт и ротацию адреса под тем же именем; переименование ноды
  /// провайдером отметку теряет — имя и есть идентичность. Дубли одного
  /// сервера под РАЗНЫМИ именами — разные узлы, гасятся раздельно. При
  /// выключении lastSeen = now (старт TTL-отсчёта, GC — на успешном сетевом
  /// refresh в _fetchEntryByRef).
  Future<void> toggleSubscriptionNode(int index, NodeSpec node) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    // §400 — идентичность берём из карты источника: она зависит от соседей
    // (тёзки нумеруются `X`, `X-2`). Узла без идентичности выключить нельзя.
    final hash = sourceNodeIdentities(list.nodes)[node];
    if (hash == null) return;
    final next = Map<String, DateTime>.from(list.disabledHashes);
    final enabling = next.containsKey(hash);
    if (enabling) {
      next.remove(hash);
    } else {
      next[hash] = DateTime.now();
    }
    // Фича 478 / PARSING_PRINCIPLES §9.4 — человек включил узел обратно: вердикт ядра
    // стирается, следующий старт проверит узел заново. Выключение рукой
    // вердикта не ставит (его ставит только страховка).
    var nextList = list.copyWith(disabledHashes: next);
    if (enabling) {
      nextList = clearSubscriptionVerdict(nextList, hash);
      unstampCoreRejected(node);
    }
    entry._replaceList(nextList);
    await _persist();
    notifyListeners();
  }

  /// §332 — вкл/выкл ВСЕХ нод подписки разом (кнопка на вкладке Nodes).
  ///
  /// enable: карта отметок очищается целиком — ручные (§283),
  /// правило-отметки (§302) и TTL-хвосты ушедших узлов. DISABLE-правила при
  /// следующем refresh поставят свои отметки заново (правило — источник
  /// истины). disable: merge поверх существующих — TTL-отметки временно
  /// отсутствующих узлов не теряются, GC доделает своё.
  Future<void> setAllSubscriptionNodes(int index,
      {required bool enabled}) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    final Map<String, DateTime> next;
    if (enabled) {
      if (list.disabledHashes.isEmpty) return;
      next = const {};
      // Фича 478 — «включить все» снимает и вердикты: узлы проверятся заново.
      entry._replaceList(list.copyWith(
          disabledHashes: const {}, nodeWarnings: const {}));
      await _persist();
      notifyListeners();
      return;
    } else {
      if (list.nodes.isEmpty) return;
      final now = DateTime.now();
      next = {
        ...list.disabledHashes,
        // Узлы без идентичности (группы §322, безымянные) отметки не
        // получают — их в карте попросту нет.
        for (final id in sourceNodeIdentities(list.nodes).values) id: now,
      };
    }
    entry._replaceList(list.copyWith(disabledHashes: next));
    await _persist();
    notifyListeners();
  }

  /// §388 — вкл/выкл ПАЧКИ нод подписки (bulk-действия по результатам probe:
  /// «Disable unreachable» / «Disable slower than…»). Отметки — та же карта
  /// ручных §283 (identity-хеш, TTL + GC на успешном refresh); ENABLE-правила
  /// фильтров при следующем refresh снимут их (§332 — правило источник
  /// истины), экран предупреждает до действия.
  Future<void> setSubscriptionNodesEnabled(int index, Iterable<NodeSpec> nodes,
      {required bool enabled}) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final list = entry.list;
    if (list is! SubscriptionServers) return;
    // §400 — идентичности от ПОЛНОГО списка источника, а не от переданной
    // пачки: уникализация тёзок считается по соседям, и подмножество дало бы
    // другие номера.
    final identities = sourceNodeIdentities(list.nodes);
    final hashes = {for (final n in nodes) ?identities[n]};
    if (hashes.isEmpty) return;
    final Map<String, DateTime> next;
    if (enabled) {
      next = Map<String, DateTime>.from(list.disabledHashes)
        ..removeWhere((h, _) => hashes.contains(h));
    } else {
      final now = DateTime.now();
      next = {...list.disabledHashes, for (final h in hashes) h: now};
    }
    entry._replaceList(list.copyWith(disabledHashes: next));
    await _persist();
    notifyListeners();
  }

  /// Вкл/выкл одного члена папки.
  Future<void> toggleMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final members = [...folder.members];
    final on = !members[memberIndex].enabled;
    members[memberIndex] = members[memberIndex].copyWith(
      enabled: on,
      // Фича 478 — ручное включение снимает вердикт ядра.
      warnings: on ? dropVerdict(members[memberIndex].warnings) : null,
    );
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// Правка raw-фрагмента члена. Новый raw обязан парситься ≥1 ноды, иначе
  /// откат (возврат текста ошибки, старый член не трогается).
  /// §456 — [nameHint]: имя для INI-текста (поле Tag редактора).
  ///
  /// §722 — [dialect]: вид нового текста из классификации входа
  /// (`prepareNodeDocumentForSave`); не задан — вход, вид определяет движок.
  Future<UiMsg?> updateMemberAt(int index, int memberIndex, String newRaw,
      {String? nameHint, SourceDialect? dialect}) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    // §722 — источник члена в своём диалекте; Save другим диалектом меняет
    // вид записи.
    final trimmed = newRaw.trim();
    final kind = dialect ?? sourceDialectOf(trimmed);
    final hint = nameHint ?? folder.members[memberIndex].nameHint;
    final probe = FolderMember(raw: trimmed, nameHint: hint, dialect: kind);
    if (probe.node == null) {
      return const ErrMsg(ErrKey.memberParseKeepCurrent);
    }
    final before = _lists();
    final members = [...folder.members];
    // §575 — секции из документа в запись не пишутся; прежние секции
    // записи остаются как были.
    final previous = members[memberIndex].node;
    members[memberIndex] = members[memberIndex].copyWith(
      raw: trimmed,
      dialect: kind,
      nameHint: hint,
    );
    var current = members[memberIndex].node;
    // Фича 478 / PARSING_PRINCIPLES §9.4 п. 1 — человек правил тело в редакторе: вердикт
    // ядра привязан к ТЕЛУ, и на изменённом теле он недействителен. Запись
    // стирается И узел включается обратно — тем же составом полей, что у
    // ручного включения (`toggleMemberAt`). Тело то же (правка имени, пробелы)
    // → вердикт держится.
    if (verdictDroppedByEdit(
      warnings: members[memberIndex].warnings,
      before: previous,
      after: current,
    )) {
      members[memberIndex] = members[memberIndex].copyWith(
        enabled: true,
        warnings: dropVerdict(members[memberIndex].warnings),
      );
      current = members[memberIndex].node;
    }
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-113) — правка тела могла сменить тег: ссылки идут за узлом.
    await _relink(before, renamed: {
      if (previous != null && current != null) previous: current,
    });
    await _persist();
    notifyListeners();
    return null;
  }

  /// §439 — добавить в папку узел автовыбора (член `kind: auto`). Члены
  /// группы — ссылки на узлы этой же папки, их собирает редактор.
  Future<UiMsg?> addAutoMemberToFolder(int index, AutoSelectSpec group) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    entry._replaceList(folder.copyWith(
        members: [...folder.members, FolderMember.auto(group)]));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
    AppLog.I.info('Folder "${folder.name}": +1 auto node');
    return null;
  }

  /// §439 — заменить группу члена-группы [memberIndex]; `enabled` члена
  /// остаётся, если не задан [enabled] (§686 — Save вкладки Source пишет
  /// запись целиком, `enabled` в ней тоже).
  Future<UiMsg?> updateAutoMemberAt(
      int index, int memberIndex, AutoSelectSpec group, {bool? enabled}) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final before = _lists();
    final members = [...folder.members];
    final previous = members[memberIndex].node;
    members[memberIndex] =
        FolderMember.auto(group,
            enabled: enabled ?? members[memberIndex].enabled);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-113) — переименование группы переписывает ссылки на неё.
    await _relink(before, renamed: {?previous: group});
    await _persist();
    notifyListeners();
    return null;
  }

  /// Удалить члена из папки (совсем).
  Future<void> removeMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final before = _lists();
    final gone = folder.members[memberIndex];
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-114) — ссылки на удалённого члена гаснут; тёзка, чей сырой тег
    // сдвинулся (`X-2` → `X`), уносит свои ссылки с собой.
    await _relink(before, subject: NodeLinkSubject.member(folder, gone));
    await _persist();
    notifyListeners();
  }

  /// Ручной порядок членов внутри папки (drag-reorder).
  Future<void> reorderMember(int index, int from, int to) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (from < 0 || from >= folder.members.length) return;
    if (to < 0 || to >= folder.members.length) return;
    final before = _lists();
    final members = [...folder.members];
    final m = members.removeAt(from);
    members.insert(to, m);
    entry._replaceList(folder.copyWith(members: members));
    // §439 — перестановка тёзок меняет их сырые теги (`X`/`X-2`).
    await _relink(before);
    await _persist();
    notifyListeners();
  }

  /// Вынести члена из папки в одиночный сервер (вставляется сразу после
  /// папки). Личные prefix/policy папки НЕ наследуются — дефолты. Авто-узел
  /// не выносится (no-op): см. [deleteFolderAt].
  Future<void> ungroupMemberAt(int index, int memberIndex) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (memberIndex < 0 || memberIndex >= folder.members.length) return;
    final member = folder.members[memberIndex];
    if (member.node?.isGroup == true) return;
    final before = _lists();
    final members = [...folder.members]..removeAt(memberIndex);
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    final us = _memberToUserServer(member);
    _entries.insert(
        index + 1, SubscriptionEntry(list: us, nodeCount: us.nodes.length));
    // §439 (D-113) — член стал корневым узлом: пара → корневой адрес.
    await _relink(before);
    await _persist();
    notifyListeners();
  }

  /// §237/§239 — личный detour члена: ссылка на узел (D-112) — сосед по
  /// папке парой с `id` этой папки, прочее — как выбрано в пикере. Отклоняет
  /// self и ребро, замыкающее интра-цикл. Возвращает null при успехе, иначе
  /// ошибку.
  Future<UiMsg?> setMemberDetour(
      int index, int memberIndex, NodeLink detour) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }

    if (detour.isNotEmpty) {
      // Интра-цикл: ребро member→target замыкает петлю, если из target по
      // существующим интра-рёбрам достижим сам member.
      final raw = <String, int>{};
      for (var k = 0; k < folder.members.length; k++) {
        final a = folderMemberAddress(folder, k);
        if (a != null) raw.putIfAbsent(a.tag, () => k);
      }
      int? intra(NodeLink l) => l.folderId == folder.id ? raw[l.tag] : null;
      final target = intra(detour);
      if (target == memberIndex) {
        return const ErrMsg(ErrKey.detourSelf);
      }
      if (target != null) {
        int? edgeOf(int k) {
          if (k == memberIndex) return target; // новое ребро
          final j = intra(folder.members[k].detour);
          return (j != null && j != k) ? j : null;
        }

        final seen = <int>{};
        int? cur = target;
        while (cur != null && seen.add(cur)) {
          if (cur == memberIndex) {
            return const ErrMsg(ErrKey.detourLoopInFolder);
          }
          cur = edgeOf(cur);
        }
      }
    }

    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(detour: detour);
    entry._replaceList(folder.copyWith(members: members));
    await _persist();
    notifyListeners();
    return null;
  }

  /// §636 — узловая TLS-политика члена папки. Возвращает null при успехе,
  /// иначе ошибку.
  Future<UiMsg?> setMemberTls(int index, int memberIndex, TlsPolicy tls) async {
    if (index < 0 || index >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);
    if (memberIndex < 0 || memberIndex >= folder.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    if (folder.members[memberIndex].tls == tls) return null;
    final members = [...folder.members];
    members[memberIndex] = members[memberIndex].copyWith(tls: tls);
    entry._replaceList(folder.copyWith(members: members));
    await _persist();
    notifyListeners();
    return null;
  }

  /// §236 — массовый toggle членов (Disable slower than N ms и т.п.).
  Future<void> setMembersEnabled(
      int index, Set<int> memberIndexes, bool enabled) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    var changed = false;
    final members = [...folder.members];
    for (final i in memberIndexes) {
      if (i < 0 || i >= members.length) continue;
      if (members[i].enabled == enabled) continue;
      members[i] = members[i].copyWith(enabled: enabled);
      changed = true;
    }
    if (!changed) return;
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    await _persist();
    notifyListeners();
  }

  /// §236 — массовое удаление членов (Delete unreachable).
  Future<void> removeMembersAt(int index, Set<int> memberIndexes) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    final members = <FolderMember>[
      for (var i = 0; i < folder.members.length; i++)
        if (!memberIndexes.contains(i)) folder.members[i],
    ];
    if (members.length == folder.members.length) return;
    final before = _lists();
    final gone = [
      for (var i = 0; i < folder.members.length; i++)
        if (memberIndexes.contains(i)) folder.members[i],
    ];
    entry._replaceList(folder.copyWith(members: members));
    entry.nodeCount = entry.list.nodes.length;
    // §439 (D-114) — как одиночное удаление члена, только пачкой.
    await _relink(
      before,
      subject: gone.length == 1
          ? NodeLinkSubject.member(folder, gone.single)
          : NodeLinkSubject.servers(gone.length),
    );
    await _persist();
    notifyListeners();
  }

  /// §236 — применить перестановку членов (Sort by ping). [order] — список
  /// старых индексов в новом порядке; обязан быть полной перестановкой.
  Future<void> applyMembersOrder(int index, List<int> order) async {
    if (index < 0 || index >= _entries.length) return;
    final entry = _entries[index];
    final folder = entry.list;
    if (folder is! FolderServers) return;
    if (order.length != folder.members.length) return;
    if (order.toSet().length != order.length) return;
    if (order.any((i) => i < 0 || i >= folder.members.length)) return;
    final before = _lists();
    entry._replaceList(folder.copyWith(
        members: [for (final i in order) folder.members[i]]));
    // §439 — перестановка тёзок меняет их сырые теги (`X`/`X-2`).
    await _relink(before);
    await _persist();
    notifyListeners();
  }

  /// Перенести члена из папки [fromIndex] в папку [toIndex].
  Future<UiMsg?> moveMemberToFolder(
      int fromIndex, int memberIndex, int toIndex) async {
    if (fromIndex < 0 || fromIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    if (toIndex < 0 || toIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    if (fromIndex == toIndex) return null;
    final fromEntry = _entries[fromIndex];
    final toEntry = _entries[toIndex];
    final from = fromEntry.list;
    final to = toEntry.list;
    if (from is! FolderServers || to is! FolderServers) {
      return const ErrMsg(ErrKey.notAFolder);
    }
    if (memberIndex < 0 || memberIndex >= from.members.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    final before = _lists();
    final moved = from.members[memberIndex];
    final member = _rehomeAutoMember(moved, from.id, to.id);
    final fromMembers = [...from.members]..removeAt(memberIndex);
    fromEntry._replaceList(from.copyWith(members: fromMembers));
    fromEntry.nodeCount = fromEntry.list.nodes.length;
    toEntry._replaceList(to.copyWith(members: [...to.members, member]));
    toEntry.nodeCount = toEntry.list.nodes.length;
    // §439 (D-113) — перенос: `folder_id` меняется, ссылки идут за узлом
    // (группа пересоздаётся с составом на новую папку — узел сопоставляется
    // явно).
    await _relink(before, renamed: {
      if (moved.node != null && member.node != null && moved.node != member.node)
        moved.node!: member.node!,
    });
    await _persist();
    notifyListeners();
    return null;
  }

  /// Перенести одиночный сервер в папку. rawBody сплитится на членов 1:1 по
  /// нодам; личные tag_prefix/detour_policy сервера отбрасываются — действуют
  /// папочные (осознанный trade-off §234). Одиночная запись удаляется.
  Future<UiMsg?> moveServerToFolder(int serverIndex, int folderIndex) async {
    if (serverIndex < 0 || serverIndex >= _entries.length) {
      return const ErrMsg(ErrKey.serverNotFound);
    }
    if (folderIndex < 0 || folderIndex >= _entries.length) {
      return const ErrMsg(ErrKey.folderNotFound);
    }
    final serverEntry = _entries[serverIndex];
    final folderEntry = _entries[folderIndex];
    final server = serverEntry.list;
    final folder = folderEntry.list;
    if (server is! UserServer) {
      return const ErrMsg(ErrKey.onlySingleServersCanBeMoved);
    }
    if (folder is! FolderServers) return const ErrMsg(ErrKey.notAFolder);

    final before = _lists();
    // §237 — личный detour одиночного (overrideDetour) переезжает в члена;
    // прочая политика (register-флаги и т.п.) заменяется папочной.
    final personalDetour = server.detourPolicy.useDetourServers
        ? server.detourPolicy.overrideDetour
        : NodeLink.none;
    final added = server.nodes.isEmpty
        // Битый/пустой raw — переносим как есть (член будет виден и правим).
        ? [
            FolderMember(
                raw: server.rawBody,
                dialect: server.dialect, // §722
                enabled: server.enabled,
                detour: personalDetour,
                // §578/§656 — поля записи едут с узлом.
                skipTailscalePresets: server.skipTailscalePresets,
                allowLocal: server.allowLocal,
                allowLan: server.allowLan,
                allowGateway: server.allowGateway,
                ownRoutes: server.ownRoutes,
                // §707 итер. 9
                disableTaildropCommands: server.disableTaildropCommands,
                disableTaildropAutosave: server.disableTaildropAutosave,
                stateDirId: server.stateDirId, // §707 1.1.160
                tls: server.tls), // §636
          ]
        : _bindAutoMembers([
            for (final (i, n) in server.nodes.indexed)
              FolderMember(
                  raw: n.rawSource,
                  nameHint: memberNameHintFor(n),
                  enabled: server.enabled,
                  detour: personalDetour,
                  // §578/§656 — поля записи едут с узлами.
                  skipTailscalePresets: server.skipTailscalePresets,
                  allowLocal: server.allowLocal,
                  allowLan: server.allowLan,
                  allowGateway: server.allowGateway,
                  ownRoutes: server.ownRoutes,
                  // §707 итер. 9
                  disableTaildropCommands: server.disableTaildropCommands,
                  disableTaildropAutosave: server.disableTaildropAutosave,
                  // §707 1.1.160 — имя каталога одно на узел: только первому,
                  // иначе у членов совпадёт.
                  stateDirId: i == 0 ? server.stateDirId : '',
                  tls: server.tls), // §636
          ], server.nodes, folder.id);
    folderEntry._replaceList(
        folder.copyWith(members: [...folder.members, ...added]));
    folderEntry.nodeCount = folderEntry.list.nodes.length;
    _entries.remove(serverEntry);
    // §439 (D-113) — узлы сервера стали членами папки: корневой адрес →
    // пара. Член разбирает свой текст заново, узел сопоставляется по месту.
    await _relink(before, renamed: {
      for (var k = 0; k < server.nodes.length && k < added.length; k++)
        server.nodes[k]: ?added[k].node,
    });
    await _persist();
    notifyListeners();
    AppLog.I.info(
        'Server moved to folder "${folder.name}" (+${added.length})');
    return null;
  }
}
