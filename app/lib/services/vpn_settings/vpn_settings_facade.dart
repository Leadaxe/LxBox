// ===========================================================================
// §293 — фасад vpn-mode: единственная точка применения VpnModeConfig,
// несущая доменные инварианты, которые обязаны разделять ВСЕ входы (UI +
// Debug API). Раньше три инварианта жили только в vpn_mode_tab, а Debug
// `_putVpnMode` их пропускал → `PUT mode=proxy` оставлял native `has_tun`
// устаревшим (VpnService.prepare() продолжал срабатывать до bootstrap).
//
// Per-call stateless (как ProbeController §296): без мутабельного состояния,
// чистая делегация в SettingsStorage + generateProxyPassword.
//
// Scope RUTHLESS (§293): это ЕДИНСТВЕННЫЙ метод с реальной политикой. Прочие
// vpn-настройки (tun_apps/native_prefs/idle_suspend/app_settings grab-bag) —
// тривиальные get/set или уже свой фасад (native_prefs §189), сюда НЕ входят.
// ===========================================================================

import '../settings_storage.dart';
import '../subscription/subscription_identity.dart' show generateProxyPassword;

class VpnSettingsFacade {
  const VpnSettingsFacade._();

  /// Применяет [requested] с тремя инвариантами и персистит:
  ///   (a) auth-on + пустой пароль (при наличии mixed-inbound) →
  ///       `generateProxyPassword()`;
  ///   (b) `effectiveAuth` уже учитывает non-loopback listen (форсит auth on) —
  ///       через getter модели, потому проверяем именно его;
  ///   (c) смена `hasTun` → зеркалим `setNativeHasTun` (§192: гейтит
  ///       `VpnService.prepare()`; proxy-режим не должен звать prepare).
  /// Возвращает разрешённый конфиг, чтобы вызывающий обновил свои контроллеры.
  static Future<VpnModeConfig> applyVpnMode(VpnModeConfig requested) async {
    var next = requested;
    if (next.hasMixed && next.effectiveAuth && next.proxyPassword.isEmpty) {
      next = next.copyWith(proxyPassword: generateProxyPassword());
    }
    final cur = await SettingsStorage.getVpnMode();
    await SettingsStorage.setVpnMode(next);
    if (next.hasTun != cur.hasTun) {
      await SettingsStorage.setNativeHasTun(next.hasTun);
    }
    return next;
  }

  /// Passthrough-чтение (симметрия с [applyVpnMode]).
  static Future<VpnModeConfig> loadVpnMode() => SettingsStorage.getVpnMode();
}
