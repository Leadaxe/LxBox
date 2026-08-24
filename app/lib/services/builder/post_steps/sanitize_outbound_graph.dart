part of '../post_steps.dart';

/// Post-step: §393 A4 — финальный граф-санитайзер outbound-секции.
///
/// Порт `core/build/outbound_graph_sanitize.go` лаунчера. Единственный проход
/// по ГРАФУ зависимостей вместо частных проверок, живших в непересекающихся
/// подграфах (у нас это был `healDanglingDetours` — он ПОГЛОЩЁН этим шагом).
///
/// У ядра рёбра зависимостей одни — `detour` узла, member группы (и позиция
/// цепочки, фаза C) — и любая висячая ссылка или кольцо в этом графе фатальны
/// для конфига ЦЕЛИКОМ: sing-box отвергает файл сообщением, которое указывает
/// не на виновника, а на первого, кто на него сослался
/// (`dependency[X] not found for outbound[Y]`).
///
/// Частные проверки выше по конвейеру ловят каждая свой класс, но не транзит
/// через рёбра ЧУЖОГО вида: узел, задетуренный на группу через промежуточный
/// узел; группа, у которой после каскада удалений не осталось участников.
/// Здесь — последняя точка, где виден весь граф целиком, поэтому политика
/// одна и окончательная: деградировать один элемент с warning, а не отдать
/// ядру конфиг, который оно отвергнет.
///
/// Правила (нумерация эталона):
///  1. `detour` на несуществующий тег → ключ снят (узел ходит напрямую).
///     Текст warning'а разный по виновнику: цели не было изначально (битая
///     подписка) либо цель опустела и снята каскадом правила 2 здесь же —
///     во втором случае «referenced missing X» было бы ложью;
///  2. группа (`selector`/`urltest`): участники-призраки исключаются из
///     состава; пустеющая группа — Направление уходит в block-fallback
///     (как `emptyFallback` в `_buildDirectionGroups`), прочая группа
///     дропается;
///  3. `default` группы вне состава → заменён на первого участника
///     (`kept[0]`), с warning. Ядро иначе отвергает конфиг целиком
///     («default outbound not found», L1);
///  4. узел с `detour` на группу, в состав которой сам входит → ВОН ИЗ
///     СОСТАВА, detour сохранён (fail-open, эталон `detour_group_cycle.go`:
///     detour задан осознанно, тихо отправить трафик напрямую — нарушить
///     ровно то, о чём просил пользователь). «Входит в состав» считается по
///     СТРУКТУРНЫМ рёбрам, вглубь вложенных групп и auto-двойников, но НЕ
///     через detour'ы чужих узлов — те кольца минимальнее рвёт правило 5.
///     Warning агрегируется по УЗЛУ, а не по группе: один узел состоит и в
///     селекторе Направления, и в его `-auto`-двойнике (§377);
///  5. кольцо по любым рёбрам (detour → member → …) разрывается по ребру,
///     замкнувшему цикл: `detour` → снят, `member` → исключён из состава
///     (эталон `breakDependencyCycle`). §254-fatal валидатора остаётся
///     ПОСЛЕДНИМ рубежом на неразруленное — санитайзер чинит ДО него.
///
/// Композиция правил 4 и 2 переворачивает политику узла: сохранённый detour
/// ведёт в Направление, которое тем же прогоном ушло в block-fallback, и
/// трафик узла теперь блокируется. Detour при этом СОХРАНЯЕТСЯ (снять =
/// выпустить трафик мимо VPN, чего `empty_direction_blocks` не допускает), но
/// после фикспойнта выдаётся КОМПОЗИТНЫЙ warning с именами таких узлов —
/// ни одна из отдельных строк последствия для узла не называет.
///
/// Удаление узла делает висячими новые ссылки — проход повторяется до
/// фикспойнта (лимит `len*4+8` защитный: каждый содержательный проход снимает
/// ребро или узел, их конечное число).
///
///  6. (§393 C4, эталон — правило 3 `sanitizeEntryRefs`, ветка `isChain()`)
///     `type: chain`: позиция на несуществующий тег ЛИБО другая цепочка на
///     позиции ≥1 → цепочка ДРОПАЕТСЯ ЦЕЛИКОМ. Это НЕ групповая семантика:
///     маршрут без хопа — другой маршрут, исключить хоп из состава нельзя;
///  7. (§393 C4, эталон `pruneChainLeavesUnderGroups`) группа, стоящая
///     позицией ≥1 какой-либо цепочки (транзитивно через вложенные группы),
///     не должна содержать цепочек в участниках — ядро обходит ЛИСТЬЯ группы
///     на старте и отвергает вложенную цепочку («nested chain is only allowed
///     at position 0»); `check` этого не ловит, падает только `run` (L4).
///
/// КЛЮЧЕВАЯ ЛОВУШКА ЦЕПОЧЕК: у `type: chain` хопы лежат в том же ключе
/// `outbounds[]`, что и состав группы, но значат ДРУГОЕ — позиции маршрута,
/// а не взаимозаменяемые опции. Записать `chain` в [_isGroup] значило бы
/// молча выдать ей групповую семантику: призрачный хоп исключился бы из
/// «состава» вместо дропа цепочки, и пользователь поехал бы по маршруту, о
/// котором не просил. Поэтому [_isGroup] цепочку НЕ включает, а всё, что
/// разбирает `outbounds[]`, обязано сначала спросить [_isChain].
///
/// [directionTags] — теги Направлений: только они при опустошении уходят в
/// block-fallback вместо дропа (Направление — цель правил маршрутизации,
/// его исчезновение сделало бы висячими `route.rules[].outbound`).
/// [blockTag]/[directTag] — теги служебных outbound'ов для fallback.
///
/// Возвращает список EN-строк для `emitWarnings`. Пустой = граф был чист.
List<String> sanitizeOutboundGraph(
  Map<String, dynamic> config, {
  Set<String> directionTags = const {},
  String blockTag = kBlockOutboundTag,
  String directTag = kDirectOutboundTag,
}) {
  final outbounds = (config['outbounds'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final endpoints = (config['endpoints'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final entries = [...outbounds, ...endpoints];
  if (entries.isEmpty) return const [];

  final warnings = <String>[];
  // §377-совместимая агрегация: одна строка на отсутствующий target, а не на
  // каждую ноду (один выключенный WARP-пресет из подписки давал 138
  // идентичных warning'ов). Собираем здесь, рендерим в конце.
  final danglingDetourOwners = <String, List<String>>{};
  // Те же снятые detour'ы, но по цели, которую УДАЛИЛ САМ санитайзер (каскад
  // правила 2): текст про «referenced missing X» тут был бы ложью — отправил
  // бы юзера искать битую подписку вместо того, что произошло на самом деле.
  final sanitizedDetourOwners = <String, List<String>>{};
  // Теги, дропнутые санитайзером за ЭТОТ прогон. Нужны только правилу 1,
  // чтобы отличить «цели никогда не было» от «цель опустела и снята здесь».
  final droppedTags = <String>{};
  // §377-агрегация для правила 4: ключ — ВИНОВАТЫЙ УЗЕЛ, значение — группы,
  // из состава которых он выброшен. Один узел состоит и в селекторе
  // Направления, и в его auto-двойнике, поэтому агрегация по группе давала бы
  // два warning'а об одной и той же ноде.
  final cyclicMemberGroups = <String, List<String>>{};
  // Направления, ушедшие в block-fallback правилом 2. Композитный warning по
  // ним считается ПОСЛЕ фикспойнта: до него неизвестно, чьи detour'ы уцелеют.
  final blockedDirections = <String>[];

  final byTag = <String, Map<String, dynamic>>{};
  for (final e in entries) {
    final tag = e['tag'];
    if (tag is String && tag.isNotEmpty) byTag[tag] = e;
  }
  final dropped = <Map<String, dynamic>>{};

  // Живость — ТОЛЬКО по факту записи в `outbounds[]`/`endpoints[]`. Никаких
  // «магических» тегов-исключений: к моменту санитайзера шаблонные outbound'ы
  // уже слиты в config (`block`/`direct-out` эмитит `magic_nodes`
  // wizard_template), а валидатор (`validator.dart`, `allTags`) строит
  // множество живых тегов ровно так же — по фактическим записям. Считать тег
  // живым «без записи» значило бы оставить ссылку, на которой валидатор
  // упадёт фатально уже ПОСЛЕ санитайзера (fail-open здесь = fatal там).
  //
  // `dns-out`/`block-out` записей не имеют и не эмитятся ничем: они лишь
  // заняты аллокатором тегов билдера (`_BuildCtx._taken`), чтобы никакое
  // Направление их не забрало. `direct`/`reject`/`drop` — ACTION-псевдоцели
  // правил маршрутизации, а не outbound-теги; в `detour`/составе группы они
  // такие же призраки, как любой другой отсутствующий тег.
  bool alive(String tag) {
    final e = byTag[tag];
    return e != null && !dropped.contains(e);
  }

  void dropEntry(Map<String, dynamic> e, String why) {
    if (!dropped.add(e)) return;
    droppedTags.add(_tagOf(e));
    warnings.add('Outbound "${_tagOf(e)}" removed from the config: $why');
  }

  final limit = entries.length * 4 + 8;
  for (var iter = 0; iter < limit; iter++) {
    var changed = false;
    for (final e in entries) {
      if (dropped.contains(e)) continue;
      if (_sanitizeEntryRefs(
        e,
        alive: alive,
        byTag: byTag,
        dropped: dropped,
        drop: dropEntry,
        warnings: warnings,
        danglingDetourOwners: danglingDetourOwners,
        sanitizedDetourOwners: sanitizedDetourOwners,
        droppedTags: droppedTags,
        cyclicMemberGroups: cyclicMemberGroups,
        blockedDirections: blockedDirections,
        directionTags: directionTags,
        blockTag: blockTag,
        directTag: directTag,
      )) {
        changed = true;
      }
    }
    if (_pruneChainLeavesUnderGroups(
      entries,
      alive: alive,
      byTag: byTag,
      dropped: dropped,
      warnings: warnings,
    )) {
      changed = true;
    }
    if (_breakDependencyCycle(
      entries,
      alive: alive,
      byTag: byTag,
      dropped: dropped,
      warnings: warnings,
    )) {
      changed = true;
    }
    if (!changed) break;
  }

  // Композиция «fail-open → fail-closed». Правило 4 сохраняет detour узла,
  // выброшенного из состава группы (снять = выпустить трафик мимо VPN, чего
  // принцип `empty_direction_blocks` не допускает). Но если ЭТА группа —
  // Направление и она же опустела до block-fallback, то сохранённый detour
  // теперь ведёт узел в `block`: политика узла молча перевернулась с «ходи
  // через Направление» на «весь твой трафик заблокирован».
  //
  // Конфиг при этом валиден и ядро стартует — молчать здесь нельзя тем более:
  // ни один другой warning не называет ПОСЛЕДСТВИЕ для конкретного узла.
  // Считаем после фикспойнта: до него неизвестно, чей detour уцелеет (свой
  // detour узел мог потерять правилом 1 или правилом 5, а сам узел — быть
  // дропнут каскадом).
  for (final dirTag in blockedDirections) {
    final riders = <String>[];
    for (final e in entries) {
      if (dropped.contains(e)) continue;
      if (e['detour'] == dirTag) {
        final owner = _tagOf(e);
        if (owner.isNotEmpty && !riders.contains(owner)) riders.add(owner);
      }
    }
    if (riders.isEmpty) continue;
    warnings.add(_blockedDetourRidersLine(dirTag, riders));
  }

  for (final e in cyclicMemberGroups.entries) {
    warnings.add(_detourGroupCycleLine(e.key, e.value));
  }
  for (final e in danglingDetourOwners.entries) {
    warnings.add(_detourRemovedLine(e.key, e.value));
  }
  for (final e in sanitizedDetourOwners.entries) {
    warnings.add(_detourRemovedLine(e.key, e.value, targetSanitized: true));
  }

  // Мутация СПИСКА на месте, а не переприсваивание: `config` приходит из
  // литералов теста и из шаблона с узкими generic'ами (`List<Map<…>>`), и
  // присвоение `List<dynamic>` кинуло бы TypeError на ровном месте.
  if (dropped.isNotEmpty) {
    for (final key in const ['outbounds', 'endpoints']) {
      final list = config[key];
      if (list is List) {
        list.removeWhere((o) => o is Map<String, dynamic> && dropped.contains(o));
      }
    }
  }
  return warnings;
}

String _tagOf(Map<String, dynamic> e) => e['tag'] as String? ?? '';

/// Группа с ПЕРЕСМАТРИВАЕМЫМ составом. `type: chain` сюда НЕ входит намеренно
/// (см. «ключевая ловушка цепочек» в шапке): её `outbounds[]` — позиции
/// маршрута, а не взаимозаменяемые опции, и «исключить призрака из состава»
/// для неё означало бы молча увести трафик другим путём.
bool _isGroup(Map<String, dynamic> e) {
  final t = e['type'];
  return t == 'selector' || t == 'urltest';
}

/// §393 C4 — цепочка хопов. Отличается от группы РОВНО типом: ключ
/// `outbounds[]` у обеих один, а смысл разный.
bool _isChain(Map<String, dynamic> e) => e['type'] == kChainOutboundType;

/// §393 A4 правило 5 — вид ребра графа зависимостей. От него зависит, ЧЕМ
/// разрывать кольцо: `detour` снимается ключом, `member` исключается из
/// состава, а `chainHop` вынуждает дропнуть цепочку целиком — снять позицию
/// нельзя, маршрут без хопа это другой маршрут (§393 C4).
enum _EdgeKind { detour, member, chainHop }

List<String> _membersOf(Map<String, dynamic> e) =>
    (e['outbounds'] as List<dynamic>? ?? const []).whereType<String>().toList();

void _setMembers(Map<String, dynamic> e, List<String> members) {
  e['outbounds'] = members;
}

/// §393 A4 — правила 1–4 для одной записи. `true`, если что-то изменилось.
bool _sanitizeEntryRefs(
  Map<String, dynamic> e, {
  required bool Function(String) alive,
  required Map<String, Map<String, dynamic>> byTag,
  required Set<Map<String, dynamic>> dropped,
  required void Function(Map<String, dynamic>, String) drop,
  required List<String> warnings,
  required Map<String, List<String>> danglingDetourOwners,
  required Map<String, List<String>> sanitizedDetourOwners,
  required Set<String> droppedTags,
  required Map<String, List<String>> cyclicMemberGroups,
  required List<String> blockedDirections,
  required Set<String> directionTags,
  required String blockTag,
  required String directTag,
}) {
  var changed = false;
  final tag = _tagOf(e);

  // Правило 1 — висячий detour: ключ снят, узел ходит напрямую (§172).
  final detour = e['detour'];
  if (detour is String && detour.isNotEmpty && !alive(detour)) {
    e.remove('detour');
    // Развилка по ВИНОВНИКУ: цель, которой не было в конфиге изначально
    // (битая подписка / чужой JSON), и цель, которую снял сам санитайзер
    // каскадом правила 2, требуют разных текстов. Свалить их в один «missing»
    // значит отправить юзера чинить подписку, в которой всё было в порядке.
    final bucket =
        droppedTags.contains(detour) ? sanitizedDetourOwners : danglingDetourOwners;
    (bucket[detour] ??= []).add(tag);
    changed = true;
  }

  // §393 C4 правило 6 — цепочка. Проверяется ДО группового ветвления и по
  // своей семантике: у неё в `outbounds[]` лежат ПОЗИЦИИ маршрута.
  //
  // Оба нарушения дропают цепочку ЦЕЛИКОМ, а не правят её состав:
  //   • позиция на несуществующий тег — ядро не стартует на висячей ссылке,
  //     а «просто убрать позицию» превратило бы маршрут в другой маршрут
  //     (`[home, de, exit]` без `de` — уже не «через Германию»);
  //   • другая цепочка на позиции ≥1 — инвариант ядра
  //     (`protocol/chain/chain.go:279`): звено это «узел через предыдущую
  //     позицию», а цепочка не узел и не пересобирается под чужой диалер.
  //
  // Зачем это ЗДЕСЬ, если `resolveChains` проверяет то же на эмиссии: там
  // виден список цепочек, здесь — итоговый конфиг. Между ними работают
  // heal'ы, которые могут дропнуть узел, БЫВШИЙ позицией живой цепочки
  // (выключенная подписка, снятый REALITY, каскад правила 2). Это и есть
  // «последняя точка, где виден весь граф».
  if (_isChain(e)) {
    final hops = _membersOf(e);
    for (var i = 0; i < hops.length; i++) {
      final ref = hops[i];
      if (!alive(ref)) {
        drop(
            e,
            'hop "$ref" (position ${i + 1}) does not exist in the final '
                'config — a route without a hop would be a different route');
        return true;
      }
      if (i >= 1) {
        final t = byTag[ref];
        if (t != null && !dropped.contains(t) && _isChain(t)) {
          drop(
              e,
              'nested chain "$ref" is at position ${i + 1} — the core allows '
                  'a nested chain only as the first hop');
          return true;
        }
      }
    }
    return changed;
  }

  if (!_isGroup(e)) return changed;

  final members = _membersOf(e);
  final kept = <String>[];
  final lost = <String>[];
  // Правило 4 — узел, чей detour ведёт в ЭТУ группу, из состава вон, а его
  // detour остаётся (fail-open, эталон `detour_group_cycle.go`: detour задан
  // осознанно, тихо отправить трафик напрямую — нарушить ровно то, о чём
  // просил пользователь).
  //
  // Достижимость считается по СТРУКТУРНЫМ рёбрам (состав групп), но НЕ через
  // detour'ы чужих узлов. Обе границы обязательны:
  //   • одного лишь ПРЯМОГО совпадения (как в эталоне, где состав группы —
  //     плоский список нод) мало: `<tag>-auto` держит те же узлы, что и
  //     селектор Направления, и узел с `detour: vpn-2` замкнул бы кольцо
  //     vpn-2 → vpn-2-auto → узел, а правило 5 развязало бы его СНЯТИЕМ
  //     detour'а — ровно тем, чего эталон требует избежать;
  //   • шагать дальше по detour'ам ЧУЖИХ узлов нельзя: тогда виновным
  //     объявляется каждый, кто просто смотрит в сторону кольца. Реальный
  //     кейс §254 (флот BL ∈ vpn-2 детурит в vpn-3, одна AWG-нода ∈ vpn-3
  //     детурит обратно в vpn-2) выбросил бы из vpn-2 весь невиновный флот и
  //     увёл Направление в block вместо того, чтобы снять один detour у
  //     виноватой ноды. Такие кольца — работа правила 5 с его минимальным
  //     набором виновников.
  final cyclic = <String>[];
  for (final ref in members) {
    if (!alive(ref)) {
      if (!lost.contains(ref)) lost.add(ref);
      continue;
    }
    // `alive(ref)` выше уже гарантировал запись; локальная переменная — чтобы
    // не индексировать мапу дважды.
    final m = byTag[ref];
    if (m != null && _detourReaches(m, tag, byTag, alive)) {
      if (!cyclic.contains(ref)) cyclic.add(ref);
      continue;
    }
    if (!kept.contains(ref)) kept.add(ref);
  }

  if (lost.isNotEmpty) {
    warnings.add(
        'Group "$tag": members ${_quotedList(lost)} do not exist in the final '
        'config — excluded from the group.');
    changed = true;
  }
  if (cyclic.isNotEmpty) {
    // Строку рисует вызывающий, агрегируя по узлу (см. [cyclicMemberGroups]).
    for (final ref in cyclic) {
      final groups = cyclicMemberGroups[ref] ??= [];
      if (!groups.contains(tag)) groups.add(tag);
    }
    changed = true;
  }
  if (lost.isNotEmpty || cyclic.isNotEmpty || kept.length != members.length) {
    _setMembers(e, kept);
    changed = true;
  }

  // Правило 2 — группа опустела.
  if (kept.isEmpty) {
    if (directionTags.contains(tag) && e['type'] == 'selector') {
      // Направление — цель правил маршрутизации: его исчезновение сделало бы
      // висячими `route.rules[].outbound`. Уходит в тот же block-fallback,
      // что и пустое по фильтру Направление (§201/§274, эталон
      // `empty_direction_blocks.expected.json`): блокировать безопаснее, чем
      // выпускать мимо VPN, direct остаётся опцией.
      _setMembers(e, [blockTag, directTag]);
      e['default'] = blockTag;
      if (!blockedDirections.contains(tag)) blockedDirections.add(tag);
      warnings.add(
          'Direction "$tag": no members left after graph sanitation — traffic '
          'is blocked (default).');
      return true;
    }
    drop(e, 'no members left');
    return true;
  }

  // Правило 3 — `default` вне состава. Ядро иначе отвергает конфиг целиком
  // («default outbound not found», L1). НЕ трогаем default=block, который
  // поставил block-fallback выше/`_buildDirectionGroups`: он в составе.
  final def = e['default'];
  if (def is String && def.isNotEmpty && !kept.contains(def)) {
    warnings.add(
        'Group "$tag": default "$def" is not among its members — replaced '
        'with "${kept.first}".');
    e['default'] = kept.first;
    changed = true;
  }
  return changed;
}

/// §393 A4 правило 4 — ведёт ли собственный `detour` узла [node] в группу
/// [target], считая по СТРУКТУРНЫМ рёбрам: сама цель detour'а и, если она
/// группа, её состав вглубь (вложенные группы, auto-двойники).
///
/// Ровно один detour-шаг — стартовый. Дальше идут только рёбра состава:
/// detour'ы ЧУЖИХ узлов сюда не входят, иначе правило объявило бы виновным
/// каждого, кто просто смотрит в сторону кольца (см. комментарий у
/// колл-сайта, кейс §254). Такие кольца развязывает правило 5.
bool _detourReaches(
  Map<String, dynamic> node,
  String target,
  Map<String, Map<String, dynamic>> byTag,
  bool Function(String) alive,
) {
  final d = node['detour'];
  if (d is! String || d.isEmpty) return false;
  final seen = <String>{};
  final queue = <String>[d];
  while (queue.isNotEmpty) {
    final tag = queue.removeLast();
    if (tag == target) return true;
    if (!seen.add(tag) || !alive(tag)) continue;
    final e = byTag[tag];
    if (e == null || !_isGroup(e)) continue;
    queue.addAll(_membersOf(e));
  }
  return false;
}

/// §393 C4 правило 7 — порт `pruneChainLeavesUnderGroups` эталона.
///
/// Множество групп, достижимых как позиция ≥1 какой-либо цепочки
/// (транзитивно, через вложенные группы), не должно содержать ЦЕПОЧЕК в
/// участниках.
///
/// Почему транзитивно и почему именно листья. Ядро на старте разворачивает
/// позицию в тот outbound, который группа выбрала, и обходит ЛИСТЬЯ группы —
/// то есть проверку «вложенная цепочка только позицией 0» оно применяет не к
/// записи в конфиге, а к тому, что реально окажется звеном. Группа опций, в
/// которой лежит цепочка, стоя́ второй позицией другой цепочки, даёт ровно
/// запрещённую конструкцию — но только в момент выбора этой опции.
/// `sing-box check` этого не ловит; падает `run` (§393 L4), то есть у
/// пользователя — при попытке подключиться.
///
/// Цепочка исключается ИЗ СОСТАВА ГРУППЫ (а не дропается сама): здесь она
/// именно взаимозаменяемая опция, и остальные опции группы валидны. Опустевшая
/// группа и `default` вне состава доработаются правилом 2 на следующей
/// итерации фикспойнта.
bool _pruneChainLeavesUnderGroups(
  List<Map<String, dynamic>> entries, {
  required bool Function(String) alive,
  required Map<String, Map<String, dynamic>> byTag,
  required Set<Map<String, dynamic>> dropped,
  required List<String> warnings,
}) {
  // Стартовое множество: группы, на которые ссылаются позиции ≥1.
  final queue = <String>[];
  final seen = <String>{};
  for (final e in entries) {
    if (dropped.contains(e) || !_isChain(e)) continue;
    final hops = _membersOf(e);
    for (var i = 1; i < hops.length; i++) {
      final ref = hops[i];
      final t = byTag[ref];
      if (t != null && !dropped.contains(t) && _isGroup(t) && seen.add(ref)) {
        queue.add(ref);
      }
    }
  }
  var changed = false;
  while (queue.isNotEmpty) {
    final tag = queue.removeAt(0);
    final g = byTag[tag];
    if (g == null || dropped.contains(g)) continue;
    final kept = <String>[];
    final lost = <String>[];
    for (final ref in _membersOf(g)) {
      final t = byTag[ref];
      if (t != null && !dropped.contains(t) && _isChain(t)) {
        if (!lost.contains(ref)) lost.add(ref);
        continue;
      }
      if (t != null && !dropped.contains(t) && _isGroup(t) && seen.add(ref)) {
        queue.add(ref);
      }
      kept.add(ref);
    }
    if (lost.isNotEmpty) {
      warnings.add(
          'Group "$tag" is used as a hop (position 2 or later) of a chain, so '
          'chains ${_quotedList(lost)} were excluded from it — the core allows '
          'a nested chain only as the first hop and would fail to start.');
      _setMembers(g, kept);
      changed = true;
    }
  }
  return changed;
}

/// §393 A4 правило 5 — кольцо по любым рёбрам (`detour` узла, member группы).
///
/// Политика — лаунчера (`breakDependencyCycle`): деградировать с warning, а
/// не отдать ядру конфиг, который оно отвергнет. Но ВЫБОР рвущегося ребра —
/// §254-й, LxBox'овый, а не «первое замыкающее из DFS» эталона: у мобилы уже
/// есть детектор минимального набора виновников (`_cyclicNodes`
/// `validator.dart`), и брать первое попавшееся ребро значило бы резать
/// невиновных. Реальный кейс §254 (флот BL детурит в vpn-3, одна AWG-нода
/// внутри vpn-3 детурит обратно в vpn-2) на «первом замыкающем» отобрал бы
/// detour у ДВУХ чистых BL-нод вместо одной виноватой AWG.
///
/// Алгоритм:
///   1. циклические узлы — итеративный Tarjan SCC (SCC>1 либо self-loop),
///      порт `_cyclicNodes` на графе санитайзера;
///   2. кандидаты — removable-рёбра ВНУТРИ циклического множества:
///      `detour` узла и member группы;
///   3. score(e) = сколько узлов перестают быть циклическими без e;
///   4. победитель (тай-брейк — лексикографический по паре тегов) снимается
///      по типу: `detour` → ключ удаляется, member → исключается из состава.
///
/// Рвёт ОДНО ребро за вызов; фикспойнт зовёт снова, пока колец не останется.
/// §254-fatal валидатора остаётся последним рубежом на неразруленное.
bool _breakDependencyCycle(
  List<Map<String, dynamic>> entries, {
  required bool Function(String) alive,
  required Map<String, Map<String, dynamic>> byTag,
  required Set<Map<String, dynamic>> dropped,
  required List<String> warnings,
}) {
  // Граф: только живые записи с непустым тегом. Магические теги (`block`,
  // `direct-out`) записей не имеют → рёбер не порождают и в граф не входят.
  final nodes = <String>[];
  final detourEdge = <String, String>{};
  final memberEdges = <String, List<String>>{};
  final chainOwners = <String>{};
  for (final e in entries) {
    if (dropped.contains(e)) continue;
    final tag = _tagOf(e);
    if (tag.isEmpty) continue;
    nodes.add(tag);
    final d = e['detour'];
    if (d is String && d.isNotEmpty && byTag[d] != null && !dropped.contains(byTag[d]!)) {
      detourEdge[tag] = d;
    }
    // Состав группы и позиции цепочки — рёбра одного графа: ядро на кольце
    // из любых из них отвергает конфиг целиком. Разводятся они только на
    // РАЗРЫВЕ (см. [_EdgeKind]), поэтому в детекции лежат вместе.
    if (_isGroup(e) || _isChain(e)) {
      final live = [
        for (final m in _membersOf(e))
          if (byTag[m] != null && !dropped.contains(byTag[m]!)) m,
      ];
      if (live.isNotEmpty) memberEdges[tag] = live;
      if (_isChain(e)) chainOwners.add(tag);
    }
  }

  Set<String> cyclicWithout(({String from, String ref, _EdgeKind kind})? cut) =>
      _cyclicGraphNodes(nodes, detourEdge, memberEdges, cut);

  final cyclic = cyclicWithout(null);
  if (cyclic.isEmpty) return false;

  // Кандидаты: рёбра, ОБА конца которых циклические (ребро вне кольца его не
  // развяжет). Порядок фиксирован — тай-брейк детерминирован.
  final candidates = <({String from, String ref, _EdgeKind kind})>[];
  for (final tag in nodes) {
    if (!cyclic.contains(tag)) continue;
    final d = detourEdge[tag];
    if (d != null && cyclic.contains(d)) {
      candidates.add((from: tag, ref: d, kind: _EdgeKind.detour));
    }
    final kind =
        chainOwners.contains(tag) ? _EdgeKind.chainHop : _EdgeKind.member;
    for (final m in memberEdges[tag] ?? const <String>[]) {
      if (cyclic.contains(m)) {
        candidates.add((from: tag, ref: m, kind: kind));
      }
    }
  }
  candidates.sort((a, b) {
    final c = a.from.compareTo(b.from);
    return c != 0 ? c : a.ref.compareTo(b.ref);
  });
  if (candidates.isEmpty) return false;

  var best = candidates.first;
  var bestScore = -1;
  for (final c in candidates) {
    final score = cyclic.length - cyclicWithout(c).length;
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  if (bestScore <= 0) return false; // ни одно ребро не развязывает — валидатору

  final from = byTag[best.from]!;
  switch (best.kind) {
    case _EdgeKind.detour:
      warnings.add(
          'Dependency cycle through detour "${best.from}" → "${best.ref}" — '
          'detour removed (the node dials directly).');
      from.remove('detour');
    case _EdgeKind.member:
      warnings.add(
          'Dependency cycle: "${best.ref}" excluded from group "${best.from}".');
      _setMembers(
          from, [for (final m in _membersOf(from)) if (m != best.ref) m]);
    case _EdgeKind.chainHop:
      // §393 C4 — у цепочки позицию не снимают: остаток был бы ДРУГИМ
      // маршрутом. Дропаем запись целиком (эталон `breakDependencyCycle`,
      // ветка "chain").
      dropped.add(from);
      warnings.add(
          'Outbound "${best.from}" removed from the config: dependency cycle '
          'through hop "${best.ref}" — a route without that hop would be a '
          'different route.');
  }
  return true;
}

/// Циклические узлы графа санитайзера — итеративный Tarjan SCC (порт
/// `_cyclicNodes` `validator.dart`): циклична SCC размера >1 либо одиночный
/// узел с self-loop. [cut] — виртуально снятое ребро (для scoring'а);
/// `member` и `chainHop` режутся одинаково (оба живут в `memberEdges`) —
/// расходятся они только в ПРИМЕНЕНИИ разрыва.
Set<String> _cyclicGraphNodes(
  List<String> nodes,
  Map<String, String> detourEdge,
  Map<String, List<String>> memberEdges,
  ({String from, String ref, _EdgeKind kind})? cut,
) {
  List<String> adjOf(String u) => [
        for (final m in memberEdges[u] ?? const <String>[])
          if (!(cut != null &&
              cut.kind != _EdgeKind.detour &&
              cut.from == u &&
              cut.ref == m))
            m,
        if (detourEdge[u] != null &&
            !(cut != null && cut.kind == _EdgeKind.detour && cut.from == u))
          detourEdge[u]!,
      ];

  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final cyclic = <String>{};
  var counter = 0;

  for (final root in nodes) {
    if (index.containsKey(root)) continue;
    final work = <(String, int)>[(root, 0)];
    while (work.isNotEmpty) {
      final (v, pi) = work.last;
      if (pi == 0) {
        index[v] = low[v] = counter++;
        stack.add(v);
        onStack.add(v);
      }
      var recursed = false;
      final adj = adjOf(v);
      for (var i = pi; i < adj.length; i++) {
        final w = adj[i];
        if (!index.containsKey(w)) {
          work.last = (v, i + 1);
          work.add((w, 0));
          recursed = true;
          break;
        } else if (onStack.contains(w)) {
          low[v] = low[v]!.compareTo(index[w]!) < 0 ? low[v]! : index[w]!;
        }
      }
      if (recursed) continue;
      if (low[v] == index[v]) {
        final comp = <String>[];
        while (true) {
          final w = stack.removeLast();
          onStack.remove(w);
          comp.add(w);
          if (w == v) break;
        }
        if (comp.length > 1) {
          cyclic.addAll(comp);
        } else if (adjOf(comp.single).contains(comp.single)) {
          cyclic.add(comp.single); // self-loop
        }
      }
      work.removeLast();
      if (work.isNotEmpty) {
        final (u, upi) = work.last;
        low[u] = low[u]!.compareTo(low[v]!) < 0 ? low[u]! : low[v]!;
        work.last = (u, upi);
      }
    }
  }
  return cyclic;
}

String _quotedList(List<String> tags) => tags.map((t) => '"$t"').join(', ');

/// §377 — одна агрегированная строка про снятые detour'ы на отсутствующий
/// [target]. Имена первых пяти нод — чтобы понять, какая подписка их принесла;
/// остаток счётчиком. Единственная нода печатается без «and 0 more» и без
/// счётчика: «1 outbound» читается хуже, чем само имя.
///
/// Жила в `build_config.dart` рядом с прежним `healDanglingDetours`; переехала
/// сюда вместе с правилом 1 (§393 A4) — формат строки не менялся, тест
/// `detour_removed_warning_aggregation_test.dart` его пинует через buildConfig.
/// §393 A4 — композитный warning: Направление [dirTag] ушло в block-fallback,
/// а detour'ы живых узлов [riders] по-прежнему в него ведут. Явно называем
/// узлы и последствие: их трафик теперь блокируется, а не «идёт через
/// Направление», как просил пользователь. Формат имён — §377 (первые пять,
/// остаток счётчиком).
String _blockedDetourRidersLine(String dirTag, List<String> riders) {
  const shown = 5;
  final head = riders.take(shown).map((r) => '"$r"').join(', ');
  final rest = riders.length - shown;
  final subject = riders.length == 1
      ? 'Outbound $head still detours'
      : '${riders.length} outbounds ($head${rest > 0 ? ', and $rest more' : ''}) '
          'still detour';
  return '$subject through direction "$dirTag", which is now blocked — '
      '${riders.length == 1 ? 'its' : 'their'} traffic is blocked too. The '
      'detour is kept on purpose: dropping it would send that traffic outside '
      'the VPN.';
}

/// §393 A4 правило 4 — одна строка на ВИНОВАТЫЙ УЗЕЛ [node] со списком групп
/// [groups], из состава которых он выброшен. Агрегация именно по узлу: один
/// узел состоит и в селекторе Направления, и в его `-auto`-двойнике, и
/// построчный вывод дал бы два warning'а об одной ноде (§377).
String _detourGroupCycleLine(String node, List<String> groups) {
  final subject = groups.length == 1
      ? 'group ${_quotedList(groups)}'
      : 'groups ${_quotedList(groups)}';
  return 'Outbound "$node" detours through $subject it belongs to — excluded '
      'from ${groups.length == 1 ? 'it' : 'them'} (its detour is kept; '
      'otherwise the kernel would not start: dependency cycle).';
}

String _detourRemovedLine(String target, List<String> owners,
    {bool targetSanitized = false}) {
  const shown = 5;
  final head = owners.take(shown).map((o) => '"$o"').join(', ');
  final rest = owners.length - shown;
  final subject = owners.length == 1
      ? 'outbound $head'
      : '${owners.length} outbounds ($head${rest > 0 ? ', and $rest more' : ''})';
  final works = owners.length == 1 ? 'node works' : 'nodes work';
  // Честный текст для цели, снятой самим санитайзером: «missing» тут было бы
  // ложью — тег БЫЛ в конфиге, но опустел каскадом и был удалён здесь же.
  if (targetSanitized) {
    return 'Detour removed: $subject pointed at "$target", which was left '
        'with no members and removed during sanitation — $works directly.';
  }
  return 'Detour removed: $subject referenced missing "$target" — '
      '$works directly.';
}
