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
/// почти нечего: собственных query-параметров у неё нет вовсе
/// (`registry/protocols/socks.json` → `uri.query` пуст). Единственное поле,
/// которое ссылка приносит сверх адреса и userinfo, — `version`, и приносит
/// его СХЕМА (§475, `mappers/socks_mapper.dart`); годность значения судит
/// enum реестра.
SocksSpec? parseSocks(String uri) {
  // Четыре схемы ведут в ОДИН маппер: `socks5` — алиас написания
  // (`socks.json` → aliases), `socks4`/`socks4a` — дискриминатор версии
  // (§475). Тело у всех одно, различается поле `version`.
  final scheme = uri.split('://').first.toLowerCase();
  return parseUriViaPipeline(uri, scheme) as SocksSpec?;
}
