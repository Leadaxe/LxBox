import '../contract/registry.dart' show ContractRegistry, RegistrySnapshot;
import 'engine/section_loader.dart' show MapperSections;

/// Синглтоны разбора основного isolate, снятые для воркера: в новом isolate
/// `ContractRegistry.I` и `MapperSections.I` пусты, а разбор без них молча
/// деградирует (коды и санитайзер пропускаются, черновые секции пусты).
final class ParseEnvSnapshot {
  const ParseEnvSnapshot({required this.registry, required this.drafts});

  /// Снимок main. Тексты уже лежат в синглтонах — повторного чтения ассетов
  /// нет.
  factory ParseEnvSnapshot.capture() => ParseEnvSnapshot(
        registry: ContractRegistry.I.snapshot,
        drafts: MapperSections.I.draftTexts,
      );

  /// `null` — на main реестр не загружен; воркер тогда работает без него же.
  final RegistrySnapshot? registry;
  final Map<String, String> drafts;

  /// Поставить снимок в синглтоны текущего (рабочего) isolate. §674 —
  /// тем же снимком воркер превью пула Направлений.
  Future<void> install() async {
    final reg = registry;
    if (reg != null) {
      await ContractRegistry.I.loadFromSnapshot(reg);
      if (!ContractRegistry.I.isLoaded) {
        throw StateError('contract registry not initialized in worker');
      }
    }
    MapperSections.I.loadDraftsFromTexts(drafts);
  }
}
