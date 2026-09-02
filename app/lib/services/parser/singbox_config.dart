/// §368 — разбор sing-box JSON: одиночный outbound, массив outbound'ов,
/// полный конфиг и массив автономных конфигов.
///
/// Паритет с Xray-веткой (§321/§322/§342): те же шесть принципов — N узлов из
/// элемента, приоритет имён от одиночных к многоузловым, дедуп по идентичности,
/// таблица синонимов, warning вместо молчаливой потери, группы. Отличия схем
/// (`remarks` против собственного `tag`, `dialerProxy` против `detour`)
/// разобраны в спеке §3.
///
/// Ядро одно — обход **массива конфигов**; остальные три формы нормализуются к
/// нему вызывающим (`parse_all.dart`).
library;

import 'dart:convert';

import '../../models/auto_select.dart';
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../node_hash.dart';
import '../node_identity.dart';
import 'json_parsers.dart';
import 'uri_utils.dart';

// §404 — `kMaxDetourDepth` переехал в `uri_utils` (лимит общий с Xray-веткой,
// иначе вышел бы круговой импорт). Ре-экспорт держит прежний адрес имени:
// импортёры `singbox_config` его уже видели.
export 'uri_utils.dart' show kMaxDetourDepth;

/// §368 §3.1 — служебные типы sing-box: не серверы, узлами не становятся.
///
/// Своя константа, НЕ переиспользует `_kXrayServiceProtocols`: наборы совпадают
/// по смыслу, но не по написанию (`freedom` против `direct`), и связать их
/// значит сломаться при первом расхождении схем. `block`/`dns` удалены из ядра
/// в 1.11, но встречаются в конфигах, которые пользователь переносит.
const _kSingboxServiceTypes = {'direct', 'block', 'dns'};

/// §368 §3.1 — типы-группы: узлом-сервером не становятся, приезжают как
/// `AutoSelectSpec` (§5).
const _kSingboxGroupTypes = {'selector', 'urltest'};

/// Разбор массива sing-box конфигов в список узлов.
///
/// Каждый элемент — самостоятельный конфиг со своими `outbounds`/`endpoints`
/// (форма подписки, §2). Одиночный конфиг — массив из одного элемента; ветвления
/// по форме внутри нет.
///
/// Не бросает: битая форма отдельного outbound'а гасится на его гранулярности,
/// соседи и остальная подписка живут (§3.5).
List<NodeSpec> parseSingboxConfigs(List<Map<String, dynamic>> configs) {
  if (configs.isEmpty) return const [];

  // §321 P4 / §404 D-086 — накопитель ПОДПИСЕЙ дедупа на всю подписку. Между
  // подписками дедуп НЕ работает намеренно: разные источники = разные
  // tag_prefix/detour_policy.
  final seen = <String>{};
  // §321 P6 — тег провайдера → ключ ПУЛА (`nodeIdentityKey`). Копится по ВСЕЙ
  // подписке: и состав группы, и detour могут ссылаться на тег соседнего
  // элемента. Гранулярность намеренно грубее подписи дедупа: `selector`
  // называет СЕРВЕР, а не конкретную запись подписки.
  final synonyms = <String, String>{};

  // §342 — ДВА прохода. Проход 1 (черновой, узлы выбрасываются): элементы от
  // одиночных к многоузловым, чтобы право назвать сервер досталось элементу с
  // осмысленным именем, а не пулу. Здесь же копится таблица синонимов и
  // владение идентичностями.
  //
  // Сортировка обязана быть СТАБИЛЬНОЙ, а List.sort в Dart стабилен только до
  // ~32 элементов — индекс в компараторе делает порядок связок детерминированно
  // авторским на подписке любого размера (§342).
  final indexed = configs.asMap().entries.toList()
    ..sort((a, b) {
      final byPayload = _payloadCount(a.value).compareTo(_payloadCount(b.value));
      return byPayload != 0 ? byPayload : a.key.compareTo(b.key);
    });

  final owner = <String, Map<String, dynamic>>{};
  for (final e in indexed) {
    final before = seen.toSet();
    _parseOne(e.value, seen: seen, synonyms: synonyms);
    for (final id in seen.difference(before)) {
      owner[id] = e.value;
    }
  }

  // Проход 2 (боевой) — элементы строго в порядке файла; элемент выпускает
  // только те серверы, что закреплены за ним в проходе 1. Имена те же, позиции
  // авторские.
  final result = <NodeSpec>[];
  for (final cfg in configs) {
    result.addAll(_parseOne(
      cfg,
      // `seen` этого прохода свой: общий накопитель уже полон, и дедуп-`continue`
      // съел бы все узлы. Владение передаём через `ownedBy`.
      seen: <String>{},
      synonyms: synonyms,
      ownedBy: (sig) => identical(owner[sig], cfg),
    ));
  }
  return result;
}

