// §084 H4 — общие форматтеры байтов / длительности / времени.
//
// До §084 эти функции были продублированы в `stats_screen`,
// `live_events_tab`, `per_app_trace_tab` с разным неймингом
// (`_fmtBytes`/`_formatBytes`), видимостью и расходящимся выводом.
// Единый источник здесь.

/// Человекочитаемый размер. `spaced=false` → компактно (`100KB`,
/// live/per-app trace). `spaced=true` → с пробелом + явный `0 B` для
/// неположительных (`100 KB`, stats screen).
String formatBytes(int b, {bool spaced = false}) {
  final sp = spaced ? ' ' : '';
  if (spaced && b <= 0) return '0 B';
  if (b < 1024) return '$b${sp}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}${sp}KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)}${sp}MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}${sp}GB';
}

/// Компактная длительность: `2h 5m` / `5m 30s` / `30s`.
///
/// §219 — на часовом разряде секунды отбрасываются НАМЕРЕННО (`1h 5m 30s` →
/// `1h 5m`): чем длиннее интервал, тем ниже нужная точность. Это не
/// несогласованность с минутным разрядом (`5m 30s`), а осознанный выбор.
///
/// `daysRollup=true` добавляет дневной разряд (`1d 6h`) при ≥24h — для
/// uptime-индикатора (§090 A1, было `traffic_bar._uptime`). По умолчанию
/// (false) разряда дней нет — `30h 5m` остаётся в часах, как раньше.
String formatDuration(Duration d, {bool daysRollup = false}) {
  if (daysRollup && d.inHours >= 24) {
    return '${d.inDays}d ${d.inHours % 24}h';
  }
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// §219 — host из `"host:port"` (часть до последнего `:`). Нет `:` → вся строка.
/// Ранее дублировалось как `_hostOf` в connections_screen / stats_screen.
String hostOf(String destination) {
  final i = destination.lastIndexOf(':');
  return i < 0 ? destination : destination.substring(0, i);
}

/// §219 — порт из `"host:port"` (часть после последнего `:`). Нет `:` /
/// висячий `:` → `''`. Ранее дублировалось (`_portOf` / `_destPort`).
String portOf(String destination) {
  final i = destination.lastIndexOf(':');
  if (i < 0 || i == destination.length - 1) return '';
  return destination.substring(i + 1);
}

/// Wall-clock `HH:mm:ss`.
String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';
