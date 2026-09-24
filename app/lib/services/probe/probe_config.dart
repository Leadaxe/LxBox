import 'dart:convert';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';

/// §236/§296 — probe-конфиг для headless-сессии: ВСЕ переданные ноды (включая
/// null-слоты для выключенных/битых) как outbounds/endpoints, БЕЗ inbound'ов
/// (openTun не вызывается), минимальный DNS (local) для резолва доменных
/// адресов.
///
/// §296 — вход обобщён с `FolderServers` до `List<NodeSpec?>` (общий probe над
/// всей подсистемой ServerList: папки передают `members.map((m)=>m.node)` —
/// nullable, unfiltered; подписки/серверы — `list.nodes`). Индекс в списке =
/// адрес результата (`onResult`), одинаково для всех видов.
///
/// Detour-политика НЕ применяется — тестируем сами ноды; собственные
/// chained-цепочки ноды (⚙ из raw) сохраняются, как в боевом билдере.
class ProbeConfig {
  const ProbeConfig({
    required this.configJson,
    required this.tagByIndex,
    required this.brokenByIndex,
  });

  /// null = нет ни одной тестируемой ноды (все слоты битые/список пуст).
  final String? configJson;

  /// index → tag ноды в probe-конфиге (по нему зовём probeUrlTest).
  final Map<int, String> tagByIndex;

  /// index → причина, почему нода НЕ попала в конфиг:
  /// 'broken' (null-слот / raw не парсится) | 'group' (узел-группа §322/§336,
  /// не тестируется) | 'invalid: …' (emit бросил).
  final Map<int, String> brokenByIndex;
}

/// Тег локального DNS-резолвера в probe-конфиге.
const kProbeDnsTag = 'local-dns';

/// §518 — сколько naive-узлов допустимо в ОДНОМ probe-конфиге.
///
/// У naive инициализация outbound'а создаёт полный сетевой стек Chromium:
/// `protocol/naive/outbound.go` зовёт `cronet.NewNaiveClient` на КАЖДУЮ запись
/// при разборе конфига, а `Start()` → `NaiveClient.Start()` поднимает движок
/// (`cronet-go/naive_client.go`, блок `engineCount`: `engineCount = 1`, и при
/// `insecure_concurrency > 1` — ещё и умножается на concurrency). Один
/// probe-конфиг со всеми узлами списка (см. [buildProbeBatches]) поднимал
/// столько Chromium-стеков, сколько в списке naive-узлов, ОДНОВРЕМЕННО и в том
/// же процессе, что UI. При `SetupOptions.oomMemoryLimit` (§173/§271; «auto» на
/// типичном устройстве — 200-512 МБ, Go soft-limit = 3/4 от него) десяток
/// движков — профиль OOM: снаружи «приложение падает на проверке всех
/// серверов» (4PDA, §518).
///
/// 1, а не 2-4: замера на устройстве нет (сервера для репро нет), а цена
/// консервативного значения — только время прогона (по одному probeStart на
/// naive-узел, остальные протоколы по-прежнему одним конфигом). Поднимать
/// имеет смысл только по замеру RSS одного движка на живом naive-узле.
const kProbeMaxNaivePerConfig = 1;

/// §518 — ключ протокола naive: по нему гейтится [kProbeMaxNaivePerConfig].
/// Сверяемся с типом ЭМИТИРОВАННОЙ записи (`outbound.type`), а не с Dart-типом
/// узла: детур-цепочка узла (`raw.detours`) тоже уходит в конфиг и тоже может
/// быть naive, а её Dart-тип виден только обходом `chained`.
const _naiveOutboundType = 'naive';

/// §518 — probe-конфиг строится батчами: см. [kProbeMaxNaivePerConfig].
/// Совместимость: единственный батч, когда naive-узлов не больше лимита —
/// поведение до §518 дословно.
ProbeConfig buildProbeConfig(List<NodeSpec?> nodes) =>
    buildProbeBatches(nodes).firstOrNull ??
    ProbeConfig(
      configJson: null,
      tagByIndex: const {},
      brokenByIndex: _brokenOf(nodes),
    );

