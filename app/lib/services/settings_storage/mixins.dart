part of '../settings_storage.dart';

// §704 — миксины итогового конфига (`mixins[]`) для [SettingsStorage].
//
// Список целиком: порядок = порядок применения при сборке, мутации UI и
// Debug API — read → изменить копию → перезаписать.

Future<List<Mixin>> _getMixins() async {
  final data = await _load();
  final raw = data[kMixinsKey];
  if (raw is! List) return const [];
  return [
    for (final m in raw)
      if (m is Map) Mixin.fromJson(m.cast<String, dynamic>()),
  ];
}

Future<void> _setMixins(List<Mixin> mixins, {bool flush = true}) async {
  final data = await _load();
  if (mixins.isEmpty) {
    data.remove(kMixinsKey);
  } else {
    data[kMixinsKey] = [for (final m in mixins) m.toJson()];
  }
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}
