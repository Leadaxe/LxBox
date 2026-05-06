import 'dart:convert';
import 'dart:typed_data';

/// Метаданные одного установленного Android-приложения. Отдаёт native
/// `getInstalledApps` (массив, без иконок — для скоростного списка) и
/// `getAppInfo(packageName)` (одно приложение, с иконкой — для UI-tile'а).
///
/// Иконка приходит как base64-encoded PNG, конвертится в `Uint8List` тут же
/// (callsite просто `Image.memory(info.icon!)`).
class AppInfo {
  const AppInfo({
    required this.packageName,
    required this.appName,
    required this.isSystem,
    this.icon,
  });

  /// Package ID — `com.telegram.messenger`. Empty string если native пришёл
  /// мусор (defensive — не бросаем).
  final String packageName;

  /// Display name — что юзер видит в Settings/Launcher. Если null от native —
  /// fallback'ится в packageName (чтобы UI не падал на пустую строку).
  final String appName;

  /// `true` для system apps (установлены OEM'ом, обычно скрыты по default).
  final bool isSystem;

  /// PNG-иконка, decoded base64 → bytes. `null` если native не приложил
  /// (getInstalledApps lightweight-mode без иконок) или decode упал.
  final Uint8List? icon;

  /// Native шлёт `Map<String, dynamic>` с ключами `packageName`, `appName`,
  /// `isSystemApp`, опционально `icon` (base64). Парсинг defensive: missing
  /// fields → defaults, broken icon base64 → null.
  factory AppInfo.fromMap(Map<String, dynamic> raw) {
    final iconStr = raw['icon'] as String? ?? '';
    Uint8List? bytes;
    if (iconStr.isNotEmpty) {
      try {
        bytes = base64Decode(iconStr);
      } catch (_) {
        // Broken base64 — оставляем null, UI покажет default-icon
      }
    }
    final pkg = (raw['packageName'] as String?) ?? '';
    return AppInfo(
      packageName: pkg,
      appName: (raw['appName'] as String?) ?? pkg,
      isSystem: (raw['isSystemApp'] as bool?) ?? false,
      icon: bytes,
    );
  }
}