/// §518 — раскладывает [nodes] на probe-конфиги так, чтобы в каждом было не
/// более [kProbeMaxNaivePerConfig] naive-узлов. Не-naive узлы целиком лежат в
/// ПЕРВОМ батче (как до §518 — один конфиг на весь список); каждый naive-узел
/// сверх лимита уезжает в свой батч. Порядок и полнота сохраняются: индексы
/// узлов — исходные, объединение `tagByIndex` всех батчей плюс `brokenByIndex`
/// покрывает весь [nodes].
///
/// Пустой список — если тестировать нечего вовсе (все слоты битые/группы);
/// вердикты таких узлов тогда берутся из [buildProbeConfig].
List<ProbeConfig> buildProbeBatches(List<NodeSpec?> nodes) {
  final built = <int, _Built>{};
  final broken = <int, String>{};
  for (var i = 0; i < nodes.length; i++) {
    final e = _buildOne(nodes[i]);
    if (e is String) {
      broken[i] = e;
    } else {
      built[i] = e as _Built;
    }
  }
  if (built.isEmpty) return const [];

  // Раскладка по батчам: не-naive — в первый, naive — порциями по лимиту.
  final groups = <List<int>>[];
  final plain = <int>[];
  final naive = <int>[];
  for (final i in built.keys) {
    (built[i]!.naiveCount > 0 ? naive : plain).add(i);
  }
  var naiveInCurrent = 0;
  for (final i in naive) {
    final n = built[i]!.naiveCount;
    if (groups.isEmpty || naiveInCurrent + n > kProbeMaxNaivePerConfig) {
      groups.add(<int>[]);
      naiveInCurrent = 0;
    }
    groups.last.add(i);
    naiveInCurrent += n;
  }
  if (plain.isNotEmpty) {
    // Не-naive идут первым батчем; если naive-батчи уже есть — подсаживаем их
    // к самому первому (у него лимит naive уже учтён).
    if (groups.isEmpty) {
      groups.add(plain);
    } else {
      groups.first.insertAll(0, plain);
    }
  }
  // Внутри батча — исходный порядок узлов: `allocate` уникализирует
  // конфликтующие теги по порядку обхода ('Alpha', 'Alpha-2'), и без сортировки
  // подсадка не-naive в начало первого батча перевесила бы, какой из двух
  // одноимённых узлов получит суффикс.
  for (final g in groups) {
    g.sort();
  }
  // Первый батч несёт вердикты битых/групп — чтобы вызывающий отдал их один раз.
  return [
    for (var g = 0; g < groups.length; g++)
      _assemble(groups[g], built, brokenByIndex: g == 0 ? broken : const {}),
  ];
}

Map<int, String> _brokenOf(List<NodeSpec?> nodes) {
  final broken = <int, String>{};
  for (var i = 0; i < nodes.length; i++) {
    final e = _buildOne(nodes[i]);
    if (e is String) broken[i] = e;
  }
  return broken;
}

/// Собранные записи одного узла (main + его детур-цепочка), ещё без тегов.
class _Built {
  _Built(this.entries, this.mainIndexInEntries, this.detourCount, this.naiveCount);

  final List<SingboxEntry> entries; // [detours…, main]
  final int mainIndexInEntries;
  final int detourCount;

  /// §518 — сколько naive-записей несёт узел (сам + детуры).
  final int naiveCount;
}

