import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/background_mode.dart';
import '../models/memory_limit_setting.dart';
import '../models/parser_config.dart';
import '../services/builder/if_engine.dart';
import '../services/l10n/template_aware_state.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../widgets/template_var_list.dart';
import '../widgets/var_values_model.dart';
import 'vpn_mode_tab.dart';
import '../services/l10n/locale_controller.dart';

/// VPN Settings — System (`VpnService.Builder` toggles) + Core (sing-box
/// engine vars, `chapter: 'core'`). Routing/DNS vars живут на своих экранах.
/// SPEC 393 D3 — гасит подпись выключенной строки настроек.
///
/// Visible-связь «галка → поля» должна гасить СТРОКУ целиком, а не только
/// контрол: §277 сделал серым дропдаун, но подпись и описание оставались в
/// полную силу — выключенная настройка читалась как активная, и связь была
/// заметна только при попытке её тронуть.
///
/// Именно [Opacity], а не `DefaultTextStyle`: подписи несут ЯВНЫЙ цвет из
/// `textTheme`/`colorScheme`, унаследованный стиль их не перекрасил бы, и
/// «починка» осталась бы невидимой. Не `IgnorePointer`/`AbsorbPointer` —
/// текст и так не интерактивен, гасится ровно читаемость.
///
/// 0.38 — коэффициент disabled-состояния Material 3, тот же, которым гаснет
/// сам контрол: строка и её поле тускнеют одинаково.
///
/// Top-level (не приватный метод State) — чтобы покрываться unit-тестом
/// напрямую, без харнесса всего экрана. Тот же приём, что
/// `assertMagicNodeMirrors` в `template_loader.dart`.
Widget dimmedWhenDisabled({required bool enabled, required Widget child}) {
  if (enabled) return child;
  return Opacity(opacity: kDisabledRowOpacity, child: child);
}

