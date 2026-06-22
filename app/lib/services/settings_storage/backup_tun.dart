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

/// §159 — применить snapshot при импорте. Фильтр default-deny на ВХОДЕ:
/// top-level ∈ [SettingsStorage.allowedTopLevelKeys], подключи `vars` ∈
/// (app-флаги ∪ vars текущего template). Всё прочее отбрасывается и
/// возвращается в списке отброшенных (`dropped`) — caller логирует/показывает.
///
/// Закрывает оба входа в storage: UI-импорт бэкапа и Debug API
/// `POST /backup/import` (оба сходятся здесь). Экспорт (`_dumpCache`) НЕ
/// фильтруется — чистим только на входе.
///
/// `merge=false` (default) — replace целиком; `merge=true` — top-level upsert
/// (присутствующие ключи overwrite, отсутствующие keep), `vars` мерджится
/// per-subkey. Фильтр применяется к обоим путям.
Future<List<String>> _replaceRaw(
  Map<String, dynamic> snapshot, {
  bool merge = false,
}) async {
  final clean = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;

  // Allowlist для vars: кодовые флаги ∪ имена vars из локального template
  // (template в бэкап не входит — резолвим против зашитого в APK, §159).
  final template = await TemplateLoader.load();
  final allowedVars =
      SettingsStorage.allowedVarKeys(template.vars.map((v) => v.name));

  final dropped = <String>[];
  final filtered = <String, dynamic>{};
  for (final entry in clean.entries) {
    final key = entry.key;
    final value = entry.value;
    if (!SettingsStorage.allowedTopLevelKeys.contains(key)) {
      dropped.add(key);
      continue;
    }
    if (key == 'vars' && value is Map) {
      final outVars = <String, dynamic>{};
      for (final v in value.entries) {
        final vk = v.key.toString();
        if (allowedVars.contains(vk)) {
          outVars[vk] = v.value;
        } else {
          dropped.add('vars.$vk');
        }
      }
      filtered[key] = outVars;
    } else {
      filtered[key] = value;
    }
  }

  if (!merge) {
    SettingsStorage._cache = filtered;
    await _save();
    return dropped;
  }

  final current = await _load();
  for (final entry in filtered.entries) {
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
  return dropped;
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
