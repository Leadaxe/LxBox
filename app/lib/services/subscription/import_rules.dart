import '../../models/import_rule.dart';
import '../parser/body_decoder.dart';

/// §302 — результат применения import-rules к декодированному телу (этап A).
///
/// - [body] — переписанное тело для `parseAll` (REPLACE применён). Тот же
///   вариант `DecodedBody`, что на входе (структура сохранена).
/// - [disabledLines] — строки (в их ПОСЛЕзаменном виде), совпавшие с
///   DISABLE-правилом. Этап B (контроллер) парсит их через `parseUri` и
///   выключает соответствующие ноды через §283. Пусто для не-URI тел.
/// - [originByRewritten] — карта `послезаменная строка → оригинал` только для
///   строк, которые REPLACE реально изменил. Контроллер кладёт оригинал в
///   `NodeSpec.originLine` (матч по `rawUri`) для UI-значка/diff. Пусто, если
///   ни одна строка не изменилась.
class ImportRulesResult {
  final DecodedBody body;
  final Set<String> disabledLines;
  final Map<String, String> originByRewritten;

  const ImportRulesResult(
    this.body, {
    this.disabledLines = const {},
    this.originByRewritten = const {},
  });
}

/// Применяет [rules] к декодированному телу подписки (этап A pipeline'а).
///
/// Семантика (согласовано §302):
/// - **REPLACE** переписывает текст (все вхождения, literal/regex/caseSensitive
///   по правилу). Для `UriLines` — построчно; для INI/JSON/Amnezia — по всему
///   блоку текста (это один «конфиг», не список нод).
/// - **DISABLE** НЕ удаляет строку (нода должна завестись и быть видна
///   зачёркнутой) — только помечает её послезаменный вид в [disabledLines].
///   Применяется лишь к `UriLines` (построчная нода ↔ строка); для INI/JSON
///   понятия «строка-нода» нет — DISABLE там игнорируется.
/// - Правила идут по порядку; для каждой строки сначала прогоняются ВСЕ
///   replace (сверху вниз), затем проверяются disable — на послезаменном виде.
/// - Битое/выключенное правило пропускается (`ImportRule.isUsable`).
///
/// Pure: без сети, без стораджа. Пустой [rules] → тело как есть, пустые сеты.
ImportRulesResult applyImportRules(DecodedBody decoded, List<ImportRule> rules) {
  final usable = rules.where((r) => r.isUsable).toList();
  if (usable.isEmpty) return ImportRulesResult(decoded);

  final replaces =
      usable.where((r) => r.action == ImportRuleAction.replace).toList();
  final disables =
      usable.where((r) => r.action == ImportRuleAction.disable).toList();

  switch (decoded) {
    case UriLines(lines: final lines, skippedComments: final skipped):
      final out = <String>[];
      final disabledLines = <String>{};
      final originByRewritten = <String, String>{};
      for (final original in lines) {
        final rewritten = _applyReplaces(original, replaces);
        if (rewritten != original) originByRewritten[rewritten] = original;
        out.add(rewritten);
        // DISABLE — по послезаменной строке (порядок: replace раньше disable).
        for (final d in disables) {
          if (d.compiledPattern!.hasMatch(rewritten)) {
            disabledLines.add(rewritten);
            break;
          }
        }
      }
      return ImportRulesResult(
        UriLines(out, skipped),
        disabledLines: disabledLines,
        originByRewritten: originByRewritten,
      );

    // INI / Amnezia / JSON — единый блок текста, «строка-нода» отсутствует.
    // REPLACE переписывает текст целиком; DISABLE неприменим (см. док).
    case IniConfig(text: final t):
      final r = _applyReplaces(t, replaces);
      return ImportRulesResult(r == t ? decoded : IniConfig(r));
    case AmneziaConfig(iniTexts: final ts):
      var changed = false;
      final out = [
        for (final t in ts)
          () {
            final r = _applyReplaces(t, replaces);
            if (r != t) changed = true;
            return r;
          }()
      ];
      return ImportRulesResult(changed ? AmneziaConfig(out) : decoded);
    case JsonConfig():
    case DecodeFailure():
      // JSON-тело — структура, не текст-строки; REPLACE по «строкам» здесь
      // семантически не определён (ноды — элементы, не строки). Не трогаем.
      return ImportRulesResult(decoded);
  }
}

/// Прогоняет все REPLACE-правила по одной строке по порядку. Каждое —
/// `replaceAll` (все вхождения). `compiledPattern` уже отфильтрован на
/// `isUsable` (не null).
String _applyReplaces(String line, List<ImportRule> replaces) {
  var s = line;
  for (final r in replaces) {
    s = s.replaceAll(r.compiledPattern!, r.replacement);
  }
  return s;
}
