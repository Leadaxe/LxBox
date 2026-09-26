import 'dart:convert';

import '../../models/auto_select.dart';
import '../../models/direction.dart' show UrltestMode;
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../../models/template_vars.dart';
import '../../models/transport_spec.dart';
import '../contract/registry.dart' show awgMtuCeilingByRegistry;
import '../node_hash.dart';
import 'engine/engine_mapper.dart' show mapJsonViaEngine;
import 'mappers/uri_pipeline.dart'
    show parseXrayViaPipeline;
import '../contract/body_sanitizer.dart' show BodySource;
import 'body_delta_builder.dart';
import 'drop_verdict.dart';
import 'tcp_keep_alive.dart';
import 'transport.dart';
import 'uri_utils.dart';
import 'utls_fingerprint.dart';

/// Служебные outbound'ы Xray: не серверы, узлами не становятся (§321).
///
/// §480 W5 — набор живёт ЗДЕСЬ, а не в маппере: это знание СБОРКИ
/// ДОКУМЕНТА («какой элемент вообще претендует на узел»), а не перевода
/// диалекта. Маппер одного узла о соседях по документу не знает; реестр
/// видов источника заберёт набор волной W6.
const kXrayServiceProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

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
            !kXrayServiceProtocols.contains(o['protocol']?.toString() ?? ''),
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
  final unread = <NodeWarning>[];
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
      // §477 — реестр вправе снять запись ЦЕЛИКОМ (`on_invalid: drop_node`):
      // негодная форма `vless.encryption` значит, что ядро не примет конфиг и
      // не стартует НА ВСЁМ наборе (случай #147). Такой узел обязан исчезнуть
      // при разборе, а не дожить до гарда сборки, стоя в списке рабочим.
      // §302/§454 — исходник узла: compact = сам outbound (он же `rawSource`
      // узла), extended = весь элемент как пришёл от провайдера (dns/inbounds/
      // routing соседи) — хранится только когда отличается. Текст считается
      // здесь один раз и уходит в `_xrayToSpec` как готовый `rawSource`
      // (§551 follow-up: раньше тот же outbound сериализовался дважды).
      final compact = _prettyJson(ob);
      final verdict = XrayDropVerdict();
      var spec = _xrayToSpec(ob, label,
          dropped: verdict, rawSource: compact, document: outbounds);
      if (spec == null && verdict.explicit) {
        // Причина — код реестра с тегом записи: `dropped[].ref` контракта
        // называет именно тег outbound'а (D-088), как и у прочих отбраковок.
        final r = verdict.reason;
        final w = RegistryWarning(
          code: r?.code ?? 'type_invalid',
          path: r?.path,
          value: r?.value,
          params: r?.params ?? const {},
          ownerTag: obTag,
        );
        dropped?.add(w);
        rejected.add(w);
        continue;
      }
      // §321 P5 — неподдержанный protocol не исчезает молча: узел не собрался,
      // но провайдер его прислал. Warning вешаем на СОСЕДА по элементу (у
      // NodeWarning нет носителя без узла); если соседей нет — элемент выпадает
      // молча (документированное ограничение §321 P5, spec §Известные дыры).
      if (spec == null) {
        final proto = ob['protocol']?.toString() ?? '';
        if (proto.isNotEmpty) unsupported.add(proto);
        // §560 — запись НЕ ПРОЧИТАНА (ни одна секция не опознала протокол
        // либо ни одна форма секции — элемент): причина — код CANON §4.1 с
        // тегом записи (D-088), см. разбор `unread` в конце функции.
        final r = verdict.reason;
        if (r != null) {
          unread.add(RegistryWarning(
            code: r.code,
            params: r.params,
            ownerTag: obTag,
          ));
        }
        continue;
      }

      // §321/§368/§404 — цепочка релеев. `dialerProxy` в Xray живёт в
      // `streamSettings.sockopt`, то есть технически возможен у любого
      // протокола (на практике встречается у VLESS/Trojan); `withChained`
      // покрывает все типы, кроме группы — та цепочку не несёт. Звено само
      // может звонить через следующее звено (§404 п.4) — строим рекурсивно.
      final ref = dialerRefOf[ob];
      NodeSpec? chained;
      if (ref != null) {
        // §488 — цель `freedom` не хоп цепочки (anti-DPI fragment Xray, не
        // релей): узел ходит наружу напрямую. Фрагментацию его TLS ставит
        // запись реестра `fragment_via_dialer` (контракт 1.1.63, `deref`) —
        // уровень документа freedom только не заводит звеном.
        if (_isXrayFreedom(byTag[ref])) {
          // прямой узел
        } else {
          chained = _xrayBuildChain(ob, byTag, ref, outbounds);
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

      result.add(node..sourceExtended = extended == compact ? null : extended);
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

  // §560 — непрочитанные записи: соседа нет — причина едет в `dropped[]`;
  // сосед есть — он уже несёт `UnsupportedProtocolWarning` (§321 P5), и
  // второй раз то же сообщение человеку не показываем (§404 P3).
  if (result.isEmpty) dropped?.addAll(unread);

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
            !kXrayServiceProtocols.contains(o['protocol']?.toString() ?? ''),
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
      // §480, дельта `vless_default_port` — БЕЗ дефолта 443: элемент без
      // порта узла не даёт вовсе (запись `port` секции объявлена
      // `required`), и синоним тега обязан это зеркалить. Иначе балансировщик
      // держал бы ключ `vless|host|443|id` на узел, которого в подписке нет:
      // §322 резолвит по нему состав пула, и тег молча уезжал бы в пустоту
      // либо, хуже, цеплялся к ЧУЖОМУ узлу, у которого порт 443 настоящий.
      // Это ровно тот инвариант, что объявлен в шапке функции.
      final rawPort = (v['port'] as num?)?.toInt();
      if (rawPort == null || rawPort <= 0) return null;
      port = rawPort;
      final users = (v['users'] as List?)?.cast<Map>() ?? const [];
      cred = users.isEmpty ? '' : (users.first['id']?.toString() ?? '');
      // §459 (контракт §24.2 п. 7.4) — зеркало конвертера: порт узла
      // `-udp443` больше не переписывает, значит и ключ identity строится по
      // исходному порту. Прежний код ставил здесь 443.
    case 'trojan':
    case 'shadowsocks':
      final servers = (s['servers'] as List?)?.cast<Map>();
      if (servers == null || servers.isEmpty) return null;
      final v = servers.first;
      server = v['address']?.toString() ?? '';
      // §480 — ни у trojan, ни у ss дефолта порта НЕТ: элемент без порта
      // узла не даёт (запись `port` обеих секций `required`), и синоним тега
      // это зеркалит. У ss так было и раньше — конвертер отбрасывал его сам
      // (port == 0 → null); у trojan стоял дефолт 443, снятый этой же
      // дельтой. Сам Xray здесь отбраковывает элемент ЯВНО и первым делом
      // (infra/conf/trojan.go:67-69 «Invalid Trojan port.»).
      final rawPort = (v['port'] as num?)?.toInt();
      if (rawPort == null || rawPort <= 0) return null;
      port = rawPort;
      cred = v['password']?.toString() ?? '';
    case 'hysteria':
      // Конвертер отдаёт Hysteria2Spec → protocol в ключе 'hysteria2'.
      final hy = (o['streamSettings'] as Map?)?['hysteriaSettings'];
      server = s['address']?.toString() ?? '';
      // §513 — как у vless/trojan выше: запись `port` секции hysteria
      // `required`, узла без порта нет, и синонима у тега быть не должно.
      // Прежний `?? 443` держал ключ на несуществующий узел.
      final rawPort = (s['port'] as num?)?.toInt();
      if (rawPort == null || rawPort <= 0) return null;
      port = rawPort;
      cred = hy is Map ? (hy['auth']?.toString() ?? '') : '';
      if (server.isEmpty) return null;
      return 'hysteria2|$server|$port|$cred';
    default:
      return null;
  }
  if (server.isEmpty) return null;
  return '$protocol|$server|$port|$cred';
}

