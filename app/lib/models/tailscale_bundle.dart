/// §435/§437 — каноническая связка узла Tailscale (NODE_SECTIONS.md §6, спека
/// features/435 §2): правило `@{self} network` — `.ts.net` и обе подсети
/// tailnet (v4 CGNAT + v6 ULA) на узел, с нетерминальным `resolve` через
/// DNS-сервер узла перед маршрутом; DNS-сервер типа `tailscale` на сам узел и
/// DNS-правило `.ts.net` → этот сервер. Плейсхолдеры `@self`/`@{self}` лежат
/// как есть — подстановка финального тега при сборке и при показе.
///
/// Живёт в `models/`, а не в папке мастера: связку ставит и контроллер
/// (свободный узел Tailscale без извлечённых записей — §437).
library;

import 'node_sections.dart';
import 'node_spec.dart';

/// Подсеть CGNAT, которую Tailscale раздаёт узлам tailnet.
const String kTailnetCidr = '100.64.0.0/10';

/// ULA-подсеть tailnet (`tsaddr.TailscaleULARange`): узлы получают и её, и при
/// стратегии `prefer_ipv6`/`ipv6_only` маршрут с одним v4 промахивается.
const String kTailnetCidrV6 = 'fd7a:115c:a1e0::/48';

/// MagicDNS-суффикс tailnet.
const String kTailnetDnsSuffix = '.ts.net';

/// Тег DNS-сервера узла (после подстановки — `<тег узла>-dns`).
const String kTailscaleDnsServerTag = '@{self}-dns';

/// Имя правила маршрута узла (после подстановки — `<тег узла> network`).
const String kTailscaleNetworkRuleName = '@{self} network';

/// Форма §2 как JSON — то, что ляжет в `server_lists[].sections`.
///
/// `domain_suffix` рядом с `ip_cidr` — внутри одного правила это ИЛИ: имя
/// `host.tailnet.ts.net` матчится и под FakeIP, когда адреса ещё нет. Пара
/// `resolve` (метаданные LxBox вне `body`) даёт при сборке нетерминальное
/// правило `action: resolve, server: <тег>-dns` ПЕРЕД маршрутом — без него
/// UDP-поток к endpoint'у ядро отбрасывает (нужен адрес до роутинга).
Map<String, dynamic> canonicalTailscaleSectionsJson() => {
      'rules': [
        {
          'kind': 'inline',
          'name': kTailscaleNetworkRuleName,
          'enabled': true,
          'num': kNodeRuleDefaultNum,
          'body': {
            'domain_suffix': [kTailnetDnsSuffix],
            'ip_cidr': [kTailnetCidr, kTailnetCidrV6],
            'outbound': kSelfPlaceholder,
          },
          'resolve': {'only': false, 'serverTag': kTailscaleDnsServerTag},
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

/// §437 — секции нового свободного узла: извлечённые парсером, иначе для
/// узла Tailscale каноническая связка (голое тело, конфиг без ссылок на тег).
/// Пользователь снимает её через Clear sections.
NodeSections? sectionsForNewNode(NodeSpec n) =>
    n.importedSections ??
    (n is TailscaleSpec ? canonicalTailscaleSections() : null);
