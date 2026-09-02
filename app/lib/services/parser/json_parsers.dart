import 'dart:convert';

import '../../models/auto_select.dart';
import '../../models/direction.dart' show UrltestMode;
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../../models/transport_spec.dart';
import '../node_hash.dart';
import 'hysteria2_obfs.dart';
import 'transport.dart';
import 'uri_utils.dart';
import 'utls_fingerprint.dart';

/// §310 — Парсинг одного элемента Xray JSON array в список узлов.
///
/// Раньше элемент сворачивался в ОДИН узел («main» VLESS, остальные —
/// отбрасывались). Провайдеры кладут в элемент несколько равноправных
/// серверов (основной + резервные) — они терялись, подписка приезжала без
/// резерва. Теперь каждый VLESS-outbound становится своим узлом.
///
/// Исключение — outbound'ы, на которые ссылается `sockopt.dialerProxy`: они
/// приезжают как звено цепочки своего владельца и самостоятельным узлом НЕ
/// дублируются (контракт §018 detour-chain не меняется).
///
/// §321 — все поддерживаемые protocol'ы, не только VLESS. Служебные
/// (`freedom`/`blackhole`/`dns`) узлами не становятся; SOCKS — только звено
/// цепочки.
///
/// §404 / контракт D-086 — дедуп идёт ПОСЛЕ конвертации, по подписи
/// `nodeDedupSignature` (эмиссия узла без tag/detour + подпись пути дозвона).
/// Прежний ключ P4 (`protocol|server|port|credential`) считался по сырому
/// JSON и не видел ни транспорта, ни релея: один сервер под двумя SNI и пара
/// «прямая + BYPASS» схлопывались в одну запись. Грубый ключ никуда не делся
/// — он остался ключом ПУЛА §322 (`nodeIdentityKey`, вопрос «какой это
/// сервер»), и в [synonyms] по-прежнему едет он.
///
/// [seen] — накопитель подписей дедупа на весь массив подписки. Запись, уже
/// виденная в этом проходе, пропускается. `null` — дедуп выключен (одиночный
/// элемент вне массива).
/// [ownedBy] — §342: фильтр «эта запись закреплена за этим элементом».
/// Заполняется черновым проходом `parse_all` (приоритет имён §321 P2) и
/// позволяет боевому проходу идти в порядке файла, не теряя имена. Аргумент —
/// та же подпись дедупа, что копится в [seen]. `null` — владение не
/// проверяется (одиночный элемент, тесты).
/// [dropped] — §404 / D-085: причины отбраковки ЦЕЛЫХ узлов, которым не
/// нашлось носителя внутри элемента. `parse_all` вешает их на первый узел
/// подписки, чтобы недостижимый релей не превращался в тихую пропажу.
List<NodeSpec> parseXrayElement(
  Map<String, dynamic> element, {
  Set<String>? seen,
  Map<String, String>? synonyms,
  bool Function(String signature)? ownedBy,
  List<NodeWarning>? dropped,
}) {
  final outbounds = element['outbounds'];
  if (outbounds is! List) return const [];

  // §321 P1 — payload = всё, кроме служебных. Неподдерживаемый protocol
  // отсеется позже в _xrayToSpec (с warning), но в payloadCount он учтён:
  // сортировка P2 считает намерение провайдера, а не наши возможности.
  final payloadAll = outbounds
      .whereType<Map<String, dynamic>>()
      .where(
        (o) =>
            !_kXrayServiceProtocols.contains(o['protocol']?.toString() ?? ''),
      )
      .toList();
  if (payloadAll.isEmpty) return const [];

  // §404 — таблица «тег outbound'а → сам outbound» на весь элемент. Нужна
  // рекурсивному обходу цепочки: звено ищет своё следующее звено по тегу, и
  // цель может лежать где угодно в `outbounds` (в т.ч. среди служебных — те
  // отсеиваются уже внутри обхода).
  final byTag = <String, Map<String, dynamic>>{};
  for (final o in outbounds.whereType<Map<String, dynamic>>()) {
    final t = o['tag']?.toString() ?? '';
    // Первый с таким тегом и побеждает: Xray сам резолвит dialerProxy по
    // первому совпадению, дубли тегов в одном конфиге — ошибка провайдера.
    if (t.isNotEmpty) byTag.putIfAbsent(t, () => o);
  }

  // dialerProxy-ссылки: цели исключаются из самостоятельных узлов.
  final dialerRefOf = <Map<String, dynamic>, String>{};
  final dialerTargets = <String>{};
  for (final ob in payloadAll) {
    // `is`-проверки, не касты: streamSettings может приехать строкой (см.
    // комментарий у _xrayAutoSelect) — каст уронил бы парсинг всей подписки.
    final stream = ob['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    final ref = sockopt is Map ? sockopt['dialerProxy']?.toString() : null;
    if (ref != null && ref.isNotEmpty) {
      dialerRefOf[ob] = ref;
      dialerTargets.add(ref);
    }
  }

  // Порядок: «main» первым (dialerProxy → тег `proxy` → первый), чтобы у
  // существующих подписок первый узел остался тем же, что и до §310.
  //
  // Из кандидатов выпадают ЦЕЛИ дозвона: релей самостоятельным узлом
  // подписки не становится, он живёт звеном цепочки владельца.
  //
  // §404 — исключение из исключения: цель, попавшая в КОЛЬЦО, целью быть не
  // может. Звено достижимо от владельца по цепочке дозвона; участник кольца
  // не достижим ни от кого снаружи — «владельца», который бы его вобрал, не
  // существует. Отсеять такой outbound здесь значит потерять узел МОЛЧА, без
  // `DialerProxyUnusableWarning`: он исчезал из подписки, и пользователю
  // никто не говорил почему. Кольцо длины 1 (`dialerProxy` = собственный тег)
  // — частный случай той же проверки.
  //
  // Прочие цели, включая промежуточные звенья многохопа со своим
  // `dialerProxy`, из кандидатов выпадают как раньше: они живут звеньями
  // цепочки владельца, а не самостоятельными узлами подписки.
  bool inDialerCycle(Map<String, dynamic> ob) {
    final start = ob['tag']?.toString() ?? '';
    if (start.isEmpty) return false;
    final seenTags = <String>{start};
    var ref = dialerRefOf[ob];
    while (ref != null && ref.isNotEmpty) {
      if (ref == start) return true;
      if (!seenTags.add(ref)) return false; // чужое кольцо, не своё
      final next = byTag[ref];
      if (next == null) return false;
      ref = dialerRefOf[next];
    }
    return false;
  }

  final candidates = payloadAll
      .where((o) =>
          !dialerTargets.contains(o['tag']?.toString()) || inDialerCycle(o))
      .toList();
  if (candidates.isEmpty) return const [];
  final mainIdx = candidates.indexWhere((o) => dialerRefOf.containsKey(o)) >= 0
      ? candidates.indexWhere((o) => dialerRefOf.containsKey(o))
      : (candidates.indexWhere((o) => o['tag'] == 'proxy') >= 0
            ? candidates.indexWhere((o) => o['tag'] == 'proxy')
            : 0);
  final ordered = [
    candidates[mainIdx],
    for (var i = 0; i < candidates.length; i++)
      if (i != mainIdx) candidates[i],
  ];

  final remarks = element['remarks']?.toString() ?? '';
  final extended = _prettyJson(element);

  // §322 — схема имён зависит от того, что в элементе. `remarks` без добавки
  // достаётся ровно ОДНОЙ сущности: группе, если она есть; иначе —
  // единственному узлу. При нескольких узлах без группы `remarks` не получает
  // никто, все идут с тегом (раньше — с индексом, §310).
  // `is`-проверки, не касты: `routing` мог приехать строкой, а `balancers` —
  // объектом. Каст уронил бы парсинг всей подписки (см. _xrayAutoSelect).
  final elRouting = element['routing'];
  final elBalancers = elRouting is Map ? elRouting['balancers'] : null;
  final hasBalancer = elBalancers is List && elBalancers.isNotEmpty;
  // `solo` — по ИСХОДНОМУ числу узлов, не по выжившим после дедупа (§321 P3):
  // если провайдер положил в элемент несколько серверов, `remarks` описывает
  // весь набор, а не того одного, кто случайно уцелел. Иначе имя элемента
  // достаётся произвольному выжившему и уезжает при следующем обновлении.
  final soloNode = !hasBalancer && ordered.length == 1;
  // Теги, встречающиеся в элементе больше одного раза: `remarks <tag>` их не
  // разведёт, нужен индекс (провайдер зовёт все узлы `proxy` — случай §310).
  final tagUses = <String, int>{};
  for (final ob in ordered) {
    final t = ob['tag']?.toString().trim() ?? '';
    if (t.isNotEmpty) tagUses[t] = (tagUses[t] ?? 0) + 1;
  }

  final result = <NodeSpec>[];
  // §321 P5 — протоколы элемента, которые мы не умеем: висят на первом
  // выжившем узле, чтобы пользователь видел, что провайдер прислал больше.
  final unsupported = <String>{};
  // §404 P3 — узлы, отбракованные из-за недостижимого релея. Вешаем их
  // причины на первого выжившего ЭТОГО элемента (как P5); если не выжил
  // никто — причины уже лежат в `dropped` и достанутся подписке целиком.
  final rejected = <NodeWarning>[];
  for (var i = 0; i < ordered.length; i++) {
    final ob = ordered[i];
    try {
      // §321 P6 — тег провайдера → ключ ПУЛА (грубая четвёрка `nodeIdentityKey`,
      // не подпись дедупа §404: `selector` провайдера называет сервер, а не
      // конкретную запись). Копим ДО пропуска дубля: именно у дублей теги и
      // различаются («Испания» = `proxy`, «Лучший» =
      // `proxy-45-196-208-40-direct`), а §322 резолвит пул по чужим тегам.
      final identity = _xrayIdentity(ob);
      final obTag = ob['tag']?.toString() ?? '';
      if (identity != null && obTag.isNotEmpty) synonyms?[obTag] = identity;

      // §310 — имя разводим на парсинге: `allocateTag` уникализирует теги лишь
      // на build'е (суффикс `-N`), а в списке узлов пользователь иначе увидит
      // несколько одинаковых строк. Одиночный узел — имя ровно как до §310.
      // Индекс `i` берётся из `ordered` (до дедупа): иначе имена поедут —
      // второй выживший получил бы i=0 и назвался как `remarks` без суффикса.
      final label = _elementLabel(
        remarks: remarks,
        ob: ob,
        index: i,
        solo: soloNode,
        tagUses: tagUses,
      );
      final spec = _xrayToSpec(ob, label);
      // §321 P5 — неподдержанный protocol не исчезает молча: узел не собрался,
      // но провайдер его прислал. Warning вешаем на СОСЕДА по элементу (у
      // NodeWarning нет носителя без узла); если соседей нет — элемент выпадает
      // молча (документированное ограничение §321 P5, spec §Известные дыры).
      if (spec == null) {
        final proto = ob['protocol']?.toString() ?? '';
        if (proto.isNotEmpty) unsupported.add(proto);
        continue;
      }

      // §302 — исходник узла для UI («Source» на экране узла) и для правил по
      // JSON-телам: compact = сам outbound, extended = весь элемент как пришёл
      // от провайдера (dns/inbounds/routing соседи). rawUri для таких узлов —
      // синтетическая заглушка `xray://<tag>`, источником служить не может.
      final compact = _prettyJson(ob);

      // §321/§368/§404 — цепочка релеев. `dialerProxy` в Xray живёт в
      // `streamSettings.sockopt`, то есть технически возможен у любого
      // протокола (на практике встречается у VLESS/Trojan); `withChained`
      // покрывает все типы, кроме группы — та цепочку не несёт. Звено само
      // может звонить через следующее звено (§404 п.4) — строим рекурсивно.
      final ref = dialerRefOf[ob];
      NodeSpec? chained;
      if (ref != null) {
        chained = _xrayBuildChain(ob, byTag, ref);
        // §404 / D-085 — недостижимая цель роняет ВЛАДЕЛЬЦА целиком. Узел с
        // прямым путём тут был бы молчаливой деанонимизацией: провайдер
        // завернул дозвон в релей именно потому, что прямой путь зарезан.
        if (chained == null) {
          // `ownerTag` — СОБСТВЕННЫЙ тег outbound'а: им контракт называет
          // отвергнутую запись в `dropped[].ref` (D-088). `label` для этого
          // не годится — он приходит из `remarks` элемента и на многоузловом
          // элементе одинаков у всех узлов.
          final w = DialerProxyUnusableWarning(label, ref, ownerTag: obTag);
          dropped?.add(w);
          rejected.add(w);
          continue;
        }
      }

      final node = chained == null ? spec : withChained(spec, chained);

      // §404 / D-086 — дедуп ПОСЛЕ конвертации: подпись считается от готового
      // узла вместе с путём дозвона.
      final signature = nodeDedupSignature(node);
      // §342 — чужая запись: право на неё получил другой элемент (тот, чьё имя
      // осмысленнее). Пропускаем ДО дедупа, чтобы `seen` этого прохода не
      // «застолбил» подпись за нами.
      if (ownedBy != null && !ownedBy(signature)) continue;
      if (seen != null) {
        if (seen.contains(signature)) continue;
        seen.add(signature);
      }

      result.add(
        node
          ..sourceCompact = compact
          ..sourceExtended = extended == compact ? null : extended,
      );
    } catch (_) {
      // §322 «битые формы не роняют парсинг целиком» на гранулярности УЗЛА:
      // мусорный тип поля (`streamSettings: "none"`, `settings: []`) бросает
      // TypeError внутри конвертера — пропускаем этот outbound, соседи по
      // элементу и остальная подписка живут. Протокол — в P5-warning, чтобы
      // пропажа не была молчаливой.
      final proto = ob['protocol']?.toString() ?? '';
      unsupported.add(proto.isEmpty ? 'malformed' : proto);
    }
  }

  // §321 P5 — развешиваем накопленное: по одному warning на протокол,
  // на первом узле элемента (не на каждом — иначе N копий одного сообщения).
  if (unsupported.isNotEmpty && result.isNotEmpty) {
    for (final proto in unsupported) {
      result.first.warnings.add(UnsupportedProtocolWarning(proto));
    }
  }

  // §404 P3 — то же для отбракованных владельцев. Носитель нашёлся внутри
  // элемента → причина висит на нём и из подписочного списка убирается, чтобы
  // пользователь не увидел одно сообщение дважды. Носителя нет → строка
  // остаётся в `dropped` и уедет на первый узел подписки (см. parse_all).
  if (rejected.isNotEmpty && result.isNotEmpty) {
    for (final w in rejected) {
      result.first.warnings.add(w);
      dropped?.remove(w);
    }
  }

  // §322 — балансировщик элемента → узел автовыбора. Ставим ПОСЛЕ узлов:
  // порядок списка = порядок появления, группа логично идёт за своими членами.
  // Синонимы отдаём ТОЛЬКО по тегам этого элемента: `selector: ["proxy"]`
  // написан в границах своего конфига, а тег `proxy` встречается ещё в 30
  // соседних элементах Liberty — общая таблица растащила бы в пул всё подряд.
  final localSyn = <String, String>{};
  for (final o in payloadAll) {
    final t = o['tag']?.toString() ?? '';
    final k = _xrayIdentity(o);
    if (t.isNotEmpty && k != null) localSyn[t] = k;
  }
  final auto = _xrayAutoSelect(element, remarks, localSyn);
  if (auto != null) result.add(auto..sourceExtended = extended);

  return result;
}

/// §322 — `routing.balancers[0]` + `burstObservatory` → узел автовыбора.
///
/// `null`, если балансировщика нет. Несколько балансировщиков в элементе —
/// схема допускает, у Liberty всегда один: берём первый, остальные молча
/// игнорируем.
AutoSelectSpec? _xrayAutoSelect(
  Map<String, dynamic> element,
  String remarks,
  Map<String, String>? synonyms,
) {
  final routing = element['routing'];
  final balancers = routing is Map ? routing['balancers'] : null;
  if (balancers is! List || balancers.isEmpty) return null;
  final b = balancers.first;
  if (b is! Map) return null;

  // Всё ниже — `is`-проверки, не `as`: подписку пишет провайдер, и любое поле
  // может приехать другого типа. Каст бросил бы и уронил парсинг ВСЕЙ
  // подписки, а не только этого пункта (проверено на крайних формах).
  final rawSel = b['selector'];
  final selector = rawSel is List
      ? rawSel.map((e) => '$e').toList()
      : const <String>[];
  final strategy = b['strategy'];
  final strategyMap = strategy is Map ? strategy : const {};
  final rawSettings = strategyMap['settings'];
  final settings = rawSettings is Map ? rawSettings : const {};
  final rawPing = element['burstObservatory'] is Map
      ? (element['burstObservatory'] as Map)['pingConfig']
      : null;
  final ping = rawPing is Map ? rawPing : const {};

  // Стратегия → режим. Xray знает ЧЕТЫРЕ (app/router/config.pb.go,
  // BalancingRule.Strategy): `random` (дефолт), `roundRobin`, `leastPing`,
  // `leastLoad`. `settings` есть только у `leastLoad`.
  //
  // | Xray | наш режим | pool |
  // |---|---|---|
  // | `leastPing` | least_test | — |
  // | `leastLoad`, expected ≤ 1 | least_test | — |
  // | `leastLoad`, expected > 1 | round_robin | expected |
  // | `roundRobin` | round_robin | весь набор |
  // | `random` / нет поля | round_robin | весь набор |
  //
  // `leastPing` → least_test: семантика совпадает («самый быстрый по замерам»).
  //
  // `expected: 1` — «держи ОДНОГО живого», а не «раздавай по пулу»: это тоже
  // наш least_test, балансировщику с пулом из одного нечего балансировать
  // (у Liberty так настроены все шесть «БС»-групп).
  //
  // `leastLoad` с expected > 1 → round_robin — приближение: Xray отбирает по
  // СТАБИЛЬНОСТИ задержки (baselines = допустимое СКО), мы по здоровью и окну
  // от лучшего. Общее — пул из N с раздачей по нему.
  //
  // `random`/`roundRobin` раскладывают по ВСЕМУ набору, размера пула у них
  // нет — берём число членов (0 = «весь набор», см. AutoSelectParams.pool).
  final type = strategyMap['type']?.toString();
  final expected = _asInt(settings['expected']);
  final spreadAll = type == null || type == 'random' || type == 'roundRobin';
  final mode = switch (type) {
    'leastPing' => UrltestMode.leastTest,
    'leastLoad' when expected != null && expected <= 1 => UrltestMode.leastTest,
    _ => UrltestMode.roundRobin,
  };

  final d = const AutoSelectParams();
  final params = AutoSelectParams(
    url: ping['destination']?.toString() ?? d.url,
    interval: ping['interval']?.toString() ?? d.interval,
    idleTimeout: d.idleTimeout,
    mode: mode,
    // §322 — у `random`/`roundRobin` размера пула нет: раскладка по всему
    // набору. Считаем членов элемента — ровно столько, сколько отберёт
    // `selector`; для leastLoad берём `expected` как есть.
    pool: spreadAll ? _payloadCount(element) : (expected ?? d.pool),
    // maxRTT — АБСОЛЮТНЫЙ потолок у Xray, а pool_tolerance — окно от лучшего.
    // Числа переносим 1:1 (решение юзера 30.07.2026): пересчитать точнее
    // нельзя, минимум по пулу на парсинге неизвестен.
    poolTolerance: clampPoolTolerance(
      _goDurationMs(settings['maxRTT']) ?? d.poolTolerance,
    ),
  );

  final label = remarks.isNotEmpty ? remarks : (b['tag']?.toString() ?? 'auto');
  return AutoSelectSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'urltest', 'auto', 0),
    label: label,
    membership: RuleMembers.fromXraySelector(selector),
    params: params,
    tagSynonyms: synonyms == null ? const {} : Map.of(synonyms),
  );
}

