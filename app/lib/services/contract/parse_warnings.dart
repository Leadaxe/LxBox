/// §460 W2a — предупреждения реестра на узле в момент РАЗБОРА.
///
/// W1 повесил санитайзер на сборку конфига: мусор снимался, но пользователь
/// узнавал о нём только в отчёте сборки, а строка узла в списке подписки
/// молчала. W2a добавляет второй прогон — над `emit()` уже разобранного
/// узла, — и его предупреждения уезжают в `NodeSpec.warnings`, где их и
/// показывает ⚠ (`NodeWarningRow`).
///
/// Три границы волны:
///
/// 1. **Тело узла не меняется.** Санитайзер здесь работает только как
///    наблюдатель: `emit()` вызывается на копии, результат очистки
///    выбрасывается. Чистит по-прежнему гард сборки — узел в хранении обязан
///    остаться тем, что прислал провайдер (§455: JSON-источник дословно).
/// 2. **Гейты ядра выключены** (`applyCoreGates: false`, 24.1.6): `min_core`
///    и `platform` зависят от запущенного ядра, а `entry` узла — нет. Поле,
///    которого ядро «пока не знает», при разборе не повод для ⚠.
/// 3. **Дедуп с рукописными кодами.** Правила значений сегодня живут в
///    URI-парсерах (спека §2.5, снятие — после цикла наблюдения), и на одно
///    и то же поле узел получил бы два сообщения: своё от парсера и код от
///    реестра. Рукописное сильнее: у него человеческий текст и место в
///    корпусе.
///
/// Реестр не загружен — весь модуль no-op.
///
/// §472 шаг 1 снял границу 1 для JSON-входа: у узла, пришедшего телом, есть
/// ДОСЛОВНАЯ карта провайдера (`rawSource`, §455), и санитайзер идёт по ней —
/// см. [annotateFromRawBody]. Тело узла по-прежнему не меняется: очищенная
/// карта выбрасывается, берутся только коды.
library;

import 'dart:convert';

import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../models/template_vars.dart';
import '../parser/mappers/uri_pipeline.dart' show isPipelineParsed;
import 'body_sanitizer.dart';
import 'registry.dart';
import 'warning_codes.dart';

/// Версия ядра, которую санитайзер видит при разборе.
///
/// Значения у неё нет: гейты, которым версия нужна (`min_core`), при разборе
/// выключены. Пустая строка была бы честнее, но `coreAtLeast` её не ждёт, а
/// заводить ради выключенной ветки третий режим — лишнее.
const _kParseTimeCore = '0.0.0';

/// Дописать узлу предупреждения реестра.
///
/// Рекурсивно спускается в `chained` — детур-звено это тот же узел со своим
/// телом, и мусор в нём валит конфиг ровно так же.
void annotateWithRegistry(NodeSpec node) {
  if (!ContractRegistry.I.isLoaded) return;

  final chained = node.chained;
  if (chained != null) annotateWithRegistry(chained);

  // Группы (§322) тела узла не имеют — санитайзеру там нечего смотреть.
  if (node.isGroup) return;

  // §472 шаг 2 — узел, разобранный конвейером, санитайзер уже прошёл: по
  // СЫРОЙ карте ссылки, до всякой нормализации. Второй проход по `emit()`
  // дал бы те же коды, но с `value` уже канонизированным (`chrome` вместо
  // написанного автором `HelloChrome_120`), и какой из двух останется,
  // решал бы порядок вызовов, а не правило. Источник кодов у такого узла
  // один — см. `mappers/uri_pipeline.dart`, `markPipelineParsed`.
  if (isPipelineParsed(node)) return;

  final Map<String, dynamic> body;
  try {
    body = Map<String, dynamic>.from(node.emit(TemplateVars.empty).map);
  } catch (_) {
    // Эмит узла падать не должен, но разбор подписки из-за одного узла
    // падать не должен тем более.
    return;
  }

  final type = body['type'];
  if (type is! String) return;

  final res = RegistrySanitizer.sanitize(
    body,
    scheme: type,
    coreVersion: _kParseTimeCore,
    applyCoreGates: false,
    // §473 — вход у ОБОИХ проходов один: он свойство УЗЛА, а не прохода.
    // Разойдись они, узел из sing-box-тела получил бы по дословной карте info
    // `awg_mtu_high`, а следом по `emit()` — warning `awg_mtu_clamped` о том
    // же поле: коды разные, дедуп по паре `(code, path)` их не схлопнет, и
    // человек прочёл бы два противоположных сообщения об одном `mtu`.
    source: bodySourceOf(node),
  );
  _mergeRegistryWarnings(node, res.warnings);
}

