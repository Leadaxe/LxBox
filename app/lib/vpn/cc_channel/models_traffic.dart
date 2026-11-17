part of '../cc_channel.dart';

/// §2.4 — группа из `writeGroups` (дерево). `selectable` заменяет `type=='Selector'`,
/// `selected` заменяет clash-поле `now`.
class CcGroup {
  const CcGroup({
    required this.tag,
    required this.type,
    required this.selectable,
    required this.selected,
    required this.isExpand,
    required this.items,
  });

  final String tag;
  final String type;
  final bool selectable;
  final String selected;
  final bool isExpand;
  final List<CcOutbound> items;

  factory CcGroup.fromMap(Map<String, dynamic> m) => CcGroup(
    tag: m['tag']?.toString() ?? '',
    type: m['type']?.toString() ?? '',
    selectable: m['selectable'] == true,
    selected: m['selected']?.toString() ?? '',
    isExpand: m['isExpand'] == true,
    items: (m['items'] is List ? m['items'] as List : const [])
        .map((e) => CcOutbound.fromMap(CcChannel._asMap(e)))
        .toList(),
  );
}

/// §3.1/§3.2 — соединение из аккумулятора. `closedAt`>0 = закрытое (closed-история).
///
/// §122 — `uplink`/`downlink` = НАКОПЛЕННЫЙ итог (`getUplinkTotal/DownlinkTotal`),
/// сколько ВСЕГО передано за соединение. `uplinkDelta`/`downlinkDelta` = байт за
/// последний тик статуса (мгновенная скорость; у idle = 0). `outbound`/
/// `outboundType` — выбранная нода/тип; `chains` — полная outbound-цепочка
/// (Clash `chains`, §174: ядро отдаёт через `Connection.chain()`-итератор).
class CcConnection {
  const CcConnection({
    required this.id,
    required this.network,
    required this.domain,
    required this.destination,
    this.source = '',
    this.inbound = '',
    this.inboundType = '',
    required this.rule,
    required this.uplink,
    required this.downlink,
    this.uplinkDelta = 0,
    this.downlinkDelta = 0,
    this.outbound = '',
    this.outboundType = '',
    this.protocol = '',
    this.chains = const [],
    this.detours = const [],
    this.packageName = '',
    this.processPath = '',
    required this.createdAt,
    required this.closedAt,
  });

  final String id;
  final String network;
  final String domain;
  final String destination;
  final String rule;

  /// §661 — источник `ip:port` и вход (тег/тип inbound). При эндпоинтах и
  /// локальных прокси мы шлюз: соединение приходит не только из `tun-in`.
  /// Пусто на старом нативе.
  final String source;
  final String inbound;
  final String inboundType;

  /// §661 — стандартный вход: TUN устройства (или натив не отдал inbound).
  bool get isStandardInbound => inbound.isEmpty || inbound == 'tun-in';

  /// §661 — `source / inbound` для нестандартного входа, иначе `''`.
  String get sourceLabel => isStandardInbound
      ? ''
      : (source.isNotEmpty ? '$source / $inbound' : inbound);

  /// Накопленный итог за соединение (всего передано). `getUplinkTotal`.
  final int uplink;
  final int downlink;

  /// Байт за последний тик (мгновенная скорость). `getUplink`. 0 у idle.
  final int uplinkDelta;
  final int downlinkDelta;

  /// Выбранная нода/тип (libbox `getOutbound`/`getOutboundType`).
  final String outbound;
  final String outboundType;
  final String protocol;

  /// §174 — полная outbound-цепочка (Clash `chains`): selector→urltest→node.
  /// Из `Connection.chain()`-итератора ядра. Пусто для прямого outbound.
  final List<String> chains;

  /// §178 — detour-хвост финального outbound (ядро SPEC 017, `Connection.detour()`).
  /// Транспортная ось (куда физически ныряет пакет: `node → WARP`), порядок
  /// node→наружу. Пусто: прямой outbound / block / dns / ядро без поля 23.
  /// НЕ дублирует `chains` — node там, detour-теги тут.
  final List<String> detours;

  /// App-attribution из `getProcessInfo()`: package (для иконки) + путь процесса.
  final String packageName;
  final String processPath;

