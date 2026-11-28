import 'connection_test.dart';

/// Итог проверки URL Check — уровень строки итога.
enum UrlCheckOutcome { success, warning, error, stopped }

/// Одна закончившаяся проверка URL Check.
class UrlCheckRecord {
  const UrlCheckRecord({
    required this.link,
    required this.depth,
    required this.outcome,
    required this.summary,
    required this.at,
    this.packageName = '',
    this.fresh = false,
    this.trace,
  });

  /// Нормализованный адрес — тот, что ушёл в ядро.
  final String link;
  final ConnectionTestDepth depth;
  final UrlCheckOutcome outcome;

  /// Текст строки итога на момент проверки.
  final String summary;

  /// Время окончания проверки.
  final DateTime at;

  /// Приложение, от имени которого шла проверка; пусто — любое.
  final String packageName;
  final bool fresh;

  /// Дерево стадий и находки — показываются из истории без нового запроса.
  final ConnectionTestTrace? trace;
}

/// История проверок URL Check: последние [limit] проверок, новые первыми;
/// каждая проверка — своя запись, и повтор адреса тоже. Живёт только в памяти процесса — ни диска, ни бэкапа;
/// после перезапуска приложения пустая.
class UrlCheckHistory {
  UrlCheckHistory({this.limit = 20});

  /// Общая история вкладки: переживает уход с экрана Diagnostics.
  static final UrlCheckHistory instance = UrlCheckHistory();

  final int limit;
  final List<UrlCheckRecord> _items = [];

  /// Записи, новые первыми.
  List<UrlCheckRecord> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// Адреса для подстановки в поле: без повторов, по последней проверке.
  List<String> get links => [
        for (final l in {for (final e in _items) e.link}) l,
      ];

  /// Добавляет запись первой. Сверх [limit] вытесняются самые старые.
  void add(UrlCheckRecord r) {
    _items.insert(0, r);
    if (_items.length > limit) _items.removeRange(limit, _items.length);
  }

  void clear() => _items.clear();
}