/// §368 §3.2 — сколько payload-элементов описывает конфиг. Служебные и группы
/// не в счёт: они есть почти в каждом конфиге и сортировку бы обнулили.
int _payloadCount(Map<String, dynamic> config) {
  var n = 0;
  for (final o in _allEntries(config)) {
    final type = o['type']?.toString() ?? '';
    if (_kSingboxServiceTypes.contains(type)) continue;
    if (_kSingboxGroupTypes.contains(type)) continue;
    n++;
  }
  return n;
}

/// `outbounds` + `endpoints` одним списком (§3.1): WireGuard и MASQUE с
/// sing-box 1.11 живут в `endpoints`, правила для них те же.
///
/// `is`-проверки, не касты: конфиг пишет провайдер, любое поле может приехать
/// другого типа — каст уронил бы разбор всей подписки.
List<Map<String, dynamic>> _allEntries(Map<String, dynamic> config) {
  final out = <Map<String, dynamic>>[];
  for (final key in const ['outbounds', 'endpoints']) {
    final raw = config[key];
    if (raw is List) out.addAll(raw.whereType<Map<String, dynamic>>());
  }
  return out;
}

/// Разбор ОДНОГО конфига. Общее тело обоих проходов §342.
List<NodeSpec> _parseOne(
  Map<String, dynamic> config, {
  required Set<String> seen,
  required Map<String, String> synonyms,
  bool Function(String signature)? ownedBy,
}) {
  final entries = _allEntries(config);
  if (entries.isEmpty) return const [];

  // Тег → сырой entry. Основа резолва detour и состава групп.
  final byTag = <String, Map<String, dynamic>>{};
  for (final e in entries) {
    final tag = e['tag']?.toString() ?? '';
    if (tag.isNotEmpty) byTag.putIfAbsent(tag, () => e);
  }

  // §4 P3 — рёбра, замыкающие кольцо. Считаем ПЕРВЫМИ: узел, участвующий в
  // кольце, иначе попал бы в `detourTargets` и исчез бы из списка совсем —
  // ровно та молчаливая потеря, против которой §3.5. Снятое ребро возвращает
  // свою цель в кандидаты.
  final brokenEdges = _findCycleEdges(entries, byTag);

  // §4 P1 — цели detour: приезжают звеном владельца, самостоятельным узлом не
  // дублируются. Правило действует независимо от того, сколько узлов на цель
  // ссылается, но ребро со снятым кольцом целью больше не считается.
  final detourTargets = <String>{};
  for (final e in entries) {
    final tag = e['tag']?.toString() ?? '';
    final d = e['detour'];
    if (d is! String || d.isEmpty) continue;
    if (brokenEdges.contains(tag)) continue;
    detourTargets.add(d);
  }

  final extended = _prettyJson(config);

  // Кандидаты в узлы: payload, не служебные, не группы, не цели detour.
  final candidates = <Map<String, dynamic>>[];
  final groups = <Map<String, dynamic>>[];
  final unsupported = <String>{};
  for (final e in entries) {
    final type = e['type']?.toString() ?? '';
    if (_kSingboxServiceTypes.contains(type)) continue;
    if (_kSingboxGroupTypes.contains(type)) {
      groups.add(e);
      continue;
    }
    final tag = e['tag']?.toString() ?? '';
    if (tag.isNotEmpty && detourTargets.contains(tag)) continue;
    candidates.add(e);
  }

  // §3.3 — теги, встречающиеся в конфиге больше раза: именем не служат, нужен
  // индексный фолбэк. Внутри валидного конфига теги уникальны, но файл пишет
  // провайдер, а в форме «массив конфигов» повтор между элементами обычен.
  final tagUses = <String, int>{};
  for (final e in candidates) {
    final t = e['tag']?.toString().trim() ?? '';
    if (t.isNotEmpty) tagUses[t] = (tagUses[t] ?? 0) + 1;
  }

  // Тег → готовый узел: нужен группам (§5.2), чтобы состав резолвился по
  // идентичности, а не по regex.
  final nodeByTag = <String, NodeSpec>{};
  final result = <NodeSpec>[];

  for (var i = 0; i < candidates.length; i++) {
    final ob = candidates[i];
    final rawTag = ob['tag']?.toString().trim() ?? '';
    try {
      final spec = parseSingboxEntry(_withLabel(ob, _entryLabel(
        tag: rawTag,
        index: i,
        tagUses: tagUses,
      )));
      if (spec == null) {
        final type = ob['type']?.toString() ?? '';
        if (type.isNotEmpty) unsupported.add(type);
        continue;
      }

      // §321 P4/P6 — идентичность считаем от ГОТОВОГО узла, а не от сырого
      // JSON: конвертер один и уже отработал, так что инвариант «ключ совпадает
      // с nodeIdentityKey» выполняется по построению, а не по договорённости
      // (в Xray-ветке его приходилось держать вручную, дублируя quirk'и).
      final identity = nodeIdentityKey(spec);
      if (identity != null && rawTag.isNotEmpty) synonyms[rawTag] = identity;

      // §4 — detour-цепочка. Строим ДО дедупа (§404): путь дозвона входит в
      // подпись, значит без него дедуп не посчитать.
      final chained = _buildChain(ob, byTag, spec.warnings);
      final node = chained == null ? spec : withChained(spec, chained);

      // §404 / D-086 — подпись записи для дедупа: эмиссия узла без tag/detour
      // + подпись пути дозвона, рекурсивно по хопам. Прежний ключ
      // `nodeIdentityKey` (четвёрка подключения) не видел ни транспорта, ни
      // релея: один сервер под двумя SNI и пара «прямая + BYPASS»
      // схлопывались в одну запись. `nodeIdentityKey` остался ключом ПУЛА
      // §322 — он выше отдан в `synonyms`.
      final signature = nodeDedupSignature(node);
      // §342 — чужой узел: право на него получил другой элемент. Пропускаем ДО
      // дедупа, чтобы `seen` этого прохода не застолбил подпись за нами.
      if (ownedBy != null && !ownedBy(signature)) continue;
      if (seen.contains(signature)) continue;
      seen.add(signature);

      // §302 — исходник узла для UI: compact = сам outbound, extended = весь
      // конфиг как пришёл (его соседи-секции).
      final compact = _prettyJson(ob);
      node
        ..sourceCompact = compact
        ..sourceExtended = extended == compact ? null : extended;

      if (rawTag.isNotEmpty) nodeByTag[rawTag] = node;
      result.add(node);
    } catch (_) {
      // §321 — «битые формы не роняют разбор целиком» на гранулярности УЗЛА:
      // мусорный тип поля бросает TypeError внутри конвертера, пропускаем этот
      // outbound. Пропажа не молчаливая — тип уходит в P5-warning.
      final type = ob['type']?.toString() ?? '';
      unsupported.add(type.isEmpty ? 'malformed' : type);
    }
  }

  // §3.5 — по одному warning на тип, на первом узле конфига (не на каждом —
  // иначе N копий одного сообщения). Носителя без узла не существует: конфиг,
  // не давший ни одного узла, теряется молча — компенсируется счётчиком
  // «skipped» в диалоге импорта (§8).
  if (unsupported.isNotEmpty && result.isNotEmpty) {
    for (final type in unsupported) {
      result.first.warnings.add(UnsupportedProtocolWarning(type));
    }
  }

  // §5 — группы ПОСЛЕ узлов: порядок списка = порядок появления, группа логично
  // идёт за своими членами.
  for (final g in groups) {
    final spec = _groupToSpec(g, nodeByTag, synonyms);
    if (spec != null) result.add(spec..sourceExtended = extended);
  }

  return result;
}

