import '../../widgets/wifi_entry.dart';

/// §051 Phase 2 — chip list → (wifiSsids, wifiBssids) для модели.
///
/// Sing-box treats lists independently and AND-ит их (cross-product).
/// Для chips с pure-ssid ничего в bssids не добавляем (sing-box матчит
/// только SSID). Для chips с обоими полями — пишем оба.
///
/// ⚠ **Cross-product trap (low-impact, documented risk)**: при 2+ chips
/// с разными `(ssid, bssid)` парами, sing-box rule `wifi_ssid:[A,B] AND
/// wifi_bssid:[X,Y]` теоретически matches «A на BSSID Y» (не задумано).
/// На практике риск мал — BSSID = globally unique MAC, коллизии
/// "правильный SSID + чужой BSSID" нереалистичны. Для exact pair semantic
/// builder должен бы эмитить N отдельных rules — deferred до реального
/// use-case. См. §051 spec «Known risks».
({List<String> ssids, List<String> bssids}) zipWifiEntries(
    List<WifiEntry> entries) {
  final ssids = <String>[];
  final bssids = <String>[];
  for (final e in entries) {
    if (e.ssid.isNotEmpty && !ssids.contains(e.ssid)) ssids.add(e.ssid);
    if (e.bssid.isNotEmpty && !bssids.contains(e.bssid)) bssids.add(e.bssid);
  }
  return (ssids: ssids, bssids: bssids);
}

/// §051 Phase 2 — (wifiSsids, wifiBssids) → chip list для loading.
///
/// Best-effort pairing: если списки одинаковой длины — pair by index.
/// Иначе создаём ssid-only chips для всех ssids (rare edge — load legacy
/// data или manual JSON edit с несовпадающими длинами; BSSID без ssid
/// остаются в JSON но не в UI).
List<WifiEntry> unzipWifiEntries(
    List<String> ssids, List<String> bssids) {
  if (ssids.isEmpty && bssids.isEmpty) return [];
  if (ssids.length == bssids.length) {
    return [
      for (var i = 0; i < ssids.length; i++) WifiEntry(ssids[i], bssids[i]),
    ];
  }
  return [for (final s in ssids) WifiEntry(s, '')];
}
