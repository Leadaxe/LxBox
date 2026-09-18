import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../app_log.dart';
import '../mappers/uri_pipeline.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// NaïveProxy — see spec 037.
// ════════════════════════════════════════════════════════════════════════════

/// §472 шаг 6 — naive разбирается КОНВЕЙЕРОМ: маппер переводит ссылку в сырую
/// карту sing-box, санитайзер реестра судит значения, `parseSingboxEntry`
/// строит модель (`mappers/uri_pipeline.dart`).
///
/// Своего разбора у этой функции больше нет — осталось имя, под которым её
/// зовут `parseUri` и тесты. Схема у naive НЕСЁТ ТРАНСПОРТ, поэтому [isQuic]
/// выбирает запись таблицы конвейера, а не аргумент маппера.
///
/// Рукописных правил ЗНАЧЕНИЯ у naive не было ни одного — судить в этой схеме
/// нечего: собственных query-параметров всего два (`extra-headers`,
/// `padding`), и оба про структуру. TLS-allowlist (§454/§270) реестр держит
/// правилом `forbidden_for: ["naive"]` с кодом `tls_field_unsupported_naive`,
/// и исполняет его санитайзер на входе ТЕЛА — со ссылки таким полям взяться
/// неоткуда.
NaiveSpec? parseNaive(String uri, {bool isQuic = false}) =>
    parseUriViaPipeline(uri, isQuic ? 'naive+quic' : 'naive+https')
        as NaiveSpec?;

/// Парсит уже-URL-decoded строку `Header1: Value1\r\nHeader2: Value2`.
/// Невалидные пары (нет `:`, имя нарушает charset, пустое имя) — drop с warn.
///
/// D-105 (`naive_extra_headers_invalid`): при первой отброшенной паре в
/// [warnings] добавляется [NaiveExtraHeadersInvalidWarning] — один раз на
/// узел, остальные отбросы только в лог. `warnings == null` — молчаливый
/// режим: так вызывает http/https-парсер, чей собственный `headers` под код
/// контракта не попадает.
Map<String, String> parseNaiveExtraHeaders(
  String raw, {
  List<NodeWarning>? warnings,
}) {
  if (raw.isEmpty) return const {};
  final out = <String, String>{};
  var warned = false;
  void dropped(String entry) {
    if (warned || warnings == null) return;
    warned = true;
    warnings.add(NaiveExtraHeadersInvalidWarning(entry));
  }

  for (final line in raw.split('\r\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final colon = l.indexOf(':');
    if (colon <= 0) {
      AppLog.I.warning("naive: invalid extra-headers entry '$l', skipping");
      dropped(l);
      continue;
    }
    final name = l.substring(0, colon).trim();
    final value = l.substring(colon + 1).trim();
    if (!isValidNaiveHeaderName(name)) {
      AppLog.I
          .warning("naive: invalid header name '$name' in extra-headers, skipping");
      dropped(l);
      continue;
    }
    out[name] = value;
  }
  return out;
}
