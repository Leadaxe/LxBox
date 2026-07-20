part of '../settings_storage.dart';

// VPN mode (§119) — выбор как ядро ловит трафик (inbound-трактовка):
//   • vpn       — только tun-inbound (текущее поведение, default).
//   • proxy     — только локальный mixed-inbound, без tun (нет establish).
//   • vpn_proxy — tun + mixed одновременно.
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Storage key: `vpn_mode`.
//
// Билдер (`applyVpnMode`) трансформирует config.inbounds императивно из этой
// модели — пароль/username НЕ идут через `@var`-substitution (type-coercion
// `_resolveVar` испортил бы числовой/«true»-пароль; `users` — массив объектов).

Future<VpnModeConfig> _getVpnMode() async {
  final data = await _load();
  final raw = data['vpn_mode'];
  if (raw is Map<String, dynamic>) {
    final mode = raw['mode'];
    if (mode == SettingsStorage._vpnModeVpn ||
        mode == SettingsStorage._vpnModeProxy ||
        mode == SettingsStorage._vpnModeVpnProxy) {
      final port = raw['proxy_port'];
      final listen = raw['proxy_listen'];
      final proto = raw['proxy_protocol'];
      return VpnModeConfig(
        mode: mode as String,
        proxyProtocol: const {
          VpnModeConfig.protoMixed,
          VpnModeConfig.protoHttp,
          VpnModeConfig.protoSocks,
        }.contains(proto)
            ? proto as String
            : VpnModeConfig.protoMixed,
        proxyPort: (port is int) ? port : VpnModeConfig.defaultPort,
        // Любой валидный IPv4 (UI валидирует ввод). Невалид/пусто → loopback.
        proxyListen: (listen is String && VpnModeConfig.isValidListenAddr(listen))
            ? listen
            : VpnModeConfig.listenLocal,
        proxyAuthEnabled: raw['proxy_auth_enabled'] != false,
        proxyUsername:
            (raw['proxy_username'] as String?) ?? VpnModeConfig.defaultUsername,
        proxyPassword: (raw['proxy_password'] as String?) ?? '',
      );
    }
  }
  // Backward-compat: ключ отсутствует / битый → дефолт = текущее поведение.
  return const VpnModeConfig.defaults();
}

Future<void> _setVpnMode(VpnModeConfig cfg, {bool flush = true}) async {
  if (![
    SettingsStorage._vpnModeVpn,
    SettingsStorage._vpnModeProxy,
    SettingsStorage._vpnModeVpnProxy,
  ].contains(cfg.mode)) {
    throw ArgumentError('vpn_mode.mode must be vpn|proxy|vpn_proxy: ${cfg.mode}');
  }
  final data = await _load();
  data['vpn_mode'] = cfg.toJson();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant.
  if (flush) await _save();
}

/// Typed wrapper over `vpn_mode` storage shape (§119).
class VpnModeConfig {
  const VpnModeConfig({
    required this.mode,
    required this.proxyProtocol,
    required this.proxyPort,
    required this.proxyListen,
    required this.proxyAuthEnabled,
    required this.proxyUsername,
    required this.proxyPassword,
  });

  /// Default = текущее поведение (mode=vpn). Для existing юзеров без ключа.
  const VpnModeConfig.defaults()
      : mode = 'vpn',
        proxyProtocol = protoMixed,
        proxyPort = defaultPort,
        proxyListen = listenLocal,
        proxyAuthEnabled = true,
        proxyUsername = defaultUsername,
        proxyPassword = '';

  static const int defaultPort = 2080;
  static const String listenLocal = '127.0.0.1';
  static const String listenPublic = '0.0.0.0';
  static const String defaultUsername = 'user';

  /// Валиден ли адрес для `listen` (IPv4: 4 октета 0..255). UI/storage
  /// отвергают всё остальное — sing-box иначе упадёт на reload.
  static bool isValidListenAddr(String addr) {
    final parts = addr.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// Loopback (127.x.x.x) — виден только на самом устройстве, auth не форсится.
  static bool isLoopback(String addr) => addr.startsWith('127.');

  /// §292 — валиден ли порт локального inbound: 1024..65535. Привилегированные
  /// (<1024) не нужны и требуют root; 0/negative/>65535 роняют sing-box на
  /// reload. Граница совпадает с UI (`vpn_mode_tab._applyPort`) — инвариант
  /// живёт здесь, оба входа (UI + Debug API) его переиспользуют, не дублируют.
  static bool isValidPort(int port) => port >= 1024 && port <= 65535;

  /// §292 — валиден ли inbound-protocol (= sing-box inbound `type`).
  static bool isValidProtocol(String proto) =>
      proto == protoMixed || proto == protoHttp || proto == protoSocks;

  /// Тип локального inbound (= sing-box inbound `type`). У всех трёх одинаковая
  /// auth-структура `users:[{username,password}]`; http не поддерживает UDP.
  static const String protoMixed = 'mixed'; // HTTP + SOCKS5 на одном порту
  static const String protoHttp = 'http'; // только HTTP
  static const String protoSocks = 'socks'; // только SOCKS5

  /// `"vpn"` | `"proxy"` | `"vpn_proxy"`.
  final String mode;

  /// `"mixed"` | `"http"` | `"socks"` — sing-box inbound type.
  final String proxyProtocol;
  final int proxyPort;

  /// IPv4 listen-адрес. `127.x` — только это устройство; всё прочее
  /// (`0.0.0.0`, конкретный LAN-IP) — потенциально видно извне.
  final String proxyListen;
  final bool proxyAuthEnabled;
  final String proxyUsername;
  final String proxyPassword;

  bool get isVpn => mode == 'vpn';
  bool get isProxy => mode == 'proxy';
  bool get isVpnProxy => mode == 'vpn_proxy';

  /// vpn + vpn_proxy → tun-inbound присутствует.
  bool get hasTun => mode != 'proxy';

  /// proxy + vpn_proxy → mixed-inbound присутствует.
  bool get hasMixed => mode != 'vpn';

  /// Потенциально доступен извне устройства — всё, что НЕ loopback (127.x).
  /// `0.0.0.0` и любой конкретный LAN-IP → требует auth безусловно.
  bool get isPublicListen => !isLoopback(proxyListen);

  /// Эффективная авторизация: не-loopback listen форсит auth on (снять нельзя).
  bool get effectiveAuth => isPublicListen ? true : proxyAuthEnabled;

  VpnModeConfig copyWith({
    String? mode,
    String? proxyProtocol,
    int? proxyPort,
    String? proxyListen,
    bool? proxyAuthEnabled,
    String? proxyUsername,
    String? proxyPassword,
  }) =>
      VpnModeConfig(
        mode: mode ?? this.mode,
        proxyProtocol: proxyProtocol ?? this.proxyProtocol,
        proxyPort: proxyPort ?? this.proxyPort,
        proxyListen: proxyListen ?? this.proxyListen,
        proxyAuthEnabled: proxyAuthEnabled ?? this.proxyAuthEnabled,
        proxyUsername: proxyUsername ?? this.proxyUsername,
        proxyPassword: proxyPassword ?? this.proxyPassword,
      );

  Map<String, Object?> toJson() => {
        'mode': mode,
        'proxy_protocol': proxyProtocol,
        'proxy_port': proxyPort,
        'proxy_listen': proxyListen,
        'proxy_auth_enabled': proxyAuthEnabled,
        'proxy_username': proxyUsername,
        'proxy_password': proxyPassword,
      };
}
