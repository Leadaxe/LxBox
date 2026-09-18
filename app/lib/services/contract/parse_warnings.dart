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
