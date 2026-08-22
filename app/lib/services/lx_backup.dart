/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';

import '../models/custom_rule.dart';
import '../config/consts.dart';
import '../models/server_list.dart';

/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4).
///
/// Схема — `contract/schema/backup.schema.json`, семантика —
/// `contract/docs/BACKUP.md`. Это НЕ замена [BackupService]: тот делает
/// полный снимок настроек для той же самой установки, а этот переносит
/// общую часть между приложениями.
///
/// Три инварианта:
///
///  1. Lossless round-trip: непереносимое (`packages`, `wifiSsids`, папки)
///     уезжает в `extensions.lxbox` и обязано пережить чужой импорт
///     нетронутым — иначе бэкап, побывавший на десктопе, возвращается
///     обеднённым.
///  2. Default-deny: неизвестный ключ вне `extensions` не применяется молча.
///  3. Нет молчаливых потерь: неприменённое названо кодом warning'а.

/// Мажорная версия формата.
const int kLxBackupVersion = 1;

const String kLxAppLxBox = 'lxbox';
const String kLxAppLauncher = 'launcher';

/// Коды предупреждений импорта (общие с Go-стороной).
const String kWarnUnknownOutbound = 'backup_unknown_outbound';
const String kWarnFinalDropped = 'backup_final_dropped';
const String kWarnUnknownPreset = 'backup_unknown_preset';
const String kWarnVarSkipped = 'backup_var_skipped';
const String kWarnUnknownField = 'backup_unknown_field';

/// Переносимые имена переменных — зеркало `registry/vars.json` (portable=true).
///
/// Сверяется с реестром тестом: разъехавшийся список означает, что бэкап либо
/// теряет настройку, либо тащит на чужую машину значение, которое там значит
/// другое (пути, интерфейсы, платформенные флаги).
const Set<String> kLxPortableVars = {
  'auto_detect_interface',
  'dns_default_domain_resolver',
  'dns_final',
  'dns_strategy',
  'ipv6_enabled',
  'log_level',
  'resolve_strategy',
  'tls_fragment',
  'tls_fragment_fallback_delay',
  'tls_mixed_case_sni',
  'tls_record_fragment',
  'tun_address6',
  'tun_mtu',
  'tun_stack',
  'urltest_interval',
  'urltest_tolerance',
  'urltest_url',
};

/// Зарезервированные цели: существуют всегда, объявлять не нужно.
const Set<String> _reservedOutbounds = {
  'direct',
  'block',
  'reject',
  'drop',
  'dns-out',
};

/// Предупреждение импорта: код + что затронуто.
class LxBackupWarning {
  const LxBackupWarning(this.code, this.detail);

  final String code;
  final String detail;

  @override
  String toString() => '$code: $detail';
}

/// Результат разбора файла.
class LxBackupFile {
  const LxBackupFile({
    required this.version,
    required this.exportedByApp,
    required this.exportedByVersion,
    required this.exportedAt,
    required this.rules,
    required this.subscriptions,
    required this.vars,
    required this.routeFinal,
    required this.foreignExtensions,
    required this.warnings,
  });

  final int version;
  final String exportedByApp;
  final String exportedByVersion;
  final String exportedAt;

  /// Правила в порядке файла (ось `num` учтена при разборе).
  final List<CustomRule> rules;

  /// Подписки: url → метаданные, применяются поверх существующих списков.
  final List<Map<String, dynamic>> subscriptions;

  final Map<String, String> vars;
  final String? routeFinal;

  /// Блобы чужих приложений — хранить нетронутыми до следующего экспорта.
  final Map<String, dynamic> foreignExtensions;

  final List<LxBackupWarning> warnings;
}

