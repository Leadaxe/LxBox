/// §435 — каноническая связка узла Tailscale для мастера «Add server →
/// Tailscale» (NODE_SECTIONS.md §6, спека features/435 §2): маршрут подсети
/// tailnet `100.64.0.0/10` на узел (num 945 — перед якорем `private-ips`),
/// DNS-сервер типа `tailscale` на сам узел и DNS-правило `.ts.net` → этот
/// сервер. Плейсхолдеры `@self`/`@{self}` лежат как есть — подстановка
/// финального тега при сборке и при показе.
library;

import '../../models/node_sections.dart';

/// Подсеть CGNAT, которую Tailscale раздаёт узлам tailnet.
const String kTailnetCidr = '100.64.0.0/10';

/// MagicDNS-суффикс tailnet.
const String kTailnetDnsSuffix = '.ts.net';

/// Тег DNS-сервера узла (после подстановки — `<тег узла>-dns`).
const String kTailscaleDnsServerTag = '@{self}-dns';

/// Имя правила маршрута узла (после подстановки — `<тег узла> network`).
const String kTailscaleNetworkRuleName = '@{self} network';

/// Форма §2 как JSON — то, что ляжет в `server_lists[].sections`.
Map<String, dynamic> canonicalTailscaleSectionsJson() => {
      'rules': [
        {
          'kind': 'inline',
          'name': kTailscaleNetworkRuleName,
          'enabled': true,
          'num': kNodeRuleDefaultNum,
          'body': {
            'ip_cidr': [kTailnetCidr],
            'outbound': kSelfPlaceholder,
          },
        },
      ],
      'dns': {
        'servers': [
          {
            'kind': 'user',
            'tag': kTailscaleDnsServerTag,
            'enabled': true,
            'body': {'type': 'tailscale', 'endpoint': kSelfPlaceholder},
          },
        ],
        'rules': [
          {
            'kind': 'user',
            'name': '',
            'enabled': true,
            'body': {
              'domain_suffix': [kTailnetDnsSuffix],
              'server': kTailscaleDnsServerTag,
            },
          },
        ],
      },
    };

/// Связка через кодек записей — ровно то, что прочитал бы контейнер из
/// хранилища. Три записи, пустой быть не может.
NodeSections canonicalTailscaleSections() =>
    NodeSections.fromJson(canonicalTailscaleSectionsJson()) ??
    (throw StateError('canonical Tailscale sections did not parse'));
