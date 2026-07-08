import '../../config/consts.dart' show kBlockOutboundTag, kDirectOutboundTag;
import '../../models/channel.dart';
import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';

/// Remote `rule_set` пресета (type=remote + url).
class PresetRemoteRuleSet {
  const PresetRemoteRuleSet({required this.tag, required this.url});
  final String tag;
  final String url;
}

/// Outbound-опция для селекторов на экране Routing.
class RoutingOutboundOption {
  const RoutingOutboundOption({
    required this.label,
    required this.tag,
    this.danger = false,
  });
  final String label;
  final String tag;

  /// §201 — рисовать красным (block, по аналогии с reject в правилах).
  final bool danger;
}

/// Sentinel для `firstWhere(..., orElse: ...)` lookups — содержимое игнорируется,
/// caller проверяет `label.isEmpty` после поиска. `presetId` обязательный
/// (§067), кладём marker который заведомо никогда не матчится в реальных
/// preset_id.
final SelectableRule kEmptySelectable =
    SelectableRule(label: '', presetId: '__empty_sentinel__');

/// Pure-функции экрана Routing (без доступа к State). Вынесены из
/// `_RoutingScreenState` чтобы ужать сам экран — поведение идентично.
class RoutingHelpers {
  const RoutingHelpers._();

  /// §125 — outbound-опции для селекторов экрана Routing из списка каналов
  /// (storage). vpn-1 всегда присутствует (required-инвариант), выключенные
  /// каналы скрыты. §248 — detour-канал не цель правил/route final (роли
  /// применения взаимоисключающие): в опции не попадает; единственная точка
  /// закрывает route final, тайлы правил, редактор правила и outbound-var
  /// пресетов. §201 — block всегда доступен (системный), красный как reject;
  /// держим его последним, direct — первым.
  static List<RoutingOutboundOption> outboundOptions(List<Channel> channels) {
    final opts = <RoutingOutboundOption>[
      const RoutingOutboundOption(label: 'direct', tag: kDirectOutboundTag),
    ];
    for (final c in channels) {
      if (c.isDetour) continue;
      if (c.enabled || c.isRequired) {
        opts.add(RoutingOutboundOption(
            label: c.label.isNotEmpty ? c.label : c.tag, tag: c.tag));
      }
    }
    opts.add(const RoutingOutboundOption(
        label: 'block', tag: kBlockOutboundTag, danger: true));
    return opts;
  }

  /// Список remote `rule_set` пресета (type=remote + url). Пустой если
  /// пресет только inline или без rule_set'ов.
  ///
  /// `rule` опционален — если передан, фильтруются rule_set'ы выключенные
  /// через `enabled: "@var"` гейтинг (§045). Без `rule` — все remote
  /// rule_set'ы (для cleanup-операций когда хотим тронуть все cached files).
  static List<PresetRemoteRuleSet> remoteRuleSetsOf(
    SelectableRule preset, [
    CustomRulePreset? rule,
  ]) {
    final out = <PresetRemoteRuleSet>[];
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      final url = rs['url'];
      if (tag is! String || tag.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      if (rule != null && !isRuleSetEnabled(rs, preset, rule)) continue;
      out.add(PresetRemoteRuleSet(tag: tag, url: url));
    }
    return out;
  }

  /// Резолв `rule_set.enabled` (§045). Поле может быть string substitution
  /// (`"@varname"`), bool literal, или отсутствовать (= always-on).
  static bool isRuleSetEnabled(
    Map<String, dynamic> rs,
    SelectableRule preset,
    CustomRulePreset rule,
  ) {
    final raw = rs['enabled'];
    if (raw == null) return true;
    if (raw is bool) return raw;
    if (raw is String) {
      String resolved = raw;
      if (raw.startsWith('@')) {
        final varName = raw.substring(1);
        final v = preset.vars.firstWhere(
          (x) => x.name == varName,
          orElse: () => WizardVar(name: '', type: '', defaultValue: 'true'),
        );
        final def = v.defaultValue.isNotEmpty ? v.defaultValue : 'true';
        // §265 — ref-var: значение в глобальном userVars, не в varsValues.
        // Pure-хелпер userVars не читает → fallback на default (defensive:
        // rule_set.enabled-гейты используют dns_enable-паттерн, не ref).
        if (v.isRef) {
          resolved = def;
        } else {
          final stored = rule.varsValues[varName];
          resolved = (stored != null && stored.isNotEmpty) ? stored : def;
        }
      }
      return resolved.toLowerCase() == 'true';
    }
    return true;
  }

