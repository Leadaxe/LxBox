/// Кодек записей контракта 1.0 (`contract/docs/ONE_NAMESPACE.md` §1–§2):
/// **запись = метаданные приложения + `body` = объект sing-box как есть.**
///
/// Это не времянка для секций узла (§435): по решению владельца тот же код
/// станет корневым парсером `custom_rules` / `dns_options` при миграции
/// хранения на форму 1.0. Поэтому здесь есть ветки и для `preset`/`template`,
/// хотя секции узла их отвергают.
///
/// Метаданные — `kind`, `id`, `name`|`tag`, `enabled`, `num`, `refs`,
/// расширения LxBox (`dns{}`, `resolve{}` у правила маршрута). Тег DNS-сервера
/// — единственное исключение из «тело как есть»: он в метаданных, в `body` его
/// нет.
///
/// Чтение толерантно: чужой `kind` и битая форма — не исключение, а
/// [RecordRead.dropped] с причиной; незнакомые ключи `body` собираются в
/// [RecordRead.unknownKeys] (вызывающий решает, показывать ли). Незнакомые
/// ключи корня записи игнорируются молча — так вторая сторона игнорирует наши
/// `dns{}`/`resolve{}`.
library;

import '../config/consts.dart' show kDirectOutboundTag;
import 'custom_rule.dart';
import 'dns_ref.dart';

/// Результат чтения одной записи: либо значение, либо причина отброса.
final class RecordRead<T> {
  const RecordRead.ok(T this.value, {this.unknownKeys = const []})
      : dropped = null;
  const RecordRead.drop(String this.dropped)
      : value = null,
        unknownKeys = const [];

  final T? value;

  /// Причина, по которой запись не читается (чужой `kind`, нет тела …).
  final String? dropped;

  /// Ключи `body`, которых кодек не знает и которые потеряны при чтении.
  final List<String> unknownKeys;
}

// ─── Правила маршрута ────────────────────────────────────────────────────────

/// Ключи `body` правила маршрута, которые LxBox применяет (имена sing-box).
/// Всё остальное при чтении — в `unknownKeys`.
const Set<String> kRuleBodyKeys = {
  'domain',
  'domain_suffix',
  'domain_keyword',
  'ip_cidr',
  'port',
  'port_range',
  'package_name',
  'protocol',
  'network',
  'ip_is_private',
  'source_ip_cidr',
  'source_ip_is_private',
  'inbound',
  'wifi_ssid',
  'wifi_bssid',
  'outbound',
  'action',
  // `rule_set` намеренно НЕ в списке: в теле записи это ссылка на набор
  // конфига, которую LxBox перенести не может, а вырезать молча нельзя —
  // правило без единственного матчера стало бы match-all (норма лаунчера
  // 14.09.2026, B3). Секции такую запись отбрасывают целиком; корень 1.0
  // решит в волне 4.
};

/// Правило LxBox → запись 1.0.
Map<String, dynamic> ruleToRecord(CustomRule r) {
  final out = <String, dynamic>{
    'kind': r.kind.name,
    'id': r.id,
    'name': r.name,
    'enabled': r.enabled,
    if (r.orderNum != null) 'num': r.orderNum,
  };
  switch (r) {
    case CustomRuleInline():
      out['body'] = _ruleBody(r, includeMatch: true);
    case CustomRuleSrs():
      // Источники наборов — снаружи `body`: это не sing-box. `rule_set` в
      // тело вписывает сборка (ONE_NAMESPACE §1, D-100).
      out['refs'] = List<String>.of(r.srsUrls);
      out['body'] = _ruleBody(r, includeMatch: false);
    case CustomRulePreset():
      out['ref'] = r.presetId;
      if (r.varsValues.isNotEmpty) {
        out['vars'] = Map<String, String>.of(r.varsValues);
      }
    case CustomRuleJson():
      // §225 — вид LxBox: тело правила текстом. У контракта такого вида нет,
      // секции его отвергают; корень 1.0 переносит текст как есть.
      out['json'] = r.json;
  }
  if (r.dns != null) out['dns'] = r.dns!.toJson();
  if (r.resolve != null) out['resolve'] = r.resolve!.toJson();
  return out;
}