/// §322 — сколько прокси-outbound'ов в элементе. Это и есть размер пула для
/// `random`/`roundRobin`: у них своего размера нет, раскладка идёт по всему
/// набору, который отобрал `selector`.
int _payloadCount(Map<String, dynamic> element) {
  final obs = element['outbounds'];
  if (obs is! List) return 0;
  return obs
      .whereType<Map<String, dynamic>>()
      .where(
        (o) =>
            !_kXrayServiceProtocols.contains(o['protocol']?.toString() ?? ''),
      )
      .length;
}

/// §322 — число из значения провайдера: `7`, `7.0` или `"7"`. Не число и не
/// разбираемая строка → `null` (потребитель подставит дефолт).
int? _asInt(Object? v) => switch (v) {
  final num n => n.toInt(),
  final String str => int.tryParse(str.trim()),
  _ => null,
};

/// Go-duration в миллисекунды: `"1500ms"`, `"3s"`, `"2m"`. `null` — не разобрали.
int? _goDurationMs(Object? raw) {
  final s = raw?.toString().trim() ?? '';
  final m = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)$').firstMatch(s);
  if (m == null) return null;
  final v = double.parse(m.group(1)!);
  return switch (m.group(2)) {
    'ms' => v.round(),
    's' => (v * 1000).round(),
    'm' => (v * 60000).round(),
    _ => (v * 3600000).round(),
  };
}

