import 'singbox_entry.dart';

/// Результат `NodeSpec.getEntries(ctx)`. Явное разделение:
///  - `main` — сам сервер (один entry, всегда есть).
///  - `detours` — его детур-цепочка (0 или больше элементов).
///
/// Именованная структура вместо позиционного `List<SingboxEntry>`
/// (где `[0]` якобы главный) — защита от опечаток и неявных контрактов.
class NodeEntries {
  final SingboxEntry main;
  final List<SingboxEntry> detours;

  const NodeEntries({required this.main, this.detours = const []});

  /// Все entries в порядке "main, потом детуры". Удобно для итерации,
  /// когда роль не важна (напр. `ctx.addEntry(e)` на каждый).
  Iterable<SingboxEntry> get all sync* {
    yield main;
    yield* detours;
  }
}
