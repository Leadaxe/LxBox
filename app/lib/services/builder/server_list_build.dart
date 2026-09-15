import '../../config/consts.dart';
import '../../models/emit_context.dart';
import '../../models/server_list.dart';
import '../../models/auto_select.dart';
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';
import '../node_hash.dart';
import '../node_identity.dart';
import '../node_link_address.dart';
import '../safe_regex.dart';
import '../tag_resolver.dart';
import 'core_chain_capability.dart';
import 'node_link_resolve.dart';

/// Сборка одной подписки в контекст `EmitContext`.
///
/// Живёт в builder-слое, чтобы модель (`lib/models/server_list.dart`)
/// осталась чистой data: без зависимостей на `SingboxEntry`/`EmitContext`.
extension ServerListBuild on ServerList {
  /// 1. Для каждого сервера решает, нужно ли пропустить детур.
  /// 2. Зовёт `server.getEntries(ctx, skipDetour)`.
  /// 3. На каждом entry: allocateTag; detour-ссылка политики (D-112)
  ///    откладывается до второго прохода сборки (`ctx.deferDetour`), финальный
  ///    тег узла записывается под его адресом (`ctx.linkTargets`).
  /// 4. Регистрирует entry в ctx: addEntry, selector/auto-списки по политике.
  void build(EmitContext ctx) {
    if (!enabled) return;
    // §237/§239 — у папки члены несут ЛИЧНЫЙ detour; интра-ссылки (пары с
    // `id` этой папки) дают план: цепочки внутри папки, exempt-набор
    // папочного override, register-гейт ⚙-целей.
    final plan = switch (this) {
      final FolderServers f => FolderDetourPlan(f),
      _ => null,
    };
    // §439 — адреса узлов: сырые теги контейнера (у одиночного сервера адрес
    // корневой — финальный тег).
    final targets = ctx.linkTargets;
    final addressTags = (targets == null || this is UserServer)
        ? null
        : containerRawTags(this);
    void noteAddress(NodeSpec node, String baseTag, String finalTag,
        {bool group = false}) {
      if (targets == null) return;
      if (this is UserServer) {
        targets.noteRootNode(finalTag);
        return;
      }
      final raw = addressTags?[node] ?? baseTag.trim();
      if (group) {
        targets.noteGroup(
            id, raw, TagResolver.displayTag(tagPrefix, raw), finalTag);
      } else {
        targets.noteMember(id, raw, finalTag);
      }
    }

    // §283 — per-node disable подписки: выключенная нода видна в UI (с
    // toggle), но в конфиг не эмитится. Ключ — идентичность узла (§400: тег,
    // уникализированный внутри источника, см. node_hash.dart). Папки
    // фильтруют members по enabled в конструкторе модели; у подписки nodes
    // нужен UI полным — поэтому фильтр здесь, в билдере.
    //
    // Карта считается от ПОЛНОГО списка узлов источника: уникализация
    // тёзок зависит от соседей, включая выключенных (иначе выключение узла
    // переименовывало бы следующего тёзку и снимало отметку с него).
    final disabledHashes = switch (this) {
      final SubscriptionServers s when s.disabledHashes.isNotEmpty =>
        s.disabledHashes,
      _ => null,
    };
    final identities =
        disabledHashes == null ? null : sourceNodeIdentities(nodes);

    // §322 — узлы автовыбора собираем ВТОРЫМ проходом: их `outbounds` — теги
    // членов, а те присваиваются `allocateTag` только в цикле ниже. Копим
    // соответствие «узел → его итоговый тег», по нему потом резолвим пулы.
    final autoSelects = <(AutoSelectSpec, int)>[];
    final resolvedTags = <NodeSpec, String>{};

    for (var i = 0; i < nodes.length; i++) {
      final server = nodes[i];
      // Узел без идентичности (группа §322, безымянный) в карте отсутствует —
      // отметки у него быть не может, и пустой ключ на него не натягиваем.
      final identity = identities?[server];
      if (identity != null && disabledHashes!.containsKey(identity)) {
        continue;
      }
      if (server is AutoSelectSpec) {
        autoSelects.add((server, i));
        continue;
      }
      // §435 / контракт ## 13 — гейт ядра (`tailscale_core_unsupported`):
      // ядро без `with_tailscale` отвергает конфиг ЦЕЛИКОМ на неизвестном
      // типе endpoint'а, и один такой узел оставил бы пользователя без VPN.
      // Узел живёт в состоянии, при сборке выбрасывается с warning'ом; его
      // секции не инжектятся (в `noteEmitted` он не попадает).
      if (server is TailscaleSpec && !ctx.coreSupportsTailscale) {
        ctx.warn(tailscaleUnsupportedByCoreLine(
          TagResolver.displayTag(tagPrefix, server.tag),
          ctx.coreVersion,
        ));
        continue;
      }
      final policy =
          plan == null ? detourPolicy : plan.policyFor(i, detourPolicy);

      // §073: replaceMode = override + replace toggle ON. Append mode
      // (default false) keeps raw chain (skipDetour: false) и подставляет
      // overrideDetour хвостом цепочки.
      final link = policy.overrideDetour;
      final replaceMode = link.isNotEmpty && policy.replaceDetourChain;
      final skipDetour = !policy.useDetourServers || replaceMode;

      final raw = server.getEntries(ctx, skipDetour: skipDetour);
      final main = raw.main;
      final detours = raw.detours;

      // Allocate tags (детуры первыми — чтобы main мог сослаться на tag).
      final detourBases = <String>[];
      for (final d in detours) {
        detourBases.add(d.tag);
        d.map['tag'] = ctx.allocateTag(TagResolver.displayTag(tagPrefix, d.tag));
      }
      final mainBase = main.tag;
      main.map['tag'] =
          ctx.allocateTag(TagResolver.displayTag(tagPrefix, mainBase));
      // §322 — итоговый тег нужен второму проходу: пул автовыбора ссылается
      // на членов уже ПОСЛЕ префикса и уникализации.
      resolvedTags[server] = main.map['tag'] as String;
      // §435 — тот же финальный тег нужен инъекции секций узла (`@self`).
      ctx.noteEmitted(server, main.map['tag'] as String);
      // §439 — адрес узла, затем звеньев его родной цепочки (сырой тег узла
      // сильнее тёзки-звена).
      noteAddress(server, mainBase, main.tag);
      for (var k = 0; k < detours.length; k++) {
        if (this is UserServer) {
          targets?.noteRootNode(detours[k].tag);
        } else {
          targets?.noteMember(id, detourBases[k].trim(), detours[k].tag);
        }
      }

      // Применить detour policy. Ссылка разрешается вторым проходом сборки:
      // финальный тег цели известен только когда собраны все источники.
      void defer(SingboxEntry holder) => ctx.deferDetour(DeferredDetour(
            holder: holder,
            link: link,
            carrier: main,
            entries: [...raw.all],
            node: server,
          ));
      // Ключ `detour` держателя не снимается до второго прохода: разрешённая
      // ссылка пишется на то же место в map (порядок ключей конфига прежний),
      // а не разрешённая роняет узел целиком.
      if (replaceMode) {
        // REPLACE — цепочка дропнута (skipDetour=true), main → override.
        defer(main);
      } else if (!policy.useDetourServers) {
        main.map.remove('detour');
      } else if (link.isNotEmpty) {
        // §073 APPEND — нативная цепочка сохранена, override хвостом.
        if (detours.isEmpty) {
          // Цепочки нет в raw config → 1-hop (как replace).
          defer(main);
        } else {
          // node → detours.first → ... → detours.last → overrideDetour
          main.map['detour'] = detours.first.tag;
          defer(detours.last);
        }
      } else if (detours.isNotEmpty) {
        main.map['detour'] = detours.first.tag;
      }

      // Регистрация: outbounds/endpoints через sealed-switch внутри ctx.
      for (final e in raw.all) {
        ctx.addEntry(e);
      }

      // Preset-группы:
      //   - main без `⚙` префикса (обычный endpoint) — всегда в selector и auto;
      //   - main с `⚙` (detour-маркер из парсинга подписки / `TagResolver`;
      //     §094 убрал ручной node_settings toggle) — регистрируется по
      //     per-server политике, как обычные chained-detours. Default обе OFF →
      //     main-as-detour скрыт в selector и ✨auto, доступен только как звено.
      //   - chained-detours (raw.detours) — как раньше, по той же политике.
      //   - §239 — член-цель ИНТРА-detour другого члена = звено цепочки папки:
      //     регистрируется по тем же register-тогглам (симметрия с ⚙ подписки).
      final isMainAsDetour = main.tag.startsWith(kDetourTagPrefix) ||
          (plan?.isChainLink(i) ?? false);
      // §435 — Tailscale без `exit_node` в интернет не выпускает и «страной»
      // не является (NODE_SECTIONS.md §6): в пул Направлений не идёт ни при
      // какой политике. В `endpoints[]` он эмитирован (`addEntry` выше) —
      // законная цель `detour`, `outbound` правила узла и позиции цепочки.
      final tailnetOnly = server is TailscaleSpec && !server.hasExitNode;
      if (tailnetOnly) {
        // ничего: ни selector, ни auto
      } else if (!isMainAsDetour) {
        ctx.addToSelectorTagList(main);
        ctx.addToAutoList(main);
      } else {
        if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(main);
        if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(main);
      }
      for (final d in detours) {
        if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(d);
        if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(d);
      }
    }

    // §322 — второй проход: узлы автовыбора. Их состав — теги членов ЭТОГО же
    // контейнера, известные только теперь.
    //
    // §439 — явный член — ссылка `{folder_id, tag}` на СЫРОЙ тег: у папки это
    // тег члена, у подписки и сервера — тег, уникализированный в источнике
    // (группы из тела адресуют членов им).
    final rawTags = this is FolderServers ||
            !autoSelects.any((a) => a.$1.membership is ExplicitMembers)
        ? null
        : sourceNodeRawTags(nodes);
    for (final (spec, _) in autoSelects) {
      final shown = TagResolver.displayTag(tagPrefix, spec.tag);
      final members = resolveAutoSelectMembers(
        spec,
        resolvedTags,
        containerId: id,
        rawTags: rawTags,
        warn: (line) => ctx.warn('Auto node "$shown": $line'),
      );
      // Пустой urltest роняет старт ядра (validator.dart) — достижимо, если
      // все члены выключены (§283) или подписка обновилась и пул опустел.
      // Не эмитим вовсе: безопаснее, чем пустая группа. Явный состав, не
      // давший ни одного члена, называется (NODE_LINK §5.1); правило, ничего
      // не поймавшее, — законная настройка.
      if (members.isEmpty) {
        if (spec.membership is ExplicitMembers) {
          ctx.warn('Auto node "$shown" was skipped: none of its members '
              'resolved, an empty group would stop the VPN core');
        }
        continue;
      }

      final entry = spec.emit(ctx.vars);
      // §272/§322 — глобальный «Passive health check»: пропускаем пробу, пока
      // узел и так подтверждён своим трафиком. Для пула из 15 узлов это
      // главная статья расхода батареи. Эмитим только при true (omitempty:
      // отсутствие = false = апстрим), как Направление в build_config.
      if (ctx.passiveCheck) entry.map['passive_check'] = true;
      entry.map['tag'] =
          ctx.allocateTag(TagResolver.displayTag(tagPrefix, spec.tag));
      noteAddress(spec, spec.tag, entry.tag, group: true);
      entry.map['outbounds'] = members;
      ctx.addEntry(entry);
      ctx.addToSelectorTagList(entry);
      // В ✨auto НЕ добавляем, и в urltest-двойник Направления группа тоже не
      // попадёт — билдер отсекает её по `type: urltest` (build_config).
    }
  }
}

