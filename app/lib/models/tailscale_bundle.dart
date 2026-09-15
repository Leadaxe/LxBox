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

/// §449 — префикс hostname по умолчанию: по имени в админке tailnet видно, что
/// устройство заведено из LxBox.
const String kTailscaleHostnamePrefix = 'LxBox';

/// §449 — потолок длины DNS-метки (`<hostname>.<tailnet>.ts.net`).
const int kTailscaleHostnameMaxLength = 63;

/// §449 — hostname узла по умолчанию: `LxBox-<модель устройства>`.
///
/// Пустое поле Hostname оставляет имя на откуп tsnet, а тот берёт имя хоста
/// системы: на стенде 15.09 узел вошёл в tailnet как `node`, и какой это из
/// серверов LxBox — по админке не прочитать. Tag узла в имя не идёт: он живёт
/// внутри приложения (заголовок записи и основа тега в конфиге ядра).
///
/// [model] — `SubscriptionIdentity.effectiveDeviceModel` (`Build.MODEL` либо
/// override из App Settings). Пустая или схлопнувшаяся целиком модель даёт
/// голый префикс: `LxBox` лучше, чем `LxBox-`.
String defaultTailscaleHostname(String model) {
  final suffix = _dnsLabelSegment(model);
  if (suffix.isEmpty) return kTailscaleHostnamePrefix;
  final room = kTailscaleHostnameMaxLength - kTailscaleHostnamePrefix.length - 1;
  final trimmed = suffix.length > room
      // Хвостовой дефис после обрезки снимаем: `LxBox-pixel-` — не метка.
      ? _stripDashes(suffix.substring(0, room))
      : suffix;
  if (trimmed.isEmpty) return kTailscaleHostnamePrefix;
  return '$kTailscaleHostnamePrefix-$trimmed';
}

/// Модель устройства как сегмент DNS-метки: латиница и цифры в нижнем
/// регистре, всё прочее (пробел, `_`, кириллица, эмодзи) — дефис, серии
/// схлопнуты, края очищены. `Pixel 7 Pro` → `pixel-7-pro`.
///
/// Санитизация тега (`tailscaleStateDirName`, §445) сюда не годится: там имя
/// каталога ФС со своим алфавитом, и схлопывание кириллицы в `___` дало бы
/// `LxBox----`.
String _dnsLabelSegment(String model) {
  final buf = StringBuffer();
  for (final code in model.toLowerCase().codeUnits) {
    final isDigit = code >= 0x30 && code <= 0x39;
    final isLetter = code >= 0x61 && code <= 0x7A;
    buf.writeCharCode(isDigit || isLetter ? code : 0x2D);
  }
  return _stripDashes(buf.toString());
}

/// Схлопывает серии дефисов и снимает их по краям.
String _stripDashes(String s) {
  final collapsed = s.replaceAll(RegExp(r'-+'), '-');
  return collapsed.replaceAll(RegExp(r'^-|-$'), '');
}

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
