import 'dart:convert';

import '../../models/auto_select.dart';
import '../../models/channel.dart' show UrltestMode;
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/tls_spec.dart';
import '../../models/transport_spec.dart';
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
/// приезжают как detour-звено (`⚙ <tag>`) своего владельца и самостоятельным
/// узлом НЕ дублируются (контракт §018 detour-chain не меняется).
///
/// §321 — все поддерживаемые protocol'ы, не только VLESS. Служебные
/// (`freedom`/`blackhole`/`dns`) узлами не становятся; SOCKS — только
/// detour-звено.
///
/// [seen] — накопитель §321 P4 (дедуп по `(protocol, server, port, credential)`)
/// на весь массив подписки. Узел, уже виденный в этом проходе, пропускается.
/// `null` — дедуп выключен (одиночный элемент вне массива).
List<NodeSpec> parseXrayElement(
  Map<String, dynamic> element, {
  Set<String>? seen,
  Map<String, String>? synonyms,
}) {
  final outbounds = element['outbounds'];
  if (outbounds is! List) return const [];

  // §321 P1 — payload = всё, кроме служебных. Неподдерживаемый protocol
  // отсеется позже в _xrayToSpec (с warning), но в payloadCount он учтён:
  // сортировка P2 считает намерение провайдера, а не наши возможности.
  final payloadAll = outbounds
      .whereType<Map<String, dynamic>>()
      .where((o) =>
          !_kXrayServiceProtocols.contains(o['protocol']?.toString() ?? ''))
      .toList();
  if (payloadAll.isEmpty) return const [];

  // dialerProxy-ссылки: цели исключаются из самостоятельных узлов.
  final dialerRefOf = <Map<String, dynamic>, String>{};
  final dialerTargets = <String>{};
  for (final ob in payloadAll) {
    final sockopt = (ob['streamSettings']?['sockopt']) as Map?;
    final ref = sockopt?['dialerProxy']?.toString();
    if (ref != null && ref.isNotEmpty) {
      dialerRefOf[ob] = ref;
      dialerTargets.add(ref);
    }
  }

  // Порядок: «main» первым (dialerProxy → тег `proxy` → первый), чтобы у
  // существующих подписок первый узел остался тем же, что и до §310.
  final candidates = payloadAll
      .where((o) => !dialerTargets.contains(o['tag']?.toString()))
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
  final hasBalancer = (element['routing']?['balancers'] as List?)?.isNotEmpty
      ?? false;
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
  for (var i = 0; i < ordered.length; i++) {
    final ob = ordered[i];

    // §321 P4 — дедуп ДО конвертации. Индекс `i` для имени берётся из
    // `ordered` (до дедупа): иначе имена поедут — второй выживший получил бы
    // i=0 и назвался как `remarks` без суффикса.
    final identity = _xrayIdentity(ob);
    // §321 P6 — тег провайдера → идентичность. Копим ДО пропуска дубля:
    // именно у дублей теги и различаются («Испания» = `proxy`, «Лучший» =
    // `proxy-45-196-208-40-direct`), а §322 резолвит пул по чужим тегам.
    final obTag = ob['tag']?.toString() ?? '';
    if (identity != null && obTag.isNotEmpty) synonyms?[obTag] = identity;
    if (identity != null && seen != null) {
      if (seen.contains(identity)) continue;
      seen.add(identity);
    }

    // §310 — имя разводим на парсинге: `allocateTag` уникализирует теги лишь
    // на build'е (суффикс `-N`), а в списке узлов пользователь иначе увидит
    // несколько одинаковых строк. Одиночный узел — имя ровно как до §310.
    final spec = _xrayToSpec(
      ob,
      _elementLabel(
        remarks: remarks,
        ob: ob,
        index: i,
        solo: soloNode,
        tagUses: tagUses,
      ),
    );
    if (spec == null) continue;

    // §302 — исходник узла для UI («Source» на экране узла) и для правил по
    // JSON-телам: compact = сам outbound, extended = весь элемент как пришёл
    // от провайдера (dns/inbounds/routing соседи). rawUri для таких узлов —
    // синтетическая заглушка `xray://<tag>`, источником служить не может.
    final compact = _prettyJson(ob);

    final ref = dialerRefOf[ob];
    NodeSpec? chained;
    if (ref != null) {
      final detour = outbounds.whereType<Map<String, dynamic>>().firstWhere(
          (o) => o['tag'] == ref,
          orElse: () => <String, dynamic>{});
      if (detour.isNotEmpty) chained = _xrayDetourToSpec(detour);
    }

    // §321 — detour-звено прикладываем только к тем типам, что умеют chained
    // из Xray. `dialerProxy` в Xray живёт в `streamSettings.sockopt`, то есть
    // технически возможен у любого протокола; на практике встречается у
    // VLESS/Trojan. Для остальных узел отдаём без звена (терять сам узел
    // из-за неподдержанной цепочки нельзя).
    final node = chained == null ? spec : _withChain(spec, chained);
    result.add(node
      ..sourceCompact = compact
      ..sourceExtended = extended == compact ? null : extended);
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
  final balancers = element['routing']?['balancers'];
  if (balancers is! List || balancers.isEmpty) return null;
  final b = balancers.first;
  if (b is! Map) return null;

  final selector = (b['selector'] as List?)?.map((e) => '$e').toList() ?? const [];
  final strategy = b['strategy'] as Map? ?? const {};
  final settings = strategy['settings'] as Map? ?? const {};
  final ping =
      (element['burstObservatory']?['pingConfig']) as Map? ?? const {};

  // Стратегия → режим. Решает не только тип, но и `expected` — размер пула,
  // который Xray старается держать живым.
  //
  // `expected: 1` — «держи ОДНОГО живого», а не «раздавай по пулу». Это наш
  // least_test, а не round_robin: балансировщику с пулом из одного нечего
  // балансировать (у Liberty так настроены все шесть «БС»-групп).
  //
  // `leastPing` → least_test всегда: семантика совпадает.
  // `leastLoad` с expected > 1 → round_robin — приближение: Xray отбирает по
  // СТАБИЛЬНОСТИ задержки (baselines = допустимое СКО), мы по здоровью и окну
  // от лучшего. Общее — пул из N с раздачей по нему.
  final expected = (settings['expected'] as num?)?.toInt();
  final mode = switch (strategy['type']?.toString()) {
    'leastPing' => UrltestMode.leastTest,
    null => UrltestMode.leastTest, // дефолт Xray — random, пула нет смысла
    _ when expected != null && expected <= 1 => UrltestMode.leastTest,
    _ => UrltestMode.roundRobin,
  };

  final d = const AutoSelectParams();
  final params = AutoSelectParams(
    url: ping['destination']?.toString() ?? d.url,
    interval: ping['interval']?.toString() ?? d.interval,
    idleTimeout: d.idleTimeout,
    mode: mode,
    pool: expected ?? d.pool,
    // maxRTT — АБСОЛЮТНЫЙ потолок у Xray, а pool_tolerance — окно от лучшего.
    // Числа переносим 1:1 (решение юзера 30.07.2026): пересчитать точнее
    // нельзя, минимум по пулу на парсинге неизвестен.
    poolTolerance: clampPoolTolerance(_goDurationMs(settings['maxRTT']) ?? d.poolTolerance),
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

/// §321 — пересборка узла с detour-звеном. NodeSpec иммутабелен и `copyWith`
/// в базе нет, поэтому ветвим по типу. Неподдержанный тип → узел как есть.
NodeSpec _withChain(NodeSpec spec, NodeSpec chained) => switch (spec) {
      VlessSpec s => VlessSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawUri: s.rawUri,
          uuid: s.uuid,
          flow: s.flow,
          tls: s.tls,
          transport: s.transport,
          packetEncoding: s.packetEncoding,
          chained: chained,
          warnings: s.warnings,
        ),
      TrojanSpec s => TrojanSpec(
          id: s.id,
          tag: s.tag,
          label: s.label,
          server: s.server,
          port: s.port,
          rawUri: s.rawUri,
          password: s.password,
          tls: s.tls,
          transport: s.transport,
          chained: chained,
          warnings: s.warnings,
        ),
      _ => spec,
    };

/// §302 — стабильный отступ для показа фрагмента подписки пользователю.
String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
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
  final tls =
      normalizeTlsFingerprint(_xrayTlsFromStream(stream, server), warnings);
  final transport = _xrayTransportFromStream(stream);

  // §115 — flow берём из конфига как есть (раньше REALITY+tcp без flow
  // получал навязанный vision → ломались валидные none-сетапы). vision
  // несовместим с транспортом → гасим flow + warning.
  if (flow == 'xtls-rprx-vision' && transport != null) {
    warnings.add(
        VisionWithTransportWarning((stream['network'] ?? 'transport').toString()));
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
    warnings: warnings,
  );
}

/// §321 — служебные outbound'ы Xray: не серверы, узлами не становятся.
const _kXrayServiceProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

/// §321 P4 — идентичность узла: `(protocol, server, port, credential)`.
/// Транспорт и TLS в ключ НЕ входят (решение юзера 30.07.2026): один сервер с
/// двумя разными SNI схлопывается в один узел — берётся первый по порядку P2.
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
      port = (v['port'] as num?)?.toInt() ?? 0;
      final users = (v['users'] as List?)?.cast<Map>() ?? const [];
      cred = users.isEmpty ? '' : (users.first['id']?.toString() ?? '');
    case 'trojan':
    case 'shadowsocks':
      final servers = (s['servers'] as List?)?.cast<Map>();
      if (servers == null || servers.isEmpty) return null;
      final v = servers.first;
      server = v['address']?.toString() ?? '';
      port = (v['port'] as num?)?.toInt() ?? 0;
      cred = v['password']?.toString() ?? '';
    case 'hysteria':
      server = s['address']?.toString() ?? '';
      port = (s['port'] as num?)?.toInt() ?? 0;
      cred = (o['streamSettings']?['hysteriaSettings']?['auth'])?.toString() ?? '';
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
  final tls =
      normalizeTlsFingerprint(_xrayTlsFromStream(stream, server), warnings);
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
  final tls =
      normalizeTlsFingerprint(_xrayTlsFromStream(stream, server), warnings);
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

  final version = (hy['version'] as num?)?.toInt() ??
      (s['version'] as num?)?.toInt() ??
      2;
  if (version != 2) return null; // hysteria v1 — своего Spec у нас нет

  final server = s['address']?.toString() ?? '';
  final port = (s['port'] as num?)?.toInt() ?? 443;
  final auth = hy['auth']?.toString() ?? '';
  if (server.isEmpty) return null;

  final warnings = <NodeWarning>[];
  final tls =
      normalizeTlsFingerprint(_xrayTlsFromStream(stream, server), warnings);
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

NodeSpec? _xrayDetourToSpec(Map<String, dynamic> o) {
  final protocol = o['protocol']?.toString() ?? '';
  if (protocol == 'socks') {
    final servers = (o['settings']?['servers'] as List?)?.cast<Map>();
    if (servers == null || servers.isEmpty) return null;
    final s = servers.first;
    final server = s['address']?.toString() ?? '';
    final port = (s['port'] as num?)?.toInt() ?? 1080;
    if (server.isEmpty) return null;
    final users = (s['users'] as List?)?.cast<Map>() ?? const [];
    final user = users.isEmpty ? const {} : users.first;
    final tag = '⚙ ${o['tag'] ?? 'jump'}';
    return SocksSpec(
      id: newUuidV4(),
      tag: tag,
      label: tag,
      server: server,
      port: port,
      rawUri: 'xray-jump://socks',
      username: user['user']?.toString() ?? '',
      password: user['pass']?.toString() ?? '',
    );
  }
  if (protocol == 'vless') {
    final spec = _xrayVlessToSpec(o, '⚙ ${o['tag'] ?? 'jump'}');
    return spec;
  }
  return null;
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
      final (path, edFromPath) =
          splitEarlyDataPath(ws['path']?.toString() ?? '/');
      // §320 — Xray-конфиги также несут early data отдельными полями
      // `wsSettings.ed` / `.eh` (хвост пути в приоритете). `eh` без `ed`
      // игнорируем: режим ядро включает по `max_early_data > 0`.
      final edField = ws['ed'];
      final ed = edFromPath ??
          (edField is int && edField > 0
              ? edField
              : int.tryParse(edField?.toString().trim() ?? ''));
      final eh = ws['eh']?.toString().trim() ?? '';
      return WsTransport(
        path: path,
        host: host,
        maxEarlyData: ed != null && ed > 0 ? ed : null,
        earlyDataHeaderName:
            (ed != null && ed > 0 && eh.isNotEmpty) ? eh : null,
      );
    case 'grpc':
      final g = stream['grpcSettings'] as Map? ?? const {};
      return GrpcTransport(
          serviceName: g['serviceName']?.toString() ?? '');
    case 'http':
    case 'h2':
      final h = stream['httpSettings'] as Map? ?? const {};
      final hosts = (h['host'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      return HttpTransport(path: h['path']?.toString() ?? '/', hosts: hosts);
    case 'xhttp': // §097 — Xray xhttpSettings → нативный xhttp
      final x = stream['xhttpSettings'] as Map? ?? const {};
      return XhttpTransport(
        path: x['path']?.toString() ?? '/',
        host: x['host']?.toString() ?? '',
        mode: x['mode']?.toString() ?? '',
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
        idleSessionCheckInterval:
            entry['idle_session_check_interval']?.toString() ?? '',
        idleSessionTimeout: entry['idle_session_timeout']?.toString() ?? '',
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
      return Hysteria2Spec(
        id: newUuidV4(),
        tag: tag.isEmpty ? 'hy2-$server-$port' : tag,
        label: label,
        server: server,
        port: port,
        rawUri: '',
        password: entry['password']?.toString() ?? '',
        obfs: obfs?['type']?.toString() ?? '',
        obfsPassword: obfs?['password']?.toString() ?? '',
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
        congestionControl:
            entry['congestion_control']?.toString() ?? 'cubic',
        udpRelayMode: entry['udp_relay_mode']?.toString() ?? 'native',
        zeroRtt: entry['zero_rtt_handshake'] == true,
        tls: _tlsFromSingbox(entry['tls'], server),
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
        privateKeyPassphrase:
            entry['private_key_passphrase']?.toString() ?? '',
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
      final addr = (entry['address'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const <String>[];
      final peers = (entry['peers'] as List?)?.cast<Map>() ?? const [];
      if (peers.isEmpty) return null;
      final p = peers.first;
      final peerServer = p['address']?.toString() ?? server;
      final peerPort = (p['port'] as num?)?.toInt() ?? port;
      if (peerServer.isEmpty) return null;
      final allowedIps = (p['allowed_ips'] as List?)
              ?.map((e) => ensureCidr(e.toString()))
              .toList() ??
          const ['0.0.0.0/0', '::/0'];
      final awg = Awg.fromJson(entry); // §097 — AmneziaWG2 obfuscation params
      final wgTag = tag.isEmpty ? 'wg-$peerServer-$peerPort' : tag;
      // §097 — AWG: клампим MTU до 1280. §219 — plain WG дефолтит 1408 как в
      // URI-парсере (было null → зеркалим `wireguard_parser.dart`, чтобы модель
      // не зависела от источника парсинга: JSON vs URI).
      final rawMtu = (entry['mtu'] as num?)?.toInt();
      // §025/§126 — WARP client_id. §219 — раньше JSON-парсер не заполнял
      // `reserved` (WARP-handshake проходил, трафик не шёл). В sing-box JSON
      // `reserved` — массив из 3 байт `[b0,b1,b2]` (наш round-trip формат
      // эмиттера); `client_id` — base64-строка. Массив берём напрямую
      // (с валидацией 3×0..255), строку — через parseReserved.
      final reserved = _reservedFromJson(p['reserved'] ?? entry['reserved']) ??
          (p['client_id'] is String
              ? parseReserved(p['client_id'] as String)
              : null);
      return WireguardSpec(
        id: newUuidV4(),
        tag: wgTag,
        label: label,
        server: peerServer,
        port: peerPort,
        rawUri: '',
        privateKey: entry['private_key']?.toString() ?? '',
        localAddresses: addr,
        peers: [
          WireguardPeer(
            publicKey: p['public_key']?.toString() ?? '',
            preSharedKey: p['pre_shared_key']?.toString() ?? '',
            endpointHost: peerServer,
            endpointPort: peerPort,
            allowedIps: allowedIps,
            persistentKeepalive:
                (p['persistent_keepalive_interval'] as num?)?.toInt(),
            reserved: reserved,
          )
        ],
        mtu: awg != null ? awgClampMtu(rawMtu, wgTag) : (rawMtu ?? 1408),
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
        network: entry['network']?.toString() ?? 'h3',
        sni: entry['sni']?.toString() ?? '',
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
  return normalizeTlsFingerprint(TlsSpec(
    enabled: true,
    serverName: raw['server_name']?.toString() ?? server,
    alpn: (raw['alpn'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    insecure: raw['insecure'] == true,
    fingerprint: utls?['fingerprint']?.toString(),
    // §169 — REALITY только при enabled И валидном X25519 public_key. Битый
    // ключ → reality=null (нода остаётся plain TLS), а не отравляет config.
    reality: reality == null ||
            reality['enabled'] != true ||
            !isValidRealityPublicKey(reality['public_key']?.toString() ?? '')
        ? null
        : RealitySpec(
            publicKey: reality['public_key']!.toString(),
            shortId:
                normalizeRealityShortId(reality['short_id']?.toString() ?? ''),
          ),
  ), null);
}

TransportSpec? _transportFromSingbox(dynamic raw) {
  if (raw is! Map) return null;
  final type = raw['type']?.toString() ?? '';
  switch (type) {
    case 'ws':
      final headers = (raw['headers'] as Map?)?.cast<String, dynamic>();
      // §303 — sing-box JSON обычно уже разделён (`max_early_data`), но в
      // редактор попадают и склеенные Xray-пути.
      final (path, edFromPath) =
          splitEarlyDataPath(raw['path']?.toString() ?? '/');
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
      return GrpcTransport(
          serviceName: raw['service_name']?.toString() ?? '');
    case 'http':
      return HttpTransport(
        path: raw['path']?.toString() ?? '/',
        hosts: (raw['host'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
    case 'httpupgrade':
      // §303 — early data у httpupgrade нет, но хвост пути всё равно чужой.
      final (path, _) = splitEarlyDataPath(raw['path']?.toString() ?? '/');
      return HttpUpgradeTransport(
        path: path,
        host: raw['host']?.toString() ?? '',
      );
    case 'xhttp': // §097 — нативный xhttp из sing-box JSON
      return XhttpTransport(
        path: raw['path']?.toString() ?? '/',
        host: raw['host']?.toString() ?? '',
        mode: raw['mode']?.toString() ?? '',
        xPaddingBytes: raw['x_padding_bytes']?.toString() ?? '',
        noGrpcHeader: raw['no_grpc_header'] == true,
        headers: (raw['headers'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const {},
      );
    default:
      return null;
  }
}
