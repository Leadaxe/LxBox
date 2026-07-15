/// §271 — memory limit ядра (SetupOptions.oomMemoryLimit, prefs `memory_limit`).
///
/// Wire-protocol с native — строки: `auto` (лимит по RAM устройства, дефолт),
/// `off` (без лимита; oom-killer ядра остаётся следить за системной свободной
/// памятью) или число мегабайт строкой (`200`/`384`/`512`/`768`). Разрешение
/// в байты живёт на native-стороне (`BoxApplication.resolveMemoryLimitBytes`).
class MemoryLimitSetting {
  MemoryLimitSetting._();

  static const auto = 'auto';
  static const off = 'off';

  /// Полный набор wire-значений (порядок = порядок в UI-dropdown).
  static const values = <String>[auto, off, '200', '384', '512', '768'];

  /// Unknown / null fallback'ится в `auto` (безопасный дефолт — native
  /// подберёт лимит по RAM устройства).
  static String normalize(String? raw) => values.contains(raw) ? raw! : auto;
}
