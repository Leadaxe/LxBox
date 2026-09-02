import '../../../models/config_node.dart';
import '../../../models/source_chain.dart';
import '../../../screens/chain_edit/chain_form_validation.dart';
import '../../../screens/chain_edit/chain_hop_candidate.dart';
import '../../../screens/chain_edit/chain_hop_targets.dart';
import '../../probe/chain_layer_probe.dart';
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
/// - `POST   /chains`            → create (body: `{"tag":"..."}` +
///                                опционально любые PATCH-поля; `tag` только
///                                при создании — он же имя цепочки, контракт
///                                0.9.0. Ключ `label` в теле игнорируется)
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
    var tag = path.substring('/chains/'.length);
    // §394 — единственный под-ресурс цепочки: послойная проба. Разбираем до
    // общей проверки «тег без слэша», иначе `/chains/{tag}/probe` уходил бы
    // в 404 вместе с настоящим мусором.
    if (tag.endsWith('/probe')) {
      tag = tag.substring(0, tag.length - '/probe'.length);
      if (tag.isEmpty || tag.contains('/')) {
        throw NotFound('chains path: $path');
      }
      if (req.method != 'GET') {
        throw BadRequest(
            'method ${req.method} not allowed on /chains/{tag}/probe');
      }
      return _probe(tag, req, ctx);
    }
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

/// §394 — чем хендлер меряет слои. Шов ради теста: прогон ходит в ядро через
/// MethodChannel, которого в юнит-тесте нет, а проверять надо СВОЮ логику
/// хендлера (404/409, форма ответа), не чужой транспорт.
ChainLayerProbe Function() chainProbeFactory = ChainLayerProbe.new;

/// §394 — `GET /chains/{tag}/probe` — послойная проба цепочки.
///
/// ТОТ ЖЕ прогон, что блок «Chain positions» вкладки Diagnostics, и намеренно
/// тот же: инструмент автоматизации, который меряет иначе, чем экран,
/// перестаёт быть инструментом отладки экрана.
///
/// Позиции берутся из ПОСЛЕДНЕГО СОБРАННОГО КОНФИГА, а не из записи storage:
/// ядро запустило собранное, служебные теги `<chain>#<i>` регистрирует оно, и
/// мерить надо работающий маршрут. Правленная без пересборки цепочка в
/// storage — это другой маршрут, и проба по нему мерила бы позиции, которых в
/// ядре нет (та же причина, по которой лаунчер спрашивает состав у ядра, а не
/// у диска: `core/debugapi/chain_endpoints.go`).
///
/// Синхронный по ответу: worst-case `positions × timeout_ms` — прогон
/// последовательный по построению (позиция i недостижима иначе как через
/// i-1). При длинной цепочке снижайте `timeout_ms`, чтобы уложиться в
/// request-timeout сервера (30с).
Future<DebugResponse> _probe(
    String tag, DebugRequest req, DebugContext ctx) async {
  final chains = await SettingsStorage.getChains();
  if (!chains.any((c) => c.tag == tag)) throw NotFound('chain: $tag');

  final config = ctx.home?.state.configModel ?? const ParsedConfig.empty();
  final hops = chainHopsFromConfig(config[tag]?.raw);
  if (hops == null) {
    // Цепочка есть в storage, но узлом конфига не стала: выключена,
    // деградировала при сборке (`chain_hop_missing` и родня) или конфиг ещё
    // ни разу не собирался. Ни в одном из случаев её нет в ядре — мерить
    // нечего, и 409 говорит это прямо, а не пустым списком слоёв.
    throw Conflict('chain "$tag" is not in the built config — '
        'it is disabled, degraded at build time, or the config was never '
        'built; there is nothing running to probe');
  }
  if (hops.isEmpty) throw Conflict('chain "$tag" has no positions');

  // Умолчания — те же `ping_options`, что у обычной пробы узла (их подставит
  // сам прогон): расхождение с кнопкой теста сделало бы «почему цифры
  // разные» ложной загадкой.
  final url = req.q('url');
  final timeoutMs = req.qInt('timeout_ms');
  if (timeoutMs != null && timeoutMs <= 0) {
    throw const BadRequest('query param "timeout_ms" must be > 0');
  }

  final ChainProbeReport report;
  try {
    report = await chainProbeFactory().run(tag, hops: hops,
        url: url, timeoutMs: timeoutMs);
  } on ChainProbeUnavailable catch (e) {
    // Туннель выключен — служебных тегов позиций в рантайме нет. Это
    // предусловие, а не сбой: агент включает VPN и повторяет.
    if (e.isVpnDown) {
      throw const Conflict(
          'VPN is down — chain hops exist only in the running core');
    }
    throw Conflict('chain probe unavailable: ${e.reason}');
  }

  return JsonResponse({
    'ok': true,
    'action': 'chain-probe',
    'tag': tag,
    'url': report.url,
    'timeout_ms': report.timeoutMs,
    'layers': [
      for (var i = 0; i < report.layers.length; i++)
        {
          'pos': report.layers[i].pos,
          // Тег позиции и тег, которым слой спрашивался у ядра: второй —
          // схема ядра (`<chain>#<i>`), и агент вправе повторить замер
          // напрямую через /action/urltest.
          'tag': report.layers[i].tag,
          'probe_tag': report.layers[i].probeTag,
          if (report.layers[i].ok)
            'cumulative_ms': report.layers[i].cumulativeMs,
          // Цена именно этого хопа: разность соседних префиксов. Ключа нет,
          // когда её не вычислить (первый слой, обрыв рядом) — ноль читался
          // бы как «хоп бесплатный».
          if (report.deltaAt(i) != null) 'delta_ms': report.deltaAt(i),
          if (report.layers[i].error.isNotEmpty)
            'error': report.layers[i].error,
          if (report.layers[i].notReached) 'not_reached': true,
        },
    ],
  });
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

/// §393 D3 — создание АТОМАРНО: собрать полную запись → провалидировать →
/// записать ОДНОЙ операцией.
///
/// Прежде хендлер звал `addChain` (запись на диск), затем применял поля и
/// только потом валидировал: отказ 400 (один хоп, самоссылка) возвращал
/// ошибку, а в storage оставалась ПУСТАЯ цепочка, которой пользователь не
/// просил. Теперь до записи доходит только то, что прошло рубеж, — «не
/// прошло» не оставляет следов.
///
/// Тег для новой записи выбираем здесь же (первый свободный `chain-N`, если
/// не задан), чтобы валидация видела итоговую запись целиком; коллизии
/// (пустой / служебный / дубль по цепочкам И Направлениям / тёзка
/// `<tag>-auto`) по-прежнему проверяет storage тем же `directionTagConflict`,
/// что зовёт форма создания, — правила не дублируются здесь.
Future<DebugResponse> _create(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final tag = fieldString(body, 'tag');

  final existing = await SettingsStorage.getChains();
  final wanted = (tag ?? nextChainTag([
    ...existing.map((c) => c.tag),
    ...(await SettingsStorage.getDirections()).map((d) => d.tag),
  ]))
      .trim();

  // Черновик записи — ровно то, что ляжет на диск. Ничего ещё не записано.
  var chain = SourceChain(tag: wanted, enabled: true);
  chain = _applyPatch(chain, body, tagConsumed: true) ?? chain;

  // Валидируем, ТОЛЬКО когда маршрут задан. Пустая цепочка законна как
  // промежуточное состояние: тот же путь проходит UI — диалог создаёт запись
  // с нулём позиций и сразу открывает форму, которая запрёт сохранение, пока
  // позиций меньше двух. Запретить пустую здесь значило бы сделать
  // `POST /chains` без тела невозможным.
  if (chain.hops.isNotEmpty) await _requireValid(chain, ctx, isNew: true);

  final SourceChain created;
  try {
    created = await SettingsStorage.createChain(chain);
  } on StateError catch (e) {
    // Конфликт тега — precondition: юзер может выбрать другой и повторить.
    // Машинный код причины (`duplicate`/`reserved`/…) внутри сообщения.
    throw Conflict(e.message);
  }

  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({...created.toJson(), ...extras}, status: 201);
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
  // §393 D2 — каскад: позиции с этим тегом уходят из ОСТАЛЬНЫХ цепочек, сами
  // они остаются. Рекурсия только через цепочки-позиции: удаление A убирает
  // позицию A из B, а B живёт дальше (возможно, укороченной).
  final healed = await SettingsStorage.deleteChain(tag);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'chains-delete',
    'tag': tag,
    // Кого задело и насколько: цепочка ниже двух позиций теперь не эмитится
    // (`chainEmitError`), цепочка 3+ хопов эмитится УКОРОЧЕННЫМ маршрутом.
    // Агент обязан увидеть это в ответе, а не по пропавшему хопу в конфиге.
    'healed': {'chain_positions': healed.positions},
    'chains_touched': healed.touched,
    ...extras,
  });
}

