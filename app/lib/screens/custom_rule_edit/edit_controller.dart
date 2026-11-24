import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../models/codec/rule_record.dart' show ruleFromRecord;
import '../../models/custom_rule.dart';
import '../../models/rule_tree.dart';
import '../../models/parser_config.dart';
import '../../models/preset_rule_set.dart' show ruleSetsEnabledByVar;
import '../../services/builder/preset_expand.dart' show PresetNode;
import '../../services/l10n/locale_controller.dart';
import '../../services/preset_on_change.dart';
import '../../services/record_vars.dart';
import '../../services/relative_time.dart';
import '../../services/rule_set_downloader.dart';
import '../../services/settings_storage.dart';
import '../../services/template_loader.dart';
import '../../models/dns_ref.dart';
import '../../services/dns/dns_server_resolver.dart'
    show defaultDnsServerTag;
import '../../services/contract/rule_conditions.dart';
import 'cond_labels.dart';
import 'cond_stack.dart';
import 'normalizers.dart' as norm;
import 'sections/srs_section.dart' show SrsDownloadState;
import 'validators.dart' as val;

export 'sections/srs_section.dart' show SrsDownloadState;

/// §053 Stage 3 — единая точка истины для editor'а custom-правила.
///
/// До Stage 3 весь state жил в `_CustomRuleEditScreenState` (1330 LOC).
/// Sections принимали controllers + callbacks как props напрямую от
/// editor'а. Stage 3 выделяет state в `ChangeNotifier`, который раздаётся
/// вниз через `CustomRuleEditScope` (InheritedNotifier). Editor scaffold
/// больше ничего о state не знает — только AppBar + Tab + dispose.
///
/// **Что владеет controller:**
/// - 8 `TextEditingController` (name + 6 match-полей + srs URL). При
///   создании read'аются из `initial`, на keystroke forward'ятся в
///   `notifyListeners` чтобы AppBar Save-icon и параметрические tab'ы
///   могли пересчитывать `isDirty`.
/// - All flags / collections (enabled, kind, outbound, protocols, packages,
///   wifiNetworks, varsValues, ipIsPrivate).
/// - Async state: `srsState`, `presetSrsPaths`, `boolVarDownloading`.
/// - `snapshot()` / `isDirty()` — pure read из текущего state.
/// - Pure async actions без BuildContext: `downloadSrs`, `clearSrsCache`,
///   `onBoolVarToggle` (нет UI-side-effect'ов кроме mutate+notify; вызов
///   snackbar/dialog — на caller'е).
///
/// **Что НЕ владеет controller:** ничего что нужно BuildContext —
/// dialog'и save/back/delete, picker'ы, snackbar'ы, navigation.
/// Эти живут на screen State и принимают controller как dependency.
class CustomRuleEditController extends ChangeNotifier {
  CustomRuleEditController({
    required this.initial,
    required this.preset,
    required this.existingNames,
    this.displayName,
    this.presetNodes = const [],
  }) {
    _init();
  }

  /// §578 — узлы для превью пресета с обходом узлов в View-табе.
  final List<PresetNode> presetNodes;

  /// Исходное правило (до open editor'а). На save сравнивается со
  /// `snapshot()` для dirty-check. Также — источник `id` (rule id не
  /// меняется через editor).
  final CustomRule initial;

  /// Bundle-пресет (§033). Не-null когда `initial.kind == preset` И
  /// пресет ещё существует в шаблоне. Null = broken preset (rule
  /// рендерит fallback UI с Delete).
  final SelectableRule? preset;

  /// Имена существующих правил (для auto-rename при коллизии). Не
  /// включает `initial.name` — собирается RoutingScreen'ом. §279 —
  /// display-резолвнутые (live-label'ы пресетов + снапшоты).
  final Set<String> existingNames;

  /// §279 (§3.5.1) — live display-имя preset-правила для read-only Name-поля
  /// (label из локализованного шаблона + порядковый суффикс копии). null —
  /// не preset либо display недоступен (fallback: `preset.label` /
  /// `initial.name`). `nameCtrl` при этом ПРОДОЛЖАЕТ держать сохранённый
  /// снапшот — save не переписывает его локализованным label'ом.
  final String? displayName;

  // ─── Text controllers ────────────────────────────────────────────────

  late final TextEditingController nameCtrl;

  /// §225 — тело raw-JSON правила (kind == json).
  late final TextEditingController jsonCtrl;

  /// §683 — адреса Answer = Fixed IP, по одному на строку.
  late final TextEditingController fixedIpCtrl;

  /// §683 — радио Answer стоит на Fixed IP. Состояние формы, не хранения:
  /// в `RuleDns` режим = непустой `fixedIps`, а радио выбирается и при ещё
  /// пустом поле (Save тогда заблокирован [fixedIpError]).
  bool _fixedChosen = false;

  /// §683 — Advanced-поля резолва (бывшее окно «Action & Resolve»).
  late final TextEditingController resolveTtlCtrl;
  late final TextEditingController resolveTimeoutCtrl;
  late final TextEditingController resolveSubnetCtrl;

  // ─── Mutable state ───────────────────────────────────────────────────

  late bool _enabled;
  late String _outbound;

  /// §757 волна 4 — тело правила в форме: стопка условий и групп (корень).
  /// Под-правила групп — вложенные стопки той же модели; правка любой из них
  /// идёт через мутаторы контроллера ([formChanged]).
  late CondStack _stack;

  /// §757 — форма открыта в JSON-виде (поле тела вместо стопки условий).
  late bool _jsonMode;

  /// §757 — форма может показать правило (стопка есть): правило-дерево,
  /// новое правило или JSON, уже разложенный в форму. У json-правила с
  /// открытия — нет, «Discard» из JSON тогда некуда возвращать.
  late bool _formAvailable;

  /// §757 — ключ узла стопки при открытии: неизменённая форма сохраняет
  /// исходное дерево (нормализация полей и «Not» простого правила группой
  /// не дают ложной правки).
  String _initialFormKey = '';

  /// §757 — были ли наборы в форме на прошлой правке (появились без файла —
  /// правило выключается, как раньше при выборе Remote).
  bool _hadRefs = false;
  late Map<String, String> _varsValues;
  late RuleDns? _dns;
  late RuleResolve? _resolve;

  /// §755 — были ли домены в форме на прошлом keystroke: галка Block
  /// HTTPS ставится на переходе «пусто → не пусто». Стартовое значение — из
  /// открытого правила, поэтому сохранённое правило с доменами при открытии
  /// галку не получает.
  late bool _hadDomains;

