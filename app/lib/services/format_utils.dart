// §084 H4 — общие форматтеры байтов / длительности / времени.
//
// До §084 эти функции были продублированы в `stats_screen`,
// `live_events_tab`, `per_app_trace_tab` с разным неймингом
// (`_fmtBytes`/`_formatBytes`), видимостью и расходящимся выводом.
// Единый источник здесь.
//
// §279 Phase 5 — граница локализации единиц (спека §5, решение 9):
// байтовые/скоростные единицы (`B/KB/MB/GB`, `Mbps`) и суффиксы длительности
// (`d/h/m/s`) НАМЕРЕННО латиница в обеих локалях, десятичная точка —
// ru-техноаудитория читает латиницу нативно, «МБ/Мб» вносит байт/бит-
// двусмысленность, паритет с логами ядра / Debug API. Это не то же самое,
// что редакционное «мс» в отдельно стоящих ru-ЛЕЙБЛАХ («Тайм-аут (мс)») —
// там слово живёт в ARB; здесь — машинная композиция число+единица, она
// втекает в локализованные предложения плейсхолдером и не переводится.
// Время/дата — через intl: локаль берётся из Intl.defaultLocale
// (проставляет LocaleController при каждой смене локали).

import 'package:intl/intl.dart';

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

/// §219 (было `connections_screen._formatDuration`) — грубая длительность
/// одним доминирующим разрядом: `30s` / `5m` / `2h5m`. Для age-колонки списка
/// соединений; НЕ сливать с [formatDuration] — там другой вывод (`5m 30s`).
String formatDurationCoarse(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  return '${d.inHours}h${d.inMinutes % 60}m';
}

/// Wall-clock `HH:mm:ss` (§279 Phase 5 — intl, локаль из Intl.defaultLocale).
String formatTime(DateTime t) => DateFormat.Hms().format(t);

/// Wall-clock `HH:mm` (§279 Phase 5 — было ручное padLeft в speed_test).
String formatTimeHm(DateTime t) => DateFormat.Hm().format(t);

/// `yyyy-MM-dd HH:mm:ss` для detail-sheet'ов (Started/Created). §279 Phase 5 —
/// ISO-порядок даты СОЗНАТЕЛЬНО в обеих локалях (спека §5): это технический
/// timestamp рядом с copy-кнопкой, ISO однозначен и сортируем; локализуется
/// только время (через [formatTime]).
String formatDateTime(DateTime t) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${pad(t.month)}-${pad(t.day)} ${formatTime(t)}';
}