/// §322 §3.3 — состав пула по режиму членства.
///
/// [resolved] — узлы контейнера с их ИТОГОВЫМИ тегами (после префикса и
/// `allocateTag`). Выключенных (§283) здесь уже нет: их отфильтровал билдер.
///
/// §439 — явный член — [NodeLink] на сырой тег члена контейнера [containerId]
/// (пустой `folderId` — свой контейнер, NODE_LINK §5.1 № 8). Сырой тег узла —
/// [rawTags] (уникализированный в источнике, `sourceNodeRawTags`), без карты
/// — `NodeSpec.tag` (член папки); у тёзок побеждает первый. Член, который не
/// разрешился, отсекается строкой в [warn].
List<String> resolveAutoSelectMembers(
  AutoSelectSpec spec,
  Map<NodeSpec, String> resolved, {
  String containerId = '',
  Map<NodeSpec, String>? rawTags,
  void Function(String line)? warn,
}) {
  final out = <String>[];
  switch (spec.membership) {
    case ExplicitMembers(:final members):
      // Порядок задаёт СПИСОК, а не обход контейнера: пользователь его
      // осмысленно упорядочил (или он приехал из selector).
      final byRaw = <String, String>{};
      for (final e in resolved.entries) {
        final raw = rawTags == null ? e.key.tag : rawTags[e.key];
        if (raw != null && raw.isNotEmpty) byRaw.putIfAbsent(raw, () => e.value);
      }
      for (final link in members) {
        if (!link.isRoot && link.folderId != containerId) {
          // Группа не выходит за свой контейнер (§322 §2).
          warn?.call('member "${link.tag}" was dropped: it is not a node of '
              'this container');
          continue;
        }
        final tag = byRaw[link.tag];
        if (tag == null) {
          // Выключен, удалён, исчез из подписки — один исход (NODE_LINK §5.1 № 3).
          warn?.call('member "${link.tag}" was dropped: it has no node '
              '"${link.tag}"');
          continue;
        }
        if (!out.contains(tag)) out.add(tag);
      }
    case RuleMembers(:final include, :final exclude):
      final inc = tryCompileRegex(include);
      final exc = tryCompileRegex(exclude);
      // §321 P6 — синонимы этого узла: теги провайдера, которые он видел в
      // СВОЁМ элементе подписки. Когда они есть, пул ограничен ими: правило
      // из `selector` написано в границах одного конфига, и матчить им по
      // всему контейнеру нельзя (тег `proxy` есть у 31 элемента Liberty).
      final scoped = spec.tagSynonyms.isNotEmpty;
      final ownKeys = spec.tagSynonyms.values.toSet();
      for (final e in resolved.entries) {
        final key = nodeIdentityKey(e.key);
        if (scoped && !ownKeys.contains(key)) continue;
        // Имена для матчинга: итоговый тег, базовый тег и теги провайдера
        // (правило из `selector` написано именно на них).
        final names = <String>[
          e.value,
          e.key.tag,
          ...spec.tagSynonyms.entries
              .where((s) => s.value == key)
              .map((s) => s.key),
        ];
        if (ruleAccepts(names, inc, exc)) out.add(e.value);
      }
  }
  return out;
}