/// Первый («main») узел элемента или `null`. Совместимость с вызовами,
/// которым нужен ровно один узел; полный список даёт [parseXrayElement].
NodeSpec? parseXrayOutbound(Map<String, dynamic> element) {
  final nodes = parseXrayElement(element);
  return nodes.isEmpty ? null : nodes.first;
}

/// §310/§322 — имя узла внутри элемента подписки.
///
/// `remarks` без добавки достаётся ровно ОДНОЙ сущности элемента:
///
/// | что в элементе | группа | узлы |
/// |---|---|---|
/// | 1 узел | — | `remarks` |
/// | N узлов (даже если выживет один) | — | `remarks <тег>` |
/// | N узлов + балансировщик | `remarks` | `remarks <тег>` |
///
/// До §322 первый узел (`i == 0`) всегда брал чистый `remarks` — и когда у
/// элемента был балансировщик, узел с группой дрались за одно имя (Liberty:
/// «Лучший сервер» и «Лучший сервер-1» в списке).
///
/// [solo] — элемент даёт ровно один узел и группы нет.
/// [index] — позиция в ИСХОДНОМ порядке элемента (§321 P3): при пропуске
/// дубля имена не съезжают, второй выживший не занимает имя первого.
/// [tagUses] — сколько раз тег встречается у выживших; при повторе `remarks
/// <тег>` не разводит узлы, и мы падаем на индекс (провайдер зовёт все узлы
/// `proxy` — исходный случай §310).
String _elementLabel({
  required String remarks,
  required Map<String, dynamic> ob,
  required int index,
  required bool solo,
  required Map<String, int> tagUses,
}) {
  if (solo) return remarks;
  final tag = ob['tag']?.toString().trim() ?? '';
  if (remarks.isEmpty) return tag.isNotEmpty ? tag : '${index + 1}';
  // Пустой или неуникальный тег именем не служит — индексный фолбэк §310.
  if (tag.isEmpty || (tagUses[tag] ?? 0) > 1) return '$remarks ${index + 1}';
  return '$remarks $tag';
}