/// §368 §3.3 — имя узла.
///
/// У sing-box, в отличие от Xray, имя приходит из самого outbound'а: `tag`, как
/// правило, уже осмысленный («🇩🇪 Frankfurt»). `remarks`-логики §321 P3 (кому
/// достаётся чистое имя, `solo`, драка узла с группой) здесь не нужно — у
/// каждой сущности имя своё.
///
/// [index] — позиция в исходном порядке (§321 P3): при пропуске дубля имена не
/// съезжают.
String _entryLabel({
  required String tag,
  required int index,
  required Map<String, int> tagUses,
}) {
  if (tag.isEmpty) return '';
  // Неуникальный тег именем не служит — индексный фолбэк.
  if ((tagUses[tag] ?? 0) > 1) return '$tag ${index + 1}';
  return tag;
}

/// Подмена тега на разведённый лейбл перед конвертацией.
///
/// `parseSingboxEntry` берёт и `tag`, и `label` из поля `tag`; когда тег
/// повторяется, нам нужен суффикс. Копия — не мутация: исходный конфиг ещё
/// нужен для `sourceCompact` и резолва detour по оригинальным тегам.
Map<String, dynamic> _withLabel(Map<String, dynamic> entry, String label) {
  if (label.isEmpty || label == entry['tag']?.toString()) return entry;
  return {...entry, 'tag': label};
}