  /// §683 — последние опции резолва: снятие «Resolve before routing» и
  /// уход с «Resolve only» не теряют Strategy/Advanced.
  RuleResolve _resolveKeep = const RuleResolve();

  /// §683 — была ли «Resolve before routing» включена до выбора Resolve
  /// only в Action (возврат к направлению восстанавливает её).
  bool _firstBeforeOnly = false;
  List<String> _dnsServerTags = const [];

  /// §030/new_fields — есть ли в текущем vpn_mode `mixed-in` inbound (режимы
  /// proxy/vpn_proxy, §119). Гейтит чекбокс `Proxy interface` в INBOUND-секции.
  /// Читается async в `_init` через [SettingsStorage.getVpnMode].
  bool _hasMixedInbound = false;

  /// §629 — есть ли `sysproxy-in` (системный HTTP-прокси VPN-сети): тумблер
  /// включён и есть TUN. Тот же источник, что [_hasMixedInbound].
  bool _hasSystemProxy = false;

  /// §264 — глобальные vars для превью пресета в View-табе (expandPreset
  /// globalVars): `@vpn_mode`/`@resolve_strategy` в правилах пресета
  /// (traffic-processing) резолвятся из глобали, иначе `#if @vpn_mode` не
  /// срабатывает → inbound[] пустеет в превью. Заполняется в `_loadVpnMode`.
  Map<String, String> _globalVars = const {};
  Map<String, String> get globalVars => _globalVars;

  /// §265 — резолвленные определения ref-vars пресета: имя ref → `WizardVar`
  /// целевой глобали (type/options/title/tooltip из секции-владельца). UI
  /// (preset_params_tab) рисует по ним контрол, значение читает/пишет в
  /// глобальный userVars (`globalVars` / `setGlobalVar`), НЕ в varsValues.
  Map<String, WizardVar> _refVarDefs = const {};
  Map<String, WizardVar> get refVarDefs => _refVarDefs;

  Map<String, String> _presetSrsPaths = const {};
  SrsDownloadState _srsState = SrsDownloadState.none;

  /// §366 — TTL кэша rule-set'а (часы, из [kSrsTtlChoicesHours]).
  int _srsTtlHours = kDefaultSrsTtlHours;

  /// §366 — готовая строка «когда обновлялся» под полем URL. Null пока
  /// метаданные не прочитаны либо файла нет.
  String? _srsLastUpdatedText;
  final Set<String> _boolVarDownloading = <String>{};

  bool _disposed = false;

  // ─── Getters ─────────────────────────────────────────────────────────

  bool get enabled => _enabled;

  /// §757 — корневая стопка условий формы.
  CondStack get stack => _stack;

  /// §757 — таблица условий реестра (условия формы и их порядок).
  RuleConditionTable get table => ruleConditionTable;

  /// §757 — форма в JSON-виде.
  bool get jsonMode => _jsonMode;

  /// §030/new_fields — доступные inbound-варианты для INBOUND-секции. Лейбл
  /// человекочитаемый, значение = тег билдера (§119). `mixed-in` гейтится по
  /// текущему vpn_mode ([_hasMixedInbound]) — в tun-only его нет.
  List<({String tag, String label})> get inboundChoices => [
        (tag: 'tun-in', label: 'TUN — system interface'),
        if (_hasMixedInbound) (tag: 'mixed-in', label: 'Proxy interface'),
        if (_hasSystemProxy)
          (tag: 'sysproxy-in', label: 'System proxy interface'),
      ];

  /// Вид правила: пресет; json — форма в JSON-виде; иначе по дереву формы
  /// (`srs` — есть наборы).
  CustomRuleKind get kind {
    if (initial.kind == CustomRuleKind.preset) return CustomRuleKind.preset;
    if (_jsonMode) return CustomRuleKind.json;
    return ruleTreeRefs(_formRoot).isEmpty
        ? CustomRuleKind.inline
        : CustomRuleKind.srs;
  }

  String get outbound => _outbound;
  Map<String, String> get varsValues => _varsValues;
  Map<String, String> get presetSrsPaths => _presetSrsPaths;
  SrsDownloadState get srsState => _srsState;

  /// §366 — строка «Updated 3d ago» / об ошибке последней попытки.
  String? get srsLastUpdatedText => _srsLastUpdatedText;

  /// §366 — читает sidecar-метаданные кэша для строки под полем URL.
  /// §757 — метаданные первого набора: [cacheId] — id кэша по ссылке
  /// (`<id>~<h8>`); нет ссылки — строки «Updated …» нет.
  Future<void> _loadSrsMeta(String? cacheId) async {
    if (cacheId == null) return;
    final meta = await RuleSetDownloader.readMeta(cacheId);
    if (_disposed) return;
    final last = meta.lastUpdated;
    if (meta.failing) {
      _srsLastUpdatedText =
          getLocalText.s("Update failed — using cached copy");
    } else if (last != null) {
      _srsLastUpdatedText =
          getLocalText.s("Updated %s", relativeTime(DateTime.now(), last));
    } else {
      _srsLastUpdatedText = null;
    }
    notifyListeners();
  }

  /// §366 — выбранный TTL кэша rule-set'а в часах (`0` = не обновлять).
  int get srsTtlHours => _srsTtlHours;

  set srsTtlHours(int v) {
    if (_srsTtlHours == v) return;
    _srsTtlHours = v;
    notifyListeners();
  }
  Set<String> get boolVarDownloading => _boolVarDownloading;

  /// §117 задача 3 — DNS-опция правила (null = не настраивалась).
  RuleDns? get dns => _dns;

  /// §247 — resolve-опция правила (null = обычный outbound).
  RuleResolve? get resolve => _resolve;

  /// §247 / §757: live-гейт применимости resolve — по ТЕКУЩЕМУ дереву
  /// формы: наборы или доменный ключ хоть в одном простом узле (чистый
  /// ip/port/proto резолвить нечего).
  bool get resolveEligible => _formKind && _hasRefsOrDomain(_formRoot);

  /// Форма редактирует правило-дерево (не пресет и не JSON-вид).
  bool get _formKind =>
      !_jsonMode && initial.kind != CustomRuleKind.preset;

  bool _hasRefsOrDomain(RuleNode root) =>
      ruleTreeHasRefsOrDomain(root, table);

  /// §117: теги существующих DNS-серверов для дропдауна (storage-refs ∪
  /// template; правило ссылается по tag, не вводит адрес — решение №2).
  List<String> get dnsServerTags => _dnsServerTags;