/// §302 — стабильный отступ для показа фрагмента подписки пользователю.
String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

/// §404 п.5 — массив строк из JSON провайдера (`server_ports`). `null`, если
/// поля нет или в нём не массив. Элементы приводятся к строке поштучно:
/// `cast<String>()` на `[443, "20000:30000"]` бросает в момент чтения, и
/// узел уехал бы в catch целиком, хотя порт-диапазон читается прекрасно.
/// Пустые элементы выбрасываются, пустой список схлопывается в `null` —
/// эмиссия пишет поле только при непустом.
List<String>? _stringListOrNull(Object? raw) {
  if (raw is! List) return null;
  final out = <String>[];
  for (final v in raw) {
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out.isEmpty ? null : out;
}

VlessSpec? _xrayVlessToSpec(Map<String, dynamic> o, String remarks) {
  final vnext = (o['settings']?['vnext'] as List?)?.cast<Map>();
  if (vnext == null || vnext.isEmpty) return null;
  final v = vnext.first;
  final server = v['address']?.toString() ?? '';
  final port = (v['port'] as num?)?.toInt() ?? 443;
  final users = (v['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final uuid = user['id']?.toString() ?? '';
  var flow = user['flow']?.toString() ?? '';
  // §335 — постквантовый слой VLESS (ядро: SPEC 032). В Xray-JSON лежит внутри
  // users[0], в конфиге ядра — плоским полем рядом с uuid. Берём как есть.
  final encryption = user['encryption']?.toString().trim() ?? '';
  if (server.isEmpty || uuid.isEmpty) return null;

  var port2 = port;
  var packetEncoding = '';
  final warnings = <NodeWarning>[];
  if (flow == 'xtls-rprx-vision-udp443') {
    flow = 'xtls-rprx-vision';
    packetEncoding = 'xudp';
    port2 = 443;
  }

  final stream = o['streamSettings'] as Map? ?? const {};
  // §281 — fp вне словаря ядра = fatal всего конфига; канонизируем на входе.
  final tls = normalizeTlsFingerprint(
    _xrayTlsFromStream(stream, server),
    warnings,
  );
  final transport = _xrayTransportFromStream(stream);

  // §115 — flow берём из конфига как есть (раньше REALITY+tcp без flow
  // получал навязанный vision → ломались валидные none-сетапы). vision
  // несовместим с транспортом → гасим flow + warning.
  if (flow == 'xtls-rprx-vision' && transport != null) {
    warnings.add(
      VisionWithTransportWarning((stream['network'] ?? 'transport').toString()),
    );
    flow = '';
  }

  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');
  final tag = tagFromLabel(label, 'vless', server, port2);

  return VlessSpec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port2,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    uuid: uuid,
    flow: flow,
    tls: tls,
    transport: transport,
    packetEncoding: packetEncoding,
    encryption: encryption,
    warnings: warnings,
  );
}

/// §321 — служебные outbound'ы Xray: не серверы, узлами не становятся.
const _kXrayServiceProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

/// §321 P4 — идентичность узла: `(protocol, server, port, credential)`.
/// Транспорт и TLS в ключ НЕ входят (решение юзера 30.07.2026): один сервер с
/// двумя разными SNI схлопывается в один узел — берётся первый по порядку P2.
///
/// ИНВАРИАНТ: ключ обязан посимвольно совпадать с `nodeIdentityKey` готового
/// NodeSpec — по нему §322 резолвит состав пула (`server_list_build`) и §302
/// ремапит синонимы. Поэтому протокол, дефолт порта и port-quirk'и зеркалят
/// конвертеры `_xray*ToSpec`, а не сырой JSON.
String? _xrayIdentity(Map<String, dynamic> o) {
  final protocol = o['protocol']?.toString() ?? '';
  final s = o['settings'] as Map? ?? const {};
  String server;
  int port;
  String cred;

  switch (protocol) {
    case 'vless':
    case 'vmess':
      final vnext = (s['vnext'] as List?)?.cast<Map>();
      if (vnext == null || vnext.isEmpty) return null;
      final v = vnext.first;
      server = v['address']?.toString() ?? '';
      port = (v['port'] as num?)?.toInt() ?? 443;
      final users = (v['users'] as List?)?.cast<Map>() ?? const [];
      cred = users.isEmpty ? '' : (users.first['id']?.toString() ?? '');
      // Зеркало quirk'а _xrayVlessToSpec: vision-udp443 переписывает порт
      // узла на 443.
      if (protocol == 'vless' &&
          users.isNotEmpty &&
          users.first['flow']?.toString() == 'xtls-rprx-vision-udp443') {
        port = 443;
      }
    case 'trojan':
    case 'shadowsocks':
      final servers = (s['servers'] as List?)?.cast<Map>();
      if (servers == null || servers.isEmpty) return null;
      final v = servers.first;
      server = v['address']?.toString() ?? '';
      // ss без порта конвертер отбрасывает (port == 0 → null) — ключ с |0|
      // просто ни с чем не совпадёт, как и узла нет.
      port = (v['port'] as num?)?.toInt() ?? (protocol == 'trojan' ? 443 : 0);
      cred = v['password']?.toString() ?? '';
    case 'hysteria':
      // Конвертер отдаёт Hysteria2Spec → protocol в ключе 'hysteria2'.
      final hy = (o['streamSettings'] as Map?)?['hysteriaSettings'];
      server = s['address']?.toString() ?? '';
      port = (s['port'] as num?)?.toInt() ?? 443;
      cred = hy is Map ? (hy['auth']?.toString() ?? '') : '';
      if (server.isEmpty) return null;
      return 'hysteria2|$server|$port|$cred';
    default:
      return null;
  }
  if (server.isEmpty) return null;
  return '$protocol|$server|$port|$cred';
}

/// §321 — диспетчер по `protocol`. Xray-схема ≠ sing-box-схема
/// (`settings.vnext`/`streamSettings` против плоских полей), поэтому
/// `parseSingboxEntry` не переиспользуется — на каждый протокол свой конвертер.
NodeSpec? _xrayToSpec(Map<String, dynamic> o, String remarks) {
  switch (o['protocol']?.toString()) {
    case 'vless':
      return _xrayVlessToSpec(o, remarks);
    case 'trojan':
      return _xrayTrojanToSpec(o, remarks);
    case 'vmess':
      return _xrayVmessToSpec(o, remarks);
    case 'shadowsocks':
      return _xraySsToSpec(o, remarks);
    case 'hysteria':
      return _xrayHy2ToSpec(o, remarks);
    default:
      return null;
  }
}

TrojanSpec? _xrayTrojanToSpec(Map<String, dynamic> o, String remarks) {
  final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
  if (servers == null || servers.isEmpty) return null;
  final v = servers.first;
  final server = v['address']?.toString() ?? '';
  final port = (v['port'] as num?)?.toInt() ?? 443;
  final password = v['password']?.toString() ?? '';
  if (server.isEmpty || password.isEmpty) return null;

  final stream = o['streamSettings'] as Map? ?? const {};
  final warnings = <NodeWarning>[];
  final tls = normalizeTlsFingerprint(
    _xrayTlsFromStream(stream, server),
    warnings,
  );
  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');

  return TrojanSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'trojan', server, port),
    label: label,
    server: server,
    port: port,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    password: password,
    tls: tls,
    transport: _xrayTransportFromStream(stream),
    warnings: warnings,
  );
}

