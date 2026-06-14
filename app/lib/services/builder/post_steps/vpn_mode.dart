part of '../post_steps.dart';

/// §119 — VPN-mode transform. Меняет `config.inbounds` (и привязанные
/// route.rules) под выбранный режим:
///   • vpn       — no-op (tun-inbound остаётся, mixed нет).
///   • proxy     — удалить tun-inbound; добавить mixed-inbound; tun-привязанные
///                 resolve/sniff правила re-tag'нуть на mixed-in.
///   • vpn_proxy — оставить tun; добавить mixed-inbound + отдельные
///                 resolve/sniff для mixed-in.
///
/// Пароль/username берутся прямо из [cfg] — НЕ через `@var`-substitution
/// (type-coercion испортил бы числовой/«true»-пароль; `users` — массив объектов).
///
/// [sniffEnabled] — глобальный sniff-флаг (`vars['sniff_enabled'] != 'false'`).
/// В vpn_proxy mixed-sniff добавляется только если sniff включён глобально
/// (для proxy tun-in sniff уже удалён до этого шага, re-tag его не встретит).
void applyVpnMode(
  Map<String, dynamic> config,
  VpnModeConfig cfg, {
  required bool sniffEnabled,
}) {
  if (cfg.isVpn) return; // tun остаётся, mixed нет, rules как есть

  final inbounds = config['inbounds'];
  if (inbounds is! List) return;
  final route = config['route'];
  final rules = (route is Map<String, dynamic>) ? route['rules'] : null;

  // proxy: удалить tun + переназначить tun-in rules → mixed-in.
  if (cfg.isProxy) {
    inbounds.removeWhere((i) => i is Map && i['type'] == 'tun');
    if (rules is List) {
      for (final r in rules) {
        if (r is Map && r['inbound'] == 'tun-in') r['inbound'] = 'mixed-in';
      }
      // hijack-dns (protocol:dns, без inbound) оставляем — работает для всех.
    }
  }

  // Локальный inbound (proxy + vpn_proxy). type = выбранный протокол
  // (mixed/http/socks); tag всегда "mixed-in" (внутренний идентификатор, на
  // него завязаны route.rules re-tag — от протокола не зависит). У всех трёх
  // типов одинаковая auth-структура `users:[{username,password}]`.
  final mixed = <String, dynamic>{
    'type': cfg.proxyProtocol,
    'tag': 'mixed-in',
    'listen': cfg.proxyListen,
    'listen_port': cfg.proxyPort,
  };
  if (cfg.effectiveAuth && cfg.proxyPassword.isNotEmpty) {
    mixed['users'] = <Map<String, dynamic>>[
      {'username': cfg.proxyUsername, 'password': cfg.proxyPassword},
    ];
  }
  inbounds.add(mixed);

  // vpn_proxy: tun-in rules не трогаем; добавляем resolve (+sniff) для mixed-in.
  if (cfg.isVpnProxy && rules is List) {
    rules.insert(0, <String, dynamic>{
      'action': 'resolve',
      'inbound': 'mixed-in',
    });
    if (sniffEnabled) {
      rules.insert(1, <String, dynamic>{
        'action': 'sniff',
        'inbound': 'mixed-in',
        'timeout': '1s',
      });
    }
  }
}
