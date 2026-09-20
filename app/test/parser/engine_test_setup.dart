import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';

import '../contract_paths.dart';

/// §480 — общая подготовка для тестов, которые просто зовут `parseUri`.
///
/// С контракта 1.1.15 секции-мапперы живут В РЕЕСТРЕ, и схема, переехавшая на
/// движок, без него не разбирается вовсе — запасного рукописного пути у неё
/// не осталось (критерий 7 спеки 480). Раньше такие тесты обходились без
/// загрузки: разбор был рукописным и реестра не требовал.
///
/// §486 — реестр из зеркала `assets/contract` (§486, [loadTestRegistry]).
Future<void> loadEngineSections() async {
  await loadTestRegistry();
  await MapperSections.I
      .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
}

/// Снять секции и реестр, загруженные [loadEngineSections].
void unloadEngineSections() {
  MapperSections.I.resetForTesting();
  ContractRegistry.I.resetForTesting();
}