/// §472 шаг 1 — предупреждения реестра по ДОСЛОВНОЙ карте JSON-узла.
///
/// [annotateWithRegistry] судит `emit()` уже разобранного узла, и мусор к
/// этому моменту снят типизированным парсером: `flow=xtls-rprx-direct` не
/// доехал до поля, `tls.insecure` снял `_tlsFromSingbox`, а ключ вне схемы
/// (`totally_unknown_key`) не имеет куда попасть в принципе. Такой узел
/// оставался БЕЗ кодов, хотя пользователю есть что сказать: коды этих полей
/// знал только гард сборки (§455, `registry_gate.dart`), и человек видел их в
/// отчёте сборки, а не в строке узла (§470).
///
/// У JSON-входа дословная карта есть — это `rawSource` (§454–§456), объект
/// outbound'а как прислал провайдер. Санитайзер идёт по ней, и его коды с
/// путём и значением встают на узел. Это ровно тот конвейер, что у лаунчера:
/// вход → карта sing-box → санитайзер по реестру.
///
/// Границы шага те же, что у W2a: **тело узла не меняется** (очищенная карта
/// выбрасывается — чистит по-прежнему гард сборки, узел в хранении обязан
/// остаться тем, что прислал провайдер), **гейты ядра выключены**
/// (`min_core`/`platform` зависят от запущенного ядра, а `entry` узла — нет).
///
/// Xray-JSON сюда НЕ попадает: у таких узлов `rawSource` — объект **Xray**
/// (`json_parsers.dart`, `_prettyJson(o)`), а санитайзер судит карту
/// **sing-box**, и ключи у них разные (`streamSettings` против `transport`,
/// `settings.vnext[].users[]` против `uuid`). Дословной sing-box-карты у
/// Xray-узла нет, пока её не построит маппер — это шаг 8 спеки 472. Здесь
/// такая карта была бы выдумкой, а `path`/`value` кода обязаны называть то,
/// что лежало в теле.
/// §477 — возвращает `true`, если реестр велел снять ЗАПИСЬ ЦЕЛИКОМ
/// (`on_invalid: drop_node`). Вызывающий (`parseAll`) убирает такой узел из
/// списка и кладёт причину в `dropped[]`.
bool annotateFromRawBody(NodeSpec node) {
  if (!ContractRegistry.I.isLoaded) return false;

  final chained = node.chained;
  if (chained != null) annotateFromRawBody(chained);

  if (node.isGroup) return false;

  // §472 шаг 8 — узел конвейера санитайзер уже прошёл, по карте, которую
  // построил маппер. Второй раз идти незачем, и та же отметка избавляет от
  // разбора `rawSource`: у Xray-узла это ОБЪЕКТ XRAY, и `jsonDecode` на нём
  // отрабатывал впустую на каждом узле подписки — только чтобы убедиться,
  // что поля `type` в нём нет.
  if (isPipelineParsed(node)) return false;

  final raw = _rawSingboxBodyOf(node);
  if (raw == null) return false;
  final type = raw['type'];
  if (type is! String) return false;

  final res = RegistrySanitizer.sanitize(
    // Копия: санитайзер переписывает карту, а `rawSource` узла — текст
    // провайдера, и трогать его нельзя.
    Map<String, dynamic>.from(raw),
    scheme: type,
    coreVersion: _kParseTimeCore,
    applyCoreGates: false,
    // §473 — этот проход по построению идёт по телу в форме ядра: карта
    // sing-box, которую написал автор узла. Это и есть вход `singbox`.
    source: BodySource.singbox,
  );
  _mergeRegistryWarnings(node, res.warnings);
  // Вердикт уезжает наружу; тело узла и здесь не меняется (границы шага 1 в
  // силе).
  //
  // Именно `explicitDropNode`, а не `body == null`: запись снимает и
  // недостающее обязательное поле, но такой узел приложение показывает с
  // самого начала и снимает только на сборке. Снести его при разборе значило
  // бы тихо поменять поведение целого класса узлов — §477 этого не решал.
  return res.explicitDropNode;
}

