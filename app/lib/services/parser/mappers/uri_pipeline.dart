/// §472 шаг 2 — конвейер разбора ссылки.
///
/// ```
/// ссылка ─маппер→ сырая карта ─санитайзер по реестру→ чистая карта
///                                      │                    │
///                                      │                    ▼
///                                      │            parseSingboxEntry → NodeSpec
///                                      └→ warnings (code, path, value) ─┘
/// ```
///
/// Три решения этого шага записаны здесь, потому что проверяются здесь же.
///
/// **1. `parseSingboxEntry` кормится ЧИСТОЙ картой.** Модель обязана быть
/// типизированным представлением того, что поедет в ядро; кормить её сырой
/// картой значило бы оставить в ней значения, которые санитайзер только что
/// объявил негодными (мусорный путь транспорта, `short_id` не в hex), и
/// рукописные guard'ы в `json_parsers.dart` пришлось бы держать вторым
/// эшелоном навсегда. Санитайзер здесь единственный судья — ровно как у
/// лаунчера.
///
/// **2. `rawSource` остаётся ССЫЛКОЙ (§454).** `parseSingboxEntry` по
/// умолчанию кладёт в него pretty-print карты; конвейер передаёт исходный
/// текст ссылки. Это не косметика: `rawSource` — то, что человек
/// импортировал, на нём стоит бэкап (§221) и повторный разбор.
///
/// **3. Второй проход по `emit()` (`annotateAllWithRegistry`) НЕ снимается.**
/// Обоснование — в [markPipelineParsed].
library;

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../contract/body_sanitizer.dart';
import '../../contract/registry.dart';
import '../json_parsers.dart';
import '../uri_utils.dart';
import 'trojan_mapper.dart';
import 'uri_mapper.dart';
import 'vless_mapper.dart';
import 'vmess_mapper.dart';

/// Версия ядра, которую санитайзер видит при разборе: гейты, которым она
/// нужна (`min_core`), здесь выключены. То же значение, что в
/// `parse_warnings.dart`.
const _kParseTimeCore = '0.0.0';

/// Схемы, переехавшие на конвейер. Растёт по шагу за протокол; список
/// нормативен для стража покрытия mapper-правил
/// (`test/parser/mapper_rules_coverage_test.dart`).
const kPipelineSchemes = <String>{'trojan', 'vless', 'vmess'};

/// Мапперы переехавших схем, по схеме ссылки.
const Map<String, UriMapper> _kMappers = <String, UriMapper>{
  'trojan': mapTrojanUri,
  'vless': mapVlessUri,
  'vmess': mapVmessUri,
};

