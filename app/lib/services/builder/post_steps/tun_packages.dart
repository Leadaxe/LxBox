part of '../post_steps.dart';

/// Post-step: §046 — настройки Tunnel apps из `tun_apps` storage.
/// Подставляет `include_package` / `exclude_package` в первый `inbound[type=tun]`
/// либо оставляет приложения внутри VPN и добавляет прямой маршрут.
///
/// Mode → sing-box config:
/// - `off`    → ничего не пишем (sing-box default = все apps через tun)
/// - `allow`  → `tun.include_package = packages` (только эти через tun)
/// - `deny`   → `tun.exclude_package = packages` (все КРОМЕ этих)
/// - `direct` → удаляем include/exclude; все apps остаются в tun, выбранные
///   пакеты идут через `package_name` → `direct-out`. Android lockdown
///   сохраняется; DNS следует существующим настройкам, включая FakeIP.
///
/// libbox читает include/exclude из config и передаёт в native слой
/// (`BoxVpnService.openTun` → `addAllowedApplication`/`addDisallowedApplication`).
/// Применяется на `builder.establish()` — нужен FULL VPN restart,
/// light reload не работает.
///
/// Если `packages` пустой, allow/deny — silently no-op; direct удаляет
/// OS-фильтры, но не добавляет маршруты (иначе все apps ушли бы напрямую).
/// Если в config нет tun-inbound (Proxy mode) — silently no-op.
///
/// Важно: если Android не определил владельца соединения (например, при
/// `curl --interface tun1`), package_name не совпадёт и сработают обычные
/// правила. Для блокировки такого трафика нужен отдельный Unknown traffic
/// с Reject перед маршрутами через прокси; этот режим его не включает.
void applyTunPackages(Map<String, dynamic> config, TunAppsConfig tunApps) {
  if (tunApps.isOff || !TunAppsConfig.isValidMode(tunApps.mode)) return;
  if (tunApps.packages.isEmpty && !tunApps.isDirect) return;

  final inbounds = config['inbounds'];
  if (inbounds is! List) return;

  Map<String, dynamic>? tun;
  for (final i in inbounds) {
    if (i is Map<String, dynamic> && i['type'] == 'tun') {
      tun = i;
      break;
    }
  }
  if (tun == null) return;

  if (tunApps.isDirect) {
    // Оставляем приложения внутри VpnService: lockdown блокирует исключённые.
    // Удаляем OS-фильтры, в том числе заданные пользовательским шаблоном.
    tun.remove('include_package');
    tun.remove('exclude_package');
    if (tunApps.packages.isEmpty) return;

    // Ограничиваем правило этим tun, чтобы в VPN+Proxy не затронуть mixed-in.
    // Встроенный шаблон уже задаёт tag; для пользовательского tun без тега
    // назначаем свободный, без конфликта с остальными inbounds.
    if (tun['tag'] is! String || (tun['tag'] as String).isEmpty) {
      final usedTags = inbounds.whereType<Map>().map((i) => i['tag']).toSet();
      var tag = 'tun-apps-in';
      while (usedTags.contains(tag)) {
        tag = '$tag-1';
      }
      tun['tag'] = tag;
    }

    final route =
        config.putIfAbsent('route', () => <String, dynamic>{})
            as Map<String, dynamic>;
    // Включаем поиск UID/пакета и native autoDetectInterfaceControl → protect.
    route['find_process'] = true;
    route['auto_detect_interface'] = true;
    final rules = List<dynamic>.from(route['rules'] as List? ?? const []);
    // Сохраняем начальную обработку пакетов, особенно hijack-dns: прямой выход
    // на виртуальный DNS-адрес tun закончился бы таймаутом. DNS, включая
    // FakeIP, продолжает использовать существующую конфигурацию DNS.
    final index = rules.indexWhere(
      (r) =>
          r is! Map ||
          !const {
            'sniff',
            'hijack-dns',
            'resolve',
            'route-options',
          }.contains(r['action']),
    );
    rules.insert(index < 0 ? rules.length : index, <String, dynamic>{
      'inbound': [tun['tag']],
      'package_name': List<String>.from(tunApps.packages),
      'action': 'route',
      'outbound': kDirectOutboundTag,
    });
    route['rules'] = rules;
    return;
  }

  final field = tunApps.isAllow ? 'include_package' : 'exclude_package';
  tun[field] = List<String>.from(tunApps.packages);
}