/// §488 — служебный `freedom` (цель `dialerProxy`, не звено цепочки).
bool _isXrayFreedom(Map<String, dynamic>? o) =>
    o != null && (o['protocol']?.toString() ?? '') == 'freedom';

/// §472 шаг 8 — Xray-outbound через ЕДИНЫЙ конвейер.
///
/// Раньше здесь стоял диспетчер по `protocol` с отдельным конвертером на
/// каждый протокол (`_xrayVlessToSpec` и соседи), и каждый нёс свою копию
/// правил значений. Теперь путь общий: маппер переводит диалект Xray в карту
/// sing-box, санитайзер по реестру судит значения, `parseSingboxEntry`
/// строит модель. Снятые отсюда рукописные правила перечислены в
/// `mappers/xray_mapper.dart`.
///
/// `rawSource` узла остаётся pretty-print ИСХОДНОГО объекта Xray байт в байт
/// (§454): карта sing-box — рабочая форма конвейера, а не то, что прислал
/// провайдер.
///
/// [dropped] — §477: реестр вправе снять запись целиком (`drop_node`), и
/// вызывающему нужно отличить это от «тела нет».
NodeSpec? _xrayToSpec(
  Map<String, dynamic> o,
  String remarks, {
  XrayDropVerdict? dropped,
  String? rawSource,
  List<dynamic>? document,
}) {
  // §560 — SOCKS-элемент Xray становится узлом, как любой другой: секция
  // `mappers.xray` реестра у socks есть, и корпус (body/xray/
  // socks_settings_users) ждёт узел. Прежний запрет §321 (socks — только
  // звено `dialerProxy`) жил в коде в обход реестра, и узел терялся целиком.
  // Звено `dialerProxy` по-прежнему не становится узлом подписки: его
  // снимает отбор релеев выше, не протокол.
  // §480 W5 — карту строит ДВИЖОК по секции `mappers.xray` реестра.
  // Диспетчера по имени протокола здесь больше нет: секцию выбирает `detect`
  // самой секции, то есть опознание элемента объявлено данными.
  final mapping =
      mapJsonViaEngine('xray', o, dropped: dropped, document: document);
  if (mapping == null) return null;
  final label = remarks.isNotEmpty ? remarks : (o['tag']?.toString() ?? '');
  return parseXrayViaPipeline(
    mapping.body,
    rawSource: rawSource ?? _prettyJson(o),
    label: label,
    warnings: mapping.warnings,
    wsEarlyDataHeaderImplicit: mapping.wsEarlyDataHeaderImplicit,
    tagScheme: mapping.tagScheme,
    dropped: dropped,
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
/// Цель `freedom` звеном не становится (§488): у владельца это прямой путь,
/// у звена — конец цепочки. Фрагментацию TLS того, кто ходит через такой
/// freedom, ставит реестр (`fragment_via_dialer`, контракт 1.1.63).
///
/// [document] — массив `outbounds` элемента: по нему запись с `deref`
/// разыменовывает `dialerProxy` звена.
NodeSpec? _xrayBuildChain(
  Map<String, dynamic> owner,
  Map<String, Map<String, dynamic>> byTag,
  String firstRef,
  List<dynamic> document,
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
    // запрещает: владелец отбраковывается. Цель-freedom обрабатывается
    // выше (§488); сюда она доходит только как звено СЕРЕДИНЫ цепочки.
    if (kXrayServiceProtocols.contains(protocol)) return null;

    visited.add(ref);

    // §404 / D-085 — тег и label звена = СОБСТВЕННЫЙ тег релея из конфига
    // провайдера (`ru-upstream`), без украшений. Прежний `⚙ <tag>` уезжал в
    // конфиг ядра как есть и мешался с §274-маркером Направлений, где `⚙`
    // значит совсем другое. Декорация — дело отображения, не разбора.
    // Все типы, которые умеет маппер: релей не ограничен socks/vless — в
    // sing-box `detour` живёт на любом outbound'е. SOCKS здесь РАЗРЕШЁН
    // явно: самостоятельным узлом подписки он не становится (§321), а
    // звеном бывает, и чаще прочих.
    final spec = _xrayToSpec(target, ref, document: document);
    if (spec == null) return null;
    // Группа цепочку не несёт (`withChained` вернул бы её как есть) —
    // конвертер её и не отдаёт, но инвариант проверяем явно.
    if (spec.isGroup) return null;

    // Звено само может звонить через следующее звено.
    final stream = target['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    final nextRef = sockopt is Map ? sockopt['dialerProxy']?.toString() : null;
    if (nextRef == null || nextRef.isEmpty) return spec;
    // Звено ходит наружу через служебный freedom — оно последнее (§488).
    if (_isXrayFreedom(byTag[nextRef])) return spec;

    final next = build(nextRef, depth + 1);
    // Негодное звено В СЕРЕДИНЕ цепочки роняет всю цепочку — и владельца
    // вместе с ней. Собрать усечённый путь значит выпустить трафик на хоп
    // раньше, чем задумал провайдер.
    if (next == null) return null;
    return withChained(spec, next);
  }

  return build(firstRef, 0);
}

/// sing-box outbound / endpoint JSON → NodeSpec (§4 round-trip).
/// Используется для JSON-редактора и Smart-Paste одиночного sing-box entry.
///
/// §472 шаг 2 — [label] задаётся явно, когда имя узла НЕ равно тегу. У
/// JSON-узла имя и есть тег (их источник один), но у ссылки имя — текст
/// фрагмента, а тег из него вычислен: ссылка без `#` даёт тег-фолбэк
/// `trojan-host-443` при пустом имени, и подставить его в `label` значило бы
/// вернуть выдуманное `#trojan-host-443` из `toUri()`.
NodeSpec? parseSingboxEntry(
  Map<String, dynamic> entry, {
  String? rawSource,
  String? label,
  bool wsEarlyDataHeaderImplicit = false,
  BodySource? sanitizedFrom,
}) {
  final node = _parseSingboxEntryTyped(entry,
      rawSource: rawSource,
      label: label,
      wsEarlyDataHeaderImplicit: wsEarlyDataHeaderImplicit);
  // §560 — модель держит не все ключи тела и дописывает свои дефолты;
  // дельта по схеме реестра возвращает телу то, что прислал провайдер.
  // Только для тела, которое УЖЕ прошло санитайзер ([sanitizedFrom]): сырую
  // карту дельта перенесла бы вместе с мусором, который модель отбрасывает.
  // Дефолты ядра снимаются только у тела в форме ядра (`singbox`): там автор
  // написал ровно то, что хотел, и дописанный моделью ключ ему чужой.
  if (node != null && sanitizedFrom != null) {
    node.bodyDelta = bodyDeltaFor(
      entry,
      node.emitRaw(TemplateVars.empty).map,
      dropDefaults: sanitizedFrom == BodySource.singbox,
    );
  }
  return node;
}

NodeSpec? _parseSingboxEntryTyped(
  Map<String, dynamic> entry, {
  String? rawSource,
  String? label,
  bool wsEarlyDataHeaderImplicit = false,
}) {
  // §454 — источник узла из JSON: его собственный объект outbound'а. Вызов из
  // целого конфига передаёт оригинал (до подмены тега лейблом), одиночный
  // entry — сам себе источник.
  final src = rawSource ?? _prettyJson(entry);
  final type = entry['type']?.toString() ?? '';
  final tag = entry['tag']?.toString() ?? '';
  final server = entry['server']?.toString() ?? '';
  final port = (entry['server_port'] as num?)?.toInt() ?? 0;
  final label0 = label ?? tag;
  // §453 — dial-поля общие для всех носителей; читаем один раз до switch'а,
  // дальше просто прокидываем. У не-носителей ключи не читаются вовсе.
  final ka = tcpKeepAliveFromSingbox(entry);
  // §103 D-008 / §472 шаг 3 — заголовок early data подставлен САМОЙ формой
  // записи (`?ed=N` хвостом пути), а не написан автором. В теле этой разницы
  // нет: `early_data_header_name` там стоит в обоих случаях, и корпус требует
  // именно так. Знает о ней только тот, кто видел ИСХОДНУЮ форму, — маппер
  // ссылки (`mappers/uri_pipeline.dart`). У JSON-входа формы «хвостом пути»
  // не бывает, поэтому дефолт `false`.
  TransportSpec? transportOf(Object? raw) {
    final t = _transportFromSingbox(raw);
    if (!wsEarlyDataHeaderImplicit) return t;
    if (t is! WsTransport || t.earlyDataHeaderName == null) return t;
    return WsTransport(
      path: t.path,
      host: t.host,
      headers: t.headers,
      maxEarlyData: t.maxEarlyData,
      earlyDataHeaderName: t.earlyDataHeaderName,
      earlyDataHeaderImplicit: true,
    );
  }

  switch (type) {
    case 'vless':
      if (server.isEmpty || port == 0) return null;
      final tls = _tlsFromSingbox(entry['tls'], server);
      return VlessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vless-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        uuid: entry['uuid']?.toString() ?? '',
        flow: entry['flow']?.toString() ?? '',
        tls: tls,
        transport: transportOf(entry['transport']),
        packetEncoding: normalizePacketEncoding(
          entry['packet_encoding']?.toString() ?? '',
          tag: tag,
        ),
        // §335 / §472 шаг 3 — постквантовый слой читался ТОЛЬКО из Xray-JSON
        // (`_vlessFromXray`), а из карты sing-box терялся молча: узел из
        // JSON-редактора или Smart-Paste уезжал в конфиг без `encryption` и
        // не поднимался. Обнаружено переездом URI-ветки на конвейер — теперь
        // через эту карту идёт и ссылка (корпус
        // `vless/encryption_mlkem768_long_key`).
        encryption: entry['encryption']?.toString().trim() ?? '',
        tcpKeepAlive: ka,
      );
    case 'vmess':
      if (server.isEmpty || port == 0) return null;
      return VmessSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'vmess-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        uuid: entry['uuid']?.toString() ?? '',
        alterId: (entry['alter_id'] as num?)?.toInt() ?? 0,
        // §459 (контракт §24.2 п. 7.11) — enum ядра и здесь: JSON-редактор и
        // Smart-Paste приносят `aes-128-ctr` наравне с подписками.
        security: normalizeVmessSecurity(entry['security']?.toString() ?? ''),
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: transportOf(entry['transport']),
        tcpKeepAlive: ka,
      );
    case 'trojan':
      if (server.isEmpty || port == 0) return null;
      return TrojanSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'trojan-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        password: entry['password']?.toString() ?? '',
        tls: _tlsFromSingbox(entry['tls'], server),
        transport: transportOf(entry['transport']),
        tcpKeepAlive: ka,
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
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        password: entry['password']?.toString() ?? '',
        tls: anyTls,
        // SPEC 103 D-024 — на всякий случай нормализуем и здесь: ручные
        // правки JSON/smart-paste могут занести голое число (в т.ч. как JSON
        // number, не строку) без единицы измерения.
        idleSessionCheckInterval: normalizeSingboxDuration(
            entry['idle_session_check_interval']?.toString() ?? ''),
        idleSessionTimeout: normalizeSingboxDuration(
            entry['idle_session_timeout']?.toString() ?? ''),
        // §472 шаг 6 — `_asInt`, а не жёсткий каст. Каст `as num?` бросал на
        // ЛЮБОМ нечисловом значении, а `parseUri`/`parseSingboxEntry` ловят
        // исключение и отдают `null`: узел исчезал целиком и молча. Задеть
        // это могло и тело провайдера (`"min_idle_session": "3"` строкой —
        // обычное дело у агрегаторов), и ссылку на конвейере, где сырое
        // значение обязано доехать до санитайзера СО СВОИМ написанием, чтобы
        // код `anytls_min_idle_invalid` назвал то, что написал автор.
        minIdleSession: _asInt(entry['min_idle_session']),
        tcpKeepAlive: ka,
      );
    case 'shadowsocks':
      if (server.isEmpty || port == 0) return null;
      return ShadowsocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'ss-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        method: entry['method']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        // §472 шаг 4 — поля SIP003 читались ТОЛЬКО URI-парсером, а из карты
        // sing-box терялись молча: узел, вставленный JSON-объектом или
        // отредактированный во вкладке JSON, уезжал в ядро без плагина и
        // соединения не поднимал (эмиссия их пишет — `emitShadowsocks`).
        // Обнаружено переездом URI-ветки на конвейер: через эту карту теперь
        // идёт и ссылка. Тот же класс, что `encryption` у vless на шаге 3.
        plugin: entry['plugin']?.toString() ?? '',
        pluginOpts: entry['plugin_opts']?.toString() ?? '',
        tcpKeepAlive: ka,
      );
    case 'hysteria2':
      if (server.isEmpty || port == 0) return null;
      // §219 — кастуем entry['obfs'] один раз (было дважды).
      final obfs = entry['obfs'] as Map?;
      // §547 A2 — обфускацию судит реестр (`hysteria2.json` →
      // `body.fields.obfs`: `type` — enum `salamander/gecko`, `trim_lower`,
      // `on_invalid: drop` с кодом `obfs_unknown`; `password` — `required` с
      // кодом `obfs_password_missing`, без него снимается весь блок). Модель
      // строится по карте санитайзера (ссылка — §472, JSON — §545), коды
      // ставит он же: у ссылки — конвейер, у JSON — проход по дословной карте
      // (`annotateFromRawBody`). Рукописная копия (`normalizeHysteria2Obfs`,
      // §358/§469) снята: второй производитель тех же кодов и второй enum.
      final obfsType = obfs?['type']?.toString() ?? '';
      // §472 шаг 5 — рукописного производителя `tls_not_applicable_quic`
      // здесь БОЛЬШЕ НЕТ.
      //
      // §469 ставил его отсюда потому, что санитайзер разбора смотрел на
      // `emit()`, где эмиттер блоки уже срезал. С шага 1 у
      // JSON-узла есть проход по ДОСЛОВНОЙ карте (`annotateFromRawBody`), и
      // правило реестра `forbidden_for` на `tls.utls`/`tls.reality` он
      // исполняет сам — по тому же телу, которое читала эта ветка, и с тем же
      // `value`. Дедуп по `(code, path)` дубль снимал, так что видно ничего не
      // было; лишним производитель от этого быть не перестал.
      //
      // Блоков нет и в теле: модель строится по карте санитайзера (§545),
      // эмиттер QUIC-срезов не делает (§546).
      return Hysteria2Spec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'hy2-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        password: entry['password']?.toString() ?? '',
        obfs: obfsType,
        obfsPassword:
            obfsType.isEmpty ? '' : obfs?['password']?.toString() ?? '',
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
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        // §281 (ревью) — naive принимает ТОЛЬКО enabled/server_name в TLS:
        // alpn/utls/insecure/reality ядро отклоняет при создании outbound
        // (fatal всего конфига). Зеркало naive_parser: срезаем блок.
        tls: _naiveTlsFromSingbox(entry['tls'], server),
        extraHeaders: extraHeaders,
        // §472 шаг 6 — поле ЧИТАЕТСЯ из тела. `emitNaive` его пишет
        // (`quic: true` + `quic_congestion_control: bbr`), а эта ветка не
        // читала вовсе: узел `naive+quic://`, пересохранённый через JSON или
        // отредактированный во вкладке JSON, молча возвращался к HTTP/2 и
        // соединения не поднимал. Тот же класс, что `encryption` у vless
        // (шаг 3) и `plugin` у shadowsocks (шаг 4).
        //
        // `quic_congestion_control` обратно в модель не идёт: у `NaiveSpec`
        // такого поля нет, значение у ядра одно (`bbr`), и эмиттер ставит его
        // сам по `quic`. Читать его было бы нечем и некуда.
        quic: entry['quic'] == true,
        tcpKeepAlive: ka,
      );
    case 'tuic':
      if (server.isEmpty || port == 0) return null;
      return TuicSpec(
        // §472 шаг 5 — рукописного производителя `tls_not_applicable_quic`
        // здесь больше нет, по той же причине, что и у hysteria2: с шага 1
        // правило реестра исполняет проход по ДОСЛОВНОЙ карте
        // (`annotateFromRawBody`), по тому же телу и с тем же значением.
        id: newUuidV4(),
        tag: tag.isEmpty ? 'tuic-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
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
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        user: entry['user']?.toString() ?? 'root',
        password: entry['password']?.toString() ?? '',
        privateKey: entry['private_key']?.toString() ?? '',
        privateKeyPassphrase: entry['private_key_passphrase']?.toString() ?? '',
        hostKey: hk is List ? hk.map((e) => e.toString()).toList() : const [],
        // §472 шаг 6 — поле ЧИТАЕТСЯ из тела. `emitSsh` его пишет, а эта
        // ветка не читала вовсе: узел, пересохранённый через JSON или
        // отредактированный во вкладке JSON, терял список алгоритмов
        // host-ключа молча. Тот же класс, что `encryption` у vless (шаг 3),
        // `plugin` у shadowsocks (шаг 4) и `quic` у naive выше.
        hostKeyAlgorithms: switch (entry['host_key_algorithms']) {
          final List l => l.map((e) => e.toString()).toList(),
          // `listable_string` реестра: одиночная строка — законная форма.
          final String s when s.isNotEmpty => [s],
          _ => const <String>[],
        },
        tcpKeepAlive: ka,
      );
    case 'socks':
      if (server.isEmpty || port == 0) return null;
      return SocksSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'socks-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        // §475 — версия ЧИТАЕТСЯ из тела. Раньше ветка её не читала вовсе, и
        // тело с `version: "4"` из JSON-вкладки уезжало в ядро пятёркой:
        // поле модели с дефолтом `'5'` никто не заполнял. Годность значения
        // судит санитайзер (enum реестра + `type_invalid`), сюда оно приходит
        // уже проверенным; пустое или отсутствующее — дефолт ядра, то есть
        // прежние `'5'`.
        version: (entry['version']?.toString().trim().toLowerCase() ?? '')
                .isEmpty
            ? '5'
            : entry['version'].toString().trim().toLowerCase(),
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        tcpKeepAlive: ka,
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
        label: label0,
        server: server,
        port: port,
        rawSource: src,
        username: entry['username']?.toString() ?? '',
        password: entry['password']?.toString() ?? '',
        path: entry['path']?.toString() ?? '',
        headers: headers,
        tls: _tlsFromSingbox(entry['tls'], server),
        tcpKeepAlive: ka,
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
      // §481 (контракт 1.1.11) — ГОДНОСТЬ ключей и правила AWG 3.x судит
      // ТОЛЬКО реестр (`wg_key_invalid`, `awg3_header_key_invalid`,
      // `awg3_padding_too_short` — все с `drop_node`). Здесь остаётся перевод
      // написания: неканоническая форма даёт другой identity-хеш той же ноде,
      // а о написании реестр молчит.
      final wgPrivRaw = entry['private_key']?.toString() ?? '';
      final wgPubRaw = p['public_key']?.toString() ?? '';
      final wgPriv = normalizeWGKey(wgPrivRaw) ?? wgPrivRaw;
      final wgPub = normalizeWGKey(wgPubRaw) ?? wgPubRaw;
      if (awg != null) normalizeAwgHeaderKey(awg);
      final wgPskRaw = p['pre_shared_key']?.toString() ?? '';
      final wgPsk =
          wgPskRaw.isEmpty ? '' : (normalizeWGKey(wgPskRaw) ?? wgPskRaw);
      return WireguardSpec(
        id: newUuidV4(),
        tag: wgTag,
        label: label0,
        server: peerServer,
        port: peerPort,
        rawSource: src,
        privateKey: wgPriv,
        localAddresses: addr,
        peers: [
          WireguardPeer(
            publicKey: wgPub,
            preSharedKey: wgPsk,
            endpointHost: peerServer,
            endpointPort: peerPort,
            allowedIps: allowedIps,
            // §421 — число или AWG3-диапазон `"N-M"` строкой.
            persistentKeepalive: _wgKeepaliveFromJson(
                p['persistent_keepalive_interval']),
            reserved: reserved,
          ),
        ],
        // §473 (контракт 1.1.5) — на входе `singbox` завышенный MTU НЕ
        // заменяется: тело в собственной форме ядра написали человек или
        // подписка, и молча переписывать его нельзя (`except_sources`,
        // решение владельца 18.09.2026). Узел получает info-код
        // `awg_mtu_high` — его ставит санитайзер по дословной карте
        // (`annotateFromRawBody`), и второй копии правила здесь не нужно.
        //
        // Дефолт 1280 при ОТСУТСТВИИ `mtu` действует и тут: исключение про
        // ЗАМЕНУ написанного, а не про подстановку недостающего (кейс корпуса
        // `body/singbox/endpoints_awg_mtu_default`). §421 — AWG3-маркер
        // (ключ корня или диапазонный keepalive) делает узел AmneziaWG
        // наравне с AWG2-полями.
        mtu: awg != null || Awg.hasAwg3Json(entry)
            ? (rawMtu ?? awgMtuCeilingByRegistry())
            : rawMtu,
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
      // §556 (контракт 1.1.64) — тело без `vhttp` остаётся без него: у ядра
      // это `auto`, и правила реестра судят его как отсутствие.
      final vhttpJson = (vhttpRaw.isEmpty || vhttpRaw == 'h3' ||
              vhttpRaw == 'h2' || vhttpRaw == 'auto')
          ? vhttpRaw
          : 'h3';
      final sniRaw = tlsMap['server_name']?.toString() ?? '';
      return MasqueSpec(
        // §472 шаг 7 — рукописного прохода по запрещённым на QUIC блокам
        // (`tls.utls`/`tls.reality`, §469) здесь БОЛЬШЕ НЕТ, и снят он не как
        // дубль, а как лишний ПРОИЗВОДИТЕЛЬ: с шага 1 у JSON-узла есть проход
        // по ДОСЛОВНОЙ карте (`annotateFromRawBody`), и правило
        // `forbidden_for` санитайзер исполняет по тому же телу, которое читала
        // эта ветка, с тем же `value`. Дедуп по `(code, path)` дубль снимал,
        // поэтому видно ничего не было. Ровно так же шаг 5 снял его у
        // hysteria2 и tuic (спека 472, 11.8); masque был последним
        // вызывающим, и вместе с ним ушла сама функция.
        id: newUuidV4(),
        tag: tag.isEmpty ? 'masque-$server-$port' : tag,
        label: label0,
        server: server,
        port: port,
        rawSource: src,
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
        tlsExtra: {
          for (final e in tlsMap.entries)
            if (e.key != 'server_name' &&
                e.key != 'disable_sni' &&
                e.key != 'enabled' &&
                e.value != null)
              '${e.key}': e.value as Object,
        },
      );
    case 'tailscale':
      // §435 / контракт ## 13 (NODE_SECTIONS.md §6) — endpoint без адреса:
      // принимается из `outbounds[]` и `endpoints[]` без `server`/
      // `server_port`, тело как есть. Никаких проверок полей: сторона, чьё
      // ядро без `with_tailscale`, всё равно обязана узел хранить — он
      // выбрасывается только при сборке (гейт ядра).
      return TailscaleSpec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'tailscale' : tag,
        label: label0,
        body: entry,
        rawSource: src,
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

/// §281/§454 — TLS для naive-entry: `enabled`/`server_name` плюс то, что
/// naive реально принимает из allowlist'а ([kNaiveTlsPassthroughKeys] —
/// `certificate`/`certificate_path`, issue #140). Остальное — `disable_sni`,
/// `insecure`, `alpn`, версии, `client_*`, `fragment*`, `kernel_*`, `utls`,
/// `reality` — ядро отвергает фаталом (`protocol/naive/outbound.go:45-86`).
/// Пин `certificate_public_key_sha256` naive молча не читает — тоже
/// срезаем, чтобы не обещать пиннинг, которого нет.
TlsSpec _naiveTlsFromSingbox(dynamic raw, String server) {
  final full = _tlsFromSingbox(raw, server);
  if (!full.enabled) return full;
  return TlsSpec(
    enabled: true,
    serverName: full.serverName,
    passthrough: {
      for (final e in full.passthrough.entries)
        if (kNaiveTlsPassthroughKeys.contains(e.key)) e.key: e.value,
    },
  );
}

/// §454 — сквозные ключи allowlist'а ядра ([kTlsPassthroughKeys]) в форме
/// прибытия. Guard «деградируй поле, не конфиг»: значение не того типа
/// (число вместо PEM, объект вместо строки, `false`) — ключ отброшен молча,
/// соседи и узел живут; `Listable[string]` с мусором ронял бы разбор всего
/// конфига в ядре. `false` у булевых = omitempty ядра, не хранится.
Map<String, Object> tlsPassthroughFromSingbox(Map raw) {
  final out = <String, Object>{};
  for (final k in kTlsPassthroughKeys) {
    if (!raw.containsKey(k)) continue;
    final v = raw[k];
    if (kTlsBoolKeys.contains(k)) {
      if (v == true) out[k] = true;
    } else if (kTlsObjectKeys.contains(k)) {
      // §459 (контракт §24.2 п. 7.2) — объектный сквозной ключ (`tls.ech`):
      // копируем карту как есть, внутрь не смотрим (состав задаёт ядро).
      // Не-Map (строка, число) → отброшен молча, как остальные guard'ы.
      if (v is Map) {
        final obj = Map<String, dynamic>.from(v.cast<String, dynamic>());
        if (obj.isNotEmpty) out[k] = obj;
      }
    } else if (kTlsListableKeys.contains(k)) {
      if (v is String) {
        if (v.isNotEmpty) out[k] = v;
      } else if (v is List) {
        final list = [
          for (final e in v)
            if (e is String && e.isNotEmpty) e,
        ];
        if (list.isNotEmpty) out[k] = list;
      }
    } else if (v is String && v.isNotEmpty) {
      out[k] = v;
    }
  }
  return out;
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
      // §472 шаг 5 — `disable_sni` отменяет ОТКАТ на адрес сервера, но не
      // трогает имя, которое автор написал сам.
      //
      // Откат существует, чтобы у обычного узла в модели стояло имя, которое
      // ядро и так подставит. При `disable_sni` ядро не отправляет расширение
      // SNI вовсе, так что подставлять было бы нечего: `toUri()` вернул бы
      // `sni=`, которого автор не писал. Тело от этого не меняется — ключ
      // сквозной (`kTlsPassthroughKeys`) и сохраняется как есть, вместе с
      // явным `server_name`, если он там был.
      //
      // §560 — откат на адрес СНЯТ из модели: его объявляет реестр там, где
      // он нужен (`default_from: host` у блоков `tls#uri`), и маппер пишет
      // имя в тело сам. Xray-блок отката не объявляет, у тела sing-box его
      // делает ядро; модель, дописывавшая адрес всем, давала тело, которого
      // провайдер не присылал (корпус xray/multinode_310).
      serverName: raw['server_name']?.toString(),
      // §460 — `alpn` у ядра Listable: массив → типизированный список, строка
      // → сквозной ключ в форме прибытия (корпус outbound_array_tls_fields
      // `vless-alpn-str`); раньше `as List` на строке ронял узел целиком.
      alpn: switch (raw['alpn']) {
        final List l => [for (final e in l) e.toString()],
        _ => const [],
      },
      insecure: raw['insecure'] == true,
      // Контракт 1.1.61 — включённый uTLS без отпечатка (его дописывает
      // `requires[].set` у REALITY) держится в модели пустой строкой.
      fingerprint: utls?['fingerprint']?.toString() ??
          (utls?['enabled'] == true ? '' : null),
      // §454 — пин (D-078) из JSON раньше не читался вовсе: только из
      // `pinSHA256=` hysteria2-URI. Listable ядра: строка или массив.
      certificatePublicKeySha256: switch (raw['certificate_public_key_sha256']) {
        final String v when v.isNotEmpty => [v],
        final List v => [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ],
        _ => const [],
      },
      passthrough: {
        ...tlsPassthroughFromSingbox(raw),
        if (raw['alpn'] case final String a when a.isNotEmpty) 'alpn': a,
      },
      // §169 — REALITY только при enabled И валидном X25519 public_key. Битый
      // ключ → reality=null (нода остаётся plain TLS), а не отравляет config.
      reality:
          reality == null ||
              reality['enabled'] != true ||
              !isValidRealityPublicKey(reality['public_key']?.toString() ?? '')
          ? null
          : RealitySpec(
              // §480 Д-6 — написание ключа переводится в форму ядра
              // (RawURL): std-алфавит законен по реестру, но ядро на нём
              // отвечает `illegal base64 data` и роняет ВЕСЬ конфиг.
              //
              // Контракт 1.1.40 объявил это правило реестром —
              // `normalize: base64_rawurl` у `tls.reality.public_key`, — и
              // санитайзер исполняет его на ВСЕХ входах. Здесь рукописный
              // перевод снят: два движка одного правила рано или поздно
              // разошлись бы, а тело рабочего узла обязано остаться одним.
              publicKey: reality['public_key']!.toString().trim(),
              shortId: normalizeRealityShortId(
                reality['short_id']?.toString() ?? '',
              ),
              keyShare: _realityKeyShare(reality['key_share']),
            ),
    ),
    null,
  );
}