VmessSpec? _xrayVmessToSpec(Map<String, dynamic> o, String remarks) {
  final vnext = (o['settings']?['vnext'] as List?)?.cast<Map>();
  if (vnext == null || vnext.isEmpty) return null;
  final v = vnext.first;
  final server = v['address']?.toString() ?? '';
  final port = (v['port'] as num?)?.toInt() ?? 443;
  final users = (v['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  final uuid = user['id']?.toString() ?? '';
  if (server.isEmpty || uuid.isEmpty) return null;

  final stream = o['streamSettings'] as Map? ?? const {};
  final warnings = <NodeWarning>[];
  final tls = normalizeTlsFingerprint(
    _xrayTlsFromStream(stream, server),
    warnings,
  );
  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');
  final security = user['security']?.toString() ?? 'auto';

  return VmessSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'vmess', server, port),
    label: label,
    server: server,
    port: port,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    uuid: uuid,
    alterId: (user['alterId'] as num?)?.toInt() ?? 0,
    security: security.isEmpty ? 'auto' : security,
    tls: tls,
    transport: _xrayTransportFromStream(stream),
    warnings: warnings,
  );
}

ShadowsocksSpec? _xraySsToSpec(Map<String, dynamic> o, String remarks) {
  final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
  if (servers == null || servers.isEmpty) return null;
  final v = servers.first;
  final server = v['address']?.toString() ?? '';
  final port = (v['port'] as num?)?.toInt() ?? 0;
  final method = v['method']?.toString() ?? '';
  final password = v['password']?.toString() ?? '';
  if (server.isEmpty || method.isEmpty || port == 0) return null;

  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');
  return ShadowsocksSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'ss', server, port),
    label: label,
    server: server,
    port: port,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    method: method,
    password: password,
  );
}

/// §321 — `protocol: "hysteria"` с `version: 2` — форма форка Xray (апстрим
/// hysteria2 не поддерживает вовсе). `finalmask.quicParams` НЕ переносим: у
/// sing-box нет соответствия, а unknown field валит весь конфиг.
Hysteria2Spec? _xrayHy2ToSpec(Map<String, dynamic> o, String remarks) {
  final s = o['settings'] as Map? ?? const {};
  final stream = o['streamSettings'] as Map? ?? const {};
  final hy = stream['hysteriaSettings'] as Map? ?? const {};

  final version =
      (hy['version'] as num?)?.toInt() ?? (s['version'] as num?)?.toInt() ?? 2;
  if (version != 2) return null; // hysteria v1 — своего Spec у нас нет

  final server = s['address']?.toString() ?? '';
  final port = (s['port'] as num?)?.toInt() ?? 443;
  final auth = hy['auth']?.toString() ?? '';
  if (server.isEmpty) return null;

  final warnings = <NodeWarning>[];
  final tls = normalizeTlsFingerprint(
    _xrayTlsFromStream(stream, server),
    warnings,
  );
  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');

  return Hysteria2Spec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'hy2', server, port),
    label: label,
    server: server,
    port: port,
    rawUri: 'xray://${o['tag'] ?? 'proxy'}',
    password: auth,
    tls: tls.enabled ? tls : const TlsSpec(enabled: true),
    warnings: warnings,
  );
}

