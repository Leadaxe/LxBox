/// Кодек правил маршрута: [CustomRule] ↔ запись `rules[]` контракта 1.0
/// (`contract/docs/ONE_NAMESPACE.md` §1, спека §439 §1.2).
///
/// **Запись = метаданные приложения + `body` = правило sing-box как есть.**
/// Метаданные — `kind`, `id`, `name`, `enabled`, `num`, `refs`, `ref`, `vars`;
/// поля LxBox рядом с телом — `dns{}`, `resolve{}`, `update_interval_hours`
/// (srs), `verbatim` (inline).
///
/// Один кодек на хранение, бэкап, файл правил, секции узла и Debug API, поэтому
/// строки (`id`, `name`) не режутся: имя srs-правила — тег `rule_set` в
/// конфиге (§439 §2.3 п. 12).
///
/// Вид `json` (§225) в записи не живёт: [CustomRuleJson] пишется как
/// `inline` + `verbatim: true`, тело-объект — в `body`; текст, который
/// объектом не разбирается (битый JSON, массив), — маркер без `body`. Массив
/// раскладывает на записи вызывающий до кодека (§439 В2).
///
/// Чтение терпимо: чужой `kind` и битая форма — [RecordRead.dropped], не
/// исключение; скаляр вместо списка читается списком; незнакомые ключи корня
/// записи игнорируются молча. Незнакомые ключи `body` — в
/// [RecordRead.unknownKeys]; с `unknownAsVerbatim` inline-запись с ними
/// читается [CustomRuleJson] с телом целиком.
library;

import 'dart:convert';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../custom_rule.dart';
import 'record_read.dart';

/// Ключи `body` правила маршрута, которые типизированная модель держит (имена
/// sing-box). Всё остальное при чтении — в `unknownKeys`.
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
  // конфига, наборы едут `refs[]`. Вырезать молча нельзя — правило без
  // единственного матчера стало бы match-all (норма лаунчера 14.09.2026, B3).
};

/// Текст тела [CustomRuleJson], прочитанного из записи.
const JsonEncoder _verbatimText = JsonEncoder.withIndent('  ');

