import '../services/builder/preset_expand.dart'
    show fragmentGateSatisfied, presetVarsMap;
import 'custom_rule.dart' show CustomRulePreset, kDefaultSrsTtlHours;
import 'parser_config.dart' show SelectableRule;

/// Remote `rule_set` пресета (type=remote + url).
///
/// §366 — живёт в `models/`, а не рядом с экраном Routing: тип нужен и
/// headless-сервису авто-обновления (`RuleSetAutoUpdater`), которому незачем
/// зависеть от слоя UI.
class PresetRemoteRuleSet {
  const PresetRemoteRuleSet({
    required this.tag,
    required this.url,
    this.updateIntervalHours = kDefaultSrsTtlHours,
  });
  final String tag;
  final String url;

  /// §366 — TTL кэша из шаблонного `update_interval` (`"168h"`). В пресетах
  /// значение задаёт шаблон, юзер его не редактирует.
  final int updateIntervalHours;
}

/// §366 — парсинг `update_interval` из шаблона. Формат sing-box'а —
/// duration-строка (`"168h"`, `"7d"`); поле уже стояло у `geoip-ru`, но до
/// §366 вырезалось билдером (`preset_expand`) и нигде не читалось.
///
/// Результат в **часах** с округлением вверх: TTL меньше часа для рулсета
/// бессмысленен, а нулём мы кодируем «никогда» — уронить `"30m"` в `0`
/// значило бы молча выключить обновление.
///
/// Отсутствие поля или мусор → [kDefaultSrsTtlHours] (неделя).
int parseUpdateIntervalHours(dynamic raw) {
  if (raw is num) return raw <= 0 ? 0 : raw.ceil();
  if (raw is! String) return kDefaultSrsTtlHours;
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return kDefaultSrsTtlHours;
  final m = RegExp(r'^(\d+)\s*(h|d|w|m|s)?$').firstMatch(s);
  if (m == null) return kDefaultSrsTtlHours;
  final n = int.tryParse(m.group(1)!);
  if (n == null) return kDefaultSrsTtlHours;
  if (n == 0) return 0; // явный «никогда»
  return switch (m.group(2)) {
    'd' => n * 24,
    'w' => n * 24 * 7,
    // Минуты и секунды округляем вверх до часа (см. выше).
    'm' => (n / 60).ceil(),
    's' => (n / 3600).ceil(),
    _ => n, // 'h' или без единицы
  };
}

/// Список remote `rule_set` пресета (type=remote + url). Пустой если
/// пресет только inline или без rule_set'ов.
///
/// `rule` опционален — если передан, выключенные гейтом наборы отфильтрованы
/// (см. [isRuleSetEnabledFor]: `#enable` §107 и легаси `enabled` §045).
/// Без `rule` — все remote rule_set'ы (для cleanup-операций, когда хотим
/// тронуть все cached files).
///
/// `globalVars` — глобальный userVars (`SettingsStorage.getAllVars()`), нужен
/// гейту на ref-переменной (§265); без `rule` не используется.
///
/// §366 — переехало из `RoutingHelpers` (осталось там реэкспортом): нужно
/// headless-сервису авто-обновления, зависимости от UI у функции нет.
List<PresetRemoteRuleSet> remoteRuleSetsOfPreset(
  SelectableRule preset, [
  CustomRulePreset? rule,
  Map<String, String> globalVars = const {},
]) {
  final out = <PresetRemoteRuleSet>[];
  for (final rs in preset.ruleSets) {
    if (rs['type'] != 'remote') continue;
    final tag = rs['tag'];
    final url = rs['url'];
    if (tag is! String || tag.isEmpty) continue;
    if (url is! String || url.isEmpty) continue;
    if (rule != null &&
        !isRuleSetEnabledFor(rs, preset, rule, globalVars: globalVars)) {
      continue;
    }
    out.add(PresetRemoteRuleSet(
      tag: tag,
      url: url,
      updateIntervalHours: parseUpdateIntervalHours(rs['update_interval']),
    ));
  }
  return out;
}

/// Включён ли гейтом `rule_set` пресета для правила `rule`.
///
/// Гейт — обе формы, как у билдера: канонический `#enable` (§107, условие
/// через `evalCond`) и легаси `enabled` (§045: строка `"@var"` или bool).
/// Обе присутствуют → and. Ни одной → always-on.
///
/// §534 — одна семантика с билдером: тот же предикат
/// (`fragmentGateSatisfied`) на том же словаре переменных (`presetVarsMap`:
/// vars пресета, ref-vars из `globalVars` §265, `globalVars` как fallback
/// §264). До §534 хелпер сам разбирал только `enabled: "@var"`, `#enable` не
/// видел — путь скачивания и экран Routing считали такой набор всегда
/// включённым. Легаси `"@var"` с необъявленной переменной теперь «выключен»,
/// как у билдера (было «включён»): набор, который в конфиг не попадёт,
/// качать незачем.
///
/// Ошибка словаря (не заполнена required-переменная) игнорируется: билдер
/// такой пресет не выпустит вовсе, гейт вычисляется на частичном словаре.
bool isRuleSetEnabledFor(
  Map<String, dynamic> rs,
  SelectableRule preset,
  CustomRulePreset rule, {
  Map<String, String> globalVars = const {},
}) =>
    fragmentGateSatisfied(
      rs,
      presetVarsMap(rule, preset, globalVars: globalVars).vars,
    );