/// §404 / контракт D-085 — цепочка релеев `sockopt.dialerProxy`, рекурсивно.
///
/// [owner] — outbound-владелец (нужен только чтобы посадить его тег в набор
/// посещённых: `dialerProxy` на самого себя — кольцо длины 1).
/// [byTag] — все outbound'ы элемента по тегу.
/// [firstRef] — тег первого звена.
///
/// Возвращает звено (со своим звеном внутри) либо `null` — и `null` здесь
/// означает «ВЛАДЕЛЕЦ НЕГОДЕН», а не «цепочки нет»: вызывающий обязан
/// отбраковать узел целиком, а не собирать его с прямым путём. Отличие от
/// sing-box-ветки (`_buildChain`, §368) намеренное: там `detour` —
/// необязательное украшение маршрута и негодное звено просто срезается, а
/// здесь провайдер явно завернул дозвон в релей.
///
/// Причины негодности: цели нет в элементе; цель — группа или служебный
/// outbound; цель не конвертируется в узел; кольцо; глубже [kMaxDetourDepth].
NodeSpec? _xrayBuildChain(
  Map<String, dynamic> owner,
  Map<String, Map<String, dynamic>> byTag,
  String firstRef,
) {
  // Кольцо ищем по тегам ТЕКУЩЕЙ цепочки, а не по всему элементу: два разных
  // узла законно ссылаются на один релей.
  final visited = <String>{};
  final ownerTag = owner['tag']?.toString() ?? '';
  if (ownerTag.isNotEmpty) visited.add(ownerTag);

  NodeSpec? build(String ref, int depth) {
    if (ref.isEmpty) return null;
    // Глубже лимита не идём. Лимит общий с sing-box-веткой (§368): цепочка из
    // данных провайдера не должна уводить рекурсию в стек.
    if (depth >= kMaxDetourDepth) return null;
    if (visited.contains(ref)) return null;

    final target = byTag[ref];
    if (target == null) return null;
    final protocol = target['protocol']?.toString() ?? '';
    // Служебный outbound (`freedom`/`blackhole`/`dns`) звеном быть не может.
    // `dialerProxy: "direct"` в Xray встречается как «ходи напрямую» — но у
    // нас прямой выход не узел, а подменять релей прямым путём D-085
    // запрещает: владелец отбраковывается.
    if (_kXrayServiceProtocols.contains(protocol)) return null;

    visited.add(ref);

    // §404 / D-085 — тег и label звена = СОБСТВЕННЫЙ тег релея из конфига
    // провайдера (`ru-upstream`), без украшений. Прежний `⚙ <tag>` уезжал в
    // конфиг ядра как есть и мешался с §274-маркером Направлений, где `⚙`
    // значит совсем другое. Декорация — дело отображения, не разбора.
    final NodeSpec? spec;
    if (protocol == 'socks') {
      spec = _xraySocksToSpec(target, ref);
    } else {
      // Все типы, которые умеет конвертер: релей больше не ограничен
      // socks/vless — в sing-box `detour` живёт на любом outbound'е.
      spec = _xrayToSpec(target, ref);
    }
    if (spec == null) return null;
    // Группа цепочку не несёт (`withChained` вернул бы её как есть) —
    // конвертер её и не отдаёт, но инвариант проверяем явно.
    if (spec.isGroup) return null;

    // Звено само может звонить через следующее звено.
    final stream = target['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    final nextRef = sockopt is Map ? sockopt['dialerProxy']?.toString() : null;
    if (nextRef == null || nextRef.isEmpty) return spec;

    final next = build(nextRef, depth + 1);
    // Негодное звено В СЕРЕДИНЕ цепочки роняет всю цепочку — и владельца
    // вместе с ней. Собрать усечённый путь значит выпустить трафик на хоп
    // раньше, чем задумал провайдер.
    if (next == null) return null;
    return withChained(spec, next);
  }

  return build(firstRef, 0);
}

/// SOCKS-outbound Xray → узел. Отдельно от `_xrayToSpec`: самостоятельным
/// узлом подписки socks не становится (§321), он бывает только звеном.
SocksSpec? _xraySocksToSpec(Map<String, dynamic> o, String label) {
  final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
  if (servers == null || servers.isEmpty) return null;
  final s = servers.first;
  final server = s['address']?.toString() ?? '';
  final port = (s['port'] as num?)?.toInt() ?? 1080;
  if (server.isEmpty) return null;
  final users = (s['users'] as List?)?.cast<Map>() ?? const [];
  final user = users.isEmpty ? const {} : users.first;
  return SocksSpec(
    id: newUuidV4(),
    tag: label,
    label: label,
    server: server,
    port: port,
    rawUri: 'xray-jump://socks',
    username: user['user']?.toString() ?? '',
    password: user['pass']?.toString() ?? '',
  );
}

TlsSpec _xrayTlsFromStream(Map stream, String server) {
  final security = stream['security']?.toString() ?? '';
  if (security == 'none' || security.isEmpty) return TlsSpec.disabled;

  if (security == 'reality') {
    final r = stream['realitySettings'] as Map? ?? const {};
    final pbk = r['publicKey']?.toString() ?? '';
    // §169 — REALITY только при валидном X25519-ключе. Битый publicKey →
    // деградируем до plain TLS (нода рабочая), а не отравляем config.json.
    return TlsSpec(
      enabled: true,
      serverName: r['serverName']?.toString() ?? server,
      fingerprint: r['fingerprint']?.toString() ?? 'random',
      reality: isValidRealityPublicKey(pbk)
          ? RealitySpec(
              publicKey: pbk,
              shortId: normalizeRealityShortId(r['shortId']?.toString() ?? ''),
            )
          : null,
    );
  }

  if (security == 'tls') {
    final t = stream['tlsSettings'] as Map? ?? const {};
    return TlsSpec(
      enabled: true,
      serverName: t['serverName']?.toString() ?? server,
      fingerprint: (t['fingerprint']?.toString() ?? '').toLowerCase().isEmpty
          ? null
          : t['fingerprint'].toString().toLowerCase(),
      insecure: t['allowInsecure'] == true,
    );
  }
  return TlsSpec.disabled;
}

TransportSpec? _xrayTransportFromStream(Map stream) {
  final net = (stream['network']?.toString() ?? 'tcp').toLowerCase();
  switch (net) {
    case 'ws':
      final ws = stream['wsSettings'] as Map? ?? const {};
      final headers = (ws['headers'] as Map?)?.cast<String, dynamic>();
      final host = headers?['Host']?.toString() ?? '';
      // §303 — Xray кладёт early data хвостом пути (`/x?ed=2560`); в sing-box
      // это отдельное поле, а хвост в пути даёт 404.
      // §103 D-016(в) — ключ `path` отсутствовал в исходном JSON → '' (не
      // эмитим); присутствовал (даже как "/") → пропускаем через сплиттер.
      final wsHasPath = ws.containsKey('path');
      final (splitPath, edFromPath) = splitEarlyDataPath(
        ws['path']?.toString() ?? '',
      );
      final path = wsHasPath ? splitPath : '';
      // §320 — Xray-конфиги также несут early data отдельными полями
      // `wsSettings.ed` / `.eh` (хвост пути в приоритете). `eh` без `ed`
      // игнорируем: режим ядро включает по `max_early_data > 0`.
      final edField = ws['ed'];
      final ed =
          edFromPath ??
          (edField is int && edField > 0
              ? edField
              : int.tryParse(edField?.toString().trim() ?? ''));
      var eh = ws['eh']?.toString().trim() ?? '';
      // §103 D-008 — как и в URI-ветке: дефолт применим ТОЛЬКО когда early
      // data взята из хвоста пути `?ed=N` (Go: applyWSEarlyData), не из
      // плоских wsSettings.ed/eh (тех Go вообще не читает).
      var ehImplicit = false;
      if (eh.isEmpty && edFromPath != null) {
        eh = 'Sec-WebSocket-Protocol';
        ehImplicit = true;
      }
      return WsTransport(
        path: path,
        host: host,
        earlyDataHeaderImplicit: ehImplicit,
        maxEarlyData: ed != null && ed > 0 ? ed : null,
        earlyDataHeaderName: (ed != null && ed > 0 && eh.isNotEmpty)
            ? eh
            : null,
      );
    case 'grpc':
      final g = stream['grpcSettings'] as Map? ?? const {};
      return GrpcTransport(serviceName: g['serviceName']?.toString() ?? '');
    case 'http':
    case 'h2':
      final h = stream['httpSettings'] as Map? ?? const {};
      final hosts =
          (h['host'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      return HttpTransport(path: h['path']?.toString() ?? '/', hosts: hosts);
    case 'xhttp': // §097 — Xray xhttpSettings → нативный xhttp
      final x = stream['xhttpSettings'] as Map? ?? const {};
      // §399 — состав полей общий с URI-веткой. Xray допускает обе раскладки:
      // плоско в `xhttpSettings` и вложенным объектом `extra`; при конфликте
      // выигрывает `extra`. Битый/не-объектный `extra` игнорируется — узел
      // собирается на плоских полях.
      return xhttpFromMap(
        mergeXhttpExtra(xhttpScalarsFromJson(x), raw: x['extra']),
      );
    default:
      return null;
  }
}

/// sing-box outbound / endpoint JSON → NodeSpec (§4 round-trip).
/// Используется для JSON-редактора и Smart-Paste одиночного sing-box entry.
NodeSpec? parseSingboxEntry(Map<String, dynamic> entry) {
  final type = entry['type']?.toString() ?? '';
  final tag = entry['tag']?.toString() ?? '';
  final server = entry['server']?.toString() ?? '';
  final port = (entry['server_port'] as num?)?.toInt() ?? 0;
  final label = tag;

  switch (type) {
    case 'vless':
      if (server.isEmpty || port == 0) return null;
      final tls = _tlsFromSingbox(entry['tls'], server);
      return VlessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vless-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        flow: entry['flow']?.toString() ?? '',
        tls: tls,
        transport: _transportFromSingbox(entry['transport']),
        packetEncoding: normalizePacketEncoding(
          entry['packet_encoding']?.toString() ?? '',
          tag: tag,
        ),
      );
    case 'vmess':
      if (server.isEmpty || port == 0) return null;
      return VmessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vmess-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        alterId: (entry['alter_id'] as num?)?.toInt() ?? 0,
        security: entry['security']?.toString() ?? 'auto',
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: _transportFromSingbox(entry['transport']),
      );
    case 'trojan':
      if (server.isEmpty || port == 0) return null;
      return TrojanSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'trojan-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: _transportFromSingbox(entry['transport']),
      );
    case 'anytls': // §269
      if (server.isEmpty || port == 0) return null;
      // AnyTLS всегда поверх TLS: если tls-блок отсутствует/выключен —
      // подставляем минимальный enabled (serverName=server).
      var anyTls = _tlsFromSingbox(entry['tls'], server);
      if (!anyTls.enabled) {
        anyTls = TlsSpec(enabled: true, serverName: server);
      }
      return AnyTlsSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'anytls-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        tls: anyTls,
        // SPEC 103 D-024 — на всякий случай нормализуем и здесь: ручные
        // правки JSON/smart-paste могут занести голое число (в т.ч. как JSON
        // number, не строку) без единицы измерения.
        idleSessionCheckInterval: normalizeSingboxDuration(
            entry['idle_session_check_interval']?.toString() ?? ''),
        idleSessionTimeout: normalizeSingboxDuration(
            entry['idle_session_timeout']?.toString() ?? ''),
        minIdleSession: (entry['min_idle_session'] as num?)?.toInt(),
      );
    case 'shadowsocks':
      if (server.isEmpty || port == 0) return null;
      return ShadowsocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'ss-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        method: entry['method']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
      );
    case 'hysteria2':
      if (server.isEmpty || port == 0) return null;
      // §219 — кастуем entry['obfs'] один раз (было дважды).
      final obfs = entry['obfs'] as Map?;
      // §358 — тип/пароль канонизируются молча: у parseSingboxEntry нет
      // warnings-аккумулятора (тот же power-user путь, что у fp выше), а
      // отдать ядру неизвестный тип нельзя — это fatal всего конфига.
      final obfsNorm = normalizeHysteria2Obfs(
        obfs?['type']?.toString() ?? '',
        obfs?['password']?.toString() ?? '',
        null,
      );
      return Hysteria2Spec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'hy2-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        obfs: obfsNorm.type,
        obfsPassword: obfsNorm.password,
        obfsMinPacketSize: (obfs?['min_packet_size'] as num?)?.toInt(),
        obfsMaxPacketSize: (obfs?['max_packet_size'] as num?)?.toInt(),
        // §404 п.5 — bandwidth-подсказки и port hopping доезжали только из
        // URI-формы, из sing-box JSON терялись молча. Читаем как `num`, не как
        // `int`: провайдеры пишут `"up_mbps": 100.0`, и `as int` уронил бы
        // весь узел в catch по TypeError.
        upMbps: (entry['up_mbps'] as num?)?.toInt(),
        downMbps: (entry['down_mbps'] as num?)?.toInt(),
        serverPorts: _stringListOrNull(entry['server_ports']),
        tls: _tlsFromSingbox(entry['tls'], server),
      );
    case 'naive':
      if (server.isEmpty || port == 0) return null;
      final eh = entry['extra_headers'];
      final extraHeaders = <String, String>{};
      if (eh is Map) {
        for (final k in eh.keys) {
          final v = eh[k];
          if (v is String) {
            extraHeaders[k.toString()] = v;
          } else if (v is List && v.isNotEmpty) {
            extraHeaders[k.toString()] = v.first.toString();
          }
        }
      }
      return NaiveSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'naive-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        // §281 (ревью) — naive принимает ТОЛЬКО enabled/server_name в TLS:
        // alpn/utls/insecure/reality ядро отклоняет при создании outbound
        // (fatal всего конфига). Зеркало naive_parser: срезаем блок.
        tls: _naiveTlsFromSingbox(entry['tls'], server),
        extraHeaders: extraHeaders,
      );
    case 'tuic':
      if (server.isEmpty || port == 0) return null;
      return TuicSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'tuic-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        uuid: entry['uuid']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        // §103 D-016(в) — ключ отсутствует в исходном JSON ⇒ не задан явно;
        // округлять до дефолта здесь нельзя, иначе эмиттер снова напишет его.
        congestionControl: entry['congestion_control']?.toString(),
        udpRelayMode: entry['udp_relay_mode']?.toString(),
        zeroRtt: entry['zero_rtt_handshake'] == true,
        tls: _tlsFromSingbox(entry['tls'], server),
        // §103 D-024 — нормализуем на всякий случай (ручная правка JSON).
        heartbeat: entry['heartbeat'] == null
            ? null
            : normalizeSingboxDuration(entry['heartbeat'].toString()),
      );
    case 'ssh':
      if (server.isEmpty || port == 0) return null;
      final hk = entry['host_key'];
      return SshSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'ssh-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        user: entry['user']?.toString() ?? 'root',
        password: entry['password']?.toString() ?? '',
        privateKey: entry['private_key']?.toString() ?? '',
        privateKeyPassphrase: entry['private_key_passphrase']?.toString() ?? '',
        hostKey: hk is List ? hk.map((e) => e.toString()).toList() : const [],
      );
    case 'socks':
      if (server.isEmpty || port == 0) return null;
      return SocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'socks-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
      );
    case 'http': // §222 — HTTP(S) CONNECT proxy
      if (server.isEmpty || port == 0) return null;
      // headers: listable-значения sing-box (string | [string, ...]) —
      // как naive extra_headers.
      final hh = entry['headers'];
      final headers = <String, String>{};
      if (hh is Map) {
        for (final k in hh.keys) {
          final v = hh[k];
          if (v is String) {
            headers[k.toString()] = v;
          } else if (v is List && v.isNotEmpty) {
            headers[k.toString()] = v.first.toString();
          }
        }
      }
      return HttpSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'http-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        path: entry['path']?.toString() ?? '',
        headers: headers,
        tls: _tlsFromSingbox(entry['tls'], server),
      );
    case 'wireguard':
      // §106 — bare IP → CIDR (/32 | /128) для address и allowed_ips.
      final addr =
          (entry['address'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const <String>[];
      final peers = (entry['peers'] as List?)?.cast<Map>() ?? const [];
      if (peers.isEmpty) return null;
      final p = peers.first;
      final peerServer = p['address']?.toString() ?? server;
      final peerPort = (p['port'] as num?)?.toInt() ?? port;
      if (peerServer.isEmpty) return null;
      final allowedIps =
          (p['allowed_ips'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const ['0.0.0.0/0', '::/0'];
      final awg = Awg.fromJson(entry); // §097 — AmneziaWG2 obfuscation params
      final wgTag = tag.isEmpty ? 'wg-$peerServer-$peerPort' : tag;
      // §097/SPEC 103 D-026 — AWG: клампим MTU до 1280. Plain WG без mtu в
      // источнике поле не эмитит вовсе (ядро само ставит 1408) — зеркалим
      // `wireguard_parser.dart`, чтобы модель не зависела от источника
      // парсинга: JSON vs URI.
      final rawMtu = (entry['mtu'] as num?)?.toInt();
      // §025/§126 — WARP client_id. §219 — раньше JSON-парсер не заполнял
      // `reserved` (WARP-handshake проходил, трафик не шёл). В sing-box JSON
      // `reserved` — массив из 3 байт `[b0,b1,b2]` (наш round-trip формат
      // эмиттера); `client_id` — base64-строка. Массив берём напрямую
      // (с валидацией 3×0..255), строку — через parseReserved.
      final reserved =
          _reservedFromJson(p['reserved'] ?? entry['reserved']) ??
          (p['client_id'] is String
              ? parseReserved(p['client_id'] as String)
              : null);
      // SPEC 103 D-023/D-030 — та же проверка ключей, что на URI/INI-путях:
      // мусорный ключ из импортированного конфига валит `sing-box check`
      // целиком, а неканоническая форма даёт другой identity-хеш той же ноде.
      final wgPriv = normalizeWGKey(entry['private_key']?.toString() ?? '');
      final wgPub = normalizeWGKey(p['public_key']?.toString() ?? '');
      if (wgPriv == null || wgPub == null) return null;
      final wgPskRaw = p['pre_shared_key']?.toString() ?? '';
      final String wgPsk;
      if (wgPskRaw.isEmpty) {
        wgPsk = '';
      } else {
        final normalized = normalizeWGKey(wgPskRaw);
        if (normalized == null) return null;
        wgPsk = normalized;
      }
      return WireguardSpec(
        id: newUuidV4(),
        tag: wgTag,
        label: label,
        server: peerServer,
        port: peerPort,
        rawUri: '',
        privateKey: wgPriv,
        localAddresses: addr,
        peers: [
          WireguardPeer(
            publicKey: wgPub,
            preSharedKey: wgPsk,
            endpointHost: peerServer,
            endpointPort: peerPort,
            allowedIps: allowedIps,
            persistentKeepalive: (p['persistent_keepalive_interval'] as num?)
                ?.toInt(),
            reserved: reserved,
          ),
        ],
        mtu: awg != null ? awgClampMtu(rawMtu, wgTag) : rawMtu,
        awg: awg,
      );
    case 'masque':
      // §130 — обратная операция к emitMasque (round-trip JSON-редактор /
      // Smart-Paste). ip/ipv6 → localAddresses; keep_alive_period → keepAlive.
      if (server.isEmpty || port == 0) return null;
      final priv = entry['private_key']?.toString() ?? '';
      final pub = entry['public_key']?.toString() ?? '';
      if (priv.isEmpty || pub.isEmpty) return null;
      final ip = entry['ip']?.toString() ?? '';
      final ipv6 = entry['ipv6']?.toString() ?? '';
      final addrs = <String>[
        if (ip.isNotEmpty) ensureCidr(ip),
        if (ipv6.isNotEmpty) ensureCidr(ipv6),
      ];
      if (addrs.isEmpty) return null;
      // §393/контракт 0.8.0 (D-078) — только схема ядра (`vhttp` + вложенный
      // `tls{}`). Плоские legacy-ключи (`network`/`sni`/`skip_cert_verify`)
      // НЕ переносятся — «не принимаем» (директива оператора 25.08). Читать
      // их не читаем; в эмит они не попадают по построению (MasqueSpec несёт
      // только свои поля) — зеркально Go-стрипу sanitizeSingboxMasqueLegacy,
      // где плоский `sni` рядом с tls.server_name ронял ядро fail-fast'ом.
      final masqueTls = entry['tls'];
      final tlsMap = masqueTls is Map ? masqueTls : const {};
      final vhttpRaw = entry['vhttp']?.toString() ?? '';
      // SPEC 103 п.5 — невалидное значение форсится в h3, как в URI-парсере.
      // Контракт 0.11.1 — `auto` в тройке допустимых (ядро >= lx.27).
      final vhttpJson = (vhttpRaw == 'h3' || vhttpRaw == 'h2' ||
              vhttpRaw == 'auto')
          ? vhttpRaw
          : 'h3';
      final sniRaw = tlsMap['server_name']?.toString() ?? '';
      return MasqueSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'masque-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        privateKeyDer: priv,
        publicKeyDer: pub,
        localAddresses: addrs,
        profile: entry['profile']?.toString() ?? 'cloudflare',
        vhttp: vhttpJson,
        sni: sniRaw,
        disableSni: tlsMap['disable_sni'] == true,
        mtu: (entry['mtu'] as num?)?.toInt(),
        idleTimeout: entry['idle_timeout']?.toString() ?? '',
        keepAlive: entry['keep_alive_period']?.toString() ?? '',
      );
    default:
      return null;
  }
}

/// §219 — `reserved` из sing-box JSON WireGuard-peer: массив ровно из 3 байт
/// `[b0,b1,b2]` (0..255). Не-массив / не-3-элемента / вне диапазона → null
/// (не роняем ноду, деградируем к «без reserved» — ср. §172).
List<int>? _reservedFromJson(dynamic raw) {
  if (raw is! List || raw.length != 3) return null;
  final out = <int>[];
  for (final e in raw) {
    final n = e is num ? e.toInt() : null;
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

/// §281 — TLS для naive-entry: только enabled/server_name (см. naive_parser).
TlsSpec _naiveTlsFromSingbox(dynamic raw, String server) {
  final full = _tlsFromSingbox(raw, server);
  if (!full.enabled) return full;
  return TlsSpec(enabled: true, serverName: full.serverName);
}

TlsSpec _tlsFromSingbox(dynamic raw, String server) {
  if (raw is! Map) return TlsSpec.disabled;
  if (raw['enabled'] != true) return TlsSpec.disabled;
  final utls = raw['utls'] as Map?;
  final reality = raw['reality'] as Map?;
  // §281 — fp канонизируется молча (псевдонимы И мусор → словарь ядра):
  // у parseSingboxEntry нет warnings-аккумулятора, это power-user путь
  // JSON-редактора/Smart-Paste — итоговое значение видно в самом JSON.
  return normalizeTlsFingerprint(
    TlsSpec(
      enabled: true,
      serverName: raw['server_name']?.toString() ?? server,
      alpn:
          (raw['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      insecure: raw['insecure'] == true,
      fingerprint: utls?['fingerprint']?.toString(),
      // §169 — REALITY только при enabled И валидном X25519 public_key. Битый
      // ключ → reality=null (нода остаётся plain TLS), а не отравляет config.
      reality:
          reality == null ||
              reality['enabled'] != true ||
              !isValidRealityPublicKey(reality['public_key']?.toString() ?? '')
          ? null
          : RealitySpec(
              publicKey: reality['public_key']!.toString(),
              shortId: normalizeRealityShortId(
                reality['short_id']?.toString() ?? '',
              ),
            ),
    ),
    null,
  );
}

TransportSpec? _transportFromSingbox(dynamic raw) {
  if (raw is! Map) return null;
  final type = raw['type']?.toString() ?? '';
  switch (type) {
    case 'ws':
      final headers = (raw['headers'] as Map?)?.cast<String, dynamic>();
      // §303 — sing-box JSON обычно уже разделён (`max_early_data`), но в
      // редактор попадают и склеенные Xray-пути.
      // §103 D-016(в) — ключ отсутствует в исходном JSON → путь не задан
      // явно, '' (не эмитим обратно); канонический sing-box JSON и так не
      // пишет "path":"/" для дефолта (см. Go option/v2ray_transport.go).
      final wsHasPath = raw.containsKey('path');
      final (splitPath, edFromPath) = splitEarlyDataPath(
        raw['path']?.toString() ?? '',
      );
      final path = wsHasPath ? splitPath : '';
      final edField = raw['max_early_data'];
      return WsTransport(
        path: path,
        host: headers?['Host']?.toString() ?? '',
        maxEarlyData: edField is int ? edField : edFromPath,
        earlyDataHeaderName:
            (raw['early_data_header_name']?.toString().isNotEmpty ?? false)
            ? raw['early_data_header_name'].toString()
            : null,
      );
    case 'grpc':
      return GrpcTransport(serviceName: raw['service_name']?.toString() ?? '');
    case 'http':
      return HttpTransport(
        path: raw['path']?.toString() ?? '/',
        hosts:
            (raw['host'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
    case 'httpupgrade':
      // §303 — early data у httpupgrade нет, но хвост пути всё равно чужой.
      // §103 D-016(в) — как и у ws: отсутствующий ключ → '' (не эмитим).
      final huHasPath = raw.containsKey('path');
      final (splitPath, _) = splitEarlyDataPath(
        raw['path']?.toString() ?? '',
      );
      final path = huHasPath ? splitPath : '';
      return HttpUpgradeTransport(
        path: path,
        host: raw['host']?.toString() ?? '',
      );
    case 'xhttp': // §097 — нативный xhttp из sing-box JSON
      // §399 — состав полей общий с URI-веткой: round-trip через JSON-редактор
      // не должен срезать расширенные поля §127. `headers` — Map, идёт отдельно.
      return xhttpFromMap(
        xhttpScalarsFromJson(raw),
        headers:
            (raw['headers'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            const {},
      );
    default:
      return null;
  }
}
