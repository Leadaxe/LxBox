/// §757 (спека §6) — разовая миграция файлов кэша наборов правил: id кэша
/// набора был позиционным (`<id правила>` у первой ссылки, `<id>~<номер>` у
/// остальных, ## 12), стал по ссылке (`<id правила>~<h8 ссылки>`,
/// [CustomRuleTree.cacheIdFor]).
///
/// Файл набора и его метаданные §366 (`<id>.meta.json`: время, ETag)
/// переименовываются по ссылкам правила в прежнем порядке (до §757 —
/// `srsUrls` записи; старая форма читается с переносом в корень дерева, так
/// что порядок [CustomRule.allRefs] тот же). Не найденный файл — обычная
/// докачка; файл, у которого уже есть новое имя, не трогается.
///
/// Идемпотентна и дешева (две проверки существования на ссылку), поэтому
/// отдельного флага «выполнено» нет: её зовут все, кто смотрит в кэш
/// наборов правил до первого обращения — сборка конфига, экран Routing
/// (до `pruneOrphans`, иначе старые файлы ушли бы сиротами), автообновление.
library;

import '../../models/custom_rule.dart';
import '../rule_set_downloader.dart';

/// Переименовать старые файлы кэша наборов [rules]; итог — число
/// переименованных наборов.
Future<int> migrateRuleSetCacheIds(Iterable<CustomRule> rules) async {
  var renamed = 0;
  for (final r in rules) {
    if (r is! CustomRuleTree) continue;
    final refs = r.allRefs;
    for (var i = 0; i < refs.length; i++) {
      final legacy = i == 0 ? r.id : '${r.id}~$i';
      final target = CustomRuleTree.cacheIdFor(r.id, refs[i]);
      if (await RuleSetDownloader.renameCache(legacy, target)) renamed++;
    }
  }
  return renamed;
}
