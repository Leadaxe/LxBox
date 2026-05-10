/// §053 Stage 1 — public Wi-Fi network entry для editor chips.
///
/// До extract'а это был private `_WifiEntry` в `custom_rule_edit_screen.dart`.
/// Стал public чтобы `WifiSavedPickerSheet` и `wifiManualAddDialog` могли
/// принимать/возвращать его через API, не дублируя класс.
///
/// `bssid` пустой если юзер не указал — sing-box матчит только по SSID
/// (любой BSSID с этим именем).
class WifiEntry {
  const WifiEntry(this.ssid, this.bssid);
  final String ssid;
  final String bssid;

  @override
  bool operator ==(Object other) =>
      other is WifiEntry && other.ssid == ssid && other.bssid == bssid;

  @override
  int get hashCode => Object.hash(ssid, bssid);

  @override
  String toString() =>
      bssid.isEmpty ? 'WifiEntry($ssid)' : 'WifiEntry($ssid · $bssid)';
}