/// Непрозрачность выключенной строки — Material 3 disabled state layer.
const double kDisabledRowOpacity = 0.38;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
    this.initialTab = 0,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  /// 0 = System, 1 = Core, 2 = Mode (§119). Used by deep-links.
  final int initialTab;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver, TemplateAwareState<SettingsScreen> {
  // §279 — заполняется через TemplateAwareState (didChangeDependencies по
  // локали), НЕ в initState: смена языка перечитывает локализованный шаблон.
  WizardTemplate? _template;
  // §232 — реактивная модель значений vars (per-key ValueNotifier). Единый
  // источник истины для экрана: поля TemplateVarListView подписаны каждый на
  // свой ключ, программные изменения (`on_change`) видны в UI мгновенно.
  // Запись — ТОЛЬКО в память (+dirty); storage/cache трогает только `_persist`
  // (dispose/paused, §076 write-on-exit) по model.dirtyKeys. Юзер, ушедший до
  // persist (force-kill), staged-значения теряет — как и раньше для всех
  // правок этого экрана.
  //
  // §084 M14 / §189: Native VPN System toggle (background_mode; §188 —
  // allow_bypass / keep_on_exit переехали в Mode-вкладку) идёт через
  // `SettingsStorage.setNativeBackgroundMode` (§189 — JSON-истина + зеркало в
  // native) + `markConfigChangedNeedRestart` (home banner «Restart VPN»). Это
  // discrete-event toggle, не config-rebuild var.
  VarValuesModel? _model;
  bool _loading = true;

  BackgroundMode _backgroundMode = BackgroundMode.never;
  bool _vpnLoaded = false;
  // §271 — memory limit ядра (native_prefs, wire-значения MemoryLimitSetting).
  String _memoryLimit = MemoryLimitSetting.auto;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // _load() стартует из onLocaleTemplateFetch (TemplateAwareState, §279).
  }

  /// §279 — первый вызов (до первого build) — полная загрузка; смена локали —
  /// только refetch шаблона (модель значений var'ов — machine-ключи, staged
  /// правки юзера не трогаем).
  @override
  void onLocaleTemplateFetch({required bool first}) {
    if (first) {
      unawaited(_load());
    } else {
      unawaited(_refetchTemplate());
    }
  }

  Future<void> _refetchTemplate() async {
    final template = await TemplateLoader.load();
    if (!mounted) return;
    setState(() => _template = template);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // §076 write-on-exit: Navigator.pop → flush dirty vars. Снимок значений
    // _persist делает СИНХРОННО до первого await — поэтому dispose модели
    // сразу после запуска безопасен (use-after-dispose исключён).
    if (_model?.dirtyKeys.isNotEmpty ?? false) unawaited(_persist());
    _model?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        (_model?.dirtyKeys.isNotEmpty ?? false)) {
      unawaited(_persist());
    }
  }

  /// §232 — ЕДИНСТВЕННОЕ место записи vars в storage: снимаем dirty-значения
  /// из модели (синхронно), стейджим в cache (`setVar flush:false`), один
  /// атомарный `flushToDisk()`. До этого момента все изменения — только в
  /// памяти модели (strict-семантика on_change: «юзер может не сохранить»).
  Future<void> _persist() async {
    final model = _model;
    if (model == null || model.dirtyKeys.isEmpty) return;
    // Синхронный снимок ДО await — dispose() модели после нас не страшен.
    final staged = {for (final k in model.dirtyKeys) k: model.get(k)};
    model.clearDirty();
    for (final e in staged.entries) {
      await SettingsStorage.setVar(e.key, e.value, flush: false);
    }
    await SettingsStorage.flushToDisk();
    // configDirty уже true (set in _onVarChanged sync). Не трогаем.
  }

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final storedVars = await SettingsStorage.getAllVars();
    _model = VarValuesModel({
      for (final v in template.vars)
        v.name: storedVars[v.name] ?? v.defaultValue,
    });
    // §189 — background_mode читаем из JSON-зеркала native_prefs (истина).
    final bgMode = BackgroundMode.fromNative(
        await SettingsStorage.getNativeBackgroundMode());
    final memoryLimit = await SettingsStorage.getNativeMemoryLimit(); // §271
    setState(() {
      _template = template;
      _backgroundMode = bgMode;
      _memoryLimit = memoryLimit;
      _vpnLoaded = true;
      _loading = false;
    });
  }

  // §188 — _toggleAllowBypass / _toggleKeepOnExit переехали в vpn_mode_tab.dart.

  Future<void> _applyBackgroundMode(BackgroundMode? mode) async {
    if (mode == null || mode == _backgroundMode) return;
    setState(() => _backgroundMode = mode);
    // §189 — через NativePrefs (JSON-истина + зеркало в native).
    await SettingsStorage.setNativeBackgroundMode(mode.wireValue);
    widget.homeController.markConfigChangedNeedRestart();
  }

  /// §271 — memory limit ядра. НЕ config-significant (не входит в sing-box
  /// JSON): native применяет к работающему ядру немедленно через
  /// reloadSetupOptions — без Restart-баннера и «next connect».
  Future<void> _applyMemoryLimit(String value) async {
    if (value == _memoryLimit) return;
    setState(() => _memoryLimit = value);
    await SettingsStorage.setNativeMemoryLimit(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(getLocalText.s("Applied.")),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// §076/§107: template var change. Staged-запись в `_cache` сразу + sync
  /// Колбэк от [TemplateVarListView] — значение УЖЕ в модели (виджет пишет
  /// через `model.set` до вызова). Здесь только config-dirty + каскад
  /// декларативных side-effect'ов.
  void _onVarChanged(String name, String value) {
    widget.subController.configDirty = true; // sync race-safe
    _applyOnChange(name);
  }

  /// §232 — декларативный side-effect var'а: `on_change.set` пишет производные
  /// var ТОЛЬКО в модель (in-memory + per-key emit подписанным полям + dirty).
  /// Storage не трогаем — staged-значения доедут до диска общим `_persist`
  /// (write-on-exit). Резолвер читает snapshot модели, где переключённая var
  /// уже новая. Рекурсия по цепочке on_change; fixpoint-guard: `model.set`
  /// возвращает false для неизменившегося значения → цикл обрывается.
  void _applyOnChange(String name) {
    final model = _model;
    final template = _template;
    if (model == null || template == null) return;
    final node = template.vars.where((v) => v.name == name).firstOrNull;
    // Канон — помеченный `#set`; легаси `set` читается бессрочно (SPEC 107).
    final set = node?.onChange?['#set'] ?? node?.onChange?['set'];
    if (set is! Map<String, dynamic>) return;
    final byName = {for (final v in template.vars) v.name: v};
    final resolve = makeResolver(model.snapshot, byName);
    set.forEach((target, ifNode) {
      final tName = target.startsWith('@') ? target.substring(1) : target;
      if (ifNode is! Map<String, dynamic>) return;
      final resolved = evalIfScalar(ifNode, resolve);
      if (resolved == null) return;
      if (model.set(tName, resolved)) {
        widget.subController.configDirty = true;
        _applyOnChange(tName); // цепочка on_change целевой var (если есть)
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(getLocalText.s("VPN Settings"))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;
    final editableVars = template
        .varsFor('core')
        .where((v) => v.isEditable)
        .toList();

    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("VPN Settings")),
          bottom: TabBar(
            tabs: [
              Tab(text: getLocalText.s("System")),
              Tab(text: getLocalText.s("Core")),
              Tab(text: getLocalText.s("Mode")),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSystemTab(context),
            _buildCoreTab(context, template, editableVars),
            VpnModeTab(
              homeController: widget.homeController,
              subController: widget.subController,
              template: template,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemTab(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        // §188 — «Allow VPN bypass» и «Keep VPN on exit» переехали в Mode-вкладку
        // (TUN-зависимы → видны только в vpn / vpn_proxy режимах).
        // §143 §9 — тумблер «Interrupt connections on switch» снят: обрыв
        // соединений при смене узла — галка Направления (ядро, SPEC 064).
        // §709 — WireGuard и QUIC переехали на Core островами.
        SettingsIsland(
          title: 'Optimization',
          description: 'Health checks, memory and VPN lifecycle',
          children: [
            // §271 — memory limit ядра. Применяется к работающему ядру сразу.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    getLocalText.s("Memory limit"),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    getLocalText.s("Memory threshold for the VPN core itself (its Go runtime), not the whole app process. Above the threshold the core drops its connections and frees memory, and near it the garbage collector keeps the processor busy and heats the phone. Auto sets no threshold. With any value the core also watches the system's free memory. Applies immediately. The current figure is in Statistics → Memory → Core memory."),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: DropdownButtonFormField<String>(
                initialValue: _memoryLimit,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String>(
                      value: MemoryLimitSetting.auto,
                      child: Text(getLocalText.s("Auto (recommended)"))),
                  // §705 — пункта Off нет: он давал бы тот же 0, что и Auto.
                  DropdownMenuItem<String>(
                      value: '200', child: Text(getLocalText.s("%d MB", 200))),
                  DropdownMenuItem<String>(
                      value: '384', child: Text(getLocalText.s("%d MB", 384))),
                  DropdownMenuItem<String>(
                      value: '512', child: Text(getLocalText.s("%d MB", 512))),
                  DropdownMenuItem<String>(
                      value: '768', child: Text(getLocalText.s("%d MB", 768))),
                ],
                onChanged: (String? v) {
                  if (!_vpnLoaded || v == null) return;
                  unawaited(_applyMemoryLimit(v));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    getLocalText.s("Tunnel sleep mode"),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    getLocalText.s("When to pause the tunnel to save battery. Takes effect on next VPN connect."),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            RadioGroup<BackgroundMode>(
              groupValue: _backgroundMode,
              onChanged: (BackgroundMode? m) {
                if (!_vpnLoaded) return;
                unawaited(_applyBackgroundMode(m));
              },
              child: Column(
                children: [
                  RadioListTile<BackgroundMode>(
                    value: BackgroundMode.never,
                    title: Text(getLocalText.s("Never sleep (recommended)")),
                    subtitle: Text(getLocalText.s("Tunnel is always active. Best reliability — pushes and long-lived sockets survive. Higher battery use.")),
                  ),
                  RadioListTile<BackgroundMode>(
                    value: BackgroundMode.lazy,
                    title: Text(getLocalText.s("Lazy sleep")),
                    subtitle: Text(getLocalText.s("Pause only in deep Doze (screen off for a long time + no motion). Balanced.")),
                  ),
                  RadioListTile<BackgroundMode>(
                    value: BackgroundMode.always,
                    title: Text(getLocalText.s("Aggressive battery saving")),
                    subtitle: Text(getLocalText.s("Pause tunnel whenever screen turns off. Max battery savings, but pushes, incoming calls and background sync stop until the screen turns on again.")),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// §709 — короткие подсказки (i) у переменных корневого блока `lx` ядра
  /// (секции Network / WireGuard / QUIC шаблона).
  static Map<String, String> _lxVarHints() => {
        'wg_idle_suspend': getLocalText.s("Core: lx.wg.idle_suspend. An idle WireGuard endpoint that is not on the active route is torn down and rebuilt on its next dial."),
        'wg_idle_suspend_reachable': getLocalText.s("Core: lx.wg.idle_suspend_reachable. The same sleep for endpoints on the active route, after a longer quiet period."),
        'wg_lazy_build': getLocalText.s("Core: lx.wg.lazy_build. An endpoint is built on its first dial instead of at core start."),
        'wg_build_max': getLocalText.s("Core: lx.wg.build_max. Over the limit the endpoint idle for the longest is torn down."),
        'awg_masquerade': getLocalText.s("Core: lx.awg_masquerade. The masquerade burst of an AWG endpoint (ip=quic, i1…) precedes the handshake. Through a detour the relay sees it as a QUIC flow and may redirect it by SNI, so by default it goes out only on the device's own socket."),
        'mtu_align': getLocalText.s("Core: lx.mtu_align. A node over a tunnel gets a packet size that fits into it: mtu for WireGuard and MASQUE, the initial packet size for Hysteria2 and TUIC. Values are never raised."),
        'masque_idle_timeout': getLocalText.s("Core: lx.masque.idle_timeout. The idle window for MASQUE nodes that have no idle_timeout of their own."),
        'quic_sniff_decoy': getLocalText.s("Core: lx.quic_sniff_decoy. A relay with UDP sniffing (Xray destOverride quic) rewrites the destination by the SNI of the first QUIC packet; a junk first byte makes it give up. Servers drop the byte. A DPI on your own uplink may react to it, hence Through detour by default. Also covers the AWG masquerade burst that imitates QUIC (ip=quic)."),
      };

  Widget _buildCoreTab(
    BuildContext context,
    WizardTemplate template,
    List<WizardVar> editableVars,
  ) {
    final sectionDescriptions = {
      for (final s in template.sectionsFor('core')) s.title: s.description,
    };
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        if (editableVars.isNotEmpty)
          TemplateVarListView(
            vars: editableVars,
            model: _model!,
            sectionDescriptions: sectionDescriptions,
            onChanged: _onVarChanged,
            // §709 — секции островами; lx-переменные с (i)-подсказкой.
            islands: true,
            hints: _lxVarHints(),
          ),
      ],
    );
  }
}