  /// §755: у правила есть условие, которого у DNS-запроса нет (порт,
  /// протокол, `network`: ключ таблицы без `dns`, не адрес и не флаг) — DNS-
  /// опции действуют на домены правила на любом порту и протоколе. Только
  /// повод для подсказки. Live по текущему дереву формы.
  bool get dnsAppliesAnyPort {
    for (final (_, leaf) in ruleTreeLeaves(_formRoot)) {
      for (final k in leaf.conditions.keys) {
        final d = table.key(k);
        if (d != null && !d.dns && d.group == null && !d.isBool) return true;
      }
    }
    return false;
  }

  /// §757: DNS-опция включена, а DNS-зеркало правила пустое (ни одного
  /// условия, видимого DNS-слою) — опция не действует, правило сохраняется
  /// (⚠ в секции DNS). Live по текущему состоянию формы.
  bool get dnsOptionsWithoutEffect =>
      _formKind && snapshot().dnsOptionsWithoutEffect;

  /// §692 / §757: секция «DNS & Resolve» видна, когда у дерева формы есть
  /// условие, видимое DNS-слою (зеркало непусто), либо DNS-опция уже
  /// включена (секция показывает ⚠ «нет эффекта» и даёт её снять).
  bool get dnsSectionVisible =>
      _formKind &&
      (ruleTreeMirrorNonEmpty(_formRoot, table) ||
          snapshot().dnsOptionsWithoutEffect);

  /// §051 — в дереве формы есть условие Wi-Fi (перед сохранением
  /// проверяются разрешения чтения SSID).
  bool get hasWifiCondition {
    for (final (_, leaf) in ruleTreeLeaves(_formRoot)) {
      for (final k in leaf.conditions.keys) {
        if (table.key(k)?.conditionId == kWifiConditionId) return true;
      }
    }
    return false;
  }

  /// §757 — id условия Wi-Fi в таблице условий.
  static const kWifiConditionId = 'wifi';

  /// §757 — id условия приложений в таблице условий (поле пакетов с выбором
  /// из установленных) и условия входа (подсказки — входы текущего режима).
  static const kAppsConditionId = 'apps';
  static const kInboundConditionId = 'inbound';

  // ─── Init / dispose ──────────────────────────────────────────────────

  List<TextEditingController> get _allTextCtrls => [
        nameCtrl,
        jsonCtrl,
        fixedIpCtrl,
        resolveTtlCtrl,
        resolveTimeoutCtrl,
        resolveSubnetCtrl,
      ];

  void _init() {
    final r = initial;
    nameCtrl = TextEditingController(text: r.name);
    // §366 — TTL наборов (§757 — поле правила-дерева; у inline без
    // наборов в запись не идёт).
    if (r is CustomRuleTree) _srsTtlHours = r.updateIntervalHours;
    // §757 волна 4 — дерево правила раскладывается в стопку условий. Не
    // ложится (два способа `one_of` сразу) — JSON-вид: текст — тело записи.
    final stack =
        r is CustomRuleTree ? CondStack.fromNode(r.root, table) : null;
    _stack = stack ?? CondStack();
    _formAvailable = r is CustomRuleTree && stack != null;
    _jsonMode = r.kind == CustomRuleKind.json || (r is CustomRuleTree && stack == null);
    _initialFormKey = _nodeKey(_stack.toNode() ?? const RuleLeaf());
    _initialJsonText = r is CustomRuleTree
        ? (_jsonMode ? _prettyBody(r) : '')
        : r.json;
    jsonCtrl = TextEditingController(text: _initialJsonText);
    _enabled = r.enabled;
    _outbound = r.outbound;
    _hadRefs = r.allRefs.isNotEmpty;
    _varsValues = Map<String, String>.from(r.varsValues);
    _dns = r.dns;
    _hadDomains = _hasDomainKey(_formRoot);
    _fixedChosen = r.dns?.fixedMode ?? false;
    _resolve = r.resolve;
    if (_resolve != null) _resolveKeep = _resolve!;
    fixedIpCtrl =
        TextEditingController(text: (r.dns?.fixedIps ?? const []).join('\n'));
    resolveTtlCtrl =
        TextEditingController(text: r.resolve?.rewriteTtl?.toString() ?? '');
    resolveTimeoutCtrl = TextEditingController(text: r.resolve?.timeout ?? '');
    resolveSubnetCtrl =
        TextEditingController(text: r.resolve?.clientSubnet ?? '');
    unawaited(_loadDnsServerTags());
    unawaited(_loadVpnMode());

    // Forward text changes — AppBar Save-icon (dirty indicator) и
    // tab'ы re-evaluate isDirty / снимок при каждом keystroke.
    for (final c in _allTextCtrls) {
      c.addListener(_onTextChanged);
    }

    if (r.allRefs.isNotEmpty) {
      _allSrsCached(r).then((cached) {
        if (_disposed) return;
        _srsState =
            cached ? SrsDownloadState.cached : SrsDownloadState.none;
        notifyListeners();
      });
      unawaited(_loadSrsMeta(r.cacheIds.firstOrNull)); // §366
    }
    if (r is CustomRulePreset && preset != null) {
      _resolvePresetSrsPaths(r, preset!);
    }
  }

  void _onTextChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// §757 — правка формы условий (поле рамки, рамка, группа, под-правило).
  /// §247: сброс resolve при опустении доменных полей НЕ здесь — правка
  /// транзиентна (юзер стирает домен, чтобы вписать новый); гейт живёт в
  /// snapshot() и в билдере, UI прячет опции через resolveEligible.
  void formChanged() {
    if (_disposed) return;
    final root = _formRoot;
    _autoCheckBlockHttps(root);
    // Наборы появились, файлов нет — правило выключается (как раньше при
    // выборе Remote); правка ссылок снимает красную ☁.
    final hasRefs = ruleTreeRefs(root).isNotEmpty;
    if (hasRefs && !_hadRefs && _srsState != SrsDownloadState.cached) {
      _enabled = false;
    }
    _hadRefs = hasRefs;
    if (_srsState == SrsDownloadState.error) _srsState = SrsDownloadState.none;
    notifyListeners();
  }

  /// §757 — узел дерева из формы. Неизменённая форма — исходное дерево.
  RuleNode get _formRoot {
    final n = _stack.toNode() ?? const RuleLeaf();
    final init = initial;
    if (init is CustomRuleTree && _nodeKey(n) == _initialFormKey) {
      return init.root;
    }
    return n;
  }

