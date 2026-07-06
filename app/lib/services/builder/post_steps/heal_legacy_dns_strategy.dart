part of '../post_steps.dart';

/// Post-step: §246 hotfix — деградация несовместимой пары в `dns.rules`.
///
/// ПРОБЛЕМА (ядро sing-box 1.14, миграция «ip_version and query_type behavior
/// changes»): легаси-опция `strategy` в DNS rule action НЕСОВМЕСТИМА с
/// `query_type` / `ip_version` в любом другом DNS-правиле того же конфига.
/// Ядро включает не-легаси DNS-режим (`resolveLegacyDNSMode: disabled`) при
/// наличии query_type/ip_version, и тогда легаси `strategy` → FATAL на старте
/// («Legacy `strategy` DNS rule action option is deprecated…»), VPN не
/// стартует. В одиночку `strategy` лишь ворчит warning'ом — потому баг не
/// виден без несовместимых правил: `query_type: [A, AAAA]` эмитит FakeIP
/// (§228), `ip_version: 6` — ru-direct Force IPv4 (§253, дефолт ON).
///
/// Известное сужение: ядро отключает легаси-режим и по другим триггерам
/// (match_response, response_rcode/answer/ns/extra, action evaluate/respond —
/// dns/router.go resolveLegacyDNSMode), которые сюда не входят: наш шаблон их
/// не эмитит, а ловить все юзерские формы — отдельная задача.
///
/// Наш шаблон `strategy` в dns.rules больше не эмитит (убрано из ru-direct),
/// но оно может прийти из подписки / raw-JSON DNS-правил. Защита как §121:
/// если конфиг содержит query_type/ip_version — снимаем `strategy` со ВСЕХ
/// dns.rules (деградация: домен резолвится по глобальной `dns.strategy`
/// вместо per-rule), VPN стартует. Зовётся ПЕРЕД `validateConfig`.
///
/// Возвращает индексы правил, у которых снят `strategy`. Пустой = чисто
/// (либо strategy нет, либо нет несовместимого query_type/ip_version).
List<int> healLegacyDnsStrategy(Map<String, dynamic> config) {
  final dns = config['dns'];
  if (dns is! Map<String, dynamic>) return const [];
  final rules = dns['rules'];
  if (rules is! List) return const [];

  final hasIncompatible = rules.any((r) =>
      r is Map<String, dynamic> &&
      (r.containsKey('query_type') || r.containsKey('ip_version')));
  if (!hasIncompatible) return const [];

  final healed = <int>[];
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    if (r is Map<String, dynamic> && r.containsKey('strategy')) {
      r.remove('strategy');
      healed.add(i);
    }
  }
  return healed;
}
