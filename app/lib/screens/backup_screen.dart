import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import '../services/dns/dns_backup.dart';
import '../services/lx_backup.dart';
import '../services/lx_backup_import.dart';
import '../services/record_vars.dart';
import '../services/warp/warp_backup.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';
import '../services/ui_helpers.dart';
import '../widgets/export_action_sheet.dart';
import 'backup_screen/export_card.dart';
import 'backup_screen/import_card.dart';
import 'backup_screen/lx_import_summary.dart';
import 'backup_screen/lx_transfer_card.dart';
import 'backup_screen/device_transfer_card.dart';
import 'backup_screen/restore_flow.dart';
import 'backup_screen/transfer_send_text.dart';
import 'qr_scan_screen.dart';
import 'transfer_receive_screen.dart';
import '../services/transfer/transfer_code.dart';
import '../services/transfer/transfer_entries.dart';
import '../services/transfer/transfer_envelope.dart';
import '../services/transfer/transfer_sender.dart';
import '../services/utf8_decode.dart';
import '../services/file_export.dart';
import '../services/file_import.dart';
import '../services/url_launcher.dart';
import '../widgets/safe_bottom.dart';


/// Backup & restore UI — спека [§040F](../../../docs/spec/tasks/040F-backup-restore-ui/spec.md).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  /// §622 — экран приёма; тест подменяет, чтобы не поднимать сервер и QR.
  @visibleForTesting
  static Future<BackupContents?> Function(BuildContext context) openReceive =
      openTransferReceiveScreen;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> with SnackHelper {
  final _service = const BackupService();

  // Export-side toggles. Default ON для всего кроме debug.
  bool _expServerLists = true;
  bool _expRouting = true;
  bool _expAppSettings = true;
  bool _expVpnSettings = true;
  bool _expDebugConfig = false;

  bool _busy = false;

  /// §622 — пункты передачи телефон → TV: приём только на TV, отправка только
  /// с камерой (P10). До ответа платформы не показываем ни один.
  TransferEntries _transfer = TransferEntries.none;

  /// Кнопка «Show code»: после восстановления фокус пульта возвращается сюда.
  final _receiveFocus = FocusNode(debugLabel: 'transfer-receive');

  @override
  void initState() {
    super.initState();
    unawaited(loadTransferEntries().then((e) {
      if (mounted) setState(() => _transfer = e);
    }));
  }

  @override
  void dispose() {
    _receiveFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Backup & restore"))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8).withSafeBottom(context),
        children: [
          if (_transfer.receive) ...[
            DeviceTransferCard.receive(
              busy: _busy,
              onReceive: _onReceive,
              focusNode: _receiveFocus,
            ),
            const SizedBox(height: 8),
          ],
          ExportCard(
            serverLists: _expServerLists,
            routing: _expRouting,
            appSettings: _expAppSettings,
            vpnSettings: _expVpnSettings,
            debugConfig: _expDebugConfig,
            busy: _busy,
            onChange: (cat, on) => setState(() {
              switch (cat) {
                case BackupCategory.serverLists:
                  _expServerLists = on;
                case BackupCategory.routing:
                  _expRouting = on;
                case BackupCategory.appSettings:
                  _expAppSettings = on;
                case BackupCategory.vpnSettings:
                  _expVpnSettings = on;
                case BackupCategory.debugConfig:
                  _expDebugConfig = on;
              }
            }),
            onExport: _onExport,
          ),
          if (_transfer.send) ...[
            const SizedBox(height: 8),
            DeviceTransferCard.send(busy: _busy, onSend: _onSendToTv),
          ],
          const SizedBox(height: 8),
          ImportCard(
            busy: _busy,
            onImport: _onImport,
          ),
          const SizedBox(height: 8),
          // §103 фаза 4 — перенос на десктоп отдельной карточкой: обычный
          // бэкап выше делает полный снимок ДЛЯ ЭТОЙ ЖЕ установки, а тут
          // переносится общая часть в другое приложение.
          LxTransferCard(
            busy: _busy,
            onExport: _onLxExport,
            onImport: _onLxImport,
          ),
        ],
      ),
    );
  }

  Set<BackupCategory> _exportInclude() {
    return {
      if (_expServerLists) BackupCategory.serverLists,
      if (_expRouting) BackupCategory.routing,
      if (_expAppSettings) BackupCategory.appSettings,
      if (_expVpnSettings) BackupCategory.vpnSettings,
      if (_expDebugConfig) BackupCategory.debugConfig,
    };
  }

  Future<void> _onExport() async {
    final include = _exportInclude();
    if (include.isEmpty) {
      showSnack(getLocalText.s("Nothing to export — pick at least one category."));
      return;
    }
    setState(() => _busy = true);
    try {
      // §374 — доступные способы выясняем ДО построения JSON: если юзер
      // закроет шит, зря работать не придётся. Обе проверки идут на
      // платформу, поэтому параллельно.
      final availability = await Future.wait([
        UrlLauncher.hasRealFilePicker(),
        UrlLauncher.canSaveToDownloads(),
      ]);
      if (!mounted) return;
      final action = await showExportActionSheet(
        context,
        canSaveToFile: availability[0],
        canSaveToDownloads: availability[1],
      );
      if (action == null) return; // юзер закрыл шит

      final json = await _service.buildExport(include: include);
      final filename = await BackupService.suggestedFilename();
      // Размер в БАЙТАХ, а не в code units: String.length считает UTF-16, и на
      // кириллице в именах узлов снекбар занижал цифру против файла на диске.
      final bytes = utf8.encode(json).length;

      final SaveOutcome outcome;
      switch (action) {
        case ExportAction.saveToFile:
          outcome = await saveFileSafely(fileName: filename, content: json);
        case ExportAction.saveToDownloads:
          outcome =
              await saveToDownloadsSafely(fileName: filename, content: json);
        case ExportAction.share:
          // Share требует файл на диске: кэш подходит — получатель копирует
          // его себе, а очистка кэша системой нам не важна.
          final tmpDir = await getTemporaryDirectory();
          final path = '${tmpDir.path}/$filename';
          await File(path).writeAsString(json);
          await SharePlus.instance.share(ShareParams(
            files: [XFile(path, mimeType: 'application/json', name: filename)],
            subject: 'LxBox backup',
          ));
          if (!mounted) return;
          showSnack(getLocalText.s("Backup exported (%d bytes)", bytes));
          return;
      }

      if (!mounted) return;
      final problem = saveProblemText(outcome);
      if (problem != null) {
        showSnack(problem);
        return;
      }
      switch (outcome) {
        case SavedToFile(:final name):
          showSnack(getLocalText.s("Saved as %s (%d bytes)", name, bytes));
        case SavedToDownloads(:final name):
          showSnack(
              getLocalText.s("Saved to Downloads: %s (%d bytes)", name, bytes));
        case SaveCancelled():
          break; // юзер закрыл диалог сохранения — молчим
        case SaveNoTarget() || SaveFailed():
          break; // покрыто saveProblemText выше
      }
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Export failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onImport() async {
    setState(() => _busy = true);
    try {
      // §372 — см. pickFileSafely: Android TV без DocumentsUI.
      final outcome = await pickFileSafely(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) showSnack(problem);
        return; // cancelled / нет пикера / сбой
      }
      final file = outcome.single;
      final raw = utf8DecodeOrNull(file.bytes);
      if (raw == null) {
        if (!mounted) return;
        showSnack(getLocalText.s("Could not read file."));
        return;
      }

      final BackupContents contents;
      try {
        contents = await _service.parseImport(raw);
      } on FormatException catch (e) {
        if (!mounted) return;
        _showError(getLocalText.s("Invalid backup"), e.message);
        return;
      }

      if (!mounted) return;
      await restoreFromContents(context, contents);
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Import failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // §219 — _snack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

  // ——— §622: передача настроек телефон → TV ———

  /// TV: экран приёма, затем общий путь восстановления (фича 031 P4).
  Future<void> _onReceive() async {
    final contents = await BackupScreen.openReceive(context);
    if (contents == null || !mounted) return;
    setState(() => _busy = true);
    // Погашенная busy кнопка отдаёт фокус своему экрану. В одном кадре с
    // открытием предпросмотра это перебивает запрос фокуса диалога, и пульт
    // ходит по экрану под ним — поэтому сначала кадр с погашенной кнопкой.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await restoreFromContents(context, contents);
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Import failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _refocusReceive());
      }
    }
  }

  /// Фокус обратно на карточку — безусловно: погашенная на время
  /// восстановления кнопка отдала его последнему фокусу экрана из истории
  /// (обычно «Back» тулбара, откуда пульт пришёл на карточку).
  void _refocusReceive() {
    if (!mounted || _receiveFocus.context == null) return;
    _receiveFocus.requestFocus();
  }

  /// Телефон: скан кода с TV → подтверждение → шифрование → отправка.
  /// Категории — те же, что отмечены в карточке Export (P5).
  Future<void> _onSendToTv() async {
    final include = _exportInclude();
    if (include.isEmpty) {
      showSnack(getLocalText.s("Nothing to export — pick at least one category."));
      return;
    }
    final outcome = await Navigator.of(context).push<ScanOutcome>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (!mounted) return;
    if (outcome is! ScannedCode) {
      final problem = outcome == null ? null : scanProblemText(outcome);
      if (problem != null) showSnack(problem);
      return;
    }
    final code = TransferCode.tryParse(outcome.value);
    if (code == null) {
      showSnack(getLocalText.s("This is not a LxBox transfer code"));
      return;
    }
    final confirmed = await _confirmSend(code);
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final json = await _service.buildExport(include: include);
      final envelope = await sealTransferEnvelope(utf8.encode(json), code.key);
      final result = await TransferSender().send(code, envelope);
      if (!mounted) return;
      showSnack(transferSendResultText(result));
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Sending failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmSend(TransferCode code) {
    final name = code.name.isEmpty ? code.addresses.first.host : code.name;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Send to %s?", name)),
        content: Text(getLocalText.s(
            "The selected categories are encrypted with the key from the code "
            "and sent over the local network. The TV shows what arrived and "
            "asks before applying it.")),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(getLocalText.s("Send")),
          ),
        ],
      ),
    );
  }

  // ——— §103 фаза 4: перенос на десктоп (LX Backup) ———

  /// Экспорт общей части настроек в переносимый формат.
  ///
  /// Переиспользует те же пути сохранения, что обычный бэкап: пользователю
  /// незачем видеть два разных диалога сохранения в одном экране.
  Future<void> _onLxExport() async {
    setState(() => _busy = true);
    try {
      final availability = await Future.wait([
        UrlLauncher.hasRealFilePicker(),
        UrlLauncher.canSaveToDownloads(),
      ]);
      if (!mounted) return;
      final action = await showExportActionSheet(
        context,
        canSaveToFile: availability[0],
        canSaveToDownloads: availability[1],
      );
      if (action == null) return; // юзер закрыл шит

      final lists = await SettingsStorage.getServerLists();
      final rules = await SettingsStorage.getCustomRules();
      final vars = await SettingsStorage.getAllVars();
      // §393 B2 — Направления едут вместе с правилами: без них правило на
      // принимающей стороне не находит цель и приезжает выключенным.
      final directions = await SettingsStorage.getDirections();
      // §393 C9 — цепочки хопов (SPEC 110, схема v1.2): корневая секция
      // `chains[]`, порядок списка нормативен и не сортируется.
      final chains = await SettingsStorage.getChains();
      final sourceKeys = await SettingsStorage.getSourceKeys();
      // §393 B6 — route.final: до B6 его разбирали на импорте, но никогда не
      // экспортировали, и круг был односторонним.
      final routeFinal = await SettingsStorage.getRouteFinal();
      // §401 — предупреждения экспорта: настройки, у которых в общей схеме
      // нет дома, в файл не едут, и пользователь узнаёт об этом ДО того, как
      // унесёт файл на другую машину (П6).
      final exportWarnings = <LxBackupWarning>[];
      // §441 — объявления переменных записей шаблона: `vars` template-серверов
      // и пресетов едут без умолчаний и необъявленных имён (SPEC 129 Н2–Н4).
      final recordVars = await loadRecordVarDecls();
      // §393 B9 — секция DNS: записи хранения + final/strategy. §439 —
      // preset-сервер несёт `preset_id` в записи, шаблон не нужен.
      final dns = dnsToBackup(
        servers: await SettingsStorage.getDnsServers(),
        rules: await SettingsStorage.getDnsRulesList(),
        dnsFinal: vars['dns_final'] ?? '',
        strategy: vars['dns_strategy'] ?? '',
        defaultDomainResolver: vars['dns_default_domain_resolver'] ?? '',
        warnings: exportWarnings,
        recordVars: recordVars,
        // §681 (контракт 1.1.135, D-139) — каталог шаблона этой стороны:
        // приёмник по нему отличает «удалён» от «не знал».
        templateCatalog: await _templateDnsCatalogOrNull(),
      );
      // §393 B8 — регистрации WARP в каноне схемы (`type: wg|masque`).
      final warpAccount = await SettingsStorage.getWarpAccount();
      final masqueAccount = await SettingsStorage.getMasqueAccount();
      final warp = <Map<String, dynamic>>[
        if (warpAccount != null) warpAccountToBackup(warpAccount),
        if (masqueAccount != null) masqueAccountToBackup(masqueAccount),
      ];
      // §409 — бюджеты теста узла по Направлениям (`ping_options.groups`,
      // §040). Форма storage → переносимая форма читается ЗДЕСЬ, а не в
      // парсере: `SettingsStorage` слою бэкапа не виден.
      final directionPing = lxDirectionPingFromStorage(
        await SettingsStorage.getPingOptions(),
      );
      final built = await buildLxBackup(
        lists: lists,
        rules: rules,
        vars: vars,
        directions: directions,
        directionPing: directionPing,
        chains: chains,
        sourceKeys: sourceKeys,
        routeFinal: routeFinal,
        dns: dns,
        warp: warp,
        recordVars: recordVars,
      );
      final json = built.json;
      exportWarnings.addAll(built.warnings);
      const filename = 'lx-backup.json';
      // Размер в БАЙТАХ, а не в code units: на кириллице в именах узлов
      // String.length занижал бы цифру против файла на диске.
      final bytes = utf8.encode(json).length;

      final SaveOutcome outcome;
      switch (action) {
        case ExportAction.saveToFile:
          outcome = await saveFileSafely(fileName: filename, content: json);
        case ExportAction.saveToDownloads:
          outcome =
              await saveToDownloadsSafely(fileName: filename, content: json);
        case ExportAction.share:
          final tmpDir = await getTemporaryDirectory();
          final path = '${tmpDir.path}/$filename';
          await File(path).writeAsString(json);
          await SharePlus.instance.share(ShareParams(
            files: [XFile(path, mimeType: 'application/json', name: filename)],
            subject: 'LX Backup',
          ));
          if (!mounted) return;
          showSnack(getLocalText.s("Backup exported (%d bytes)", bytes));
          _showExportLosses(exportWarnings);
          return;
      }

      if (!mounted) return;
      final problem = saveProblemText(outcome);
      if (problem != null) {
        showSnack(problem);
        return;
      }
      switch (outcome) {
        case SavedToFile(:final name):
          showSnack(getLocalText.s("Saved as %s (%d bytes)", name, bytes));
          _showExportLosses(exportWarnings);
        case SavedToDownloads(:final name):
          showSnack(
              getLocalText.s("Saved to Downloads: %s (%d bytes)", name, bytes));
          _showExportLosses(exportWarnings);
        case SaveCancelled():
          break;
        case SaveNoTarget() || SaveFailed():
          break;
      }
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Export failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Импорт переносимого бэкапа.
  ///
  /// Показывает, что приедет, ДО применения: импорт заменяет правила целиком,
  /// и спрашивать после было бы поздно.
  Future<void> _onLxImport() async {
    setState(() => _busy = true);
    try {
      final outcome = await pickFileSafely(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) showSnack(problem);
        return;
      }
      final file = outcome.single;
      final raw = utf8DecodeOrNull(file.bytes);
      if (raw == null) {
        if (!mounted) return;
        showSnack(getLocalText.s("Could not read file."));
        return;
      }

      // D-117 — план импорта считает сервис: слияние и один список известных
      // целей после него (BACKUP.md §3). Экран его не собирает.
      const importer = LxBackupImportService();
      final LxImportPlan plan;
      try {
        plan = await importer.prepare(raw);
      } on FormatException catch (e) {
        if (!mounted) return;
        _showError(getLocalText.s("Invalid backup"), e.message);
        return;
      }

      if (!mounted) return;
      final confirmed = await _confirmLxImport(plan.file);
      if (confirmed != true) return;

      final result = await importer.apply(plan);
      if (!mounted) return;

      // §641 — итог одной строкой: замена правил приёмника названа хвостом,
      // а не посчитана в «не применено».
      showSnack(lxImportSnackText(
        result.file,
        appliedDirections: result.appliedDirections,
        appliedSettings: result.appliedSettings,
        appliedChains: result.appliedChains,
      ));
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Import failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Показывает состав файла и что не применится — до применения.
  Future<bool?> _confirmLxImport(LxBackupFile parsed) {
    // §641 — строки превью и последняя фраза о правилах — в одном месте.
    final lines = lxImportPreviewLines(parsed);

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Import backup")),
        content: SingleChildScrollView(child: Text(lines.join('\n'))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(getLocalText.s("Import")),
          ),
        ],
      ),
    );
  }

  /// §401 — что не поехало в файл. Диалог, а не snack: перечень длиннее
  /// строки, и потерю настройки пользователь обязан увидеть целиком, а не
  /// поймать боковым зрением за две секунды (П6).
  void _showExportLosses(List<LxBackupWarning> warnings) {
    if (warnings.isEmpty || !mounted) return;
    final lines = <String>[
      getLocalText.s("These settings have no place in the shared format:"),
      '',
      for (final w in warnings.take(12)) '• ${w.detail}',
      if (warnings.length > 12) '… +${warnings.length - 12}',
    ];
    _showError(getLocalText.s("Not included in the file"), lines.join('\n'));
  }

  void _showError(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(getLocalText.s("OK")))
        ],
      ),
    );
  }
}

/// §681 — каталог DNS-серверов шаблона для `dns.template_catalog`; `null` —
/// шаблон не загрузился, поле не пишется (приёмник уйдёт в переходную ветку).
Future<List<String>?> _templateDnsCatalogOrNull() async {
  try {
    final template = await TemplateLoader.load();
    return [for (final s in template.dnsOptionsModel.servers) s.tag];
  } catch (_) {
    return null;
  }
}