/// §473 — вход, которым приехало тело узла.
///
/// Признак ровно тот же, по которому [annotateFromRawBody] опознаёт свою
/// карту: `rawSource` — JSON-объект с полем `type`. Второго признака заводить
/// нельзя — два ответа на вопрос «чей это вход» разошлись бы, и узел получил
/// бы разные правила на разных проходах.
///
/// Вход СТАБИЛЕН и потому переживает перезапуск: `rawSource` — то, что лежит
/// в хранении (§454–§456), и разбор идёт заново при каждой загрузке. Считай
/// мы вход из чего-то, что живёт только в сессии (флаг импорта, путь вызова),
/// узел с `mtu: 1420` получил бы кламп задним числом при следующем старте —
/// настройка человека исчезла бы молча.
///
/// Xray-JSON сюда не попадает: у него `rawSource` — объект Xray, где тип
/// записи зовётся `protocol` (см. [annotateFromRawBody], шаг 8 спеки 472).
BodySource bodySourceOf(NodeSpec node) =>
    _rawSingboxBodyOf(node)?['type'] is String
        ? BodySource.singbox
        : BodySource.other;

/// Дословное тело JSON-узла как карта sing-box, либо `null`.
///
/// `rawSource` у URI-узла — ссылка, у INI — текст конфига, у Xray — объект
/// Xray: ни то, ни другое, ни третье санитайзеру sing-box-схемы не карта.
/// Единственный признак, по которому JSON-вход опознаётся, — сам JSON-объект
/// с полем `type` (его проверяет вызывающий): `type` есть у sing-box и нет у
/// Xray, где тип записи зовётся `protocol`.
Map<String, dynamic>? _rawSingboxBodyOf(NodeSpec node) {
  final src = node.rawSource.trimLeft();
  if (!src.startsWith('{')) return null;
  try {
    final v = jsonDecode(src);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    // Битый JSON в `rawSource` — не повод ронять разбор подписки.
    return null;
  }
}

/// Дописать узлу коды реестра, не задвоив уже сказанное.
///
/// Дедуп — по паре `(code, path)`: конверт контракта одну и ту же пару дважды
/// не несёт (CANON §6), и человеку второе сообщение о том же поле не нужно.
///
/// Рукописный класс сильнее кода реестра: у него человеческий текст и место в
/// корпусе. Но «сильнее» считается ПО ПУТИ, а не по одному коду: рукописный
/// класс, который путь несёт (`flow` у `DeprecatedFlowWarning`), закрывает
/// только свой путь, а код реестра о другом поле с тем же кодом остаётся.
/// Классы без пути (их большинство: путь знают пятнадцать из них,
/// `corpus_warnings.dart`) закрывают код целиком — иначе на одном поле
/// оказались бы два сообщения, рукописное без адреса и реестровое с адресом.
/// Оставляется ОДНА запись, и предпочтение у той, что несёт путь: адрес поля
/// — это то, чего человеку не хватало (§470, `unknown_key` без `value`).
void _mergeRegistryWarnings(NodeSpec node, List<RegistryWarning> incoming) {
  if (incoming.isEmpty) return;

  // Коды рукописных классов, не назвавших поля: такой класс закрывает свой код
  // целиком — приписать ему путь здесь было бы выдумкой.
  final handwrittenAnywhere = <String>{};
  // Пары `(code, path)`, уже стоящие на узле.
  final seen = <String>{};
  for (final w in node.warnings) {
    final code = warningCodeOf(w);
    if (code == null) continue;
    if (w is RegistryWarning) {
      seen.add('$code ${w.path ?? ''}');
    } else {
      final path = handwrittenWarningPath(w);
      if (path == null) {
        handwrittenAnywhere.add(code);
      } else {
        seen.add('$code $path');
      }
    }
  }

  for (final w in incoming) {
    if (handwrittenAnywhere.contains(w.code)) continue;
    if (!seen.add('${w.code} ${w.path ?? ''}')) continue;
    node.warnings.add(w);
  }
}

/// То же для списка узлов — форма, в которой работает `parseAll`.
void annotateAllWithRegistry(List<NodeSpec> nodes) {
  if (!ContractRegistry.I.isLoaded) return;
  for (final n in nodes) {
    annotateWithRegistry(n);
  }
}

/// §472 шаг 1 — [annotateFromRawBody] для списка узлов.
///
/// §477 — возвращает узлы, которым реестр вынес `drop_node`: их запись ядро не
/// примет, и оставить их в списке значило бы отдать ядру конфиг, на котором
/// оно не стартует. Убирает их из списка не этот модуль, а `parseAll`: ему же
/// принадлежит `dropped[]`, куда уезжает причина.
List<NodeSpec> annotateAllFromRawBody(List<NodeSpec> nodes) {
  if (!ContractRegistry.I.isLoaded) return const [];
  final dropped = <NodeSpec>[];
  for (final n in nodes) {
    if (annotateFromRawBody(n)) dropped.add(n);
  }
  return dropped;
}