/// §368 §4 P3 — теги узлов, чьё исходящее `detour`-ребро замыкает кольцо.
///
/// Обход по каждому старту; ребро, ведущее на узел, уже находящийся в **текущем
/// пути**, объявляется замыкающим. Владелец такого ребра — виновник; его
/// цепочка обрывается на нём, а сама цель возвращается в кандидаты (иначе узел,
/// на который ссылается только кольцо, исчез бы из списка целиком).
///
/// Детерминизм: старты идут в порядке файла, поэтому на кольце `A → B → A`
/// виновником всегда назначается тот, кого обошли первым.
Set<String> _findCycleEdges(
  List<Map<String, dynamic>> entries,
  Map<String, Map<String, dynamic>> byTag,
) {
  final broken = <String>{};
  // Узлы, для которых обход уже завершён: повторно стартовать смысла нет.
  final settled = <String>{};

  for (final start in entries) {
    final startTag = start['tag']?.toString() ?? '';
    if (startTag.isEmpty || settled.contains(startTag)) continue;

    final path = <String>{};
    var current = start;
    var tag = startTag;
    while (true) {
      path.add(tag);
      settled.add(tag);
      final d = current['detour'];
      if (d is! String || d.isEmpty) break;
      if (path.contains(d)) {
        broken.add(tag);
        break;
      }
      final next = byTag[d];
      if (next == null) break;
      current = next;
      tag = d;
    }
  }
  return broken;
}

/// §368 §4 — `detour: "<tag>"` → вложенный `chained`.
///
/// Возвращает звено (со своей цепочкой внутри) либо `null`, если цепочки нет
/// или ссылка непригодна. Все причины непригодности — warning в [warnings]
/// владельца, узел при этом остаётся рабочим (§169: отброс негодной части).
NodeSpec? _buildChain(
  Map<String, dynamic> owner,
  Map<String, Map<String, dynamic>> byTag,
  List<NodeWarning> warnings,
) {
  // Кольцо ищем по тегам ТЕКУЩЕЙ цепочки, а не по всему конфигу: два разных
  // узла законно ссылаются на один джамп.
  final visited = <String>{};
  final ownerTag = owner['tag']?.toString() ?? '';
  if (ownerTag.isNotEmpty) visited.add(ownerTag);

  NodeSpec? build(Map<String, dynamic> node, int depth) {
    final raw = node['detour'];
    if (raw is! String || raw.isEmpty) return null;

    // §4 P2 — глубже лимита не идём.
    if (depth >= kMaxDetourDepth) {
      warnings.add(const DetourChainTooDeepWarning(kMaxDetourDepth));
      return null;
    }

    // §4 P3 — замыкающее ребро. Рвём его (а не роняем конфиг, как §254):
    // кольцо приехало из чужого файла, пользователь его не создавал.
    if (visited.contains(raw)) {
      warnings.add(DetourCycleBrokenWarning(raw));
      return null;
    }

    final target = byTag[raw];
    // §4 P4 — висячая ссылка.
    if (target == null) {
      warnings.add(DetourTargetMissingWarning(raw));
      return null;
    }

    // §4 P5 — цепочка на группу: типово выразима, семантически не поддержана
    // (getEntries развернёт группу в detour-список без её членов).
    final type = target['type']?.toString() ?? '';
    if (_kSingboxGroupTypes.contains(type)) {
      warnings.add(DetourToGroupWarning(raw));
      return null;
    }
    if (_kSingboxServiceTypes.contains(type)) {
      // `detour: "direct"` — распространённая форма «ходи напрямую». Это не
      // ошибка конфига и не звено: у нас прямой выход не узел. Молча.
      return null;
    }

    visited.add(raw);
    final NodeSpec? spec;
    try {
      spec = parseSingboxEntry(target);
    } catch (_) {
      // Битое звено: узел-владелец важнее цепочки.
      warnings.add(DetourTargetMissingWarning(raw));
      return null;
    }
    if (spec == null) {
      warnings.add(DetourTargetMissingWarning(raw));
      return null;
    }

    final next = build(target, depth + 1);
    return next == null ? spec : withChained(spec, next);
  }

  return build(owner, 0);
}