Map<String, dynamic> _ruleBody(CustomRule r, {required bool includeMatch}) {
  final b = <String, dynamic>{};
  if (includeMatch) {
    if (r.domains.isNotEmpty) b['domain'] = List<String>.of(r.domains);
    if (r.domainSuffixes.isNotEmpty) {
      b['domain_suffix'] = List<String>.of(r.domainSuffixes);
    }
    if (r.domainKeywords.isNotEmpty) {
      b['domain_keyword'] = List<String>.of(r.domainKeywords);
    }
    if (r.ipCidrs.isNotEmpty) b['ip_cidr'] = List<String>.of(r.ipCidrs);
  }
  // Типы sing-box: `port` — числа, `port_range` — строки `"a:b"`.
  final ports = r.intPorts;
  if (ports.isNotEmpty) b['port'] = ports;
  if (r.portRanges.isNotEmpty) b['port_range'] = List<String>.of(r.portRanges);
  if (r.packages.isNotEmpty) b['package_name'] = List<String>.of(r.packages);
  if (r.protocols.isNotEmpty) b['protocol'] = List<String>.of(r.protocols);
  if (r.network.isNotEmpty) b['network'] = List<String>.of(r.network);
  if (r.ipIsPrivate) b['ip_is_private'] = true;
  if (r.sourceIpCidrs.isNotEmpty) {
    b['source_ip_cidr'] = List<String>.of(r.sourceIpCidrs);
  }
  if (r.sourceIpIsPrivate) b['source_ip_is_private'] = true;
  if (r.inbounds.isNotEmpty) b['inbound'] = List<String>.of(r.inbounds);
  if (r.wifiSsids.isNotEmpty) b['wifi_ssid'] = List<String>.of(r.wifiSsids);
  if (r.wifiBssids.isNotEmpty) b['wifi_bssid'] = List<String>.of(r.wifiBssids);
  if (r.outbound == kOutboundReject) {
    b['action'] = 'reject';
  } else if (r.outbound.isNotEmpty) {
    b['outbound'] = r.outbound;
  }
  return b;
}

