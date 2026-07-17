part of '../settings_storage.dart';

// §189 — native_prefs: JSON-зеркало Android-prefs (`boxvpn_boot.*`).
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
// Storage key: `native_prefs`. Состав полей — см. NativePrefsKeys.

/// Ключи секции `native_prefs` (= wire-имена бэкапа, обратная совместимость).
class NativePrefsKeys {
  static const autoStart = 'auto_start';
  static const keepOnExit = 'keep_on_exit';
  static const backgroundMode = 'background_mode'; // String (never/lazy/always)
  static const coreLogsEnabled = 'core_logs_enabled';
  static const allowBypass = 'allow_bypass';
  static const autoRedirect = 'auto_redirect';
  static const memoryLimit = 'memory_limit'; // §271 — String (auto/off/МБ строкой)

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
    memoryLimit,
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
  NativePrefsKeys.memoryLimit: MemoryLimitSetting.auto, // §271
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

/// memory_limit (§271, String wireValue) из JSON-зеркала.
Future<String> _getNativeMemoryLimit() async {
  final p = await _getNativePrefs();
  final v = p[NativePrefsKeys.memoryLimit];
  return MemoryLimitSetting.normalize(v is String ? v : null);
}

/// Записать memory_limit: JSON + зеркало в native (native применяет к
/// работающему ядру немедленно через reloadSetupOptions).
Future<void> _setNativeMemoryLimit(String wireValue) async {
  final v = MemoryLimitSetting.normalize(wireValue);
  await _writeNativeJson(NativePrefsKeys.memoryLimit, v);
  await BoxVpnClient().setMemoryLimit(v);
}

// ──────────────────── backup-блок (единая сериализация) ────────────────────
// Единственное место, знающее состав/дефолты/типы блока vpn_settings бэкапа.
// backup_service И debug-handler делегируют сюда (без дублей). Wire-ключи =
// NativePrefsKeys-значения (стабильны — старые бэкапы импортируются).

/// Снимок всех ключей для бэкапа (из JSON-зеркала, дефолты из единого места).
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
      } else if (key == NativePrefsKeys.memoryLimit) {
        // §271 — нормализация через MemoryLimitSetting (мусор → auto).
        await _setNativeMemoryLimit(
            MemoryLimitSetting.normalize(data[key]?.toString()));
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
  // §279 — app_language: пере-пуш derived cache на каждом старте (как sync
  // выше — диск-истина перезаливает native-копию).
  await _mirrorAppLanguageToNative(await SettingsStorage.getAppLanguage());
}

/// §279 — зеркало `app_language` в native (`boxvpn_boot`). Документированное
/// исключение из правила §189 «прямые native-записи эфемерны»: `app_language`
/// НЕ член [NativePrefsKeys] (членство экспортировало бы его вторым
/// представлением в vpn_settings-блок бэкапа с неопределённым precedence на
/// import). Его boxvpn_boot-копия — derived cache: единственный источник
/// истины — var в lxbox_settings.json; кэш пере-пушится setAppLanguage и
/// bootstrapAndSyncNativePrefs. Best-effort: native-handler появляется в
/// Phase 6 фичи l10n — до того вызов падает в notImplemented и глотается.
Future<void> _mirrorAppLanguageToNative(String value) async {
  try {
    await BoxVpnClient().setAppLanguage(value);
  } catch (_) {
    // JSON остаётся истиной; native-поверхности догонят при следующем пуше.
  }
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
    NativePrefsKeys.memoryLimit: await vpn.getMemoryLimit(), // §271
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
  // §271 — memory_limit: диск перезаливает native, как и остальные ключи.
  final wantMl = json[NativePrefsKeys.memoryLimit];
  if (wantMl is String) {
    final normMl = MemoryLimitSetting.normalize(wantMl);
    final haveMl = await vpn.getMemoryLimit();
    if (haveMl != normMl) await vpn.setMemoryLimit(normMl);
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
