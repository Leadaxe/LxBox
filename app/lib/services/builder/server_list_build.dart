import '../../config/consts.dart';
import '../../models/emit_context.dart';
import '../../models/server_list.dart';
import '../../models/auto_select.dart';
import '../../models/node_spec.dart';
import '../node_hash.dart';
import '../node_identity.dart';
import '../safe_regex.dart';
import '../tag_resolver.dart';

/// Сборка одной подписки в контекст `EmitContext`.
///
/// Живёт в builder-слое, чтобы модель (`lib/models/server_list.dart`)
/// осталась чистой data: без зависимостей на `SingboxEntry`/`EmitContext`.
extension ServerListBuild on ServerList {
  /// 1. Для каждого сервера решает, нужно ли пропустить детур.
  /// 2. Зовёт `server.getEntries(ctx, skipDetour)`.
  /// 3. На каждом entry применяет `_updateEntry`: allocateTag,
  ///    подмена поля `detour` по политике подписки.
  /// 4. Регистрирует entry в ctx: addEntry, selector/auto-списки по политике.
  void build(EmitContext ctx) {
    if (!enabled) return;
    // §237/§239 — у папки члены несут ЛИЧНЫЙ detour; интра-ссылки (на членов
    // той же папки) резолвятся планом: цепочки внутри папки, exempt-набор
    // папочного override, разрыв циклов, register-гейт ⚙-целей.
    final plan = switch (this) {
      final FolderServers f => FolderDetourPlan(f),
      _ => null,
    };

    // §283 — per-node disable подписки: выключенная нода видна в UI (с
    // toggle), но в конфиг не эмитится. Ключ — identity-хеш сути узла
    // (переживает refresh и переименования, см. node_hash.dart). Папки
    // фильтруют members по enabled в конструкторе модели; у подписки nodes
    // нужен UI полным — поэтому фильтр здесь, в билдере.
    final disabledHashes = switch (this) {
      final SubscriptionServers s when s.disabledHashes.isNotEmpty =>
        s.disabledHashes,
      _ => null,
    };

    // §322 — узлы автовыбора собираем ВТОРЫМ проходом: их `outbounds` — теги
    // членов, а те присваиваются `allocateTag` только в цикле ниже. Копим
    // соответствие «узел → его итоговый тег», по нему потом резолвим пулы.
    final autoSelects = <(AutoSelectSpec, int)>[];
    final resolvedTags = <NodeSpec, String>{};

    for (var i = 0; i < nodes.length; i++) {
      final server = nodes[i];
      if (disabledHashes != null &&
          disabledHashes.containsKey(nodeIdentityHash(server))) {
        continue;
      }
      if (server is AutoSelectSpec) {
        autoSelects.add((server, i));
        continue;
      }
      final policy =
          plan == null ? detourPolicy : plan.policyFor(i, detourPolicy);

      // §073: replaceMode = override + replace toggle ON. Append mode
      // (default false) keeps raw chain (skipDetour: false) и подставляет
      // overrideDetour хвостом цепочки.
      final replaceMode =
          policy.overrideDetour.isNotEmpty && policy.replaceDetourChain;
      final skipDetour = !policy.useDetourServers || replaceMode;

      final raw = server.getEntries(ctx, skipDetour: skipDetour);
      final main = raw.main;
      final detours = raw.detours;

      // Allocate tags (детуры первыми — чтобы main мог сослаться на tag).
      for (final d in detours) {
        d.map['tag'] = ctx.allocateTag(TagResolver.displayTag(tagPrefix, d.tag));
      }
      main.map['tag'] =
          ctx.allocateTag(TagResolver.displayTag(tagPrefix, main.tag));
      // §322 — итоговый тег нужен второму проходу: пул автовыбора ссылается
      // на членов уже ПОСЛЕ префикса и уникализации.
      resolvedTags[server] = main.map['tag'] as String;

      // Применить detour policy.
      if (replaceMode) {
        // REPLACE — цепочка дропнута (skipDetour=true), main → override.
        main.map['detour'] = policy.overrideDetour;
      } else if (!policy.useDetourServers) {
        main.map.remove('detour');
      } else if (policy.overrideDetour.isNotEmpty) {
        // §073 APPEND — нативная цепочка сохранена, override хвостом.
        if (detours.isEmpty) {
          // Цепочки нет в raw config → 1-hop (как replace).
          main.map['detour'] = policy.overrideDetour;
        } else {
          // node → detours.first → ... → detours.last → overrideDetour
          main.map['detour'] = detours.first.tag;
          detours.last.map['detour'] = policy.overrideDetour;
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
      if (!isMainAsDetour) {
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
    for (final (spec, _) in autoSelects) {
      final members = resolveAutoSelectMembers(spec, resolvedTags);
      // Пустой urltest роняет старт ядра (validator.dart) — достижимо, если
      // все члены выключены (§283) или подписка обновилась и пул опустел.
      // Не эмитим вовсе: безопаснее, чем пустая группа.
      if (members.isEmpty) continue;

      final entry = spec.emit(ctx.vars);
      // §272/§322 — глобальный «Passive health check»: пропускаем пробу, пока
      // узел и так подтверждён своим трафиком. Для пула из 15 узлов это
      // главная статья расхода батареи. Эмитим только при true (omitempty:
      // отсутствие = false = апстрим), как Направление в build_config.
      if (ctx.passiveCheck) entry.map['passive_check'] = true;
      entry.map['tag'] =
          ctx.allocateTag(TagResolver.displayTag(tagPrefix, spec.tag));
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
List<String> resolveAutoSelectMembers(
  AutoSelectSpec spec,
  Map<NodeSpec, String> resolved,
) {
  final out = <String>[];
  switch (spec.membership) {
    case ExplicitMembers(:final keys):
      // Порядок задаёт СПИСОК, а не обход контейнера: пользователь его
      // осмысленно упорядочил (или он приехал из selector).
      final byKey = <String, String>{};
      for (final e in resolved.entries) {
        final k = nodeIdentityKey(e.key);
        if (k != null) byKey[k] = e.value;
      }
      for (final k in keys) {
        final tag = byKey[k];
        // Ключ без узла — член выключен или исчез из подписки. Пропускаем.
        if (tag != null) out.add(tag);
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

/// §239 — план detour-резолюции папки. Считается один раз на build:
///
/// - **Интра-ссылка**: значение личного detour (или папочного override),
///   совпадающее с ГОЛЫМ тегом другого члена → цель внутри папки; display-
///   форма (префикс) подставляется здесь. Иначе значение трактуется как
///   внешний display-таг (§080). Приоритет члена — папочная область ближе.
/// - **Циклы** интра-рёбер рвутся (замыкающее ребро выбрасывается) — основной
///   guard в контроллере (`setMemberDetour`), здесь страховка от ручного
///   бэкапа.
/// - **Exempt-набор**: если папочный override указывает в СВОЕГО члена X,
///   X и всё достижимое из него по интра-рёбрам ведут себя как policy=Use
///   (личные сохраняются, папочный не применяется) — иначе `…→X→…→X`.
/// - **isChainLink**: член-цель чужого интра-detour (для register-гейта).
class FolderDetourPlan {
  FolderDetourPlan(FolderServers folder)
      : _prefix = folder.tagPrefix,
        _personalRaw = folder.nodeDetours {
    final n = folder.nodes.length;
    final bareIndex = <String, int>{};
    for (var i = 0; i < n; i++) {
      bareIndex.putIfAbsent(folder.nodes[i].tag, () => i);
    }

    // Интра-рёбра (self-ссылка ребром не считается → внешняя → heal §172).
    _edge = List<int?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final p = _personalRaw[i];
      if (p.isEmpty) continue;
      final j = bareIndex[p];
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

    // Резолвнутые личные detour'ы: интра → display-форма; интра-кандидат с
    // вырезанным ребром (цикл/self) → '' (не эмитим ссылку — иначе голый тег
    // ушёл бы в конфиг dangling'ом); иначе — внешний display-таг как хранится.
    _personalResolved = List<String>.generate(n, (i) {
      final j = _edge[i];
      if (j != null) return TagResolver.displayTag(_prefix, folder.nodes[j].tag);
      final p = _personalRaw[i];
      if (p.isNotEmpty && bareIndex.containsKey(p)) return '';
      return p;
    });

    // Папочный override: интра-цель → display + exempt-закрытие.
    final ov = folder.detourPolicy.overrideDetour;
    final ovIdx = ov.isEmpty ? null : bareIndex[ov];
    if (ovIdx != null) {
      _overrideResolved =
          TagResolver.displayTag(_prefix, folder.nodes[ovIdx].tag);
      final exempt = <int>{};
      int? cur = ovIdx;
      while (cur != null && exempt.add(cur)) {
        cur = _edge[cur];
      }
      _exempt = exempt;
    } else {
      _overrideResolved = ov;
      _exempt = const <int>{};
    }
  }

  final String _prefix;
  final List<String> _personalRaw;
  late final List<int?> _edge;
  late final Set<int> _chainLinks;
  late final List<String> _personalResolved;
  late final String _overrideResolved;
  late final Set<int> _exempt;

  /// Член-цель чужого интра-detour → регистрируется как звено (⚙-семантика).
  bool isChainLink(int i) => _chainLinks.contains(i);

  /// Эффективная политика ноды [i] поверх папочной [base] (§237-семантика +
  /// §239 exempt/резолюция).
  DetourPolicy policyFor(int i, DetourPolicy base) {
    final personal = _personalResolved[i];

    if (_exempt.contains(i)) {
      // Инфраструктура папочного override: как Use — личный сохраняется,
      // папочный не применяется (иначе цикл через цель).
      return base.copyWith(
          overrideDetour: personal, replaceDetourChain: false);
    }

    final folderReplaces =
        _overrideResolved.isNotEmpty && base.replaceDetourChain;
    if (personal.isNotEmpty && base.useDetourServers && !folderReplaces) {
      return base.copyWith(
          overrideDetour: personal, replaceDetourChain: false);
    }
    if (_overrideResolved != base.overrideDetour) {
      return base.copyWith(overrideDetour: _overrideResolved);
    }
    return base;
  }
}
