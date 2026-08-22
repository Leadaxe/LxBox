part of '../post_steps.dart';

/// Post-step: §103 C7 — миграция ссылок на теги пресетов после введения
/// неймспейса `<preset_id>:<tag>`.
///
/// ПРОБЛЕМА: теги DNS-серверов и rule-set'ов, объявленных внутри пресета,
/// теперь префиксуются. Состояние пользователя, записанное ДО этого, хранит
/// локальный тег (`yandex_doh`, `ru-domains`) — например, в
/// `RuleDns.serverTag` (выбор сервера для правила) или в raw-JSON правиле.
/// После обновления такая ссылка указывает в никуда.
///
/// Ядро не валидирует это на старте: `sing-box check` конфиг пропускает, а
/// падает лениво — `DNS server not found: <tag>` на каждом сматчившемся
/// соединении. Пользователь увидит не «обновление сломало настройку», а
/// «интернет не работает на части сайтов».
///
/// РЕШЕНИЕ: переписать ссылку на новый тег, если старый локальный
/// однозначно принадлежит ровно одному пресету. Неоднозначность (два
/// пресета объявили одинаковый локальный тег) не чиним: угадывать, какой из
/// них имел в виду пользователь, — значит молча выбрать не тот. Такая ссылка
/// уедет в штатную деградацию [healDanglingResolveServers].
///
/// Зовётся ПЕРЕД деградацией — иначе та снимет ссылку раньше, чем мы успеем
/// её починить, и настройка потеряется вместо переезда.
///
/// Возвращает список переписанных ссылок (`старый → новый`) для emitWarnings.
List<({String from, String to})> healPresetTagPrefix(
    Map<String, dynamic> config) {
  final healed = <({String from, String to})>[];

  final dns = config['dns'];
  final dnsServers = (dns is Map<String, dynamic>)
      ? (dns['servers'] as List<dynamic>? ?? const [])
      : const [];

  // Карта «локальный тег → префиксованный». Тег, встреченный дважды,
  // помечается неоднозначным и не чинится.
  final byLocal = <String, String?>{};
  void index(Iterable<dynamic> items) {
    for (final it in items) {
      if (it is! Map<String, dynamic>) continue;
      final tag = it['tag'];
      if (tag is! String) continue;
      final sep = tag.indexOf(':');
      if (sep <= 0) continue; // тег без префикса — чинить нечего
      final local = tag.substring(sep + 1);
      if (local.isEmpty) continue;
      byLocal[local] = byLocal.containsKey(local) ? null : tag;
    }
  }

  index(dnsServers);
  final route = config['route'];
  if (route is Map<String, dynamic>) {
    index(route['rule_set'] as List<dynamic>? ?? const []);
  }
  if (byLocal.isEmpty) return healed;

  /// Уже существующие теги: ссылка на живой тег не трогается, даже если
  /// совпала с чьим-то локальным именем.
  final existing = <String>{
    for (final s in dnsServers)
      if (s is Map<String, dynamic> && s['tag'] is String) s['tag'] as String,
    if (route is Map<String, dynamic>)
      for (final rs in (route['rule_set'] as List<dynamic>? ?? const []))
        if (rs is Map<String, dynamic> && rs['tag'] is String)
          rs['tag'] as String,
  };

  Object? healRef(Object? value) {
    if (value is String) {
      if (existing.contains(value)) return value;
      final target = byLocal[value];
      if (target == null) return value; // нет замены или неоднозначно
      healed.add((from: value, to: target));
      return target;
    }
    if (value is List) {
      return [for (final v in value) healRef(v)];
    }
    return value;
  }

  // DNS-правила: server + rule_set.
  if (dns is Map<String, dynamic>) {
    for (final r in (dns['rules'] as List<dynamic>? ?? const [])) {
      if (r is! Map<String, dynamic>) continue;
      if (r['server'] != null) r['server'] = healRef(r['server']);
      if (r['rule_set'] != null) r['rule_set'] = healRef(r['rule_set']);
    }
    if (dns['final'] != null) dns['final'] = healRef(dns['final']);
  }

  // Route-правила: rule_set + server (у action: resolve).
  if (route is Map<String, dynamic>) {
    for (final r in (route['rules'] as List<dynamic>? ?? const [])) {
      if (r is! Map<String, dynamic>) continue;
      if (r['rule_set'] != null) r['rule_set'] = healRef(r['rule_set']);
      if (r['server'] != null) r['server'] = healRef(r['server']);
    }
  }

  return healed;
}