  static String _nodeKey(RuleNode n) =>
      jsonEncode(ruleTreeBodyToJson(RuleTreeBody(root: n)));

  static String _prettyBody(CustomRuleTree r) =>
      const JsonEncoder.withIndent('  ').convert(ruleTreeBodyToJson(r.body));

  /// §755 — хоть в одном простом узле есть доменный ключ.
  bool _hasDomainKey(RuleNode root) {
    for (final (_, leaf) in ruleTreeLeaves(root)) {
      for (final k in leaf.conditions.keys) {
        if (table.key(k)?.isDomain ?? false) return true;
      }
    }
    return false;
  }

  /// §755 — автогалка Block HTTPS: домены из пустых стали непустыми (в том
  /// числе повторно — стёрли и ввели заново). Снятая руками галка при
  /// дальнейшем вводе в непустое поле не возвращается.
  void _autoCheckBlockHttps(RuleNode root) {
    final now = _hasDomainKey(root);
    if (now && !_hadDomains && !(_dns?.blockHttps ?? false)) {
      _dns = (_dns ?? const RuleDns()).copyWith(blockHttps: true);
    }
    _hadDomains = now;
  }

  /// §755 / §757 — переключатель Block HTTPS доступен: в дереве формы есть
  /// наборы или доменный ключ. Live по форме.
  bool get blockHttpsAvailable => resolveEligible;

  // ─── §757: правка стопки условий ─────────────────────────────────────

  /// Условия меню «+ Condition» для стопки [s]: условия формы LxBox по
  /// порядку таблицы, кроме уже добавленных.
  List<RuleCondition> conditionsToAdd(CondStack s) => [
        for (final c in table.conditions)
          if (c.shownIn(kRuleCondFormLxbox) && s.frame(c.id) == null) c,
      ];

  void addCondition(CondStack s, RuleCondition c) {
    if (s.frame(c.id) != null) return;
    s.frames.add(CondFrame(c));
    formChanged();
  }

  void removeFrame(CondStack s, CondFrame f) {
    if (s.frames.remove(f)) formChanged();
  }

  /// Значение поля рамки: текст, выбор чипов или флажок.
  void setFieldRaw(CondFrame f, String key, Object raw) {
    f.raw[key] = raw;
    formChanged();
  }

  /// Условие `one_of`: выбран другой ключ — значение переезжает к нему.
  void setOneOfKey(CondFrame f, String key) {
    if (f.raw.containsKey(key)) return;
    final old = f.raw.values.firstOrNull;
    f.raw
      ..clear()
      ..[key] = old is String ? old : '';
    formChanged();
  }

  /// Группа правил с одним пустым под-правилом.
  CondGroup addGroup(CondStack s) {
    final g = CondGroup(rules: [CondStack()]);
    s.groups.add(g);
    formChanged();
    return g;
  }

  void removeGroup(CondStack s, CondGroup g) {
    if (s.groups.remove(g)) formChanged();
  }

  void setGroupAny(CondGroup g, bool any) {
    if (g.any == any) return;
    g.any = any;
    formChanged();
  }

  void setGroupNot(CondGroup g, bool not) {
    if (g.not == not) return;
    g.not = not;
    formChanged();
  }

  CondStack addSubRule(CondGroup g) {
    final r = CondStack();
    g.rules.add(r);
    formChanged();
    return r;
  }

  void removeSubRule(CondGroup g, CondStack r) {
    if (g.rules.remove(r)) formChanged();
  }

  // ─── §757: JSON-вид ⇄ форма ──────────────────────────────────────────

  /// Форма → JSON-вид: текст — тело текущего правила с целью.
  void enterJsonMode() {
    if (_jsonMode) return;
    final snap = snapshot();
    if (snap is CustomRuleTree) jsonCtrl.text = _prettyBody(snap);
    _jsonMode = true;
    notifyListeners();
  }

  /// JSON-вид → форма: тело раскладывается в стопку, цель — в Direction.
  /// null — разложено; иначе причина, по которой форма его не покажет
  /// (вызывающий спрашивает Discard / Keep editing).
  String? applyJsonToForm() {
    if (!_jsonMode) return null;
    final err = jsonError;
    if (err != null) return err;
    final tree = _treeFromJsonText(nameCtrl.text.trim());
    final stack = tree == null ? null : CondStack.fromNode(tree.root, table);
    if (tree == null || stack == null) {
      return getLocalText.s("The form cannot show this rule.");
    }
    _stack = stack;
    _outbound = tree.outbound;
    _jsonMode = false;
    _formAvailable = true;
    formChanged();
    return null;
  }

  /// «Discard» из JSON-вида: обратно в форму без правок JSON. false — формы
  /// нет (json-правило с открытия), остаёмся в JSON.
  bool discardJson() {
    if (!_jsonMode || !_formAvailable) return false;
    _jsonMode = false;
    notifyListeners();
    return true;
  }

  bool get formAvailable => _formAvailable;

  /// §757 — все ссылки наборов дерева формы (блок наборов: ☁, период).
  List<String> get allRefs => ruleTreeRefs(_formRoot);

  /// §755: галка Block HTTPS/SVCB records (HTTPS/SVCB-глушилка).
  /// Ортогональна enabled/serverTag, как Force IPv4.
  void setBlockHttps(bool v) {
    final next = (_dns ?? const RuleDns()).copyWith(blockHttps: v);
    _dns = next.isEmpty ? null : next;
    notifyListeners();
  }

  /// §117/§680: теги DNS-серверов для дропдауна — только список
  /// пользователя (kind-ref'ы §043, синхронизируются на каждом
  /// build/DNS-screen open). Серверы шаблона вне списка не предлагаются:
  /// mirror на них не эмитится (висящая ссылка).
  Future<void> _loadDnsServerTags() async {
    final stored = await SettingsStorage.getDnsServers();
    final template = await TemplateLoader.load();
    final wrappers = template.dnsOptionsModel.wrappersByTag;
    final tags = <String>{
      for (final s in stored)
        if (s.tag.isNotEmpty) s.tag,
    };
    // Тип для пригодности дефолта: inline — из тела, template — из обёртки;
    // у preset тип здесь неизвестен — считается пригодным.
    final typeByTag = <String, String>{
      for (final s in stored)
        s.tag: switch (s) {
          DnsServerInline(:final body) => body['type']?.toString() ?? '',
          DnsServerTemplate() =>
            (wrappers[s.tag]?['server'] as Map?)?['type']?.toString() ?? '',
          DnsServerPreset() => '',
        },
    };
    if (_disposed) return;
    _dnsServerTags = tags.toList();
    _dnsDefaultServerTag = defaultDnsServerTag(_dnsServerTags,
        eligible: (t) => typeByTag[t] != 'fakeip' && typeByTag[t] != 'hosts');
    notifyListeners();
  }

