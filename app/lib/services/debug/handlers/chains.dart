import '../../../models/config_node.dart';
import '../../../models/source_chain.dart';
import '../../../screens/chain_edit/chain_form_validation.dart';
import '../../../screens/chain_edit/chain_hop_candidate.dart';
import '../../../screens/chain_edit/chain_hop_targets.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §393 C — `/chains/*` — CRUD источников-цепочек (SPEC 110).
///
/// Тонкая обёртка над `SettingsStorage.addChain / updateChain / deleteChain`
/// (отдельного `ChainMutations` нет — у цепочек нет зеркала в контроллере,
/// которое надо ресинкать: единственный in-memory буфер живёт в
/// `subscriptions_screen` и перечитывается с диска после каждой мутации).
///
/// ВАЛИДАЦИЯ — тот же рубеж, что у формы (§393 L4). `sing-box check` НЕ ловит
/// ошибки старта цепочки (снятый `tls.utls` на reality-узле, вложенная
/// цепочка на позиции ≥1 — конфиг проверку ПРОХОДИТ и падает на `run`), а
/// ядро отвергает такой конфиг ЦЕЛИКОМ: пользователь остаётся без VPN, а не
/// без одного маршрута. Поэтому write'и прогоняются через
/// [validateChainForm] — ровно то, что запирает кнопку «сохранить» в форме, —
/// и блокирующая находка даёт 400 с её машинным кодом. Debug API не имеет
/// права быть дырой в обход рубежа, через который обязан пройти UI.
///
/// Окружение для валидации собирается тем же [collectChainHopTargets], что и
/// форма: цели берутся из ПОСЛЕДНЕГО СОБРАННОГО КОНФИГА
/// (`HomeController.state.configModel`) — там теги окончательные. Контроллера
/// может не быть (Debug API поднимается раньше UI) → пустой [ParsedConfig],
/// `targetsKnown == false`: инварианты ядра (позиций <2, дубли, самоссылка,
/// пустая позиция) проверяются всегда, а «позиция потеряна» — только когда
/// снимок целей есть, иначе рабочая цепочка была бы объявлена битой.
///
/// Routes:
/// - `GET    /chains`            → list (SourceChain.toJson, snake_case)
/// - `POST   /chains`            → create (body: `{"tag":"...","label":"..."}`
///                                + опционально любые PATCH-поля; `tag`
///                                только при создании)
/// - `GET    /chains/{tag}`      → single
/// - `PATCH  /chains/{tag}`      → partial update
/// - `DELETE /chains/{tag}`      → remove
///
/// Все write'ы принимают `?rebuild=true`: цепочка — узел конфига, правка
/// маршрута config-significant.
Future<DebugResponse> chainsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  if (path == '/chains') {
    return switch (req.method) {
      'GET' => _list(),
      'POST' => _create(req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /chains'),
    };
  }

  if (path.startsWith('/chains/')) {
    final tag = path.substring('/chains/'.length);
    if (tag.isEmpty || tag.contains('/')) {
      throw NotFound('chains path: $path');
    }
    return switch (req.method) {
      'GET' => _single(tag),
      'PATCH' => _update(tag, req, ctx),
      'DELETE' => _delete(tag, req, ctx),
      _ => throw BadRequest('method ${req.method} not allowed on /chains/{tag}'),
    };
  }

  throw NotFound('chains path: $path');
}

Future<DebugResponse> _list() async {
  final chains = await SettingsStorage.getChains();
  return JsonResponse(chains.map((c) => c.toJson()).toList());
}

