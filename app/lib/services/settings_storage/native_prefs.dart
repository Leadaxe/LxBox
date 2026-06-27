part of '../settings_storage.dart';

// §189 — native_prefs: JSON-зеркало шести Android-prefs (`boxvpn_boot.*`).
//
// Модель: lxbox_settings.json = ИСТОЧНИК ИСТИНЫ (диск); native SharedPreferences
// = рабочая копия (оперативка) для Dart-less моментов (BOOT_COMPLETED, swipe
// onTaskRemoved, openTun/establish). native читает СВОЮ копию синхронно.
//
// Поток (write-through): любой set → пишет в JSON (первично) → зеркалит в native.
// native НИКОГДА не пишет JSON. На старте sync JSON⇒native выправляет расхождения
// (диск перезаливает оперативку — само чинится). Bootstrap: первый старт без
// секции → seed native⇒JSON (диск пуст, единственный случай native⇒JSON).
//
// Все писатели (UI, импорт, Debug API) идут через этот слой — иначе их прямые
// native-записи эфемерны (sync откатит на следующем старте).
//
// Storage key: `native_prefs`. Шесть полей — см. NativePrefsKeys.

/// Ключи секции `native_prefs` (= wire-имена бэкапа, обратная совместимость).
class NativePrefsKeys {
  static const autoStart = 'auto_start';
  static const keepOnExit = 'keep_on_exit';
  static const backgroundMode = 'background_mode'; // String (never/lazy/always)
  static const coreLogsEnabled = 'core_logs_enabled';
  static const allowBypass = 'allow_bypass';
  static const autoRedirect = 'auto_redirect';

  static const bools = <String>{
    autoStart,
    keepOnExit,
    coreLogsEnabled,
    allowBypass,
    autoRedirect,
  };
  static const all = <String>{
    autoStart,
    keepOnExit,
    backgroundMode,
    coreLogsEnabled,
    allowBypass,
    autoRedirect,
  };
}

// Реализации — приватные top-level (как _getVpnMode/_setVpnMode). Публичные
// static-обёртки в основном классе SettingsStorage (см. блок «§189 native_prefs»).

const Map<String, Object> _nativePrefsDefaults = {
  NativePrefsKeys.autoStart: false,
  NativePrefsKeys.keepOnExit: true, // §188 — дефолт ON
  NativePrefsKeys.backgroundMode: 'never',
  NativePrefsKeys.coreLogsEnabled: false,
  NativePrefsKeys.allowBypass: false,
  NativePrefsKeys.autoRedirect: false,
};

/// Весь снимок секции `native_prefs` (для UI / бэкапа). Пусто → дефолты.
Future<Map<String, dynamic>> _getNativePrefs() async {
  final data = await _load();
  final raw = data['native_prefs'];
  if (raw is Map<String, dynamic>) return Map<String, dynamic>.from(raw);
  return Map<String, dynamic>.from(_nativePrefsDefaults);
}

/// bool-ключ из JSON-зеркала (UI читает отсюда, не method-channel).
Future<bool> _getNativeBool(String key) async {
  assert(NativePrefsKeys.bools.contains(key), 'not a bool native pref: $key');
  final p = await _getNativePrefs();
  final v = p[key];
  return v is bool ? v : (_nativePrefsDefaults[key] as bool);
}

/// background_mode (String wireValue) из JSON-зеркала.
Future<String> _getNativeBackgroundMode() async {
  final p = await _getNativePrefs();
  final v = p[NativePrefsKeys.backgroundMode];
  return v is String
      ? v
      : (_nativePrefsDefaults[NativePrefsKeys.backgroundMode] as String);
}

/// Записать bool-pref: JSON (истина) + зеркало в native. Все писатели
/// (UI/импорт/Debug API) идут сюда.
Future<void> _setNativeBool(String key, bool value) async {
  assert(NativePrefsKeys.bools.contains(key), 'not a bool native pref: $key');
  await _writeNativeJson(key, value);
  await _mirrorBoolToNative(key, value);
}

/// Записать background_mode: JSON + зеркало в native.
Future<void> _setNativeBackgroundMode(String wireValue) async {
  await _writeNativeJson(NativePrefsKeys.backgroundMode, wireValue);
  await BoxVpnClient().setBackgroundMode(BackgroundMode.fromNative(wireValue));
}

// ──────────────────── backup-блок (единая сериализация) ────────────────────
// Единственное место, знающее состав/дефолты/типы блока vpn_settings бэкапа.
// backup_service И debug-handler делегируют сюда (без дублей). Wire-ключи =
// NativePrefsKeys-значения (стабильны — старые бэкапы импортируются).

/// Снимок всех 6 ключей для бэкапа (из JSON-зеркала, дефолты из единого места).
Future<Map<String, dynamic>> _exportToBackupMap() async {
  final p = await _getNativePrefs();
  return {
    for (final key in NativePrefsKeys.all) key: p[key] ?? _nativePrefsDefaults[key],
  };
}

