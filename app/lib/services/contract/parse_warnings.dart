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
import '../../models/tls_spec.dart';
import 'body_sanitizer.dart';
import 'registry.dart';
import 'warning_codes.dart';

/// §469 — предупреждения о TLS-блоках, которые схема узла запрещает, для
/// путей, где санитайзер до них не дотягивается.
///
/// Граница волны W2a: санитайзер при разборе смотрит на `emit()` уже
/// разобранного узла. У QUIC-схем (hysteria2, tuic) `emit()` зовёт
/// [TlsSpec.toSingboxForQuic], и `utls`/`reality` в теле не появляются вовсе
/// — значит правило реестра `forbidden_for` на них не срабатывает и узел
/// остаётся без кода, хотя пользователь задал `fp=`. Срез при этом менять
/// нельзя: тело узла нормировано корпусом и обязано остаться без блоков.
///
/// Поэтому код ставит парсер — но НЕ своим списком схем. Какие схемы и какой
/// код, решает реестр (`tls.json body.fields.utls/reality` → `forbidden_for`
/// + `forbidden_codes`): второй копии правила в Dart не заводится, иначе оно
/// разошлось бы с контрактом на первом же бампе. Правило снимется само,
/// когда эмиссия переедет на реестр и блоки доедут до санитайзера.
///
/// [blocks] — блоки, которые НЕСЛА ссылка или тело, в форме sing-box
/// (`utls` → `{enabled: true, fingerprint: …}`, `reality` →
/// [RealitySpec.toSingbox]). Отсутствие блока в карте значит «его не
/// просили»: кода без просьбы не бывает. Блоки передаются картой, а не
/// [TlsSpec], нарочно — класть запрещённый REALITY в модель QUIC-узла
/// значило бы тащить его через равенство, identity-хеш и правила
/// `normalizeTlsFingerprint` (там REALITY заводит свои коды) ради значения,
/// которое всё равно никуда не эмитится.
///
/// Реестр не загружен — пустой список: молчание лучше выдуманного кода.
List<NodeWarning> forbiddenTlsBlockWarnings(
  String scheme,
  Map<String, Map<String, dynamic>> blocks,
) {
  // Список ВСЕГДА растущий, даже пустой: он уезжает в `NodeSpec.warnings`,
  // куда потом дописывает санитайзер разбора (`annotateWithRegistry`), а
  // `const []` там обернулся бы «Cannot add to an unmodifiable list».
  final out = <NodeWarning>[];
  if (blocks.isEmpty) return out;
  final schema = ContractRegistry.I.sharedSchema('tls');
  if (schema == null) return out;

  // Порядок — `order` схемы TLS: тот же, по которому идёт санитайзер, и тот
  // же, в котором коды стоят в ожиданиях корпуса.
  for (final key in schema.order) {
    final value = blocks[key];
    if (value == null || value.isEmpty) continue;
    final f = schema.fields[key];
    if (f == null) continue;
    if (f.forbiddenFor?.contains(scheme) != true) continue;
    final code = f.forbiddenCodeFor(scheme);
    if (code == null) continue;
    // Значение печатается ТЕМ ЖЕ рендером, что у санитайзера: `value` в
    // конверте — канон записи, и две формы печати одного блока расходились
    // бы между путями разбора.
    out.add(RegistryWarning(
      code: code,
      path: 'tls.$key',
      value: RegistrySanitizer.renderWarningValue(value, secret: f.secret),
    ));
  }
  return out;
}

/// §469 — блок `tls.utls` в форме sing-box из отпечатка ссылки/тела; пустой
/// отпечаток блока не даёт (ядро берёт свой дефолт, а не заданное значение).
Map<String, Map<String, dynamic>> utlsBlockOf(String? fingerprint) =>
    (fingerprint ?? '').isEmpty
        ? const {}
        : {
            'utls': <String, dynamic>{
              'enabled': true,
              'fingerprint': fingerprint,
            },
          };

/// §469 — блоки `utls`/`reality` ИЗ СЫРОЙ карты `tls` тела узла, как их
/// прислал провайдер. Для JSON-входа это точнее любой реконструкции из
/// модели: `value` кода обязан назвать то, что было в теле, а модель к этому
/// моменту уже нормализовала отпечаток и могла отбросить негодный REALITY.
Map<String, Map<String, dynamic>> tlsBlocksOfBody(Object? rawTls) {
  if (rawTls is! Map) return const {};
  final out = <String, Map<String, dynamic>>{};
  for (final key in const ['utls', 'reality']) {
    final block = rawTls[key];
    if (block is Map && block.isNotEmpty) {
      out[key] = block.cast<String, dynamic>();
    }
  }
  return out;
}

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
void annotateFromRawBody(NodeSpec node) {
  if (!ContractRegistry.I.isLoaded) return;

  final chained = node.chained;
  if (chained != null) annotateFromRawBody(chained);

  if (node.isGroup) return;

  final raw = _rawSingboxBodyOf(node);
  if (raw == null) return;
  final type = raw['type'];
  if (type is! String) return;

  final res = RegistrySanitizer.sanitize(
    // Копия: санитайзер переписывает карту, а `rawSource` узла — текст
    // провайдера, и трогать его нельзя.
    Map<String, dynamic>.from(raw),
    scheme: type,
    coreVersion: _kParseTimeCore,
    applyCoreGates: false,
  );
  _mergeRegistryWarnings(node, res.warnings);
}

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
void annotateAllFromRawBody(List<NodeSpec> nodes) {
  if (!ContractRegistry.I.isLoaded) return;
  for (final n in nodes) {
    annotateFromRawBody(n);
  }
}