/// Собирает LX Backup из настроек LxBox.
///
/// [foreignExtensions] — сохранённые блобы других приложений; возвращаются
/// в файл как есть.
Future<String> buildLxBackup({
  required List<ServerList> lists,
  required List<CustomRule> rules,
  required Map<String, String> vars,
  String? routeFinal,
  Map<String, dynamic> foreignExtensions = const {},
}) async {
  var appVersion = '';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // В тестовом окружении PackageInfo недоступен — версия не критична.
  }

  final subscriptions = <Map<String, dynamic>>[];
  final servers = <Map<String, dynamic>>[];
  for (final list in lists) {
    // ServerList — sealed: url и период обновления есть только у подписки,
    // папки и одиночные серверы устроены иначе.
    if (list is SubscriptionServers) {
      subscriptions.add(_subscriptionToJson(list));
    } else {
      servers.add(_serverListToJson(list));
    }
  }

  final portableVars = <String, String>{
    for (final e in vars.entries)
      if (kLxPortableVars.contains(e.key)) e.key: e.value,
  };

  final out = <String, dynamic>{
    'lx_backup': kLxBackupVersion,
    'exported_by': {
      'app': kLxAppLxBox,
      'version': appVersion,
      'platform': 'android',
    },
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    if (subscriptions.isNotEmpty) 'subscriptions': subscriptions,
    if (servers.isNotEmpty) 'servers': servers,
    if (rules.isNotEmpty) 'rules': [for (final r in rules) _ruleToJson(r)],
    if (portableVars.isNotEmpty) 'vars': portableVars,
    if (routeFinal != null && routeFinal.isNotEmpty)
      'route': {'final': routeFinal},
    if (foreignExtensions.isNotEmpty) 'extensions': foreignExtensions,
  };

  return const JsonEncoder.withIndent('  ').convert(out);
}

Map<String, dynamic> _subscriptionToJson(SubscriptionServers list) => {
      'url': list.url,
      'label': list.name,
      if (!list.enabled) 'enabled': false,
      if (list.tagPrefix.isNotEmpty) 'tag': {'prefix': list.tagPrefix},
      if (list.updateIntervalHours > 0)
        'update': {'interval_hours': list.updateIntervalHours},
      // Непереносимое (собственный id, тип списка) — в extensions: на
      // десктопе этих понятий нет, но вернуться они обязаны.
      'extensions': {
        kLxAppLxBox: {'id': list.id, 'type': list.type},
      },
    };

/// Папка или одиночный сервер: url у них нет, поэтому в схему они едут
/// секцией servers[]. Узлы не переносятся — они производные от подписки
/// либо принадлежат конкретной установке.
Map<String, dynamic> _serverListToJson(ServerList list) => {
      'label': list.name,
      if (!list.enabled) 'enabled': false,
      'extensions': {
        kLxAppLxBox: {'id': list.id, 'type': list.type},
      },
    };

/// Правило LxBox → запись схемы.
///
/// Матчеры, которых нет на десктопе (`packages`, `wifiSsids`, `wifiBssids`,
/// `inbounds`), уезжают в `extensions.lxbox`: применить их там нечем, а
/// терять при round-trip нельзя.
Map<String, dynamic> _ruleToJson(CustomRule rule) {
  final out = <String, dynamic>{
    'kind': rule.kind.name,
    'name': rule.name,
    if (!rule.enabled) 'enabled': false,
    if (rule.orderNum != null) 'num': rule.orderNum,
  };

  final raw = rule.toJson();

  if (rule is CustomRuleInline) {
    out['outbound'] = rule.outbound;
    final match = <String, dynamic>{
      if (rule.domains.isNotEmpty) 'domain': rule.domains,
      if (rule.domainSuffixes.isNotEmpty) 'domain_suffix': rule.domainSuffixes,
      if (rule.domainKeywords.isNotEmpty)
        'domain_keyword': rule.domainKeywords,
      if (rule.ipCidrs.isNotEmpty) 'ip_cidr': rule.ipCidrs,
      if (rule.ports.isNotEmpty) 'port': rule.ports,
      if (rule.portRanges.isNotEmpty) 'port_range': rule.portRanges,
      if (rule.protocols.isNotEmpty) 'protocol': rule.protocols,
      if (rule.network.isNotEmpty) 'network': rule.network,
    };
    if (match.isNotEmpty) out['match'] = match;

    final mobileOnly = <String, dynamic>{
      if (rule.packages.isNotEmpty) 'packages': rule.packages,
      if (rule.wifiSsids.isNotEmpty) 'wifiSsids': rule.wifiSsids,
      if (rule.wifiBssids.isNotEmpty) 'wifiBssids': rule.wifiBssids,
      if (rule.inbounds.isNotEmpty) 'inbounds': rule.inbounds,
      if (rule.ipIsPrivate) 'ipIsPrivate': true,
      if (rule.sourceIpCidrs.isNotEmpty) 'sourceIpCidrs': rule.sourceIpCidrs,
      if (rule.sourceIpIsPrivate) 'sourceIpIsPrivate': true,
    };
    if (mobileOnly.isNotEmpty) {
      out['extensions'] = {kLxAppLxBox: mobileOnly};
    }
  } else if (rule is CustomRuleSrs) {
    out['ref'] = (raw['url'] as String?) ?? (raw['srsUrl'] as String?) ?? '';
    out['outbound'] = (raw['outbound'] as String?) ?? '';
  } else if (rule is CustomRulePreset) {
    out['ref'] = (raw['presetId'] as String?) ?? (raw['ref'] as String?) ?? '';
    final vars = raw['vars'];
    if (vars is Map && vars.isNotEmpty) {
      out['vars'] = vars.map((k, v) => MapEntry('$k', '$v'));
    }
  } else if (rule is CustomRuleJson) {
    // Сырое правило: на десктопе применить нечем, но и терять нельзя.
    out['extensions'] = {
      kLxAppLxBox: {'json': rule.json},
    };
  }

  return out;
}