/// §368 §5 — `urltest`/`selector` → узел автовыбора.
///
/// `null`, если состав пуст: пустой `urltest` роняет старт ядра
/// (`server_list_build.dart`), не эмитим вовсе.
AutoSelectSpec? _groupToSpec(
  Map<String, dynamic> group,
  Map<String, NodeSpec> nodeByTag,
  Map<String, String> synonyms,
) {
  final warnings = <NodeWarning>[];
  final type = group['type']?.toString() ?? '';

  // §5.1 — ручной выбор своим типом узла у нас не представлен. Терять состав,
  // собранный руками, хуже, чем сменить режим отбора.
  if (type == 'selector') warnings.add(const SelectorAsAutoWarning());

  // §5.2 — состав по ТОЧНЫМ идентичностям, а не regex'ом (как §322 для Xray):
  // тег внутри конфига ведёт ровно к одному outbound'у, который мы уже
  // разобрали, — гадать незачем.
  final rawMembers = group['outbounds'];
  final memberTags = rawMembers is List
      ? rawMembers.map((e) => '$e').where((e) => e.isNotEmpty).toList()
      : const <String>[];

  final keys = <String>[];
  var lost = 0;
  for (final tag in memberTags) {
    // Свой узел этого конфига — приоритет; иначе тег соседнего элемента через
    // таблицу синонимов (§3.6).
    final node = nodeByTag[tag];
    final key = node != null ? nodeIdentityKey(node) : synonyms[tag];
    // §5.3 — вложенная группа, служебный тип или битый outbound: членом пула
    // быть не может (nodeIdentityKey группы = null).
    if (key == null) {
      lost++;
      continue;
    }
    if (!keys.contains(key)) keys.add(key);
  }
  if (lost > 0) warnings.add(GroupMemberMissingWarning(lost));
  if (keys.isEmpty) return null;

  final label = group['tag']?.toString() ?? '';
  const d = AutoSelectParams();
  final params = AutoSelectParams(
    // §5.1 — дефолты берём из НАШИХ AutoSelectParams, не из апстрима: значения
    // совпадают, а источник истины должен быть один.
    url: group['url']?.toString() ?? d.url,
    interval: group['interval']?.toString() ?? d.interval,
    tolerance: _asInt(group['tolerance']) ?? d.tolerance,
    idleTimeout: group['idle_timeout']?.toString() ?? d.idleTimeout,
    interruptExistConnections:
        group['interrupt_exist_connections'] == true,
    // Режим не переносим: `mode`/`balancer` — наше расширение (§208), у
    // апстримного urltest его нет. Дефолт least_test отвечает семантике
    // «самый быстрый по замерам».
    mode: d.mode,
  );

  return AutoSelectSpec(
    id: newUuidV4(),
    tag: tagFromLabel(label, 'urltest', 'auto', 0),
    label: label,
    membership: ExplicitMembers(keys),
    params: params,
    // §302 — ремап синонимов при мутации узлов; для ExplicitMembers
    // scoped-ветка resolveAutoSelectMembers не выполняется.
    tagSynonyms: Map.of(synonyms),
    warnings: warnings,
  )..sourceCompact = _prettyJson(group);
}

/// Число из значения провайдера: `7`, `7.0` или `"7"`. Иначе `null`.
int? _asInt(Object? v) => switch (v) {
      final num n => n.toInt(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };

/// §302 — стабильный отступ для показа фрагмента конфига пользователю.
String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}
