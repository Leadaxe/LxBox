/// Результат чтения одной записи контракта 1.0 кодеком `lib/models/codec/`.
library;

/// Результат чтения одной записи: либо значение, либо причина отброса.
final class RecordRead<T> {
  const RecordRead.ok(T this.value, {this.unknownKeys = const []})
      : dropped = null;
  const RecordRead.drop(String this.dropped)
      : value = null,
        unknownKeys = const [];

  final T? value;

  /// Причина, по которой запись не читается (чужой `kind`, нет тела …).
  final String? dropped;

  /// Ключи `body`, которых типизированная модель не держит. Что с ними
  /// сталось, решает читатель (см. `ruleFromRecord`).
  final List<String> unknownKeys;
}