  final int createdAt;
  final int closedAt;

  bool get isClosed => closedAt > 0;

  /// §204 — routing-строка в нотации §252 (эволюция §181), идентичная
  /// `TrafficEvent.routingLineOf`: `[net] rule ⇒ группы : транспорт-вход → …
  /// → выход (селектор (выбор)) → dest` — справа от `:` физический путь
  /// пакета (вход первым, выход перед целью).
  /// `chains`/`detours` приходят из ТОГО ЖЕ источника ядра, что
  /// `TrafficEvent.outboundChain`/`detourChain` (`Connection.chain()`/`.detour()`),
  /// порядок идентичен (`[node, …selectors]` / `[node→наружу]`) — поэтому логика
  /// копируется 1:1.
  ///
  /// Отличия от TrafficEvent (намеренно): process НЕ включаем (у ряда Conns своя
  /// app-строка); duration НЕ дописываем (§204 D — таймер рендерится отдельным
  /// виджетом справа в ряду / секцией Timing в detail, не внутри строки).
  ///
  /// [compact] — для ряда: опускает префикс `[net]` (дублирует бейдж/иконку),
  /// строка начинается с `rule`.
  /// [ruleLabel] — резолвленное человекочитаемое имя правила (UI-слой
  /// `RuleNameResolver`); если передано — используется вместо сырого `rule`
  /// (модель vpn не знает про резолвер). Пусто → берётся `rule` или `final`.
  /// [labels] — `tag Направления → label` от UI (модель storage не знает):
  /// Направления подписаны `label (tag)` ([directionTagDisplay]).
  String routingLineOf({
    bool compact = false,
    String? ruleLabel,
    Map<String, String> labels = const {},
  }) {
    final sb = StringBuffer();
    // Ось решения (⇒): [net] rule → селекторы (сверху вниз = chains[1:].reversed).
    final inner = <String>[];
    final ruleText = (ruleLabel != null && ruleLabel.isNotEmpty)
        ? ruleLabel
        : (rule.isNotEmpty ? rule : 'final');
    inner.add(
      !compact && network.isNotEmpty ? '[$network] $ruleText' : ruleText,
    );
    if (chains.length > 1) {
      inner.addAll(chains
          .sublist(1)
          .reversed
          .map((t) => directionTagDisplay(t, labels)));
    }
    sb.write(inner.join(' ⇒ '));
    // §252 — физический путь (→ по ходу пакета): транспорт изнутри наружу
    // (detour-ось развёрнута: вход первым) → выход ОДНИМ элементом
    // `селектор (…вложенно… (node))` (свёртка ПО СТРУКТУРЕ chains
    // `[node, …selectors]`, не через SelectorInfo; пустые chains —
    // outbound-fallback) → назначение.
    final phys = <String>[
      ...foldSelectorPairs(detours, labels: labels).reversed,
    ];
    final exitChain = chains.isNotEmpty
        ? chains
        : (outbound.isNotEmpty ? [outbound] : null);
    if (exitChain != null) {
      var exit = directionTagDisplay(exitChain.first, labels);
      for (final sel in exitChain.skip(1)) {
        exit = '${directionTagDisplay(sel, labels)} ($exit)';
      }
      phys.add(exit);
    }
    final dest = domain.isNotEmpty ? domain : _hostOfDestination;
    if (dest.isNotEmpty) phys.add(dest);
    if (phys.isNotEmpty) sb.write(' : ${phys.join(' → ')}');
    return sb.toString();
  }

  /// Host из `destination` (`host:port` → `host`); IPv6 в `[..]:port` сохраняем.
  String get _hostOfDestination {
    final d = destination;
    if (d.isEmpty) return '';
    if (d.startsWith('[')) {
      final end = d.indexOf(']');
      return end > 0 ? d.substring(0, end + 1) : d;
    }
    final colon = d.lastIndexOf(':');
    return colon > 0 ? d.substring(0, colon) : d;
  }