/// §393 L4 — тот же рубеж, что запирает «сохранить» в форме.
///
/// Блокирующая находка → 400 с её машинным кодом ([ChainIssueCode]) и текстом
/// формы. Предупреждения и справки (потерянная позиция, detour на входе)
/// write не запрещают — это осознанный выбор пользователя, а не сломанный
/// конфиг: ровно та же граница, что у [chainFormCanSave].
Future<void> _requireValid(
  SourceChain chain,
  DebugContext ctx, {
  bool isNew = false,
}) async {
  final chains = await SettingsStorage.getChains();
  final directions = await SettingsStorage.getDirections();
  // Список цепочек с ПОДСТАВЛЕННЫМ кандидатом: порядок нормативен (ссылка
  // только на цепочку ВЫШЕ по общему списку источников), а редактируемая
  // версия может отличаться от лежащей на диске.
  //
  // §393 D3 — создаваемой на диске ещё нет: она встанет в КОНЕЦ общего списка
  // (`_createChain`), и валидация обязана видеть её ровно там. Подставить её
  // в начало значило бы разрешить ссылку вперёд, которую сборка потом
  // деградирует, — 201 на цепочку, которая не соберётся.
  final ordered = isNew
      ? [...chains, chain]
      : [
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
        'field "tag" is immutable (outbound id, and the chain\'s only name)');
  }

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

  final changed = enabled != null ||
      hops != null ||
      idleTimeout != null ||
      stripEvasion != null ||
      clearStripEvasion ||
      strip != null ||
      rewrite != null;
  if (!changed) return null;

  return c.copyWith(
    enabled: enabled,
    hops: hops,
    idleTimeout: idleTimeout,
    stripEvasion: stripEvasion,
    clearStripEvasion: clearStripEvasion,
    strip: strip,
    rewrite: rewrite,
  );
}
