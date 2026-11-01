/// §271 — memory limit ядра (SetupOptions.oomMemoryLimit, prefs `memory_limit`).
///
/// Wire-protocol с native — строки: `auto` (без порога, дефолт; oom-killer
/// ядра следит за свободной памятью системы) или число мегабайт строкой
/// (`200`/`384`/`512`/`768`) — порог по RSS всего процесса. Разрешение
/// в байты живёт на native-стороне (`BoxApplication.resolveMemoryLimitBytes`).
///
/// §705: `off` — legacy-значение (до §705 Auto выбирал лимит по RAM, Off
/// снимал его); теперь оба дают 0, пункта Off в UI нет, на чтении `off`
/// нормализуется в `auto` (бэкапы, prefs старых версий).
class MemoryLimitSetting {
  MemoryLimitSetting._();

  static const auto = 'auto';
  static const off = 'off';

  /// Полный набор wire-значений (порядок = порядок в UI-dropdown).
  static const values = <String>[auto, '200', '384', '512', '768'];

  /// Unknown / null / legacy `off` fallback'ятся в `auto` (безопасный
  /// дефолт — без порога).
  static String normalize(String? raw) => values.contains(raw) ? raw! : auto;
}
