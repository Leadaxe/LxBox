part of '../settings_storage.dart';

// §025 — кеш Cloudflare WARP-аккаунта. Storage key: `warp_account`.
//
// Вынесено `part`'ом (как vpn_mode §119) — та же библиотека, доступ к
// `_load`/`_save`/`_cache`. Хранит секреты (priv_key, token) — это локальный
// файл приложения, но они НЕ должны попадать в логи/diag (см.
// WarpAccount.redacted()).
//
// Идемпотентность: контроллер по умолчанию переиспользует закешированный
// аккаунт вместо новой регистрации (не плодим device-регистрации в Cloudflare).
// «Re-register» очищает ключ → следующий getWarp регистрирует заново.

Future<WarpAccount?> _getWarpAccount() async {
  final data = await _load();
  final raw = data['warp_account'];
  if (raw is Map<String, dynamic>) {
    return WarpAccount.fromJson(raw);
  }
  return null;
}

Future<void> _setWarpAccount(WarpAccount? account, {bool flush = true}) async {
  final data = await _load();
  if (account == null) {
    data.remove('warp_account');
  } else {
    data['warp_account'] = account.toJson();
  }
  SettingsStorage._cache = data;
  // Не config-significant сам по себе: WARP-узел попадает в конфиг через
  // обычный UserServer (markConfigDirty там, где меняется список подписок).
  if (flush) await _save();
}

// §130 — кеш MASQUE-WARP аккаунта. Storage key: `masque_account`. Отдельный от
// `warp_account` (другая крипта ECDSA, другой транспорт). Секреты (priv_key_der,
// token) — не в логи (см. MasqueAccount.redacted()).

Future<MasqueAccount?> _getMasqueAccount() async {
  final data = await _load();
  final raw = data['masque_account'];
  if (raw is Map<String, dynamic>) {
    return MasqueAccount.fromJson(raw);
  }
  return null;
}

Future<void> _setMasqueAccount(MasqueAccount? account, {bool flush = true}) async {
  final data = await _load();
  if (account == null) {
    data.remove('masque_account');
  } else {
    data['masque_account'] = account.toJson();
  }
  SettingsStorage._cache = data;
  if (flush) await _save();
}