/// Применить backup-блок через write-through (JSON + native). Возвращает число
/// применённых ключей; ошибку каждого ключа отдаёт в [onError] (key, error) —
/// один битый ключ не прерывает остальные (resilience backup_service). Ключи,
/// отсутствующие в [data], пропускаются (forward-compat старых бэкапов).
Future<int> _applyFromBackupMap(
  Map<String, dynamic> data, {
  void Function(String key, Object error)? onError,
}) async {
  var n = 0;
  for (final key in NativePrefsKeys.all) {
    if (!data.containsKey(key)) continue;
    try {
      if (key == NativePrefsKeys.backgroundMode) {
        // Нормализация/валидация через BackgroundMode (не голый каст).
        await _setNativeBackgroundMode(
            BackgroundMode.fromNative(data[key]?.toString()).wireValue);
      } else {
        await _setNativeBool(key, data[key] == true);
      }
      n++;
    } catch (e) {
      onError?.call(key, e);
    }
  }
  return n;
}

/// Старт: bootstrap (секции нет → seed native⇒JSON) ИЛИ sync (JSON⇒native).
/// + §192 — зеркалим has_tun из vpn_mode (производное, НЕ часть backup-блока).
Future<void> _bootstrapAndSyncNativePrefs() async {
  final data = await _load();
  if (data['native_prefs'] is! Map<String, dynamic>) {
    await _bootstrapFromNative();
  } else {
    await _syncJsonToNative();
  }
  // §192 — has_tun = производное от vpn_mode (не настройка, не бэкапится).
  // Синхронизируем на старте: гейтит VpnService.prepare() (proxy → не звать).
  await _syncHasTunToNative();
}

/// §192 — зеркалить has_tun (из vpn_mode) в native. Вычисляемое, не в backup.
Future<void> _setNativeHasTun(bool hasTun) =>
    BoxVpnClient().setHasTun(hasTun);

Future<void> _syncHasTunToNative() async {
  final cfg = await _getVpnMode();
  await BoxVpnClient().setHasTun(cfg.hasTun);
}

/// Записать одно поле в JSON-секцию (создаёт секцию если нет), flush на диск.
Future<void> _writeNativeJson(String key, Object value) async {
  final data = await _load();
  final section = (data['native_prefs'] is Map<String, dynamic>)
      ? Map<String, dynamic>.from(data['native_prefs'] as Map)
      : <String, dynamic>{};
  section[key] = value;
  data['native_prefs'] = section;
  SettingsStorage._cache = data;
  await _save();
}

/// Зеркалирование bool в native по ключу (method-channel).
Future<void> _mirrorBoolToNative(String key, bool value) async {
  final vpn = BoxVpnClient();
  switch (key) {
    case NativePrefsKeys.autoStart:
      await vpn.setAutoStart(value);
      break;
    case NativePrefsKeys.keepOnExit:
      await vpn.setKeepOnExit(value);
      break;
    case NativePrefsKeys.coreLogsEnabled:
      await vpn.setCoreLogsEnabled(value);
      break;
    case NativePrefsKeys.allowBypass:
      await vpn.setAllowBypass(value);
      break;
    case NativePrefsKeys.autoRedirect:
      await vpn.setAutoRedirect(value);
      break;
  }
}

/// BOOTSTRAP: native → JSON (первый старт, секции нет). Единственный native⇒JSON.
Future<void> _bootstrapFromNative() async {
  final vpn = BoxVpnClient();
  final section = <String, dynamic>{
    NativePrefsKeys.autoStart: await vpn.getAutoStart(),
    NativePrefsKeys.keepOnExit: await vpn.getKeepOnExit(),
    NativePrefsKeys.backgroundMode: (await vpn.getBackgroundMode()).wireValue,
    NativePrefsKeys.coreLogsEnabled: await vpn.getCoreLogsEnabled(),
    NativePrefsKeys.allowBypass: await vpn.getAllowBypass(),
    NativePrefsKeys.autoRedirect: await vpn.getAutoRedirect(),
  };
  final data = await _load();
  data['native_prefs'] = section;
  SettingsStorage._cache = data;
  await _save();
}

/// SYNC: JSON ⇒ native для расходящихся ключей. Диск перезаливает оперативку.
Future<void> _syncJsonToNative() async {
  final vpn = BoxVpnClient();
  final json = await _getNativePrefs();
  for (final key in NativePrefsKeys.bools) {
    final want = json[key];
    if (want is! bool) continue;
    final have = await _nativeGetBool(vpn, key);
    if (have != want) await _mirrorBoolToNative(key, want);
  }
  final wantBg = json[NativePrefsKeys.backgroundMode];
  if (wantBg is String) {
    final haveBg = (await vpn.getBackgroundMode()).wireValue;
    if (haveBg != wantBg) {
      await vpn.setBackgroundMode(BackgroundMode.fromNative(wantBg));
    }
  }
}

Future<bool> _nativeGetBool(BoxVpnClient vpn, String key) async {
  switch (key) {
    case NativePrefsKeys.autoStart:
      return vpn.getAutoStart();
    case NativePrefsKeys.keepOnExit:
      return vpn.getKeepOnExit();
    case NativePrefsKeys.coreLogsEnabled:
      return vpn.getCoreLogsEnabled();
    case NativePrefsKeys.allowBypass:
      return vpn.getAllowBypass();
    case NativePrefsKeys.autoRedirect:
      return vpn.getAutoRedirect();
    default:
      return false;
  }
}