/// Разбирает LX Backup.
///
/// [knownOutbounds] — цели, на которые правилу разрешено ссылаться;
/// пустой набор означает «проверять нечем» — тогда ссылки не режутся.
LxBackupFile parseLxBackup(
  String raw, {
  Set<String> knownOutbounds = const {},
  Set<String> knownPresets = const {},
}) {
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Это не файл LX Backup');
  }
  final version = decoded['lx_backup'];
  if (version is! int) {
    throw const FormatException('Это не файл LX Backup: нет поля lx_backup');
  }
  if (version > kLxBackupVersion) {
    throw FormatException(
        'Формат бэкапа v$version новее поддерживаемого v$kLxBackupVersion — обновите приложение');
  }

  final warnings = <LxBackupWarning>[];

  // Default-deny: ключи вне схемы не применяются молча.
  const known = {
    'lx_backup', 'exported_by', 'exported_at', 'subscriptions', 'servers',
    'rules', 'dns', 'vars', 'route', 'warp', 'extensions',
  };
  for (final key in decoded.keys) {
    if (!known.contains(key)) {
      warnings.add(LxBackupWarning(kWarnUnknownField, key));
    }
  }

  final by = (decoded['exported_by'] as Map?)?.cast<String, dynamic>() ?? {};

  final rules = <CustomRule>[];
  for (final item in (decoded['rules'] as List? ?? const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final parsed = _ruleFromJson(j, knownOutbounds, knownPresets, warnings);
    if (parsed != null) rules.add(parsed);
  }
  // Ось порядка: относительный порядок сохраняется, номера — свои.
  rules.sort((a, b) => (a.orderNum ?? 0).compareTo(b.orderNum ?? 0));

  final vars = <String, String>{};
  final rawVars = (decoded['vars'] as Map?)?.cast<String, dynamic>() ?? {};
  for (final key in rawVars.keys.toList()..sort()) {
    if (!kLxPortableVars.contains(key)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key));
      continue;
    }
    vars[key] = '${rawVars[key]}';
  }

  String? routeFinal;
  final route = (decoded['route'] as Map?)?.cast<String, dynamic>();
  final finalTag = route?['final'] as String?;
  if (finalTag != null && finalTag.isNotEmpty) {
    if (knownOutbounds.isEmpty || _isKnownOutbound(finalTag, knownOutbounds)) {
      routeFinal = finalTag;
    } else {
      warnings.add(LxBackupWarning(kWarnFinalDropped, finalTag));
    }
  }

  final foreign = <String, dynamic>{};
  final ext = (decoded['extensions'] as Map?)?.cast<String, dynamic>() ?? {};
  for (final entry in ext.entries) {
    if (entry.key == kLxAppLxBox) continue; // своё применяется полями выше
    foreign[entry.key] = entry.value;
  }

  return LxBackupFile(
    version: version,
    exportedByApp: (by['app'] as String?) ?? '',
    exportedByVersion: (by['version'] as String?) ?? '',
    exportedAt: (decoded['exported_at'] as String?) ?? '',
    rules: rules,
    subscriptions: [
      for (final s in (decoded['subscriptions'] as List? ?? const []))
        if (s is Map) s.cast<String, dynamic>(),
    ],
    vars: vars,
    routeFinal: routeFinal,
    foreignExtensions: foreign,
    warnings: warnings,
  );
}