/// Запись 1.0 → правило LxBox.
RecordRead<CustomRule> ruleFromRecord(Map<String, dynamic> j) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('rule without kind');
  }
  final id = _optString(j['id']);
  final name = _optString(j['name']) ?? '';
  final enabled = j['enabled'] != false;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;
  final dns = RuleDns.fromJson(j['dns']);
  final resolve = RuleResolve.fromJson(j['resolve']);

  switch (kind) {
    case 'inline':
    case 'srs':
      final rawBody = j['body'];
      final body = rawBody is Map ? rawBody.cast<String, dynamic>() : null;
      if (rawBody != null && body == null) {
        return RecordRead.drop('rule "$name": body is not an object');
      }
      final b = body ?? const <String, dynamic>{};
      final unknown = [
        for (final k in b.keys)
          if (!kRuleBodyKeys.contains(k)) k,
        // §438 — `action` модель выражает ровно одним значением, `reject`
        // (цель kOutboundReject). Самостоятельный эффект ядра (`sniff`,
        // `resolve`, `hijack-dns`, …) у типизированного правила дома не имеет:
        // прочитанный как правило на direct-out, он молча стал бы маршрутом.
        // Ключ считается незнакомым, решение принимает вызывающий (секции
        // отбрасывают запись, корень бэкапа 1.0 переносит тело видом json).
        if (b.containsKey('action') && b['action'] != 'reject') 'action',
      ]..sort();
      final outbound = _outboundOf(b);
      if (kind == 'inline') {
        return RecordRead.ok(
          CustomRuleInline(
            id: id,
            name: name,
            enabled: enabled,
            orderNum: orderNum,
            domains: _strList(b['domain']),
            domainSuffixes: _strList(b['domain_suffix']),
            domainKeywords: _strList(b['domain_keyword']),
            ipCidrs: _strList(b['ip_cidr']),
            ports: _strList(b['port']),
            portRanges: _strList(b['port_range']),
            packages: _strList(b['package_name']),
            protocols: _strList(b['protocol']),
            network: _strList(b['network']),
            ipIsPrivate: b['ip_is_private'] == true,
            sourceIpCidrs: _strList(b['source_ip_cidr']),
            sourceIpIsPrivate: b['source_ip_is_private'] == true,
            inbounds: _strList(b['inbound']),
            wifiSsids: _strList(b['wifi_ssid']),
            wifiBssids: _strList(b['wifi_bssid']),
            outbound: outbound,
            dns: dns,
            resolve: resolve,
          ),
          unknownKeys: unknown,
        );
      }
      final refs = _strList(j['refs']);
      final ref = _optString(j['ref']);
      return RecordRead.ok(
        CustomRuleSrs(
          id: id,
          name: name,
          enabled: enabled,
          orderNum: orderNum,
          // `refs` главнее одиночного `ref` (## 12).
          srsUrls: refs.isNotEmpty ? refs : [?ref],
          ports: _strList(b['port']),
          portRanges: _strList(b['port_range']),
          packages: _strList(b['package_name']),
          protocols: _strList(b['protocol']),
          network: _strList(b['network']),
          ipIsPrivate: b['ip_is_private'] == true,
          sourceIpCidrs: _strList(b['source_ip_cidr']),
          sourceIpIsPrivate: b['source_ip_is_private'] == true,
          inbounds: _strList(b['inbound']),
          wifiSsids: _strList(b['wifi_ssid']),
          wifiBssids: _strList(b['wifi_bssid']),
          outbound: outbound,
          dns: dns,
          resolve: resolve,
        ),
        unknownKeys: unknown,
      );
    case 'preset':
      final ref = _optString(j['ref']) ?? '';
      final vars = j['vars'];
      return RecordRead.ok(CustomRulePreset(
        id: id,
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        presetId: ref,
        varsValues: vars is Map
            ? {
                for (final e in vars.entries)
                  e.key.toString(): e.value?.toString() ?? '',
              }
            : const {},
      ));
    case 'json':
      final text = _optString(j['json']) ?? '';
      return RecordRead.ok(CustomRuleJson(
        id: id,
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        json: text,
      ));
    default:
      return RecordRead.drop('rule "$name": unknown kind "$kind"');
  }
}

String _outboundOf(Map<String, dynamic> body) {
  if (body['action'] == 'reject') return kOutboundReject;
  final o = body['outbound'];
  if (o is String && o.isNotEmpty) return o;
  return kDirectOutboundTag;
}

// ─── DNS-серверы ─────────────────────────────────────────────────────────────

/// Ref DNS-сервера LxBox → запись 1.0. Пользовательская запись — `kind: user`
/// (у LxBox внутри — `inline`), тело без `tag`.
Map<String, dynamic> dnsServerToRecord(DnsServerRef s) => switch (s) {
      DnsServerInline() => {
          'kind': 'user',
          'tag': s.tag,
          'enabled': s.enabled,
          'body': Map<String, dynamic>.of(s.body)..remove('tag'),
          if (s.description != null) 'description': s.description,
        },
      // §438 — у записи preset тега нет, её идентичность — `ref`
      // (BACKUP.md §2, §9 п. 5). У LxBox ссылкой служит тег сервера пресета.
      DnsServerPreset() => {
          'kind': 'preset',
          'ref': s.tag,
          'enabled': s.enabled,
          if (s.description != null) 'description': s.description,
        },
      DnsServerTemplate() => {
          'kind': 'template',
          'tag': s.tag,
          'enabled': s.enabled,
          if (s.varValues.isNotEmpty) 'vars': Map<String, String>.of(s.varValues),
          if (s.description != null) 'description': s.description,
        },
    };

