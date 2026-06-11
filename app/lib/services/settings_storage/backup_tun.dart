part of '../settings_storage.dart';

// Backup snapshot (§031) + tun-apps split-tunneling (§046) для
// [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Семантика storage-ключей идентична исходнику.

Future<Map<String, dynamic>> _dumpCache() async {
  final data = await _load();
  return jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}

Future<void> _replaceRaw(
  Map<String, dynamic> snapshot, {
  bool merge = false,
}) async {
  final clean = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
  if (!merge) {
    SettingsStorage._cache = clean;
    await _save();
    return;
  }
  final current = await _load();
  for (final entry in clean.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key == 'vars' && value is Map<String, dynamic>) {
      final existing = (current['vars'] as Map<String, dynamic>?) ?? {};
      for (final v in value.entries) {
        existing[v.key] = v.value;
      }
      current['vars'] = existing;
    } else {
      current[key] = value;
    }
  }
  SettingsStorage._cache = current;
  await _save();
}

Future<TunAppsConfig> _getTunApps() async {
  final data = await _load();
  final raw = data['tun_apps'];
  if (raw is Map<String, dynamic>) {
    final mode = raw['mode'];
    final packages = (raw['packages'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        const <String>[];
    if (mode == SettingsStorage._tunAppsModeAllow ||
        mode == SettingsStorage._tunAppsModeDeny ||
        mode == SettingsStorage._tunAppsModeOff) {
      return TunAppsConfig(mode: mode as String, packages: packages);
    }
  }
  return const TunAppsConfig(
    mode: SettingsStorage._tunAppsModeOff,
    packages: <String>[],
  );
}

Future<void> _setTunApps(TunAppsConfig cfg, {bool flush = true}) async {
  if (![
    SettingsStorage._tunAppsModeOff,
    SettingsStorage._tunAppsModeAllow,
    SettingsStorage._tunAppsModeDeny,
  ].contains(cfg.mode)) {
    throw ArgumentError('tun_apps.mode must be off|allow|deny: ${cfg.mode}');
  }
  final dedup = <String>{};
  for (final p in cfg.packages) {
    final t = p.trim();
    if (t.isEmpty) continue;
    dedup.add(t);
  }
  final data = await _load();
  data['tun_apps'] = {
    'mode': cfg.mode,
    'packages': dedup.toList()..sort(),
  };
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

/// Typed wrapper over `tun_apps` storage shape (§046).
class TunAppsConfig {
  const TunAppsConfig({required this.mode, required this.packages});

  /// `"off"` | `"allow"` | `"deny"`.
  final String mode;
  final List<String> packages;

  bool get isOff => mode == 'off';
  bool get isAllow => mode == 'allow';
  bool get isDeny => mode == 'deny';

  TunAppsConfig copyWith({String? mode, List<String>? packages}) =>
      TunAppsConfig(
        mode: mode ?? this.mode,
        packages: packages ?? this.packages,
      );

  Map<String, Object?> toJson() => {'mode': mode, 'packages': packages};
}
