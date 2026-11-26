import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../models/rule_tree.dart';
import 'builder/post_steps.dart' show customRuleAxisTags;
import 'rule_display_names.dart';

/// §165 — резолвер человекочитаемого имени правила для Stats/Conns.
///
/// ПРОБЛЕМА: ядро в `connection.rule` (`rule.String()`) отдаёт условия через
/// пробел БЕЗ имени правила, и списки >3 элементов ОБРЕЗАЕТ (`[a b c...]`).
/// Парсить/предсказывать строку байт-в-байт ненадёжно.
///
/// РЕШЕНИЕ (вариант C): строим соответствие «строка правила → title» из
/// `custom_rules` (знаем И условия, И name). Матч устойчив к обрезке/формату:
///   1. нормализуем обе стороны (схлопнуть пробелы, убрать переносы)
///   2. ядровая строка обрезана → её префикс (до `...`) ⊂ нашей полной → indexOf
///   3. кэшируем `c.rule → title` (И промахи) — `ruleName` зовётся в цикле
///      ×10/сек (FAST), без кэша = фриз. Сброс кэша при смене правил (stop VPN).
///
/// §757 — правило пользователя выпускает наборы (ссылки и inline-набор
/// узла с доменами / адресами), и ядро печатает его `rule_set=<теги>`;
/// поэтому первым идёт матч по тегам наборов правила (схема §6.13 тем же
/// расчётом, что у сборки), затем — по строкам условий (правило без
/// наборов; у правила с группами — по строке на простой узел).
class RuleNameResolver {
  RuleNameResolver._();
  static final RuleNameResolver I = RuleNameResolver._();

  /// Кэш: сырой `c.rule` → итоговое имя (title ИЛИ fallback). Промахи тоже
  /// кэшируются, чтобы не пересчитывать каждый тик.
  final Map<String, String> _cache = {};

  /// Эталонные нормализованные строки правил: строки → title. Перестраивается
  /// при `setRules` (смена конфига) и `relocalize` (смена локали). У плоского
  /// правила строка одна; §757 — у правила с группами по строке на простой
  /// узел, матч — все строки входят в строку ядра.
  final List<({List<String> norms, String title})> _rules = [];

  /// §757 — тег набора правила пользователя (база, ссылки, inline-наборы
  /// узлов; схема §6.13, тот же расчёт, что у сборки) → display-титул.
  /// Правило с наборами ядро печатает `rule_set=<теги>`, а у правила с
  /// группами — дерево листьев через `&&` / `||`, поэтому тег — главный
  /// признак. Длинные теги первыми: тег `X:ads` не путается с `X`.
  final List<({String tag, String title})> _userTags = [];

  /// §279 — исходный список правил последнего [setRules]: relocalize
  /// пере-дерайвит из него display-титулы под новый шаблон.
  List<CustomRule> _sourceRules = const [];

  /// §279 — preset-label-часть зеркал: rule_set-tag пресета → display-титул
  /// правила-владельца. Preset-правила не несут match-полей (их условия живут
  /// в шаблоне), kernel-строка матчится rule_set-фолбэком — без этой мапы
  /// Stats показывал бы сырой тег вместо live-label'а пресета.
  final Map<String, String> _ruleSetTagTitles = {};

  /// §165 — задать актуальные правила (из `getCustomRules()`). Сбрасывает кэш
  /// (строки правил сменились → старые соответствия невалидны). Зовётся на
  /// connect / смену конфига.
  ///
  /// §279 — [template] (локализованный, `TemplateLoader.cachedOrNull()`) даёт
  /// live-label'ы preset-правил + порядковую дизамбигуацию копий; null —
  /// fallback на сохранённые `name`-снапшоты.
  void setRules(List<CustomRule> rules, {WizardTemplate? template}) {
    _sourceRules = List.of(rules);
    _rebuild(template);
  }

  /// §165 — сброс при stop VPN (правила могут смениться к следующему запуску).
  void clear() {
    _cache.clear();
    _rules.clear();
    _ruleSetTagTitles.clear();
    _userTags.clear();
    _sourceRules = const [];
  }

