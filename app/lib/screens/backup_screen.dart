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
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';
import '../services/ui_helpers.dart';
import '../vpn/box_vpn_client.dart';
import '../widgets/export_action_sheet.dart';
import 'backup_screen/export_card.dart';
import 'backup_screen/import_card.dart';
import 'backup_screen/import_preview_dialog.dart';
import 'backup_screen/lx_transfer_card.dart';
import '../services/utf8_decode.dart';
import '../services/file_export.dart';
import '../services/file_import.dart';
import '../services/url_launcher.dart';
import '../widgets/safe_bottom.dart';


/// Backup & restore UI — спека [§040](../../docs/spec/features/040 backup
/// restore ui/spec.md).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Backup & restore"))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8).withSafeBottom(context),
        children: [
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
      final result = await showImportPreview(context, contents);
      if (result == null) return; // cancelled

      final apply = await _service.applyImport(
        contents,
        merge: result.merge,
        include: result.include,
      );
      // §279 — restore мог привезти другой app_language: применить через
      // владеющий пайплайн (LocaleController), не дожидаясь рестарта.
      await LocaleController.I.reloadFromStorage();
      if (!mounted) return;
      final summary = StringBuffer('Imported');
      final parts = <String>[];
      if (apply.serverListsApplied > 0) {
        parts.add('${apply.serverListsApplied} server lists');
      }
      if (apply.routingApplied > 0) {
        parts.add('routing (${apply.routingApplied} rules)');
      }
      if (apply.appSettingsApplied > 0) {
        parts.add('${apply.appSettingsApplied} app settings');
      }
      if (apply.debugConfigApplied > 0) {
        parts.add('debug config');
      }
      if (apply.vpnSettingsApplied > 0) {
        parts.add('${apply.vpnSettingsApplied} VPN settings');
      }
      if (parts.isEmpty) {
        summary.write(' nothing (all categories deselected)');
      } else {
        summary.write(': ${parts.join(', ')}');
      }
      if (apply.hasErrors) {
        summary.write(' (${apply.errors.length} errors)');
      }
      // §159 — allowlist отбросил неизвестные/чужеродные ключи.
      if (apply.droppedKeys.isNotEmpty) {
        summary.write(' · ${apply.droppedKeys.length} unknown keys skipped');
      }
      // applyImport пишет в SettingsStorage, но controllers (Subscription /
      // Home / Routing screen state) держат in-memory snapshot — UI остаётся
      // stale. Restart-кнопка вызывает quitApp(); юзер сам тапает иконку,
      // app поднимается с fresh storage.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(summary.toString()),
            duration: const Duration(seconds: 6),
            action: parts.isEmpty
                ? null
                : SnackBarAction(
                    label: getLocalText.s("Restart now"),
                    onPressed: () =>
                        unawaited(BoxVpnClient().quitApp()),
                  ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Import failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // §219 — _snack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

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
      // §393 B6 — route.final: до B6 его разбирали на импорте, но никогда не
      // экспортировали, и круг был односторонним.
      final routeFinal = await SettingsStorage.getRouteFinal();
      // §401 — предупреждения экспорта: настройки, у которых в общей схеме
      // нет дома, в файл не едут, и пользователь узнаёт об этом ДО того, как
      // унесёт файл на другую машину (П6).
      final exportWarnings = <LxBackupWarning>[];
      // §441 — объявления переменных записей шаблона: `vars` template-серверов
      // и пресетов едут без умолчаний и необъявленных имён (SPEC 128 Н2–Н4).
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

      final parsed = result.file;
      final appliedDirections = result.appliedDirections;
      final counts = result.appliedSettings;
      final skipped = parsed.warnings.length;
      // Счётное существительное — только через plural: по-русски иначе
      // получится «Импортировано 2 правил».
      //
      // §393 B5 — созданные Направления названы отдельно: правила приехали
      // рабочими именно потому, что цели заведены, и молчать об этом значило
      // бы скрыть половину произошедшего с настройками.
      //
      // §393 B6 — то же и с остальными секциями: подписки, DNS, переменные и
      // регистрации WARP теперь реально применяются, и счётчик обязан их
      // показать — иначе «Импортировано 0 правил» после файла с тремя
      // подписками выглядит как отказ, хотя всё применилось.
      final String message;
      if (skipped > 0) {
        message = getLocalText.s("Imported %d rule(s), %d items not applied",
            parsed.rules.length, skipped);
      } else if (appliedDirections > 0 && counts > 0) {
        message = getLocalText.s(
            "Imported %1\$d rules, %2\$d directions and %3\$d settings",
            parsed.rules.length,
            appliedDirections,
            counts);
      } else if (appliedDirections > 0) {
        message = getLocalText.s("Imported %1\$d rules and %2\$d directions",
            parsed.rules.length, appliedDirections);
      } else if (counts > 0) {
        message = getLocalText.s("Imported %1\$d rules and %2\$d settings",
            parsed.rules.length, counts);
      } else {
        message = getLocalText.plural("Imported %d rules", parsed.rules.length);
      }
      // §393 C9 — цепочки названы ОТДЕЛЬНОЙ клаузой, а не влиты в счётчик
      // настроек: это созданные сущности, как Направления, и «Импортировано
      // правил: 0, настроек: 2» после файла с двумя маршрутами скрыло бы
      // ровно то, что произошло. Клауза-суффикс, а не шестая ветка лестницы:
      // добавить цепочки измерением удвоило бы число строк каталога,
      // из которых половина не встречается никогда.
      showSnack(result.appliedChains > 0
          ? '$message; ${getLocalText.s("chains: %d", result.appliedChains)}'
          : message);
    } catch (e) {
      if (!mounted) return;
      showSnack(getLocalText.s("Import failed: %s", formatUserError(e).render()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Показывает состав файла и что не применится — до применения.
  Future<bool?> _confirmLxImport(LxBackupFile parsed) {
    final lines = <String>[
      getLocalText.s("From %s %s", parsed.exportedByApp, parsed.exportedByVersion),
      // §393 B5 — Направления названы отдельной строкой: они не «часть
      // правил», а создаваемые сущности, и пользователь вправе увидеть,
      // сколько их заведётся, ДО применения.
      if (parsed.directions.isNotEmpty)
        getLocalText.s("Directions: %d", parsed.directions.length),
      // §393 C9 — цепочки хопов: тоже создаваемые сущности, и их число
      // пользователь вправе увидеть ДО применения.
      if (parsed.chains.isNotEmpty)
        getLocalText.s("Chains: %d", parsed.chains.length),
      getLocalText.s("Rules: %d", parsed.rules.length),
      getLocalText.s("Subscriptions: %d", parsed.subscriptions.length),
      // §401 — одиночные узлы и члены папок: до этого их разбирали и не
      // применяли, и пользователь не видел ни строки о том, что приехало.
      if (parsed.servers.isNotEmpty)
        getLocalText.s("Servers: %d", parsed.servers.length),
      getLocalText.s("Variables: %d", parsed.vars.length),
      // §393 B8/B9 — секции, которые теперь применяются: пользователь должен
      // увидеть их ДО применения, а не обнаружить постфактум чужой DNS-сервер
      // в списке.
      if (parsed.dns != null && !parsed.dns!.isEmpty)
        getLocalText.s("DNS entries: %d",
            parsed.dns!.servers.length + parsed.dns!.rules.length),
      if (parsed.warp.isNotEmpty)
        getLocalText.s("WARP accounts: %d", parsed.warp.length),
    ];
    if (parsed.warnings.isNotEmpty) {
      lines.add('');
      lines.add(getLocalText.s("Not applied as-is:"));
      for (final w in parsed.warnings.take(8)) {
        lines.add('• ${w.detail}');
      }
      if (parsed.warnings.length > 8) {
        lines.add('… +${parsed.warnings.length - 8}');
      }
    }
    lines.add('');
    lines.add(getLocalText.s("Importing replaces the current rules."));

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