/// §239 — план detour-структуры папки. Считается один раз на build:
///
/// - **Интра-ссылка**: личный detour (или папочный override) — пара с `id`
///   ЭТОЙ папки (D-112). Сама ссылка не переписывается: финальный тег цели
///   подставляет второй проход сборки (`node_link_resolve.dart`).
/// - **Циклы** интра-рёбер для структуры плана рвутся (замыкающее ребро не
///   считается звеном и не даёт exempt-закрытия); сама ссылка остаётся и
///   на втором проходе роняет участников кольца с предупреждением. Основной
///   guard — в контроллере (`setMemberDetour`), здесь страховка от ручного
///   бэкапа.
/// - **Exempt-набор**: если папочный override указывает в СВОЕГО члена X,
///   X и всё достижимое из него по интра-рёбрам ведут себя как policy=Use
///   (личные сохраняются, папочный не применяется) — иначе `…→X→…→X`.
/// - **isChainLink**: член-цель чужого интра-detour (для register-гейта).
class FolderDetourPlan {
  FolderDetourPlan(FolderServers folder) : _personal = folder.nodeDetours {
    final n = folder.nodes.length;
    final raw = containerRawTags(folder);
    final rawIndex = <String, int>{};
    for (var i = 0; i < n; i++) {
      final t = raw[folder.nodes[i]];
      if (t != null) rawIndex.putIfAbsent(t, () => i);
    }
    int? intraIndex(NodeLink l) =>
        l.folderId == folder.id ? rawIndex[l.tag] : null;

    // Интра-рёбра (self-ссылка ребром не считается).
    _edge = List<int?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final j = intraIndex(_personal[i]);
      if (j != null && j != i) _edge[i] = j;
    }