  /// §279 (§3.5.4) — смена локали: пере-дерайв preset-label-частей зеркал из
  /// сохранённых custom_rules + свежелокализованного [template] + сброс
  /// мемоизации. Зовётся из LocaleController._applyLocale после прогрева
  /// шаблона, БЕЗ касания конфига (никакого markConfigDirty — условия правил
  /// не меняются, только display-титулы).
  void relocalize(WizardTemplate? template) {
    _rebuild(template);
  }

  /// Перестроить эталонные строки `norm → title` + мапу rule_set-тегов
  /// пресетов из [_sourceRules] с display-титулами по [template]; сбросить
  /// мемо-кэш.
  void _rebuild(WizardTemplate? template) {
    _rules.clear();
    _ruleSetTagTitles.clear();
    _userTags.clear();
    final titles = ruleDisplayNames(_sourceRules, template);
    // §757 — теги наборов правил пользователя: заняты теги `route.rule_set`
    // шаблона и наборов пресетов (как в сборке). Без шаблона занятых тегов
    // нет: база может разойтись со сборкой лишь у правила, чьё имя совпало
    // с тегом шаблона или пресета.
    final axisTags = customRuleAxisTags(
      _sourceRules,
      takenTags: _templateRuleSetTags(template),
      presets: template?.selectableRules ?? const [],
    );
    for (var i = 0; i < _sourceRules.length; i++) {
      final r = _sourceRules[i];
      if (r.kind == CustomRuleKind.preset) {
        // §279 — match-полей у preset-правила нет; регистрируем rule_set-теги
        // его шаблонного тела → live display-титул (первая копия wins).
        final preset = _presetOf(template, r.presetId);
        if (preset != null) {
          for (final rs in preset.ruleSets) {
            final tag = rs['tag'];
            if (tag is String && tag.isNotEmpty) {
              _ruleSetTagTitles.putIfAbsent(tag, () => titles[i]);
            }
          }
        }
        continue;
      }
      final tags = axisTags[r.id];
      if (tags != null) {
        for (final t in {...tags.refTags.values, ...tags.inlineTags.values}) {
          _userTags.add((tag: t, title: titles[i]));
        }
      }
      // Строки условий — для правил без наборов и для конфига, собранного
      // до §757 (тот же процесс ядра переживает обновление приложения).
      final strings = r is CustomRuleTree && r.hasGroups
          ? [
              for (final (_, leaf) in ruleTreeLeaves(r.root))
                _leafConditionString(leaf),
            ].where((s) => s.isNotEmpty).toList()
          : [_ruleConditionString(r)].where((s) => s.isNotEmpty).toList();
      if (strings.isEmpty) continue;
      _rules.add((norms: [for (final s in strings) _norm(s)], title: titles[i]));
    }
    _userTags.sort((a, b) => b.tag.length.compareTo(a.tag.length));
    _cache.clear();
  }

  /// §757 — теги `route.rule_set` шаблона (заняты до правил пользователя).
  static List<String> _templateRuleSetTags(WizardTemplate? template) {
    final route = template?.config['route'];
    final sets = route is Map ? route['rule_set'] : null;
    if (sets is! List) return const [];
    return [
      for (final rs in sets)
        if (rs is Map && rs['tag'] is String) rs['tag'] as String,
    ];
  }

  static SelectableRule? _presetOf(WizardTemplate? template, String presetId) {
    if (template == null || presetId.isEmpty) return null;
    for (final p in template.selectableRules) {
      if (p.presetId == presetId) return p;
    }
    return null;
  }

  /// Человекочитаемое имя для `connection.rule`. Кэшируется (вкл. промахи).
  String resolve(String coreRule) {
    final cached = _cache[coreRule];
    if (cached != null) return cached;
    final result = _resolve(coreRule);
    _cache[coreRule] = result;
    return result;
  }

