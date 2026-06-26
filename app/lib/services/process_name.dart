/// §154 — чистый package name из `processPath`. Ядро форматирует его как
/// `com.app (com.app)` либо `com.app (user)` / `com.app (1000)` (см. sing-box
/// `tracker.go`: `processPath + " (" + userName/userId + ")"`). Для резолва
/// иконки нужен голый package — берём часть до первого пробела. Возвращает ''
/// если пусто или похоже на абсолютный путь (не Android-pkg).
///
/// §122 — вынесено из `connections_screen.dart` (тот перешёл на CcConnection,
/// где processPath нет). Используется TrafficProfiler-стеком (Live/Aggregated),
/// у которого process в событиях ещё есть.
String packageNameFromProcess(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  final pkg = s.split(' ').first.trim();
  // Android package = `a.b.c`, без слешей. Путь вида /usr/bin/foo — не pkg.
  if (pkg.contains('/') || !pkg.contains('.')) return '';
  return pkg;
}