Future<DebugResponse> _single(String tag) async {
  final chains = await SettingsStorage.getChains();
  final c = chains.where((c) => c.tag == tag).firstOrNull;
  if (c == null) throw NotFound('chain: $tag');
  return JsonResponse(c.toJson());
}

Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final label = fieldString(body, 'label');
  // Тег опционален — отсутствует → первый свободный `chain-N`
  // ([nextChainTag]). Валидацию коллизий (пустой / служебный / дубль по
  // цепочкам И Направлениям / тёзка `<tag>-auto`) делает storage тем же
  // `directionTagConflict`, что зовёт форма создания, — правила не
  // дублируются здесь.
  final tag = fieldString(body, 'tag');
  final SourceChain created;
  try {
    created = await SettingsStorage.addChain(label: label, tag: tag);
  } on StateError catch (e) {
    // Конфликт тега — precondition: юзер может выбрать другой и повторить.
    // Машинный код причины (`duplicate`/`reserved`/…) внутри сообщения.
    throw Conflict(e.message);
  }

  // Остальные поля body — как PATCH сразу после создания (один вызов вместо
  // POST+PATCH). Пустая цепочка ядру не годится (нужно минимум две позиции),
  // и требовать двух запросов ради одного маршрута смысла нет.
  var chain = created;
  final patched = _applyPatch(chain, body, tagConsumed: true);
  if (patched != null) {
    chain = patched;
    // Валидируем, ТОЛЬКО когда маршрут задан. Пустая цепочка законна как
    // промежуточное состояние: тот же путь проходит UI — диалог создаёт
    // запись с нулём позиций и сразу открывает форму, которая запрёт
    // сохранение, пока позиций меньше двух. Запретить пустую здесь значило
    // бы сделать `POST /chains` без тела невозможным.
    if (chain.hops.isNotEmpty) await _requireValid(chain, ctx);
    try {
      await SettingsStorage.updateChain(chain);
    } on StateError catch (e) {
      throw Conflict(e.message);
    }
  }

  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({...chain.toJson(), ...extras}, status: 201);
}

Future<DebugResponse> _update(String tag, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final chains = await SettingsStorage.getChains();
  final chain = chains.where((c) => c.tag == tag).firstOrNull;
  if (chain == null) throw NotFound('chain: $tag');

  final next = _applyPatch(chain, body) ?? chain;
  // Пустая цепочка (0 позиций) — законное промежуточное состояние, как в UI:
  // запись создана, маршрут ещё не набран. Всё остальное — через рубеж.
  if (next.hops.isNotEmpty) await _requireValid(next, ctx);
  try {
    await SettingsStorage.updateChain(next);
  } on StateError catch (e) {
    throw Conflict(e.message);
  }
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({...next.toJson(), ...extras});
}

Future<DebugResponse> _delete(String tag, DebugRequest req, DebugContext ctx) async {
  final chains = await SettingsStorage.getChains();
  if (!chains.any((c) => c.tag == tag)) throw NotFound('chain: $tag');
  await SettingsStorage.deleteChain(tag);
  final extras = await maybeRebuild(req, ctx);
  // Ссылки на удалённый тег в позициях ДРУГИХ цепочек не вычищаются
  // (`_deleteChain`): снятие позиции превращает маршрут в другой маршрут.
  // Сборка деградирует такую цепочку целиком (`chain_hop_missing`) — здесь
  // перечисляем, кого это задело, чтобы агент увидел последствие сразу, а не
  // по пропавшему узлу.
  final dangling = [
    for (final c in chains)
      if (c.tag != tag && c.hops.contains(tag)) c.tag,
  ];
  return JsonResponse({
    'ok': true,
    'action': 'chains-delete',
    'tag': tag,
    'dangling_refs': dangling,
    ...extras,
  });
}

/// §393 L4 — тот же рубеж, что запирает «сохранить» в форме.
///
/// Блокирующая находка → 400 с её машинным кодом ([ChainIssueCode]) и текстом
/// формы. Предупреждения и справки (потерянная позиция, detour на входе)
/// write не запрещают — это осознанный выбор пользователя, а не сломанный
/// конфиг: ровно та же граница, что у [chainFormCanSave].
Future<void> _requireValid(SourceChain chain, DebugContext ctx) async {
  final chains = await SettingsStorage.getChains();
  final directions = await SettingsStorage.getDirections();
  // Список цепочек с ПОДСТАВЛЕННЫМ кандидатом: порядок объявления нормативен
  // (ссылка только на цепочку выше), а редактируемая версия может отличаться
  // от лежащей на диске.
  final ordered = [
    for (final c in chains)
      if (c.tag == chain.tag) chain else c,
  ];
  final config = ctx.home?.state.configModel ?? const ParsedConfig.empty();
  final candidates = chainHopLookup(collectChainHopTargets(
    config: config,
    directions: directions,
    chains: ordered,
    selfTag: chain.tag,
  ));
  final issues = validateChainForm(
    ChainFormState.of(chain),
    ChainFormContext(
      candidates: candidates,
      targetsKnown: chainTargetsKnown(config),
      // Тег занят кем-то ДРУГИМ: Направлением, другой цепочкой, узлом
      // конфига. Свой тег не считается — цепочка занимает своё же имя.
      takenTags: {
        for (final d in directions) d.tag,
        for (final c in ordered)
          if (c.tag != chain.tag) c.tag,
        for (final t in config.byTag.keys)
          if (t != chain.tag) t,
      },
      originalTag: chain.tag,
    ),
  );
  final blocker = issues.where((i) => i.blocks).firstOrNull;
  if (blocker != null) {
    throw BadRequest('chain ${chain.tag} rejected '
        '(${blocker.code.name}): ${blocker.message}');
  }
}