  /// Composite ключ для `_srsCached` / `_srsDownloading` у preset-rule_set'ов.
  /// У `CustomRuleSrs` там просто `rule.id`; у preset'ов — `<id>|<tag>`,
  /// чтобы не путаться между несколькими rule_set'ами одного пресета.
  static String presetSrsKey(CustomRulePreset rule, String tag) =>
      '${rule.id}|$tag';

  /// `true` если у preset-правила есть remote rule_set'ы и хотя бы один из
  /// них НЕ закэширован. Используется для disabled-switch (switch auto-
  /// download'ит при toggle-on) и для выбора иконки ☁/✅.
  static bool presetNeedsDownload(
    CustomRulePreset rule,
    SelectableRule preset,
    Set<String> srsCached,
  ) {
    final remotes = remoteRuleSetsOf(preset, rule); // §045: enabled-gating
    if (remotes.isEmpty) return false;
    for (final rs in remotes) {
      if (!srsCached.contains(presetSrsKey(rule, rs.tag))) return true;
    }
    return false;
  }

  static String presetOut(CustomRule rule, SelectableRule? preset) {
    final explicit = rule.varsValues['outbound'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (preset == null) return kDirectOutboundTag;
    for (final v in preset.vars) {
      if (v.name == 'outbound') return v.defaultValue;
    }
    // §246: rule может быть массивом — outbound-дефолт несёт терминальный
    // элемент (resolve/sniff — промежуточные, у них outbound'а нет).
    final action = preset.terminalRule['action'];
    if (action is String && action.isNotEmpty) return action;
    final literal = preset.terminalRule['outbound'];
    if (literal is String && literal.isNotEmpty && !literal.startsWith('@')) {
      return literal;
    }
    return kDirectOutboundTag;
  }

  static String ruleSubtitle(CustomRule rule, SelectableRule? preset) {
    if (rule.kind == CustomRuleKind.preset) {
      if (preset == null) return 'Preset not found — tap to fix';
      // §045: только non-default vars; preset.label дублирует title (rule.name)
      final extras = <String>[];
      for (final v in preset.vars) {
        // §265 — ref-var: её значение в ГЛОБАЛЬНОМ userVars, не в varsValues.
        // Subtitle читает varsValues → показал бы застрявшее/неверное значение
        // (напр. resolve_enabled: true, когда глобаль уже false). Ref-vars из
        // подписи исключаем — их состояние не место в subtitle правила.
        if (v.isRef) continue;
        // §266 — hidden-var (rule_enable и т.п.) служебная, не для показа.
        if (v.wizardUI == 'hidden') continue;
        final value = rule.varsValues[v.name] ?? v.defaultValue;
        if (value.isEmpty || value == v.defaultValue) continue;
        extras.add('${v.name}: $value');
      }
      if (extras.isEmpty) return 'Tap to edit';
      return '${extras.take(2).join(' · ')} — tap to edit';
    }
    final summary = rule.summary;
    return summary.isEmpty
        ? 'Tap to add match fields'
        : '$summary — tap to edit';
  }

  static String uniqueCustomRuleName(
    String requested,
    String selfId,
    List<CustomRule> customRules,
  ) {
    final others = customRules
        .where((r) => r.id != selfId)
        .map((r) => r.name)
        .toSet();
    if (!others.contains(requested)) return requested;
    var i = 2;
    while (others.contains('$requested ($i)')) {
      i++;
    }
    return '$requested ($i)';
  }
}
