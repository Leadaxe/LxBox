part of '../settings_storage.dart';

// Vars-домен + Wi-Fi history (§051) для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Семантика storage-ключей идентична исходнику.

Future<String> _getVar(String name, String defaultValue) async {
  final data = await _load();
  final vars = data['vars'] as Map<String, dynamic>? ?? {};
  return vars[name]?.toString() ?? defaultValue;
}

Future<void> _setVar(String name, String value) async {
  final data = await _load();
  final vars = (data['vars'] as Map<String, dynamic>?) ?? {};
  vars[name] = value;
  data['vars'] = vars;
  SettingsStorage._cache = data;
  await _save();
}

Future<Map<String, String>> _getAllVars() async {
  final data = await _load();
  final vars = data['vars'] as Map<String, dynamic>? ?? {};
  return vars.map((k, v) => MapEntry(k, v.toString()));
}

Future<void> _removeVar(String name) async {
  final data = await _load();
  final vars = data['vars'] as Map<String, dynamic>?;
  if (vars == null || !vars.containsKey(name)) return;
  vars.remove(name);
  data['vars'] = vars;
  SettingsStorage._cache = data;
  await _save();
}

Future<List<Map<String, String>>> _getWifiHistory() async {
  final raw = await SettingsStorage.getVar('wifi_history', '[]');
  final decoded = (jsonDecode(raw) as List?) ?? const [];
  // Growable — caller'ы (Pick saved bottom sheet) делают `removeWhere`
  // для optimistic UI update. `growable: false` ломал это с silent
  // UnsupportedError в setState callback.
  return decoded
      .whereType<Map>()
      .map<Map<String, String>>((e) => {
            'ssid': (e['ssid'] as String?) ?? '',
            'bssid': (e['bssid'] as String?) ?? '',
            'last_seen': (e['last_seen'] as String?) ?? '',
          })
      .where((e) => (e['ssid'] ?? '').isNotEmpty)
      .toList();
}

Future<void> _addToWifiHistory(String ssid, String bssid) async {
  if (ssid.isEmpty) return;
  final normalized = bssid.trim().toLowerCase();
  final history = (await SettingsStorage.getWifiHistory()).toList();
  final now = DateTime.now().toUtc().toIso8601String();
  history.removeWhere((e) =>
      (e['ssid'] ?? '') == ssid && (e['bssid'] ?? '') == normalized);
  history.insert(0, {
    'ssid': ssid,
    'bssid': normalized,
    'last_seen': now,
  });
  if (history.length > SettingsStorage._wifiHistoryCap) {
    history.removeRange(SettingsStorage._wifiHistoryCap, history.length);
  }
  await SettingsStorage.setVar('wifi_history', jsonEncode(history));
}

Future<void> _removeFromWifiHistory(String ssid, String bssid) async {
  final normalized = bssid.trim().toLowerCase();
  final history = (await SettingsStorage.getWifiHistory()).toList();
  final initial = history.length;
  history.removeWhere((e) =>
      (e['ssid'] ?? '') == ssid && (e['bssid'] ?? '') == normalized);
  if (history.length != initial) {
    await SettingsStorage.setVar('wifi_history', jsonEncode(history));
  }
}