  String _resolve(String coreRule) {
    final r = coreRule.trim();
    if (r.isEmpty) return 'final';
    // Отрезаем хвост действия `=> route(...)` (не часть условий).
    var core = r;
    final arrow = core.indexOf('=>');
    if (arrow >= 0) core = core.substring(0, arrow).trim();
    if (core.isEmpty) return 'final';

    final normCore = _norm(core);
    // Ядро обрезает списки до `[a b c...]` — отрезаем хвост `...`, ищем префикс.
    final probe = _stripTruncation(normCore);

    // §757 — тег набора правила пользователя в `rule_set=` строки ядра.
    final byTag = _userTagTitle(core);
    if (byTag != null) return byTag;

    for (final rule in _rules) {
      if (rule.norms.length == 1) {
        // Матч: обрезанная ядровая строка (или её префикс до `...`) ⊂ полной нашей.
        final norm = rule.norms.single;
        if (norm.contains(probe) || normCore.contains(norm)) return rule.title;
      } else if (rule.norms.every(normCore.contains)) {
        // §757 — правило с группами: строка каждого листа — в строке ядра.
        return rule.title;
      }
    }
    // Не нашли правило — fallback: имя rule_set'а если есть, иначе `final`.
    return _fallback(core);
  }

  /// §757 — титул правила пользователя, чей тег набора стоит в одном из
  /// `rule_set=` строки ядра (у `logical` их несколько). Теги содержат
  /// пробелы (`Ads (2)`), поэтому список не режется на слова: тег ищется
  /// целиком с границами — начало значения, `[`, `(` или пробел слева;
  /// конец, `]`, `)` или пробел справа (ядро: `rule_set=[a b]`, у `invert`
  /// — `!(…)`, у `logical` — листья через ` && ` / ` || `).
  String? _userTagTitle(String core) {
    if (_userTags.isEmpty) return null;
    const key = 'rule_set=';
    final values = <String>[];
    for (var i = core.indexOf(key); i >= 0; i = core.indexOf(key, i + 1)) {
      final v = _kvValue(core.substring(i), key);
      if (v != null && v.isNotEmpty) values.add(v);
    }
    if (values.isEmpty) return null;
    for (final e in _userTags) {
      for (final v in values) {
        if (_containsTag(v, e.tag)) return e.title;
      }
    }
    return null;
  }

  static final RegExp _dedupSuffix = RegExp(r'^ \(\d+\)');

  static bool _containsTag(String value, String tag) {
    for (var i = value.indexOf(tag); i >= 0; i = value.indexOf(tag, i + 1)) {
      final before = i == 0 ? 0x20 : value.codeUnitAt(i - 1);
      final end = i + tag.length;
      final after = end == value.length ? 0x20 : value.codeUnitAt(end);
      // ` (2)` за тегом — это развод другого тега (`Ads` внутри `Ads (2)`),
      // `:` — производный тег; оба отсекаются границей справа.
      if ((before == 0x20 || before == 0x5B || before == 0x28) &&
          (after == 0x20 || after == 0x5D || after == 0x29) &&
          !_dedupSuffix.hasMatch(value.substring(end))) {
        return true;
      }
    }
    return false;
  }

  /// Fallback когда правило не сматчилось: `rule_set=<tag>` целиком (§279 —
  /// тег пресета резолвится в live display-титул владельца), иначе
  /// одиночное условие, иначе `final`.
  String _fallback(String core) {
    final rsValue = _kvValue(core, 'rule_set=');
    if (rsValue != null && rsValue.isNotEmpty) {
      String tag;
      if (rsValue.startsWith('[')) {
        var v = rsValue.substring(1);
        if (v.endsWith(']')) v = v.substring(0, v.length - 1);
        tag = _firstToken(v.trim());
      } else {
        tag = rsValue;
      }
      return _ruleSetTagTitles[tag] ?? tag;
    }
    final eq = core.indexOf('=');
    if (eq < 0) return core.isEmpty ? 'final' : _firstToken(core);
    var val = core.substring(eq + 1).trim();
    if (val.startsWith('[')) val = val.substring(1).trim();
    if (val.endsWith(']')) val = val.substring(0, val.length - 1).trim();
    return val.isEmpty ? 'final' : _firstToken(val);
  }