  /// §680 — дефолт DNS-опции правила: [defaultDnsServerTag] по списку.
  String _dnsDefaultServerTag = '';

  /// §030/new_fields — читает текущий vpn_mode для гейта `mixed-in`-чекбокса
  /// в INBOUND-секции. `mixed-in` существует только в proxy/vpn_proxy (§119).
  Future<void> _loadVpnMode() async {
    final cfg = await SettingsStorage.getVpnMode();
    final userVars = await SettingsStorage.getAllVars();
    final template = await TemplateLoader.load();
    if (_disposed) return;
    _hasMixedInbound = cfg.hasMixed;
    _hasSystemProxy = cfg.systemProxyEnabled && cfg.hasTun;

    // §265 — резолвим ref-vars пресета: для каждой `{"ref": name}` берём
    // определение глобали из template + значение (userVars или её default).
    final refDefs = <String, WizardVar>{};
    final refDefaults = <String, String>{};
    final p = preset;
    if (p != null) {
      for (final v in p.vars) {
        if (!v.isRef) continue;
        final global = template.globalVar(v.ref);
        if (global == null) continue; // битая ссылка → UI пропустит
        refDefs[v.ref] = global;
        refDefaults[v.ref] = global.defaultValue;
      }
    }
    _refVarDefs = refDefs;

    // §264 — globalVars: template-дефолты ref-целей (fallback) < userVars
    // (юзерский выбор) + vpn_mode из VpnModeConfig (он приходит не через
    // userVars, а прямым присваиванием в билдере). Дефолты нужны, чтобы
    // ref-var контрол показывал текущее значение, даже если юзер её не трогал.
    _globalVars = {...refDefaults, ...userVars, 'vpn_mode': cfg.mode};
    notifyListeners();
  }

  /// §265 — запись значения ref-var (глобальной) в userVars. В отличие от
  /// [setVarValue] (varsValues пресета), пишет в глобальный storage —
  /// единый источник (напр. resolve_strategy питает и config.dns.strategy).
  Future<void> setGlobalVar(String name, String val) async {
    await SettingsStorage.setVar(name, val);
    _globalVars = {..._globalVars, name: val};
    notifyListeners();
  }