/// Собирает записи одного узла. Возвращает [_Built] или строку-вердикт.
Object _buildOne(NodeSpec? node) {
  if (node == null) return 'broken';
  // §336 — группа (§322) не тестируется: её emitRaw — заготовка urltest с
  // пустым outbounds (члены дописывает только боевой билдер), ядро валит
  // на ней ВЕСЬ probe-конфиг «missing tags». Члены группы лежат в том же
  // контейнере и тестируются поштучно.
  if (node.isGroup) return 'group';
  // §435 — Tailscale: адреса нет, а probe-конфиг поднимал бы tsnet ради
  // пинга (вход в tailnet по auth_key, каталог состояния). Не тестируем;
  // на Home у узла «—» вместо задержки.
  if (node is TailscaleSpec) return 'no-address';
  try {
    final raw = node.getEntries(null);
    // Зеркалим ServerListBuild: детуры первыми (main ссылается на tag).
    final entries = <SingboxEntry>[...raw.detours, raw.main];
    var naive = 0;
    for (final e in entries) {
      // §518 — снимаем insecure_concurrency ТОЛЬКО в пробе: в замере задержки
      // пул изолированных сессий не нужен, а Chromium-движки он множит
      // линейно (`engineCount = concurrency`). Тело боевого конфига не
      // затрагивается: `emit` отдаёт свежую map на каждый вызов (§307).
      if (e.map['type'] == _naiveOutboundType) {
        naive++;
        e.map.remove('insecure_concurrency');
      }
    }
    return _Built(entries, entries.length - 1, raw.detours.length, naive);
  } catch (e) {
    return 'invalid: $e';
  }
}

ProbeConfig _assemble(
  List<int> indexes,
  Map<int, _Built> built, {
  required Map<int, String> brokenByIndex,
}) {
  final outbounds = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': kDirectOutboundTag},
  ];
  final endpoints = <Map<String, dynamic>>[];
  final tagByIndex = <int, String>{};
  final usedTags = <String>{kDirectOutboundTag, kProbeDnsTag};

  String allocate(String base) {
    final b = base.isEmpty ? 'node' : base;
    if (usedTags.add(b)) return b;
    for (var i = 2;; i++) {
      final candidate = '$b-$i';
      if (usedTags.add(candidate)) return candidate;
    }
  }

  for (final i in indexes) {
    final b = built[i]!;
    // Детуры первыми (main ссылается на tag) — порядок [_Built.entries].
    for (var k = 0; k < b.detourCount; k++) {
      b.entries[k].map['tag'] = allocate(b.entries[k].tag);
    }
    final main = b.entries[b.mainIndexInEntries];
    final mainTag = allocate(main.tag);
    main.map['tag'] = mainTag;
    if (b.detourCount > 0) {
      main.map['detour'] = b.entries[0].tag;
    }
    for (final e in b.entries) {
      switch (e) {
        case Outbound():
          outbounds.add(e.map);
        case Endpoint():
          endpoints.add(e.map);
      }
    }
    tagByIndex[i] = mainTag;
  }

  if (tagByIndex.isEmpty) {
    return ProbeConfig(
      configJson: null,
      tagByIndex: tagByIndex,
      brokenByIndex: brokenByIndex,
    );
  }

  final config = <String, dynamic>{
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': kProbeDnsTag},
      ],
    },
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': {
      // Адреса серверов бывают доменами — ядру нужен резолвер по умолчанию.
      'default_domain_resolver': kProbeDnsTag,
    },
  };
  return ProbeConfig(
    configJson: jsonEncode(config),
    tagByIndex: tagByIndex,
    brokenByIndex: brokenByIndex,
  );
}

/// §284 — минимальный headless-конфиг для WARP-скана: БЕЗ нод (сырая проба идёт
/// по IP напрямую, теги не нужны), только `direct` + local DNS, чтобы ядро
/// поднялось. `openTun` не вызывается (нет inbound'ов, §119-инвариант).
String buildScanProbeConfigJson() => jsonEncode(<String, dynamic>{
      'log': {'level': 'error'},
      'dns': {
        'servers': [
          {'type': 'local', 'tag': kProbeDnsTag},
        ],
      },
      'outbounds': [
        {'type': 'direct', 'tag': kDirectOutboundTag},
      ],
      'route': {'default_domain_resolver': kProbeDnsTag},
    });