  // ─────────────────────────── helpers ───────────────────────────

  /// §165 — нормализация: множественные пробелы → один, убрать переносы, trim.
  /// Обе стороны проходят это → формат-различия исчезают (indexOf без regex —
  /// hot-path по символам).
  static String _norm(String s) {
    final out = StringBuffer();
    var prevSpace = false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      // пробел / таб / \n / \r → один пробел
      final isWs = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
      if (isWs) {
        if (!prevSpace) out.writeCharCode(0x20);
        prevSpace = true;
      } else {
        out.writeCharCode(c);
        prevSpace = false;
      }
    }
    return out.toString().trim();
  }

  /// Отрезать хвост обрезки ядра `...]` / `...`, чтобы получить сравнимый префикс.
  static String _stripTruncation(String s) {
    final i = s.indexOf('...');
    return i < 0 ? s : s.substring(0, i).trim();
  }

  /// Значение `<key>...` до следующего ` <слово>=` или конца (indexOf, без regex).
  static String? _kvValue(String s, String key) {
    final i = s.indexOf(key);
    if (i < 0) return null;
    final rest = s.substring(i + key.length);
    // Граница следующей k=v-пары: ` <ident>=`. Ищем посимвольно.
    var j = 0;
    while (j < rest.length) {
      if (rest.codeUnitAt(j) == 0x20) {
        // после пробела — ident (буквы/_) затем `=`?
        var k = j + 1;
        while (k < rest.length && _isIdent(rest.codeUnitAt(k))) {
          k++;
        }
        if (k > j + 1 && k < rest.length && rest.codeUnitAt(k) == 0x3D) {
          return rest.substring(0, j).trim();
        }
      }
      j++;
    }
    return rest.trim();
  }

  static bool _isIdent(int c) =>
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x41 && c <= 0x5A) || // A-Z
      c == 0x5F; // _

  /// Первый токен (до пробела/запятой) — `a b c` → `a`.
  static String _firstToken(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x2C) return s.substring(0, i);
    }
    return s;
  }

  /// §165 — построить эталонную строку УСЛОВИЙ правила (как `rule.String()`
  /// ядра, но БЕЗ обрезки — полная). Порядок полей как в sing-box
  /// `rule_item_*`: domain → suffix → keyword → regex → ip_cidr → port → package →
  /// package_regex →
  /// protocol → network_type → network_is_expensive → wifi_ssid → wifi_bssid.
  /// Формат: `key=val` / `key=[a b c]`.
  static String _ruleConditionString(CustomRule r) {
    final leaf = r.flatLeaf;
    return leaf == null ? '' : _leafConditionString(leaf);
  }

  /// §757 — строка условий простого узла дерева (тот же порядок ключей).
  static String _leafConditionString(RuleLeaf leaf) =>
      _conditionString((key) => switch (leaf.conditions[key]) {
            final List l => [for (final e in l) e.toString()],
            true => const ['true'],
            _ => const <String>[],
          });

  static String _conditionString(List<String> Function(String key) values) {
    final parts = <String>[];
    void add(String key, List<String> vals) {
      if (vals.isEmpty) return;
      parts.add(vals.length == 1 ? '$key=${vals.first}' : '$key=[${vals.join(' ')}]');
    }

    for (final key in const [
      'domain',
      'domain_suffix',
      'domain_keyword',
      'domain_regex', // §712
      'ip_cidr',
      'package_name',
      'package_name_regex', // §712
      'protocol',
      // §694 — в ядре network_type / network_is_expensive идут перед wifi.
      'network_type',
    ]) {
      add(key, values(key));
    }
    if (values('network_is_expensive').isNotEmpty) {
      parts.add('network_is_expensive=true');
    }
    add('wifi_ssid', values('wifi_ssid'));
    add('wifi_bssid', values('wifi_bssid'));
    return parts.join(' ');
  }
}