    // Разрыв циклов (DFS, замыкающее ребро выбрасывается).
    final color = List<int>.filled(n, 0); // 0=нет, 1=в пути, 2=готов
    void dfs(int u) {
      color[u] = 1;
      final v = _edge[u];
      if (v != null) {
        if (color[v] == 1) {
          _edge[u] = null; // цикл — рвём здесь
        } else if (color[v] == 0) {
          dfs(v);
        }
      }
      color[u] = 2;
    }

    for (var i = 0; i < n; i++) {
      if (color[i] == 0) dfs(i);
    }

    _chainLinks = {
      for (final v in _edge) ?v,
    };

    // Папочный override в своего члена → exempt-закрытие.
    final ovIdx = intraIndex(folder.detourPolicy.overrideDetour);
    if (ovIdx != null) {
      final exempt = <int>{};
      int? cur = ovIdx;
      while (cur != null && exempt.add(cur)) {
        cur = _edge[cur];
      }
      _exempt = exempt;
    } else {
      _exempt = const <int>{};
    }
  }

  final List<NodeLink> _personal;
  late final List<int?> _edge;
  late final Set<int> _chainLinks;
  late final Set<int> _exempt;

  /// Член-цель чужого интра-detour → регистрируется как звено (⚙-семантика).
  bool isChainLink(int i) => _chainLinks.contains(i);

  /// Эффективная политика ноды [i] поверх папочной [base] (§237-семантика +
  /// §239 exempt).
  DetourPolicy policyFor(int i, DetourPolicy base) {
    final personal = _personal[i];

    if (_exempt.contains(i)) {
      // Инфраструктура папочного override: как Use — личный сохраняется,
      // папочный не применяется (иначе цикл через цель).
      return base.copyWith(
          overrideDetour: personal, replaceDetourChain: false);
    }

    final folderReplaces =
        base.overrideDetour.isNotEmpty && base.replaceDetourChain;
    if (personal.isNotEmpty && base.useDetourServers && !folderReplaces) {
      return base.copyWith(
          overrideDetour: personal, replaceDetourChain: false);
    }
    return base;
  }
}
