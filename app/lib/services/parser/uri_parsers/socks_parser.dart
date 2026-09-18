import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// SOCKS 5
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 6 — socks разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Рукописных правил ЗНАЧЕНИЯ у socks не было ни одного, и судить в схеме
/// нечего: собственных query-параметров у неё нет вовсе
/// (`registry/protocols/socks.json` → `uri.query` пуст), а `version` в тело из
/// ссылки не пишется — см. `mappers/socks_mapper.dart`.
SocksSpec? parseSocks(String uri) {
  // `socks://` и `socks5://` эквивалентны (`socks.json` → aliases); обе
  // записи таблицы ведут в один маппер.
  final scheme = uri.split('://').first.toLowerCase();
  return parseUriViaPipeline(uri, scheme) as SocksSpec?;
}
