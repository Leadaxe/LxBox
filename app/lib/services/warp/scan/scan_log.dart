// §835 — журнал сканера эндпоинтов.
//
// Зачем отдельный тип, а не AppLog: строки скана нужны ПОЛЬЗОВАТЕЛЮ (кнопка
// «Копировать» на экране сканера — отдать разработчику для диагноза), а не
// только в общий debug-журнал. Поэтому формат — самостоятельный, компактный,
// с миллисекундами и уровнем на каждой строке, и он же сериализуется в
// clipboard/share как есть.
//
// Экземпляр создаёт экран сканера и передаёт в [EndpointScanner]; сам сканер
// ничего не знает про UI. Живых строк не больше [maxLines] (кольцевой буфер):
// прогон по 300 адресам иначе копил бы память.

/// Уровень строки журнала. Порядок — от подробного к фатальному.
enum ScanLogLevel { debug, info, warn, error }

/// Одна строка журнала: время (локальное), уровень, тег фазы и текст.
class ScanLogLine {
  const ScanLogLine({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime time;
  final ScanLogLevel level;

  /// Короткий тег источника: `pool`, `p1`, `p2`, `core`, `net`, `done`.
  final String tag;
  final String message;
}

/// Кольцевой журнал скана. Потокобезопасность не нужна: скан однопоточный
/// (асинхронный, но без параллельных мутаций журнала).
class ScanLog {
  ScanLog({this.maxLines = 3000});

  final int maxLines;
  final List<ScanLogLine> _lines = [];

  /// Снимок строк (новые — в конце). Копия: UI читает, скан пишет.
  List<ScanLogLine> get lines => List.unmodifiable(_lines);

  int get length => _lines.length;

  bool get isEmpty => _lines.isEmpty;

  void add(ScanLogLevel level, String tag, String message) {
    _lines.add(ScanLogLine(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    ));
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  void d(String tag, String message) => add(ScanLogLevel.debug, tag, message);
  void i(String tag, String message) => add(ScanLogLevel.info, tag, message);
  void w(String tag, String message) => add(ScanLogLevel.warn, tag, message);
  void e(String tag, String message) => add(ScanLogLevel.error, tag, message);

  void clear() => _lines.clear();

  /// Плоский текст для копирования/шаринга. Заголовок — версия протокола
  /// журнала, чтобы разработчик понимал формат и мог отличить сборки.
  String get text {
    final b = StringBuffer();
    b.writeln('# lxbox endpoint-scan log v1 (${_lines.length} lines)');
    for (final l in _lines) {
      b.writeln(formatLine(l));
    }
    return b.toString();
  }

  /// Одна строка в текстовом виде: `[HH:mm:ss.mmm] LEVEL tag: message`.
  static String formatLine(ScanLogLine l) {
    final t = l.time;
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '.${t.millisecond.toString().padLeft(3, '0')}';
    return '[$ts] ${l.level.name.toUpperCase().padRight(5)} ${l.tag}: '
        '${l.message}';
  }
}
