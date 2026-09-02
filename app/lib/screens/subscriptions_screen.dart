import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/server_list.dart';
import '../services/error_format.dart';
import '../services/settings_storage.dart';
import '../services/subscription/auto_updater.dart';
import '../services/url_launcher.dart';
import 'add_server_wizard_screen.dart';
import 'app_settings_screen.dart';
import 'folder_detail_screen.dart';
import 'node_settings_screen.dart';
import 'qr_scan_screen.dart';
import 'subscription_detail_screen.dart';
import 'warp_wizard_screen.dart';
import 'subscriptions_screen/clipboard_analysis.dart';
import 'subscriptions_screen/entry_context_menu.dart';
import 'subscriptions_screen/folder_picker.dart';
import 'subscriptions_screen/paste_dialogs.dart';
import 'subscriptions_screen/public_test_servers.dart';
import '../models/source_chain.dart';
import 'chain_edit/new_chain_dialog.dart';
import 'chain_edit_screen.dart';
import 'subscriptions_screen/widgets/add_icon_button.dart';
import 'subscriptions_screen/widgets/chains_section.dart';
import 'subscriptions_screen/widgets/subscription_entry_tile.dart';
import 'subscriptions_screen/widgets/subscriptions_empty_state.dart';
import '../services/l10n/locale_controller.dart';
import '../services/file_import.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({
    super.key,
    required this.subController,
    required this.homeController,
    required this.autoUpdater,
    this.focusEntryId,
    this.initialInput,
  });

  final SubscriptionController subController;
  final HomeController homeController;
  final AutoUpdater autoUpdater;

  /// §255 — при открытии проскроллить к этому entry и мигнуть его строкой
  /// (навигация из detour-cycle sheet к владельцу ноды-виновника). null = нет.
  final String? focusEntryId;

  /// §357 — предзаполнить поле «URL подписки или proxy-ссылка» (lxbox-кнопка
  /// `add:<uri>` support-ленты). Только prefill: добавление подтверждает сам
  /// юзер кнопкой «+». null = пустое поле.
  final String? initialInput;

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  final _inputController = TextEditingController();
  bool _autoUpdateEnabled = true;

  /// §393 D1 — источники-цепочки. Рисуются СТРОКАМИ ОБЩЕГО СПИСКА наравне с
  /// подписками ([_rows]), но живут в своём storage-ключе (`chains[]`), а не в
  /// `SubscriptionController.entries`: цепочка написана пользователем руками и
  /// обязана пережить и обновление подписки, и её удаление. Отсюда отдельная
  /// загрузка — контроллер о них ничего не знает.
  List<SourceChain> _chains = const [];

  /// §375 — есть ли камера. null = ещё не ответил канал; до ответа пункт
  /// «Scan QR code» показываем (проверка мгновенная, на телефоне камера есть
  /// практически всегда). На Android TV — false, пункт прячется.
  bool? _hasCamera;

  // §255 — прокрутка к владельцу + вспышка строки (навигация из detour-cycle
  // sheet). Локальная (в этом экране нет HomeState для персистентного кольца) —
  // таймер-вспышка, гаснет сама.
  final _scrollController = ScrollController();
  final _tileKeys = <String, GlobalKey>{};
  String? _highlightedEntryId;
  Timer? _highlightTimer;

  GlobalKey _tileKey(String id) => _tileKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoUpdateFlag());
    unawaited(_loadCameraAvailability());
    unawaited(_loadChains());
    // §357 — prefill поля ввода из lxbox-кнопки `add:<uri>` support-ленты.
    final prefill = widget.initialInput;
    if (prefill != null && prefill.trim().isNotEmpty) {
      _inputController.text = prefill.trim();
    }
    final focus = widget.focusEntryId;
    if (focus != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusEntry(focus, attempt: 0));
    }
  }

  /// §255 — скролл к строке владельца + вспышка. Retry по кадрам: строка за
  /// вьюпортом в lazy-списке не смонтирована (currentContext null); грубо
  /// прыгаем по оценке позиции и повторяем ensureVisible.
  void _focusEntry(String id, {required int attempt}) {
    if (!mounted) return;
    if (attempt == 0) setState(() => _highlightedEntryId = id);
    const maxAttempts = 6;
    final ctx = _tileKeys[id]?.currentContext;
    if (ctx != null) {
      unawaited(Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.3));
    } else if (attempt < maxAttempts && _scrollController.hasClients) {
      final idx = widget.subController.entries.indexWhere((e) => e.id == id);
      if (idx >= 0) {
        final target = (idx * 88.0)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.jumpTo(target);
      }
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusEntry(id, attempt: attempt + 1));
      return;
    }
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _highlightedEntryId = null);
    });
  }

  Future<void> _loadAutoUpdateFlag() async {
    final v = await SettingsStorage.getAutoUpdateSubs();
    if (!mounted) return;
    setState(() => _autoUpdateEnabled = v);
  }

  /// §375 — спрашиваем платформу о камере один раз при открытии экрана:
  /// меню строится синхронно в itemBuilder, асинхронную проверку туда не
  /// вставить.
  Future<void> _loadCameraAvailability() async {
    final v = await UrlLauncher.hasCamera();
    if (!mounted) return;
    setState(() => _hasCamera = v);
  }

  // ── §393 C7/D1 — источники-цепочки ─────────────────────────────────────

  Future<void> _loadChains() async {
    final v = await SettingsStorage.getChains();
    if (!mounted) return;
    setState(() => _chains = v);
  }

  /// Создание цепочки: тег спрашиваем ДО создания (после он immutable — на
  /// него ссылаются фильтры Направлений, `route_final` и позиции ДРУГИХ
  /// цепочек), затем сразу открываем форму: пустая цепочка ядру не годится
  /// (нужно минимум две позиции), и оставлять пользователя наедине со строкой
  /// «0 hops» смысла нет.
  Future<void> _addChain() async {
    final directions = await SettingsStorage.getDirections();
    if (!mounted) return;
    final req = await showNewChainDialog(
      context,
      usedTags: [
        ..._chains.map((c) => c.tag),
        ...directions.map((d) => d.tag),
      ],
    );
    if (req == null || !mounted) return;
    final SourceChain created;
    try {
      created = await SettingsStorage.addChain(tag: req.tag);
    } on StateError catch (e) {
      // Гонка со вторым источником мутаций (Debug API / restore): форма
      // считала тег свободным, storage — уже нет.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    await _loadChains();
    if (!mounted) return;
    await _editChain(created);
  }

  Future<void> _editChain(SourceChain chain) async {
    final directions = await SettingsStorage.getDirections();
    if (!mounted) return;
    final result = await openChainEditor(
      context,
      initial: chain,
      // Последний собранный конфиг — источник ОКОНЧАТЕЛЬНЫХ тегов позиций
      // (префикс подписки приклеен, дубли уникализированы аллокатором).
      config: widget.homeController.state.configModel,
      directions: directions,
      chains: _chains,
    );
    if (result == null || !mounted) return;
    var chainPositionsRemoved = 0;
    if (result.wasDeleted) {
      // §393 D2 — каскад через цепочки-позиции: удаление этой цепочки снимает
      // её ПОЗИЦИЮ у остальных, но их самих не трогает.
      final healed = await SettingsStorage.deleteChain(chain.tag);
      chainPositionsRemoved = healed.positions;
    } else if (result.saved != null) {
      await SettingsStorage.updateChain(result.saved!);
    }
    await _loadChains();
    if (!mounted) return;
    // Укороченный маршрут обязан быть замечен: цепочка ниже двух позиций
    // теперь не эмитится, 3+ хопов эмитится короче — пользователь узнаёт об
    // этом здесь, тем же механизмом, что rules/detours-heal (§202/§248).
    _notifyChainPositionsRemoved(chainPositionsRemoved);
    // Цепочка — узел конфига: правка маршрута обязана доехать до сборки, иначе
    // пользователь увидит старый маршрут под новым именем.
    await _regenerateAndSave();
  }

  /// §393 D2 — уведомление о вычищенных позициях цепочек.
  ///
  /// Тот же механизм, что у rules/detours/includes-heal (§202/§248): счётчик
  /// в snackbar'е. Показывать обязательно — удаление источника МЕНЯЕТ МАРШРУТ
  /// уцелевших цепочек (3+ хопов эмитится укороченной, 2-хоповая перестаёт
  /// эмититься вовсе), и промолчать значило бы подменить маршрут молча.
  void _notifyChainPositionsRemoved(int removed) {
    if (removed <= 0 || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(getLocalText.s('%s chain position(s) removed', '$removed')),
    ));
  }

  /// §393 D2 — забрать счётчик, накопленный контроллером на удалении
  /// источника, и показать его. Контроллер копит, экран показывает: у
  /// контроллера нет `BuildContext`, а у экрана — знания, какие мутации
  /// сейчас прошли.
  void _drainChainHealNotice() {
    final removed = widget.subController.lastChainPositionsRemoved;
    if (removed <= 0) return;
    widget.subController.clearChainHealNotice();
    _notifyChainPositionsRemoved(removed);
    unawaited(_loadChains()); // строки цепочек показывают новое число хопов
  }

  Future<void> _toggleChain(SourceChain chain) async {
    await SettingsStorage.updateChain(
        chain.copyWith(enabled: !chain.enabled));
    await _loadChains();
    if (!mounted) return;
    await _regenerateAndSave();
  }

  Future<void> _toggleAutoUpdate() async {
    final next = !_autoUpdateEnabled;
    await SettingsStorage.setAutoUpdateSubs(next);
    if (!mounted) return;
    setState(() => _autoUpdateEnabled = next);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    // Unsaved-input guard (night T4-3): если юзер ввёл что-то в поле и
    // уходит со screen без сабмита — подтверждаем, чтобы не терять URL
    // / proxy-link, который он только что вставил.
    final pending = _inputController.text.trim();
    if (pending.isEmpty) return true;
    if (!mounted) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Discard input?")),
        content: Text(getLocalText.s("You have unsaved text in the input field. Leave and discard it?")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Stay")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Discard")),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// §074 — open Add server wizard (long-press на «+»). Wizard сам зовёт
  /// `addUserServer`/`addFromInput`; после successful add — callback
  /// делает `_regenerateAndSave` тут.
  void _openAddServerWizard() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AddServerWizardScreen(
        subController: widget.subController,
        onAdded: _regenerateAndSave,
      ),
    ));
  }

  /// Открыть App Settings сразу на табе «Subscriptions» (initialTab: 1).
  void _openSubscriptionSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const AppSettingsScreen(initialTab: 1),
    ));
  }

  /// §025 — открыть full-screen визард Cloudflare WARP.
  void _openWarpWizard() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WarpWizardScreen(
        subController: widget.subController,
        onAdded: _regenerateAndSave,
      ),
    ));
  }

  Future<void> _add() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      // Пустое поле + тап «+» = paste-from-clipboard поток с диалогом
      // подтверждения (анализ + предпросмотр).
      await _pasteFromClipboard();
      return;
    }
    await widget.subController.addFromInput(text);
    if (widget.subController.lastError == null) {
      _inputController.clear();
      await _regenerateAndSave();
    }
  }

  /// После любого add'а — пересобрать конфиг и сохранить, чтобы новые
  /// узлы попали в выбираемые group'ы без ручного нажатия rebuild.
  Future<void> _regenerateAndSave() async {
    final config = await widget.subController.generateConfig();
    if (!mounted || config == null) return;
    await widget.homeController.saveParsedConfig(config);
    if (!mounted) return;
    final n = widget.subController.entries
        .where((e) => e.enabled)
        .fold<int>(0, (s, e) => s + e.nodeCount);
    // Директива оператора 24.08 («поменял цепочку — конфиг не перестроился
    // сам»): правка источников при живом туннеле применяется сама через
    // in-place reload (§367-механика, туннель не рвётся), а не баннером
    // «перезапустите VPN». Гейт canReload даёт connected + cooldown 3s —
    // серия быстрых правок не устроит шторм перезагрузок: применится
    // последняя по баннеру, как раньше.
    final applied = widget.homeController.canReload;
    if (applied) unawaited(widget.homeController.reloadVpn());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(applied
              ? getLocalText.plural("Config regenerated & applied: %d nodes", n)
              : getLocalText.plural("Config regenerated: %d nodes", n)),
          duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Clipboard is empty"))),
        );
      }
      return;
    }

    final analysis = analyzeClipboard(text);
    if (!mounted) return;

    if (analysis.type == 'unknown') {
      showUnknownFormatDialog(context, text);
      return;
    }

    final confirmed = await showConfirmAddDialog(context, analysis);

    if (confirmed != true || !mounted) return;
    await widget.subController.addFromInput(text);
    final addErr = widget.subController.lastError;
    if (addErr == null) {
      await _regenerateAndSave();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(addErr.render())),
      );
    }
  }

  /// §375 — импорт по QR-коду с камеры. Сканер только поставляет строку:
  /// разбор формата и подтверждение — тот же путь, что у буфера обмена, так
  /// что юзер видит, что именно приехало в коде, до записи в конфиг (QR —
  /// недоверенный ввод из внешнего мира).
  Future<void> _scanQrCode() async {
    final outcome = await Navigator.of(context).push<ScanOutcome>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (!mounted) return;

    // Уход системной кнопкой «назад» — pop без значения.
    if (outcome is! ScannedCode) {
      final problem =
          outcome == null ? null : scanProblemText(outcome);
      if (problem != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(problem)),
        );
      }
      return;
    }

    final text = outcome.value;
    final analysis = analyzeClipboard(text);
    if (!mounted) return;

    if (analysis.type == 'unknown') {
      showUnknownFormatDialog(context, text);
      return;
    }

    final confirmed = await showConfirmAddDialog(context, analysis);
    if (confirmed != true || !mounted) return;

    await widget.subController
        .addFromInput(text, origin: UserSource.qr);
    final addErr = widget.subController.lastError;
    if (addErr == null) {
      await _regenerateAndSave();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(addErr.render())),
      );
    }
  }

  /// §234 — создать пустую папку серверов.
  Future<void> _createFolder() async {
    final name = await showFolderNameDialog(context);
    if (name == null) return;
    await widget.subController.addFolder(name);
  }

  /// Импорт подписки/конфига из файла. Содержимое (URI-список, JSON-конфиг,
  /// proxy-link) идёт в тот же `addFromInput`, что и paste/manual — парсер
  /// сам определяет формат. file_picker уже используется на других экранах
  /// (config_screen / backup) — паттерн чтения bytes/path идентичный.
  ///
  /// §234 — multi-select: несколько файлов → все серверы в новую папку
  /// (имена нод — из имён файлов). Один файл — прежние пути (§129
  /// file-подписка при >1 ноды / одиночный сервер).
  Future<void> _importFromFile() async {
    try {
      // §372 — Android TV без файлового менеджера: подсказка вместо тупика.
      final outcome = await pickFileSafely(allowMultiple: true);
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(problem)));
        }
        return;
      }
      if (outcome.files.length > 1) {
        await _importFilesIntoFolder(outcome.files);
        return;
      }
      final file = outcome.single;
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(getLocalText.s("File is empty"))),
          );
        }
        return;
      }
      if (!mounted) return;
      // §129 — если в файле > 1 ноды, создаём ФАЙЛОВУЮ подписку (снапшот в
      // кэше, живёт как обычная подписка). ≤ 1 ноды → старое поведение
      // (addFromInput → одиночный сервер/нода).
      final asFileSub =
          await widget.subController.addFileSubscription(text, file.name);
      if (!asFileSub) {
        if (!mounted) return;
        // §243 — имя файла уходит nameHint'ом: для WG/AWG `.conf` оно
        // становится tag'ом узла (фрагмент синтетического URI). Прежний
        // §234-renameAt в entry.name убран — displayName одиночного сервера
        // name игнорирует, правда живёт в tag'е.
        await widget.subController.addFromInput(text,
            nameHint: SubscriptionController.fileBaseName(file.name));
      }
      final importErr = widget.subController.lastError;
      if (importErr == null) {
        await _regenerateAndSave();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(importErr.render())),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(getLocalText.s(
                  "Error: %s", formatUserError(e).render()))),
        );
      }
    }
  }

  static Future<String?> _readPickedFile(PlatformFile file) async {
    if (file.bytes != null && file.bytes!.isNotEmpty) {
      return String.fromCharCodes(file.bytes!);
    }
    if (file.path != null) return File(file.path!).readAsString();
    return null;
  }

  /// §234 — несколько выбранных файлов → новая папка со всеми серверами.
  Future<void> _importFilesIntoFolder(List<PlatformFile> files) async {
    final name = await showFolderNameDialog(context,
        title: getLocalText.plural("Import %d files into folder", files.length));
    if (name == null || !mounted) return;
    await widget.subController.addFolder(name);
    final folderIndex = widget.subController.entries.length - 1;
    var addedFiles = 0;
    final errors = <String>[];
    for (final file in files) {
      final text = (await _readPickedFile(file))?.trim() ?? '';
      if (text.isEmpty) {
        errors.add(getLocalText.s("%s: empty file", file.name));
        continue;
      }
      final err = await widget.subController.addMembersToFolder(
        folderIndex,
        text,
        nameFallback: SubscriptionController.fileBaseName(file.name),
      );
      if (err == null) {
        addedFiles++;
      } else {
        errors.add('${file.name}: ${err.render()}');
      }
    }
    if (!mounted) return;
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errors.join('\n'))),
      );
    }
    if (addedFiles > 0) {
      await _regenerateAndSave();
    }
  }

  Future<void> _updateAll() async {
    // Ручной force-refresh: сбрасываем session-cap (5 фейлов) и форсим через
    // AutoUpdater — так получаем `_running` guard от дубль-кликов и общий
    // логирующий путь. После fetch'а — локальный generateConfig (без HTTP).
    widget.autoUpdater.resetAllFailCounts();
    await widget.autoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: true);
    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (!mounted) return;
    if (config != null) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              getLocalText.plural("Config generated: %d nodes", widget.subController.entries
                  .fold<int>(0, (s, e) => s + e.nodeCount)),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.subController,
      builder: (context, _) {
        final ctrl = widget.subController;
        // §393 D2 — счётчик вычищенных позиций накопил контроллер (удаление
        // источника идёт из контекстного меню, у которого нет ни нашего
        // состояния, ни списка цепочек). Забираем его ПОСЛЕ кадра: snackbar
        // во время build запрещён, а мутация уже завершилась — контроллер
        // как раз поэтому и уведомил.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _drainChainHealNotice());
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (await _onWillPop()) {
              if (context.mounted) Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(getLocalText.s("Servers")),
                  Text(getLocalText.s("Subscriptions & proxy"),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.normal)),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: getLocalText.s("Update all & generate"),
                  onPressed: ctrl.busy ? null : () => unawaited(_updateAll()),
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    // §074: «Add server» — duplicate access к wizard'у
                    // (long-press на «+» — discoverability через accidental,
                    // overflow menu — explicit affordance).
                    if (v == 'wizard') _openAddServerWizard();
                    if (v == 'warp') _openWarpWizard();
                    if (v == 'public') unawaited(_pickPublicTestServer());
                    if (v == 'paste') unawaited(_pasteFromClipboard());
                    if (v == 'qr') unawaited(_scanQrCode());
                    if (v == 'file') unawaited(_importFromFile());
                    if (v == 'folder') unawaited(_createFolder());
                    if (v == 'chain') unawaited(_addChain());
                    if (v == 'auto_update') unawaited(_toggleAutoUpdate());
                    if (v == 'sub_settings') _openSubscriptionSettings();
                  },
                  itemBuilder: (_) => [
                    // Раскладка утверждена оператором 24.08: четыре смысловые
                    // секции — создать / получить готовое / импортировать / подписки.
                    PopupMenuItem(value: 'wizard', child: Text(getLocalText.s("Add server…"))),
                    // §393 C7 — цепочка это ТРЕТИЙ ТИП ИСТОЧНИКА (маршрут через
                    // несколько хопов подряд): создание рядом с сервером, а не среди
                    // Направлений (§393 L5).
                    PopupMenuItem(
                        value: 'chain',
                        child: Text(getLocalText.s("Add hop chain…"))),
                    PopupMenuItem(value: 'folder', child: Text(getLocalText.s("New folder…"))),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'warp', child: Text(getLocalText.s("Get WARP"))),
                    PopupMenuItem(value: 'public', child: Text(getLocalText.s("Get Public Test Servers"))),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'paste', child: Text(getLocalText.s("Paste from clipboard"))),
                    // §375 — на устройстве без камеры (Android TV) пункта нет:
                    // альтернативы у сканирования не существует, и пункт,
                    // который всегда отвечает «нельзя», — мусор в меню.
                    if (_hasCamera ?? true)
                      PopupMenuItem(value: 'qr', child: Text(getLocalText.s("Scan QR code"))),
                    PopupMenuItem(value: 'file', child: Text(getLocalText.s("Import from file…"))),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem<String>(
                      value: 'auto_update',
                      checked: _autoUpdateEnabled,
                      child: Text(getLocalText.s("Auto-update subscriptions")),
                    ),
                    PopupMenuItem(
                      value: 'sub_settings',
                      child: Text(getLocalText.s("Subscription settings…")),
                    ),
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                _buildInputBar(ctrl),
                if (ctrl.lastError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      ctrl.lastError!.render(),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (ctrl.progressMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(ctrl.progressMessage!.render())),
                      ],
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    // Pull-to-refresh (night T3-2): стандартный Android UX-жест,
                    // альтернативный кнопке refresh в AppBar. Эквивалент
                    // `_updateAll()`; noop если уже busy.
                    onRefresh: () async {
                      if (ctrl.busy) return;
                      await _updateAll();
                    },
                    child: _buildList(ctrl),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputBar(SubscriptionController ctrl) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              decoration: InputDecoration(
                hintText: getLocalText.s("Subscription URL or proxy link"),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          // §074: tap = paste-from-clipboard / parse text input (existing).
          // long-press = full-screen Add server wizard (SOCKS5 form / Paste
          // URI / Paste JSON tabs).
          //
          // НЕ IconButton — у того встроенный Tooltip widget (даже без
          // tooltip:, Material InkWell внутри его перехватывает long-press
          // первым в gesture arena). Используем raw InkWell + Material
          // styled под IconButton.filled (primary container + circle).
          // Pattern уже applied для §070 sort button.
          AddIconButton(
            busy: ctrl.busy,
            onTap: () => unawaited(_add()),
            onLongPress: _openAddServerWizard,
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context, int index, SubscriptionEntry entry) {
    showEntryContextMenu(
      context,
      index,
      entry,
      subController: widget.subController,
      autoUpdater: widget.autoUpdater,
    );
  }

  Future<void> _launchUrl(String url) async {
    final opened = await UrlLauncher.open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Copied: %s", url))),
      );
    }
  }

  Future<void> _pickPublicTestServer() async {
    await pickPublicTestServer(
      context,
      onSelectSource: (source) => _inputController.text = source,
    );
  }

  /// §393 D1 — общий список источников: подписки/серверы/папки и цепочки
  /// ОДНИМ рядом. Порядок цепочек внутри него и есть их взаимный порядок, по
  /// которому считается инвариант «позиция ссылается только на цепочку ВЫШЕ».
  ///
  /// Цепочки идут ПОСЛЕ записей контроллера: `_setChains` нумерует их от длины
  /// `server_lists`, и рисовать их надо там же, где они лежат. Смешанной
  /// сортировки нет намеренно — она потребовала бы держать `order` и у
  /// `ServerList`, то есть переписать общий ordering ради того, чего
  /// пользователь не просил.
  List<_SourceRow> _rows(SubscriptionController ctrl) => [
        for (var i = 0; i < ctrl.entries.length; i++)
          _SourceRow.entry(ctrl.entries[i], i),
        for (final c in _chains) _SourceRow.chain(c),
      ];

  Widget _buildList(SubscriptionController ctrl) {
    if (ctrl.entries.isEmpty && _chains.isEmpty) {
      return SubscriptionsEmptyState(
        busy: ctrl.busy,
        onPickPublicTestServer: () => unawaited(_pickPublicTestServer()),
      );
    }
    final rows = _rows(ctrl);
    return ReorderableListView.builder(
      // §098 — drag-reorder источников (grab-strip слева, как routing rules).
      // AlwaysScrollable — pull-to-refresh на коротких списках. Divider теперь
      // внутри самой строки (у ReorderableListView нет separatorBuilder).
      scrollController: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      // Bottom safe-area: последняя подписка не должна прятаться за системной
      // навигацией Android (жесты/кнопки). Паттерн проекта — padding.bottom + 24.
      padding: EdgeInsets.fromLTRB(
          12, 0, 12, MediaQuery.of(context).padding.bottom + 24),
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorderItem: (oldIndex, newIndex) {
        // onReorderItem уже нормализует newIndex под удалённый элемент.
        unawaited(_reorderRows(ctrl, oldIndex, newIndex));
      },
      itemBuilder: (context, i) {
        final row = rows[i];
        final chain = row.chain;
        if (chain != null) {
          return KeyedSubtree(
            key: ValueKey('chain:${chain.tag}'),
            child: ChainEntryTile(
              dragIndex: i,
              chain: chain,
              onTap: () => unawaited(_editChain(chain)),
              onToggle: () => unawaited(_toggleChain(chain)),
            ),
          );
        }
        final entry = row.entry!;
        final at = row.entryIndex;
        final highlighted = _highlightedEntryId == entry.id;
        final cs = Theme.of(context).colorScheme;
        // §255 — reorder-key остаётся top-level (KeyedSubtree); GlobalKey для
        // ensureVisible + вспышка — на внутреннем Container.
        return KeyedSubtree(
          key: ValueKey(entry.id),
          child: AnimatedContainer(
            key: _tileKey(entry.id),
            duration: const Duration(milliseconds: 200),
            decoration: highlighted
                ? BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.5),
                    border: Border(
                        left: BorderSide(color: cs.primary, width: 3)),
                  )
                : null,
            child: SubscriptionEntryTile(
              dragIndex: i,
              entry: entry,
              onToggle: () {
                unawaited(widget.subController.toggleAt(at));
              },
              onLaunchUrl: _launchUrl,
              onLongPress: (context) => _showContextMenu(context, at, entry),
              onTap: (context) {
                // §234 — папка открывает свой экран (члены + settings).
                if (entry.list is FolderServers) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FolderDetailScreen(
                        entry: entry,
                        controller: widget.subController,
                      ),
                    ),
                  );
                  return;
                }
                final isDirectServer =
                    entry.url.isEmpty && entry.connections.isNotEmpty;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => isDirectServer
                        ? NodeSettingsScreen(
                            entry: entry,
                            index: at,
                            subController: widget.subController,
                          )
                        : SubscriptionDetailScreen(
                            entry: entry,
                            controller: widget.subController,
                          ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// §393 D1 — перестановка в ОБЩЕМ списке источников.
  ///
  /// Ряды двух родов лежат в одном списке, но в двух storage-ключах, поэтому
  /// перестановка раскладывается обратно: подписки — своим `moveEntry`,
  /// цепочки — своим `reorderChains`. Ключевое свойство (ради него всё и
  /// затевалось): перетащить подписку МЕЖДУ двумя цепочками ЗАКОННО и
  /// взаимный порядок цепочек от этого не меняется — значит, ни одна ссылка
  /// «на цепочку выше» не ломается.
  Future<void> _reorderRows(
      SubscriptionController ctrl, int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final rows = _rows(ctrl);
    if (oldIndex < 0 || oldIndex >= rows.length) return;
    if (newIndex < 0 || newIndex >= rows.length) return;
    final moved = [...rows];
    moved.insert(newIndex, moved.removeAt(oldIndex));

    if (rows[oldIndex].chain != null) {
      // Двигали цепочку: у подписок порядок не изменился, переписываем только
      // взаимный порядок цепочек — в том виде, в каком они легли в общий ряд.
      await SettingsStorage.reorderChains(
          [for (final r in moved) if (r.chain != null) r.chain!]);
      await _loadChains();
      // Ссылка «только на цепочку выше» — свойство сборки: изменившийся
      // порядок мог сделать позицию ссылкой вперёд, и об этом обязан сказать
      // билдер, а не молчащий storage.
      if (!mounted) return;
      await _regenerateAndSave();
      return;
    }

    // Двигали подписку: цепочки своего взаимного порядка не меняют, а
    // контроллер работает в СВОЁМ счёте — переводим индексы, отбросив ряды
    // цепочек.
    final entryOrder = [
      for (final r in moved)
        if (r.entry != null) r.entryIndex,
    ];
    final to = entryOrder.indexOf(rows[oldIndex].entryIndex);
    if (to < 0) return;
    await widget.subController.moveEntry(rows[oldIndex].entryIndex, to);
  }
}

/// §393 D1 — ряд общего списка источников: либо запись контроллера
/// (подписка/сервер/папка), либо цепочка. Ровно два рода, поэтому обычный
/// класс с двумя nullable-полями, а не sealed-иерархия: тип живёт внутри
/// одного экрана и наружу не выходит.
class _SourceRow {
  const _SourceRow.entry(this.entry, this.entryIndex) : chain = null;
  const _SourceRow.chain(this.chain)
      : entry = null,
        entryIndex = -1;

  final SubscriptionEntry? entry;

  /// Индекс записи в `SubscriptionController.entries` — счёт контроллера, не
  /// общего списка. Мутации подписок адресуются им.
  final int entryIndex;
  final SourceChain? chain;
}