bool _isKnownOutbound(String tag, Set<String> known) {
  final t = tag.trim().toLowerCase();
  return _reservedOutbounds.contains(t) ||
      known.map((e) => e.trim().toLowerCase()).contains(t);
}

/// Запись схемы → правило LxBox.
///
/// Ссылка в никуда не повод терять правило: оно приезжает ВЫКЛЮЧЕННЫМ.
/// Включённое правило с несуществующей целью роняет конфиг ядра целиком.
CustomRule? _ruleFromJson(
  Map<String, dynamic> j,
  Set<String> knownOutbounds,
  Set<String> knownPresets,
  List<LxBackupWarning> warnings,
) {
  final kindName = (j['kind'] as String?) ?? '';
  final name = (j['name'] as String?) ?? '';
  var enabled = (j['enabled'] as bool?) ?? true;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;
  final outbound = (j['outbound'] as String?) ?? '';

  if (outbound.isNotEmpty &&
      knownOutbounds.isNotEmpty &&
      !_isKnownOutbound(outbound, knownOutbounds)) {
    enabled = false;
    warnings.add(LxBackupWarning(
        kWarnUnknownOutbound, '${name.isEmpty ? kindName : name} → $outbound'));
  }

  final ext = ((j['extensions'] as Map?)?[kLxAppLxBox] as Map?)
          ?.cast<String, dynamic>() ??
      const {};

  switch (kindName) {
    case 'inline':
      final match =
          (j['match'] as Map?)?.cast<String, dynamic>() ?? const {};
      return CustomRuleInline(
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        domains: _strList(match['domain']),
        domainSuffixes: _strList(match['domain_suffix']),
        domainKeywords: _strList(match['domain_keyword']),
        ipCidrs: _strList(match['ip_cidr']),
        ports: _strList(match['port']),
        portRanges: _strList(match['port_range']),
        protocols: _strList(match['protocol']),
        network: _strList(match['network']),
        // Mobile-only матчеры возвращаются из extensions — иначе round-trink
        // через десктоп терял бы их безвозвратно.
        packages: _strList(ext['packages']),
        wifiSsids: _strList(ext['wifiSsids']),
        wifiBssids: _strList(ext['wifiBssids']),
        inbounds: _strList(ext['inbounds']),
        ipIsPrivate: ext['ipIsPrivate'] == true,
        sourceIpCidrs: _strList(ext['sourceIpCidrs']),
        sourceIpIsPrivate: ext['sourceIpIsPrivate'] == true,
        outbound: outbound.isEmpty ? kDirectOutboundTag : outbound,
      );

    case 'preset':
      final ref = (j['ref'] as String?) ?? '';
      if (knownPresets.isNotEmpty && !knownPresets.contains(ref)) {
        enabled = false;
        warnings.add(LxBackupWarning(kWarnUnknownPreset, ref));
      }
      return CustomRulePreset.fromJson({
        'name': name,
        'enabled': enabled,
        'num': ?orderNum,
        'presetId': ref,
        'vars': (j['vars'] as Map?)?.cast<String, dynamic>() ?? const {},
      });

    case 'srs':
      return CustomRuleSrs.fromJson({
        'name': name,
        'enabled': enabled,
        'num': ?orderNum,
        'url': j['ref'] ?? '',
        'outbound': outbound,
      });

    case 'json':
      final body = ext['json'];
      if (body is String && body.isNotEmpty) {
        return CustomRuleJson.fromJson({
          'name': name,
          'enabled': enabled,
          'num': ?orderNum,
          'json': body,
        });
      }
      warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[].kind=json: $name'));
      return null;

    default:
      warnings.add(LxBackupWarning(kWarnUnknownField, 'rules[].kind=$kindName'));
      return null;
  }
}

List<String> _strList(Object? v) {
  if (v is List) return [for (final e in v) '$e'];
  return const [];
}