/// Применяет PATCH-поля body к [c]. Возвращает новую цепочку или null, если
/// ни одно изменяемое поле не передано. Бросает [BadRequest] на невалидные
/// значения.
SourceChain? _applyPatch(SourceChain c, Map<String, dynamic> body,
    {bool tagConsumed = false}) {
  // POST принимает `tag` (пожелание для СОЗДАНИЯ, уже применён выше); PATCH —
  // нет: после создания тег immutable, на него ссылаются фильтры Направлений,
  // `route_final` и позиции других цепочек.
  if (!tagConsumed && body.containsKey('tag')) {
    throw const BadRequest(
        'field "tag" is immutable (outbound id, edit "label" instead)');
  }

  final label = fieldString(body, 'label');
  final enabled = fieldBool(body, 'enabled');
  final hops = fieldStringList(body, 'hops');
  final idleTimeout = fieldString(body, 'idle_timeout');

  // Трёхзначность `strip_evasion` (см. [SourceChain.stripEvasion]): ключа нет
  // = не трогаем, null = вернуть умолчание ядра, bool = явный выбор
  // пользователя. Обычный `fieldBool` не отличил бы null от отсутствия.
  var clearStripEvasion = false;
  bool? stripEvasion;
  if (body.containsKey('strip_evasion')) {
    final raw = body['strip_evasion'];
    if (raw == null) {
      clearStripEvasion = true;
    } else if (raw is bool) {
      stripEvasion = raw;
    } else {
      throw BadRequest(
          'field "strip_evasion" must be bool or null, got ${raw.runtimeType}');
    }
  }

  // `strip` — ЗАМЕНА каталога, не merge: ключей всего четыре, они видны
  // целиком, и «убрать галку» иначе было бы невыразимо. Неизвестный ключ —
  // отказ, а не молчаливый отсев: ядро считает его ошибкой старта, и принять
  // его здесь значило бы отдать пользователю цепочку, которой он не получит.
  Map<String, bool>? strip;
  if (body.containsKey('strip')) {
    final raw = body['strip'];
    if (raw is! Map) {
      throw BadRequest('field "strip" must be object, got ${raw.runtimeType}');
    }
    strip = {};
    for (final e in raw.entries) {
      final key = e.key;
      if (key is! String || !kChainStripDefault.containsKey(key)) {
        throw BadRequest('field "strip": unknown key "$key" '
            '(allowed: ${kChainStripKeys.join(', ')})');
      }
      final v = e.value;
      if (v is! bool) {
        throw BadRequest(
            'field "strip.$key" must be bool, got ${v.runtimeType}');
      }
      strip[key] = v;
    }
  }

  // `rewrite` — произвольный JSON merge-patch по типам outbound'ов (RFC 7396),
  // формой не правится: `null` внутри патча УДАЛЯЕТ ключ, и «чистка пустого»
  // сломала бы round-trip. Проверяем только форму верхнего уровня.
  Map<String, dynamic>? rewrite;
  if (body.containsKey('rewrite')) {
    final raw = body['rewrite'];
    if (raw is! Map) {
      throw BadRequest('field "rewrite" must be object, got ${raw.runtimeType}');
    }
    rewrite = <String, dynamic>{};
    for (final e in raw.entries) {
      final key = e.key;
      if (key is! String) {
        throw BadRequest('field "rewrite" keys must be strings, got ${key.runtimeType}');
      }
      rewrite[key] = e.value;
    }
  }

  final changed = label != null ||
      enabled != null ||
      hops != null ||
      idleTimeout != null ||
      stripEvasion != null ||
      clearStripEvasion ||
      strip != null ||
      rewrite != null;
  if (!changed) return null;

  return c.copyWith(
    label: label,
    enabled: enabled,
    hops: hops,
    idleTimeout: idleTimeout,
    stripEvasion: stripEvasion,
    clearStripEvasion: clearStripEvasion,
    strip: strip,
    rewrite: rewrite,
  );
}