  factory CcConnection.fromMap(Map<String, dynamic> m) => CcConnection(
    id: m['id']?.toString() ?? '',
    network: m['network']?.toString() ?? '',
    domain: m['domain']?.toString() ?? '',
    destination: m['destination']?.toString() ?? '',
    source: m['source']?.toString() ?? '',
    inbound: m['inbound']?.toString() ?? '',
    inboundType: m['inboundType']?.toString() ?? '',
    rule: m['rule']?.toString() ?? '',
    uplink: _int(m['uplink']),
    downlink: _int(m['downlink']),
    uplinkDelta: _int(m['uplinkDelta']),
    downlinkDelta: _int(m['downlinkDelta']),
    outbound: m['outbound']?.toString() ?? '',
    outboundType: m['outboundType']?.toString() ?? '',
    protocol: m['protocol']?.toString() ?? '',
    chains:
        (m['chains'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    detours:
        (m['detours'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    packageName: m['packageName']?.toString() ?? '',
    processPath: m['processPath']?.toString() ?? '',
    createdAt: _int(m['createdAt']),
    closedAt: _int(m['closedAt']),
  );
}

/// §180 — структурное DNS-событие из ядра (SPEC 018 v2, §261: команда
/// `CommandDNS` в мультиплексе profilerClient, приходит через `writeDNSQuery`).
/// Заменяет текстовый парсинг core-лога: атрибуция к приложению (`packageName`)
/// приходит ИЗ ЯДРА (processInfo), не сшивается по connId.
class CcDnsQuery {
  const CcDnsQuery({
    required this.domain,
    required this.queryType,
    required this.rcode,
    this.ttl = 0,
    this.source = '',
    this.failed = false,
    this.error = '',
    this.packageName = '',
    this.processPath = '',
    this.dnsServer = '',
    this.dnsServerType = '',
    this.outbound = const [],
    this.answers = const [],
    this.groupPath = const [],
    this.attempts = const [],
    this.fanned = false,
    this.survival = false,
  });

  /// Запрошенный домен (оригинал, не финальный CNAME-target).
  final String domain;

  /// qtype: 1=A, 28=AAAA, 5=CNAME, 65=HTTPS, 33=SRV, … (DNS RR type).
  final int queryType;

  /// Q1 (SPEC 018): `-1` = НЕТ ОТВЕТА (timeout), физически ≠ 65535. Иначе —
  /// реальный response.Rcode (0=NOERROR, 3=NXDOMAIN…). НЕ кастить в unsigned:
  /// ядро отдаёт signed, `_int` знак сохраняет.
  final int rcode;

  final int ttl;

  /// exchanged/cached/optimistic/refreshed/rejected/failed (источник ответа).
  final String source;

  /// Q2 (SPEC 018): true на провале (timeout/SERVFAIL/rejected/loopback).
  /// failed-событие → профайлер делает `dnsFail`.
  final bool failed;

  /// Причина провала ("timeout"/"loopback"/"rejected"…); "" на успехе.
  final String error;

  /// Атрибуция к приложению ИЗ ЯДРА (processInfo). Часто непуст — в отличие от
  /// connId-сшивки текстового пути (корень §177-баннера).
  final String packageName;
  final String processPath;

  /// rc.10 (SPEC 018+) — какой DNS-сервер резолвил запрос (на всех путях, вкл.
  /// провалы). Пусто на старом ядре / если ядро не отдало.
  final String dnsServer;

  /// rc.10 — тип DNS-сервера (udp/tcp/tls/https/quic/…).
  final String dnsServerType;

  /// rc.10 — outbound-канал DNS-сервера (селектор развёрнут в активный узел
  /// через Now() server-side), список как chain/detour. ПУСТО на cached
  /// (cache-hit без сетевого пути).
  final List<String> outbound;

  /// Q3 (SPEC 018): ВЕСЬ response.Answer (CNAME-hops + финальные A/AAAA) в
  /// исходном порядке. Пусто если подписка без includeAnswers. cnameChain
  /// собирается из элементов с type==CNAME(5).
  final List<CcDnsAnswer> answers;

  /// §315 (kernel SPEC 035) — путь DNS-групп ИЗНУТРИ НАРУЖУ; пусто = запрос
  /// шёл мимо группы. При вложенности: `[inner, outer]`.
  final List<String> groupPath;

  /// §315 — хронология проб ЭТОГО запроса: кто опрошен, с каким исходом и
  /// RTT. Пусто на кеш-попадании и на не-групповых путях. Опоздавшие ответы
  /// веера сюда НЕ попадают (их не было на момент эмита) — полная картина
  /// живёт в state-RPC `getDnsGroups` (§312).
  final List<CcDnsGroupAttempt> attempts;

  /// §315 — в запросе был веер (спасение после сбоя цели / выборы `fastest` /
  /// любой запрос `parallel`).
  final bool fanned;

  /// §315 — режим выживания: чистых членов не осталось, ответ получен одной
  /// попыткой к наименее грязному. Красный флаг здоровья группы.
  final bool survival;

  /// Q1-helper: ответа от сервера не было (timeout).
  bool get noAnswer => rcode == -1;

  /// §315 — запрос шёл через DNS-группу.
  bool get viaGroup => groupPath.isNotEmpty;

  factory CcDnsQuery.fromMap(Map<String, dynamic> m) => CcDnsQuery(
    domain: m['domain']?.toString() ?? '',
    queryType: _int(m['queryType']),
    rcode: _int(m['rcode']), // знак сохраняется → -1 остаётся -1 (Q1)
    ttl: _int(m['ttl']),
    source: m['source']?.toString() ?? '',
    failed: m['failed'] == true,
    error: m['error']?.toString() ?? '',
    packageName: m['packageName']?.toString() ?? '',
    processPath: m['processPath']?.toString() ?? '',
    dnsServer: m['dnsServer']?.toString() ?? '',
    dnsServerType: m['dnsServerType']?.toString() ?? '',
    outbound:
        (m['outbound'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const [],
    answers:
        (m['answers'] as List?)
            ?.map(
              (a) => CcDnsAnswer.fromMap(
                (a as Map).map((k, v) => MapEntry(k.toString(), v)),
              ),
            )
            .toList() ??
        const [],
    // §315 — трасса группы; на старом ядре/нативе ключей нет → пустые дефолты.
    groupPath:
        (m['groupPath'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const [],
    attempts:
        (m['attempts'] as List?)
            ?.whereType<Map>()
            .map(
              (a) => CcDnsGroupAttempt.fromMap(
                a.map((k, v) => MapEntry(k.toString(), v)),
              ),
            )
            .toList() ??
        const [],
    fanned: m['fanned'] == true,
    survival: m['survival'] == true,
  );
}

/// §315 (kernel SPEC 035) — одна проба DNS-группы из трассы запроса.
class CcDnsGroupAttempt {
  const CcDnsGroupAttempt({
    required this.server,
    required this.serverType,
    required this.outcome,
    required this.rttMs,
  });

  /// Тег опрошенного участника (лист — не группа).
  final String server;

  /// Тип транспорта участника (udp/tls/https/…).
  final String serverType;

  /// `answered` · `timeout` · `network_error` · `servfail`.
  final String outcome;

  /// RTT пробы, мс.
  final int rttMs;

  bool get answered => outcome == 'answered';

  factory CcDnsGroupAttempt.fromMap(Map<String, dynamic> m) =>
      CcDnsGroupAttempt(
        server: m['server']?.toString() ?? '',
        serverType: m['serverType']?.toString() ?? '',
        outcome: m['outcome']?.toString() ?? '',
        rttMs: _int(m['rttMs']),
      );
}

/// §180 — одна DNS-запись ответа (RR). Часть `CcDnsQuery.answers`.
class CcDnsAnswer {
  const CcDnsAnswer({
    required this.name,
    required this.type,
    required this.rdata,
    this.ttl = 0,
  });

  final String name;
  final int type; // RR type (5=CNAME, 1=A, 28=AAAA…)
  final String rdata; // значение записи (target для CNAME, IP для A/AAAA)
  final int ttl;

  bool get isCname => type == 5;
  bool get isAddress => type == 1 || type == 28; // A / AAAA

  factory CcDnsAnswer.fromMap(Map<String, dynamic> m) => CcDnsAnswer(
    name: m['name']?.toString() ?? '',
    type: _int(m['type']),
    rdata: m['rdata']?.toString() ?? '',
    ttl: _int(m['ttl']),
  );
}