/// Правило LxBox → запись 1.0.
Map<String, dynamic> ruleToRecord(CustomRule r) {
  final out = <String, dynamic>{
    'kind': r is CustomRuleJson ? 'inline' : r.kind.name,
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
      if (r.updateIntervalHours != kDefaultSrsTtlHours) {
        out['update_interval_hours'] = r.updateIntervalHours;
      }
      out['body'] = _ruleBody(r, includeMatch: false);
    case CustomRulePreset():
      out['ref'] = r.presetId;
      if (r.varsValues.isNotEmpty) {
        out['vars'] = Map<String, String>.of(r.varsValues);
      }
    case CustomRuleJson():
      out['verbatim'] = true;
      final body = _objectOf(r.json);
      if (body != null) out['body'] = body;
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
  // Типы sing-box: `port` — числа (нечисловые отбрасываются, сборка их тоже
  // не эмитит), `port_range` — строки `"a:b"`.
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
  // Пустая цель пишется как есть: сборка такое правило пропускает, а запись
  // без `outbound` читается целью по умолчанию и попала бы в конфиг.
  if (r.outbound == kOutboundReject) {
    b['action'] = 'reject';
  } else {
    b['outbound'] = r.outbound;
  }
  return b;
}

/// Запись 1.0 → правило LxBox.
///
/// [unknownAsVerbatim] — путь хранения: inline-запись, тело которой модель не
/// выражает (незнакомый матчер, `rule_set`, `action` кроме `reject`,
/// `method`), читается [CustomRuleJson] с телом целиком, ключи всё равно
/// перечислены в [RecordRead.unknownKeys]. Без флага (секции узла, импорт)
/// читается типизированное правило, ключи потеряны, решает вызывающий.
RecordRead<CustomRule> ruleFromRecord(
  Map<String, dynamic> j, {
  bool unknownAsVerbatim = false,
}) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('rule without kind');
  }
  final rawId = j['id'];
  final id = rawId is String && rawId.trim().isNotEmpty ? rawId : null;
  final rawName = j['name'];
  final name = rawName is String ? rawName : '';
  final enabled = j['enabled'] != false;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;

  switch (kind) {
    case 'inline':
    case 'srs':
      final rawBody = j['body'];
      final body = rawBody is Map ? rawBody.cast<String, dynamic>() : null;
      if (rawBody != null && body == null) {
        return RecordRead.drop('rule "$name": body is not an object');
      }
      if (kind == 'inline' && j['verbatim'] == true) {
        return RecordRead.ok(CustomRuleJson(
          id: id,
          name: name,
          enabled: enabled,
          orderNum: orderNum,
          json: body == null ? '' : _verbatimText.convert(body),
        ));
      }
      final b = body ?? const <String, dynamic>{};
      final unknown = [
        for (final k in b.keys)
          if (!kRuleBodyKeys.contains(k)) k,
        // §438 — `action` модель выражает ровно одним значением, `reject`
        // (цель kOutboundReject). Самостоятельный эффект ядра (`sniff`,
        // `resolve`, `hijack-dns`, …) у типизированного правила дома не имеет:
        // прочитанный как правило на direct-out, он молча стал бы маршрутом.
        if (b.containsKey('action') && b['action'] != 'reject') 'action',
      ]..sort();
      if (kind == 'inline' && unknownAsVerbatim && unknown.isNotEmpty) {
        return RecordRead.ok(
          CustomRuleJson(
            id: id,
            name: name,
            enabled: enabled,
            orderNum: orderNum,
            json: _verbatimText.convert(b),
          ),
          unknownKeys: unknown,
        );
      }
      final outbound = _outboundOf(b);
      final dns = RuleDns.fromJson(j['dns']);
      final resolve = RuleResolve.fromJson(j['resolve']);
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
            ports: _portList(b['port']),
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
      final ref = j['ref'];
      return RecordRead.ok(
        CustomRuleSrs(
          id: id,
          name: name,
          enabled: enabled,
          orderNum: orderNum,
          // `refs` главнее одиночного `ref` (## 12).
          srsUrls: refs.isNotEmpty ? refs : [if (ref is String) ref],
          updateIntervalHours:
              CustomRuleSrs.ttlHoursFrom(j['update_interval_hours']),
          ports: _portList(b['port']),
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
      final ref = j['ref'];
      final vars = j['vars'];
      return RecordRead.ok(CustomRulePreset(
        id: id,
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        presetId: ref is String ? ref : '',
        varsValues: vars is Map
            ? {
                for (final e in vars.entries)
                  e.key.toString(): e.value?.toString() ?? '',
              }
            : const {},
      ));
    default:
      return RecordRead.drop('rule "$name": unknown kind "$kind"');
  }
}

/// Цель из тела: `action: reject` → [kOutboundReject]; строковый `outbound`
/// как есть (пустой тоже); без ключа — цель по умолчанию.
String _outboundOf(Map<String, dynamic> body) {
  if (body['action'] == 'reject') return kOutboundReject;
  final o = body['outbound'];
  return o is String ? o : kDirectOutboundTag;
}

/// Текст правила вида json → объект тела; массив, скаляр и мусор → null.
Map<String, dynamic>? _objectOf(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
}

/// Список строк из значения JSON: массив → элементы `toString()`; скаляр →
/// один элемент (sing-box принимает и строку, и массив). `null`/пусто → [].
List<String> _strList(Object? v) {
  if (v == null) return const [];
  if (v is List) return [for (final e in v) e.toString()];
  if (v is String) return v.isEmpty ? const [] : [v];
  return [v.toString()];
}

/// Порты тела: только числа 0–65535, строками модели. Нечисловое отбрасывается
/// на чтении так же, как на записи ([CustomRule.intPorts]).
List<String> _portList(Object? v) => [
      for (final e in _strList(v))
        if (int.tryParse(e) case final p? when p >= 0 && p <= 65535) '$p',
    ];