  /// Async-prefetch cached paths для remote rule_set'ов пресета (§011).
  /// Без этого View tab показывал бы warnings «no cached file» для
  /// уже скачанного пресета.
  Future<void> _resolvePresetSrsPaths(
      CustomRulePreset rule, SelectableRule preset) async {
    final paths = <String, String>{};
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      if (tag is! String || tag.isEmpty) continue;
      final p =
          await RuleSetDownloader.cachedPathForPreset(rule.presetId, tag);
      if (p != null) paths[tag] = p;
    }
    if (_disposed) return;
    _presetSrsPaths = paths;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _allTextCtrls) {
      c.removeListener(_onTextChanged);
      c.dispose();
    }
    super.dispose();
  }

  // ─── Mutators ────────────────────────────────────────────────────────

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    notifyListeners();
    _applyPresetOnChange(); // §266 — @rule_enable сменился
  }

  /// §266 — каскад on_change пресета (пишет глобальные цели вроде
  /// resolve_enabled в userVars). Псевдо-vars берутся из текущего snapshot
  /// (enabled + varsValues). No-op для не-preset правил / пресета без on_change.
  void _applyPresetOnChange() {
    final p = preset;
    if (p == null) return;
    final snap = snapshot();
    if (snap is CustomRulePreset) {
      unawaited(applyPresetOnChange(p, snap));
    }
  }

  void setOutbound(String v) {
    if (_outbound == v) return;
    _outbound = v;
    notifyListeners();
  }

  /// §683 — Action = Resolve only (пункт в Action-пикере). Выбранное
  /// направление в модели сохраняется (§247); возврат к направлению —
  /// `only = false`, «Resolve before routing» как была до выбора.
  bool get resolveOnly => _resolve?.only ?? false;

  void setResolveOnly(bool v) {
    if (resolveOnly == v) return;
    if (v) {
      _firstBeforeOnly = _resolve != null;
      _resolve = (_resolve ?? _resolveKeep).copyWith(only: true);
      _resolveKeep = _resolve!;
    } else {
      _resolveKeep = _resolve!.copyWith(only: false);
      _resolve = _firstBeforeOnly ? _resolveKeep : null;
    }
    notifyListeners();
  }

  /// §683 — галка «Resolve before routing» (бывшее «Resolve first», §247).
  /// При Resolve only неактивна (UI).
  void setResolveFirst(bool v) {
    if (resolveOnly) return;
    if (v == (_resolve != null)) return;
    if (v) {
      _resolve = _resolveKeep.copyWith(only: false);
    } else {
      _resolveKeep = _resolve!;
      _resolve = null;
    }
    notifyListeners();
  }

  /// §683 — правка опций резолва (Strategy и Advanced). Действует, только
  /// когда резолв включён (иначе поля неактивны).
  void updateResolve(RuleResolve Function(RuleResolve r) edit) {
    final cur = _resolve;
    if (cur == null) return;
    _resolve = edit(cur);
    _resolveKeep = _resolve!;
    notifyListeners();
  }

  // ─── §683: Advanced-поля резолва — та же валидация, что была в окне ──

  String? get resolveTtlError {
    final t = resolveTtlCtrl.text.trim();
    if (t.isEmpty) return null;
    final v = int.tryParse(t);
    if (v == null || v < 0) return getLocalText.s("Non-negative integer");
    return null;
  }

  String? get resolveTimeoutError {
    final t = resolveTimeoutCtrl.text.trim();
    if (t.isEmpty) return null;
    if (!RegExp(r'^\d+(ms|s|m|h)$').hasMatch(t)) {
      return getLocalText.s("e.g. 5s, 500ms");
    }
    return null;
  }

  static final _subnetPattern = RegExp(
      r'^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+:[0-9A-Fa-f:]*)(/\d{1,3})?$');

  String? get resolveSubnetError {
    final t = resolveSubnetCtrl.text.trim();
    if (t.isEmpty) return null;
    if (!_subnetPattern.hasMatch(t)) {
      return getLocalText.s("IP or CIDR, e.g. 1.2.3.0/24");
    }
    return null;
  }

  /// §683 — resolve для snapshot: опции + текст Advanced-полей.
  RuleResolve? get _effectiveResolve {
    final r = _resolve;
    if (r == null) return null;
    final ttl = int.tryParse(resolveTtlCtrl.text.trim());
    return r.copyWith(
      rewriteTtl: ttl,
      clearRewriteTtl: ttl == null,
      timeout: resolveTimeoutCtrl.text.trim(),
      clientSubnet: resolveSubnetCtrl.text.trim(),
    );
  }

  /// §225 — тело json-правила изменилось (jsonCtrl уже в _allTextCtrls, но
  /// нужен явный notify для live-пересчёта jsonError → helper/Save-гейт).
  void notifyJsonChanged() => notifyListeners();

  void setVarValue(String name, String val) {
    _putVarValue(name, val);
    notifyListeners();
  }

  /// §441 (Н3/Н4) — запись значения переменной пресета: подрезанное;
  /// пустое или равное умолчанию объявления снимает ключ (выбор умолчания —
  /// сброс к шаблону). Имя без объявления (универсальная замена цели
  /// `outbound`) пишется без сверки с умолчанием.
  void _putVarValue(String name, String val) {
    WizardVar? decl;
    for (final v in preset?.vars ?? const <WizardVar>[]) {
      if (v.name == name && !v.isRef) {
        decl = v;
        break;
      }
    }
    // §643 (D-132) — `unique` у `text_list`: дубли снимаются при сохранении;
    // `internal` в запись не пишется.
    final stored = recordVarValueToStore(
      val,
      decl == null
          ? null
          : RecordVarDecl(
              name: decl.name,
              defaultValue: decl.defaultValue,
              type: decl.type,
              isInternal: decl.isInternal,
              unique: decl.unique,
            ),
    );
    if (stored == null) {
      _varsValues.remove(name);
    } else {
      _varsValues[name] = stored;
    }
  }

  /// §683 — режим Answer секции DNS & Resolve (радио). Fixed IP — из
  /// состояния формы [_fixedChosen], а не из [RuleDns.fixedMode]: радио
  /// выбрано и при ещё пустом поле адресов.
  DnsAnswerMode get dnsAnswerMode {
    final d = _dns;
    if (_fixedChosen) return DnsAnswerMode.fixedIp;
    if (d == null) return DnsAnswerMode.defaultDns;
    if (d.enabled) return DnsAnswerMode.dedicated;
    return DnsAnswerMode.defaultDns;
  }

  /// §683 — выбор Answer. serverTag при переключении хранится; Default и
  /// Dedicated стирают адреса Fixed IP (поле очищается), Fixed IP снимает
  /// `enabled`. Первый выбор Dedicated без сервера — преселект дефолтного
  /// (§117).
  void setDnsAnswerMode(DnsAnswerMode m) {
    final cur = _dns ?? const RuleDns();
    final RuleDns next;
    switch (m) {
      case DnsAnswerMode.defaultDns:
        next = cur.copyWith(enabled: false, fixedIps: const []);
      case DnsAnswerMode.dedicated:
        next = cur.copyWith(
          enabled: true,
          fixedIps: const [],
          serverTag: cur.serverTag.isEmpty ? _dnsDefaultServerTag : null,
        );
      case DnsAnswerMode.fixedIp:
        next = cur.copyWith(enabled: false);
    }
    _fixedChosen = m == DnsAnswerMode.fixedIp;
    if (!_fixedChosen && fixedIpCtrl.text.isNotEmpty) fixedIpCtrl.clear();
    _dns = next.isEmpty && _dns == null ? null : next;
    if (m == DnsAnswerMode.dedicated) _linkResolveToAnswer(next.serverTag);
    notifyListeners();
  }

  /// §711 — выбор Dedicated server и сервера в Answer всегда включает
  /// «Resolve before routing» (при Resolve only резолв уже есть) и ставит
  /// сервер резолва = сервер Answer. Strategy и Advanced-поля не трогаются.
  /// Только для kind'ов, где resolve применим (inline/srs; живой гейт по
  /// доменам — в snapshot). Гидрация правила сюда не ходит.
  void _linkResolveToAnswer(String serverTag) {
    if (!_formKind) return;
    final base = _resolve ?? _resolveKeep.copyWith(only: false);
    _resolve = base.copyWith(serverTag: serverTag);
    _resolveKeep = _resolve!;
  }

  /// §683 — адреса поля Fixed IP: непустые строки.
  List<String> get _fixedIpLines => [
        for (final l in fixedIpCtrl.text.split('\n'))
          if (l.trim().isNotEmpty) l.trim(),
      ];

  /// §683 — ошибка поля Fixed IP (номер первой неразбираемой строки) или
  /// null. Только при выбранном Fixed IP; блокирует Save.
  String? get fixedIpError {
    if (dnsAnswerMode != DnsAnswerMode.fixedIp) return null;
    final lines = fixedIpCtrl.text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (l.isEmpty) continue;
      if (RuleDns.ipRecordType(l) == null) {
        return getLocalText.s("Line %d: not an IPv4 or IPv6 address", i + 1);
      }
    }
    if (_fixedIpLines.isEmpty) return getLocalText.s("Enter an IP address");
    return null;
  }

  /// §683 — dns для snapshot: адреса берутся из поля (годные строки) и
  /// только при выбранном Fixed IP.
  RuleDns? get _effectiveDns {
    final ips = [
      if (_fixedChosen)
        for (final l in _fixedIpLines)
          if (RuleDns.ipRecordType(l) != null) l,
    ];
    // §755 — без доменов inline-правило Block HTTPS не несёт (переключатель
    // недоступен; стёрли домены — галка не остаётся висеть в хранилище).
    final blockHttps = (_dns?.blockHttps ?? false) && blockHttpsAvailable;
    if (_dns == null && ips.isEmpty) return null;
    return (_dns ?? const RuleDns())
        .copyWith(fixedIps: ips, blockHttps: blockHttps);
  }

  /// §117: выбор DNS-сервера для mirror'а (по tag из существующих).
  void setDnsServerTag(String tag) {
    _dns = (_dns ?? const RuleDns()).copyWith(serverTag: tag);
    _linkResolveToAnswer(tag);
    notifyListeners();
  }

  /// §256: галка Force IPv4 (AAAA-глушилка). Ортогональна enabled/serverTag —
  /// `RuleDns` может существовать только из-за неё (enabled=false, serverTag='').
  /// Снятие галки на «пустой» dns (без dedicated-сервера) обнуляет _dns целиком
  /// — иначе в storage/backup остаётся мёртвый `RuleDns{}` (шумит isDirty).
  void setForceIpv4(bool v) {
    final next = (_dns ?? const RuleDns()).copyWith(forceIpv4: v);
    _dns = next.isEmpty ? null : next;
    notifyListeners();
  }

  // ─── SRS download (used by SrsSection cloud-button) ──────────────────

  Future<void> downloadSrs() async {
    final urls = ruleTreeRefs(_formRoot);
    if (urls.isEmpty) return;
    _srsState = SrsDownloadState.loading;
    notifyListeners();
    // ## 12 — все наборы по порядку в свои файлы кэша; первый провал =
    // провал правила (частично скачанное не включаем).
    var ok = true;
    for (var i = 0; i < urls.length; i++) {
      final path = await RuleSetDownloader.download(
          CustomRuleTree.cacheIdFor(initial.id, urls[i]), urls[i]);
      if (_disposed) return;
      if (path == null) {
        ok = false;
        break;
      }
    }
    _srsState = ok ? SrsDownloadState.cached : SrsDownloadState.error;
    notifyListeners();
    // §366 — обновить строку «Updated …»: метаданные записал downloader.
    unawaited(_loadSrsMeta(CustomRuleTree.cacheIdFor(initial.id, urls.first)));
  }

  /// Cloud-menu «Clear cached file»: удаляет локальный `.srs`, не
  /// трогая правило в storage. _enabled сбрасывается — без cache
  /// правило не может работать.
  Future<void> clearSrsCache() async {
    // ## 12 — файлы всех наборов: и сохранённых, и набранных в поле (юзер
    // мог скачать новый список, не сохраняя правило).
    // §757 — кэш по ссылке: файлы сохранённых и набранных ссылок.
    final cacheIds = {
      ...initial.cacheIds,
      for (final u in ruleTreeRefs(_formRoot))
        CustomRuleTree.cacheIdFor(initial.id, u),
    };
    for (final c in cacheIds) {
      await RuleSetDownloader.delete(c);
    }
    if (_disposed) return;
    _srsState = SrsDownloadState.none;
    _enabled = false;
    _srsLastUpdatedText = null; // §366 — метаданные ушли вместе с файлом
    notifyListeners();
  }

  /// ## 12 — правило «скачано», когда есть файлы ВСЕХ его наборов.
  static Future<bool> _allSrsCached(CustomRule r) async {
    if (r.allRefs.isEmpty) return false;
    for (final cacheId in r.cacheIds) {
      if (!await RuleSetDownloader.isCached(cacheId)) return false;
    }
    return true;
  }

  /// На URL-edit: если состояние было `error`, сбрасываем в `none`
  /// (юзер начал править — пусть не висит красная иконка).
  void resetSrsErrorIfAny() {
    if (_srsState != SrsDownloadState.error) return;
    _srsState = SrsDownloadState.none;
    notifyListeners();
  }

  // ─── §045 bool-var toggle (preset rendering) ─────────────────────────

  /// Toggle bool-var. Если var управляет remote rule_set'ом (гейт набора —
  /// `#enable` или легаси `enabled`, отбор через [ruleSetsEnabledByVar],
  /// §534) — toggle-on auto-downloads .srs; на fail toggle откатывается и
  /// метод возвращает `true` (caller покажет snackbar).
  ///
  /// Toggle-off — без downloads, всегда `false`.
  Future<bool> onBoolVarToggle(WizardVar v, bool val) async {
    final p = preset;
    if (p == null) return false;

    // §265 — ref-var пишется в ГЛОБАЛЬНЫЙ userVars, не в varsValues пресета.
    // UI-слой (bool-case) уже роутит ref через setGlobalVar до вызова, но
    // guard на случай прямого вызова: не даём ref-значению утечь в varsValues.
    if (v.isRef) {
      await setGlobalVar(v.ref, val ? 'true' : 'false');
      return false;
    }

    if (!val) {
      _putVarValue(v.name, 'false');
      notifyListeners();
      _applyPresetOnChange(); // §266 — dns_enable вход формулы on_change
      return false;
    }

    final initial = this.initial;
    final presetId =
        initial is CustomRulePreset ? initial.presetId : p.presetId;
    // §534 — наборы, которые включает эта переменная: семантика гейта
    // билдера (обе формы, составные условия), а не поиск строки "@<name>".
    final controlled = ruleSetsEnabledByVar(
      p,
      CustomRulePreset(name: '', presetId: presetId, varsValues: _varsValues),
      v.name,
      globalVars: _globalVars,
    );

    if (controlled.isEmpty) {
      _putVarValue(v.name, 'true');
      notifyListeners();
      _applyPresetOnChange(); // §266
      return false;
    }

    final missing = <_PendingDownload>[];
    for (final rs in controlled) {
      final cached =
          await RuleSetDownloader.cachedPathForPreset(presetId, rs.tag) != null;
      if (!cached) missing.add(_PendingDownload(tag: rs.tag, url: rs.url));
    }
    if (_disposed) return false;

    if (missing.isEmpty) {
      _putVarValue(v.name, 'true');
      _presetSrsPaths = {..._presetSrsPaths};
      notifyListeners();
      _applyPresetOnChange(); // §266
      return false;
    }

    _boolVarDownloading.add(v.name);
    notifyListeners();

    final newPaths = <String, String>{};
    var anyFailed = false;
    for (final m in missing) {
      final path = await RuleSetDownloader.downloadForPreset(
          presetId, m.tag, m.url);
      if (path == null) {
        anyFailed = true;
      } else {
        newPaths[m.tag] = path;
      }
    }
    if (_disposed) return false;

    _boolVarDownloading.remove(v.name);
    if (!anyFailed) {
      _putVarValue(v.name, 'true');
      _presetSrsPaths = {..._presetSrsPaths, ...newPaths};
      _applyPresetOnChange(); // §266
    }
    notifyListeners();
    return anyFailed;
  }

  // ─── Snapshot / dirty ────────────────────────────────────────────────

  /// Текущее состояние формы как `CustomRule`. Не валидирует name-
  /// collision (это делает `save` flow на screen State).
  ///
  /// §381 — `orderNum` (ось §370) переносится из `initial` во ВСЕ ветки:
  /// редактор позицию правила не меняет, а потеря номера читалась как две
  /// разные жалобы. Без него `isDirty()` (равенство моделей) видел разницу по
  /// `orderNum` ещё до первой правки — «Save changes?» на пустом выходе; а
  /// сохранённое правило уезжало в storage с `num == null` и при следующей
  /// загрузке экрана размечалось `markRuleOrder` заново от `kUserRuleNumStart`,
  /// то есть прыгало в начало пользовательской зоны.
  CustomRule snapshot() {
    final name = nameCtrl.text.trim();
    switch (kind) {
      case CustomRuleKind.json:
        // §757 — json-правило остаётся json-правилом (verbatim в дерево
        // само не превращается); правило-дерево и новое — дерево из текста,
        // если тело им читается.
        final tree =
            initial is CustomRuleJson ? null : _treeFromJsonText(name);
        if (tree != null) return tree;
        return CustomRuleJson(
          id: initial.id,
          name: name,
          enabled: _enabled,
          orderNum: initial.orderNum,
          json: jsonCtrl.text,
        );
      case CustomRuleKind.preset:
        final init = initial;
        return CustomRulePreset(
          id: init.id,
          name: name,
          enabled: _enabled,
          orderNum: init.orderNum,
          presetId: init is CustomRulePreset ? init.presetId : '',
          varsValues: Map<String, String>.from(_varsValues),
        );
      case CustomRuleKind.inline:
      case CustomRuleKind.srs:
        return CustomRuleTree(
          id: initial.id,
          name: name,
          enabled: _enabled,
          orderNum: initial.orderNum,
          root: _formRoot,
          outbound: _outbound,
          dns: _effectiveDns, // §683 — адреса Fixed IP из поля
          // §247: гейт на случай snapshot до notify.
          resolve: resolveEligible ? _effectiveResolve : null,
          // §366 / §757 — TTL наборов — поле правила.
          updateIntervalHours: _srsTtlHours,
        );
    }
  }

  /// Правило вида json равно по содержимому JSON; редактор считает правкой и
  /// смену форматирования текста json-правила.
  bool isDirty() =>
      snapshot() != initial ||
      (initial is CustomRuleJson &&
          _jsonMode &&
          jsonCtrl.text != _initialJsonText);

  /// Исходный текст поля JSON (тело дерева либо текст json-правила).
  String _initialJsonText = '';

  /// §757 — текст JSON-вида снова разбирается деревом (кодек записи, путь
  /// хранения): правило остаётся деревом с целью из текста и DNS / resolve /
  /// TTL наборов формы. Не дерево — null (сохранится json-правилом).
  CustomRuleTree? _treeFromJsonText(String name) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonCtrl.text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final init = initial;
    final read = ruleFromRecord({
      'kind': 'inline',
      'id': init.id,
      'name': name,
      'enabled': _enabled,
      'body': decoded.cast<String, dynamic>(),
    }, unknownAsVerbatim: true);
    final v = read.value;
    if (v is! CustomRuleTree) return null;
    final eligible = _hasRefsOrDomain(v.root);
    return CustomRuleTree(
      id: init.id,
      name: name,
      enabled: _enabled,
      orderNum: init.orderNum,
      root: v.root,
      outbound: v.outbound,
      dns: _dns,
      resolve: eligible ? _resolve : null,
      updateIntervalHours: _srsTtlHours,
    );
  }

  /// §447 — единственная проверка перед сохранением: Save формы, Save в
  /// AppBar и Save из диалога несохранённых правок. `null` — сохранять можно,
  /// иначе текст причины (тот же, что под полем JSON). Текст формы не
  /// трогается — пользователь исправляет набранное.
  String? get saveBlockReason =>
      jsonError ??
      regexError ??
      // §757 — правило без условий (как у формы лаунчера).
      (_formKind && _stack.toNode() == null
          ? getLocalText.s("The rule has no conditions")
          : null) ??
      // §683 — поле Fixed IP и Advanced-поля резолва.
      (_formKind
          ? (fixedIpError ??
              (_resolve != null && resolveEligible
                  ? (resolveTtlError ??
                      resolveTimeoutError ??
                      resolveSubnetError)
                  : null))
          : null);

  /// §712 / §757 — первая невалидная регулярка в полях-регулярках всех
  /// условий дерева формы. Ядро на битой регулярке не стартует — Save
  /// блокируется.
  String? get regexError {
    if (!_formKind) return null;
    for (final f in _stack.allFrames) {
      for (final k in f.cond.keys) {
        if (!norm.isRegexConditionKey(k.key)) continue;
        final bad = norm
            .normalizedRegexes(f.text(k.key))
            .where((r) => !val.isValidRegex(r))
            .firstOrNull;
        if (bad != null) {
          return getLocalText.s(
              "%1\$s: invalid regex %2\$s", condKeyLabel(k), bad);
        }
      }
    }
    return null;
  }

  /// §225 — валиден ли текущий текст json-правила (для inline-хелпера в
  /// JsonSection и гейта Save). `null` = ок (нет ошибки), иначе краткое
  /// описание. Пустой ввод считается «ещё не заполнено» (ошибка), т.к.
  /// сохранять пустое json-правило смысла нет.
  ///
  /// §439 В2 — массив не сохраняется: запись правила держит один объект
  /// sing-box, несколько правил заводятся отдельно.
  String? get jsonError {
    if (kind != CustomRuleKind.json) return null;
    final text = jsonCtrl.text.trim();
    if (text.isEmpty) return 'Enter a JSON object.';
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return 'Invalid JSON.';
    }
    if (decoded is Map) return null;
    if (decoded is List) {
      return getLocalText.s(
          "One rule holds one JSON object. Add each object of the array as a separate rule.");
    }
    return 'Expected a JSON object.';
  }
}

/// §045: tag+url пара для batch download'а внутри `onBoolVarToggle`.
class _PendingDownload {
  const _PendingDownload({required this.tag, required this.url});
  final String tag;
  final String url;
}

/// §053 Stage 3 — InheritedNotifier для раздачи controller'а вниз по
/// tree без prop-drilling. Любой widget внутри `body` editor'а делает
/// `CustomRuleEditScope.of(context)` и подписывается на rebuild при
/// `notifyListeners`.
class CustomRuleEditScope extends InheritedNotifier<CustomRuleEditController> {
  const CustomRuleEditScope({
    super.key,
    required CustomRuleEditController super.notifier,
    required super.child,
  });

  static CustomRuleEditController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<CustomRuleEditScope>();
    assert(scope != null, 'CustomRuleEditScope.of: no scope in context');
    return scope!.notifier!;
  }
  // §141 P2.3i — `read()` (non-listening lookup) удалён: 0 call-sites.
}

/// §683 — режим Answer секции DNS & Resolve.
enum DnsAnswerMode { defaultDns, dedicated, fixedIp }