/// Запись 1.0 → ref DNS-сервера LxBox.
RecordRead<DnsServerRef> dnsServerFromRecord(Map<String, dynamic> j) {
  final kind = j['kind'];
  // §438 — preset адресуется `ref` (контракт 1.0); `tag` у preset — прежняя
  // форма этого кодека, читается запасным ходом.
  final tag = kind == 'preset'
      ? (_optString(j['ref']) ?? _optString(j['tag']))
      : _optString(j['tag']);
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('dns server without kind');
  }
  if (tag == null) return RecordRead.drop('dns server ($kind) without tag');
  final enabled = j['enabled'] != false;
  final description = _optString(j['description']);
  switch (kind) {
    case 'user':
      final body = j['body'];
      if (body is! Map) {
        return RecordRead.drop('dns server "$tag": body is not an object');
      }
      return RecordRead.ok(DnsServerInline(
        enabled: enabled,
        tag: tag,
        body: Map<String, dynamic>.of(body.cast<String, dynamic>())
          ..remove('tag'),
        description: description,
      ));
    case 'preset':
      return RecordRead.ok(
          DnsServerPreset(enabled: enabled, tag: tag, description: description));
    case 'template':
      final vars = j['vars'];
      return RecordRead.ok(DnsServerTemplate(
        enabled: enabled,
        tag: tag,
        varValues: vars is Map
            ? {
                for (final e in vars.entries)
                  e.key.toString(): e.value?.toString() ?? '',
              }
            : const {},
        description: description,
      ));
    default:
      return RecordRead.drop('dns server "$tag": unknown kind "$kind"');
  }
}

// ─── DNS-правила ─────────────────────────────────────────────────────────────

/// Ref DNS-правила LxBox → запись 1.0. Пользовательская запись — `kind: user`,
/// тело — правило sing-box целиком (`server` внутри).
Map<String, dynamic> dnsRuleToRecord(DnsRuleRef r) => switch (r) {
      DnsRuleInline() => {
          'kind': 'user',
          'name': r.name,
          'enabled': r.enabled,
          'body': Map<String, dynamic>.of(r.rule),
        },
      DnsRuleSrs() => {
          'kind': 'srs',
          'name': r.name,
          'id': r.id,
          if (r.body != null) 'body': Map<String, dynamic>.of(r.body!),
        },
      DnsRulePreset() => {
          'kind': 'preset',
          'ref': r.presetId,
          'enabled': r.enabled,
        },
      DnsRuleTemplate() => {'kind': 'template', 'name': r.name},
    };

/// Запись 1.0 → ref DNS-правила LxBox.
RecordRead<DnsRuleRef> dnsRuleFromRecord(Map<String, dynamic> j) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('dns rule without kind');
  }
  final name = _optString(j['name']) ?? '';
  switch (kind) {
    case 'user':
      final body = j['body'];
      if (body is! Map) {
        return RecordRead.drop('dns rule "$name": body is not an object');
      }
      return RecordRead.ok(DnsRuleInline(
        name: name,
        rule: Map<String, dynamic>.of(body.cast<String, dynamic>()),
        enabled: j['enabled'] != false,
      ));
    case 'srs':
      final id = _optString(j['id']);
      if (id == null) return RecordRead.drop('dns rule "$name": srs without id');
      final body = j['body'];
      return RecordRead.ok(DnsRuleSrs(
        name: name,
        id: id,
        body: body is Map ? body.cast<String, dynamic>() : null,
      ));
    case 'preset':
      final ref = _optString(j['ref']);
      if (ref == null) return const RecordRead.drop('dns rule: preset without ref');
      return RecordRead.ok(DnsRulePreset(presetId: ref, enabled: j['enabled'] != false));
    case 'template':
      if (name.isEmpty) {
        return const RecordRead.drop('dns rule: template without name');
      }
      return RecordRead.ok(DnsRuleTemplate(name: name));
    default:
      return RecordRead.drop('dns rule "$name": unknown kind "$kind"');
  }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

String? _optString(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

/// Список строк из значения JSON: массив → элементы `toString()`; скаляр →
/// один элемент (sing-box принимает и строку, и массив). `null`/пусто → [].
List<String> _strList(Object? v) {
  if (v == null) return const [];
  if (v is List) return [for (final e in v) e.toString()];
  if (v is String) return v.isEmpty ? const [] : [v];
  return [v.toString()];
}