/// §457 — `tls.reality.key_share` в модель: пустое не пишем.
///
/// §547 A1 — значение судит реестр (`tls.json` →
/// `body.fields.reality.fields.key_share`: enum `""/hybrid/classical`,
/// `normalize: trim_lower`, `on_invalid: drop` с кодом
/// `reality_key_share_invalid`). Модель строится по карте санитайзера на всех
/// входах (ссылка — конвейер §472, sing-box JSON — §545), а гард сборки
/// (`applyRegistryGate`) судит тело ещё раз перед ядром. Рукописная копия
/// enum (`kRealityKeyShares`) и её фильтр сняты: правка реестра до них не
/// доходила.
String? _realityKeyShare(dynamic raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

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
        // §476 — прочие заголовки ЧИТАЮТСЯ. `WsTransport.headers` их эмитит, а
        // эта ветка брала из карты один `Host`: узел с `User-Agent` или
        // `X-Forwarded-For`, пересохранённый через JSON-вкладку, терял их
        // молча. `Host` остаётся отдельным полем (его пишет эмиттер сам) и в
        // карту заголовков не дублируется.
        headers: _headersExceptHost(headers),
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
        // §476 — заголовки ЧИТАЮТСЯ: `HttpTransport.headers` их эмитит, а эта
        // ветка не читала вовсе. У http-транспорта `Host` живёт отдельным
        // полем `host` (списком), поэтому карта берётся целиком.
        headers: (raw['headers'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), _headerValue(v)),
            ) ??
            const {},
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
        // §476 — заголовки ЧИТАЮТСЯ, как у ws. `Host` идёт отдельным полем.
        headers: _headersExceptHost(
            (raw['headers'] as Map?)?.cast<String, dynamic>()),
      );
    // §463 / контракт §24.2 п. 7.13 — алиас прежнего имени Xray.
    case 'splithttp':
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

/// §476 — заголовки транспорта, кроме `Host`: он живёт отдельным полем модели
/// (`WsTransport.host`) и эмитится ею же, так что в карте он был бы вторым
/// производителем одного ключа.
Map<String, String> _headersExceptHost(Map<String, dynamic>? raw) {
  if (raw == null) return const {};
  final out = <String, String>{};
  for (final e in raw.entries) {
    if (e.key == 'Host') continue;
    out[e.key] = _headerValue(e.value);
  }
  return out;
}

/// Значение заголовка: sing-box зовёт его `Listable[string]` — строка либо
/// массив. Модель держит строку, поэтому из списка берётся первый элемент,
/// ровно как у `naive.extra_headers` и `http.headers` узла.
String _headerValue(Object? v) {
  if (v is List) return v.isEmpty ? '' : v.first.toString();
  return v?.toString() ?? '';
}

/// §421 — `persistent_keepalive_interval` из JSON: число → `int`,
/// строка-диапазон `"N-M"` → как есть (валидная), иначе `null`.
Object? _wgKeepaliveFromJson(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return parseWgKeepalive(v);
  return null;
}
