import '../../../models/node_spec.dart';
import '../mappers/uri_pipeline.dart';

// ════════════════════════════════════════════════════════════════════════════
// SSH
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 6 — ssh разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Рукописных правил ЗНАЧЕНИЯ у ssh не было ни одного: все поля тела это
/// `string` или `listable_string` без enum'ов и форматов. Рукописным остался
/// ПЕРЕВОД написания — userinfo, списки через запятую, §466 `private_key` в
/// query как форма хранения (см. `mappers/ssh_mapper.dart`).
SshSpec? parseSsh(String uri) => parseUriViaPipeline(uri, 'ssh') as SshSpec?;