/// Разобрать ссылку конвейером, если её схема переехала. `null` — схема ещё
/// идёт старым путём (вызывающий обязан обработать сам) ИЛИ ссылка не
/// разбирается вовсе.
///
/// Различать эти два «null» вызывающему не нужно: `parseUri` выбирает ветку
/// ДО вызова, по имени схемы ([kPipelineSchemes]).
NodeSpec? parseUriViaPipeline(String uri, String scheme) {
  final mapper = _kMappers[scheme];
  if (mapper == null) return null;

  // §472 шаг 4 — маппер получает ИСХОДНЫЙ ТЕКСТ. Общего `Uri.tryParse` здесь
  // больше нет: у vmess и shadowsocks ссылка не URI, и приведение authority к
  // нижнему регистру убивало бы base64 (см. [UriMapper]).
  final mapping = mapper(uri);
  if (mapping == null) return null;

  final warnings = <NodeWarning>[...mapping.warnings];

  // Санитайзер по реестру — единственный судья значений. Гейты `min_core`/
  // `platform` выключены: они зависят от ЗАПУЩЕННОГО ядра, а узел от него не
  // зависит (24.1.6, та же граница, что у W2a и шага 1).
  var body = mapping.body;
  if (ContractRegistry.I.isLoaded) {
    final res = RegistrySanitizer.sanitize(
      body,
      scheme: body['type'] as String,
      coreVersion: _kParseTimeCore,
      applyCoreGates: false,
    );
    // `drop_node` — запись снята целиком: ядро её не принимает, и узла нет.
    if (res.body == null) return null;
    body = res.body!;
    warnings.addAll(res.warnings);
  }

  // §453 — поля, которых реестр не описывает (`dialer.json` → `skipped`),
  // дописываются ПОСЛЕ санитайзера: он снял бы их как `unknown_key` вместе с
  // настройкой человека. Обоснование границы — [UriMapping.extensionFields].
  body.addAll(mapping.extensionFields);

  // Имя узла: `tag` вычисляется из фрагмента общим правилом, как раньше.
  // `parseSingboxEntry` читает `label` из `tag`, поэтому тег кладётся в карту
  // перед вызовом — и снимается санитайзером он не может (ключ сборки).
  final server = body['server']?.toString() ?? '';
  final port = (body['server_port'] as num?)?.toInt() ?? 0;
  body['tag'] = tagFromLabel(mapping.label, scheme, server, port);

  // §454 — `rawSource` узла из ссылки это САМА ССЫЛКА, а не карта.
  // `label` — текст фрагмента, а не тег: ссылка без `#` даёт тег-фолбэк, и
  // подставить его в имя значило бы вернуть выдуманное `#trojan-host-443`
  // из `toUri()`.
  // §103 D-008 — заголовок early data подставлен САМОЙ формой `?ed=N`
  // хвостом пути. В теле этой разницы нет, и знает о ней только маппер:
  // он один видел исходную форму. Знание доносится ДО постройки модели —
  // шаг 2 пересобирал узел после (`_withImplicitEdHeader` ветвился по
  // `TrojanSpec`), и каждая новая схема требовала бы там своей ветки.
  final node = parseSingboxEntry(
    body,
    rawSource: uri,
    label: mapping.label,
    wsEarlyDataHeaderImplicit: mapping.wsEarlyDataHeaderImplicit,
  );
  if (node == null) return null;

  node.warnings.addAll(warnings);
  markPipelineParsed(node);
  return node;
}

/// Узел, разобранный конвейером: его коды реестра уже стоят, по `emit()`
/// второй раз идти незачем.
///
/// **Решение по второму проходу (п. 2 задания шага 2).** Проход по `emit()`
/// (`annotateAllWithRegistry`) НЕ снимается совсем, а ПРОПУСКАЕТСЯ адресно —
/// по этой отметке. Разница существенная:
///
/// - снять проход целиком нельзя: им судятся URI/INI-узлы схем, которые ещё
///   не переехали (двенадцать из тринадцати на шаге 2), и JSON-узлы, где есть
///   значения, поставленные САМИМ разбором;
/// - оставить его на переехавших узлах тоже нельзя, хотя дедуп по
///   `(code, path)` дубли и снял бы. Причина не в дублях, а в `value`:
///   санитайзер конвейера видит СЫРОЕ значение ссылки
///   (`fp=HelloChrome_120`), а проход по `emit()` — уже канонизированное
///   (`chrome`). Первый пришедший выигрывает, то есть дедуп дал бы верный
///   ответ случайно, порядком вызовов. Отметка делает это правилом: у узла
///   конвейера источник кодов ровно один, и `value` называет то, что написал
///   автор ссылки.
///
/// Отметка — [Expando], а не поле модели и не запись в `warnings`.
/// `NodeSpec` это ХРАНИМАЯ форма узла: служебный флаг в ней уехал бы в бэкап
/// (§221) и в `emit()`, то есть в identity-хеш. Expando живёт ровно столько,
/// сколько объект узла в памяти, ничего не сериализует и не мешает GC.
final _pipelineParsed = Expando<bool>('§472 разобран конвейером');

void markPipelineParsed(NodeSpec node) => _pipelineParsed[node] = true;

/// Разобран ли узел конвейером (коды реестра на нём уже стоят).
bool isPipelineParsed(NodeSpec node) => _pipelineParsed[node] == true;
