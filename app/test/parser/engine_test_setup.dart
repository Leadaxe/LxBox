import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';

/// §480 — общая подготовка для тестов, которые просто зовут `parseUri`.
///
/// С контракта 1.1.15 секции-мапперы живут В РЕЕСТРЕ, и схема, переехавшая на
/// движок, без него не разбирается вовсе — запасного рукописного пути у неё
/// не осталось (критерий 7 спеки 480). Раньше такие тесты обходились без
/// загрузки: разбор был рукописным и реестра не требовал.
///
/// Зеркало `assets/contract`, а не вендоренная копия `app/contract`: второй
/// на CI нет, и под её гейтом тест молча пропускался бы.
Future<void> loadEngineSections() async {
  if (!ContractRegistry.I.isLoaded) {
    await ContractRegistry.I.loadFromDirectory('assets/contract');
  }
  await MapperSections.I
      .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
}
