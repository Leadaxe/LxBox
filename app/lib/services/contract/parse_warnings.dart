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
library;

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
  if (res.warnings.isEmpty) return;

  // Коды, которые узлу уже назвал парсер: рукописное предупреждение о том же
  // сильнее кода реестра.
  final handwritten = <String>{};
  // Пары `{code, path}`, уже стоящие на узле: один и тот же путь дважды
  // конверт контракта не несёт (CANON §6) и человеку он не нужен.
  final seen = <String>{};
  for (final w in node.warnings) {
    final code = warningCodeOf(w);
    if (code == null) continue;
    if (w is RegistryWarning) {
      seen.add('$code ${w.path ?? ''}');
    } else {
      handwritten.add(code);
    }
  }

  for (final w in res.warnings) {
    if (handwritten.contains(w.code)) continue;
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
