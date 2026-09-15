// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/dns/dns_backup.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/record_vars.dart';
import 'package:lxbox/services/rule_set_downloader.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';
import 'package:lxbox/services/warp/warp_backup.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// §439 волна 0 — общая обвязка golden-тестов хранения.
//
// Фикстура `test/fixtures/storage/<name>.json` — `lxbox_settings.json` формы
// 2.23.2. Рядом:
//   • `sub_cache/<name>/sub_<N>.txt` — тело подписки с URL
//     `https://example.com/sub/<N>` (узлы подписок в хранении не живут, их
//     поднимает регидрация из кэша тел, как на старте приложения);
//   • `rule_sets/<name>/<id>.srs` — «скачанные» наборы правил: сборка
//     эмитит `rule_set` только для набора с файлом в кэше.
//
// Фикстуры:
//   • `rich_v0` — синтетика: все виды источников, цепочек, правил, DNS-записей
//     и Направлений, поля L из §1.2 спеки 439, мёртвые ключи. После сборки
//     хранение не меняется, кроме намеренной сироты — DNS-правила
//     `kind: template` с именем, которого нет в шаблоне (резолвер её снимает);
//   • `avd_v0` — снимок AVD `LxBox_test` на 2.23.2 (`GET
//     /backup/export?include=storage`, 14.09.2026). Секреты заменены
//     синтетикой той же формы: ключи WG/AWG/Amnezia и MASQUE, UUID узлов,
//     пароли, идентификаторы и токены WARP, IPv6 WARP, домашние IP,
//     `debug_token`, пароль прокси, Wi-Fi; URL подписок —
//     `https://example.com/sub/<N>`. Разбор узлов до и после замены сверен:
//     те же узлы, теги, типы и набор полей эмиссии.
//
// Эталоны — `test/fixtures/storage/golden/`. `UPDATE_GOLDEN=1` пишет их
// вместо сверки.
//
// Сборка и бэкап повторяют боевой путь без виджетов: состав `BuildSettings`
// — `SubscriptionController._generate`, экспорт LX Backup —
// `BackupScreen._onLxExport`, импорт — сервис `LxBackupImportService` (его же
// зовёт экран). Правка экспорта в `lib/` обязана отразиться здесь.

const kStorageFixturesDir = 'test/fixtures/storage';
const kStorageGoldenDir = 'test/fixtures/storage/golden';

/// Фикстуры волны 0.
const kStorageFixtures = ['rich_v0', 'avd_v0'];

/// Версия ядра в сборке: фиксирована, чтобы бамп пина не переписывал
/// эталоны. lx.39 знает и цепочки, и Tailscale.
const kGoldenCoreVersion = '1.14.0-lx.39';

/// Корень `state_directory` узлов Tailscale (native `filesDir` на устройстве).
const kGoldenTailscaleStateRoot = '/data/user/0/com.leadaxe.lxbox/files';

/// Подстановка вместо временного каталога песочницы (пути кэша `.srs`).
const kSandboxPlaceholder = '<sandbox>';

/// Нормализованные поля конверта LX Backup.
const kGoldenExportedAt = '2026-01-01T00:00:00.000Z';
const kGoldenExportedVersion = '0.0.0+0';

/// Сборка и импорт на богатой фикстуре идут секунды; под нагрузкой CI —
/// дольше дефолтных 30 с.
const kGoldenTimeout = Timeout(Duration(minutes: 5));

bool get updateGolden => Platform.environment['UPDATE_GOLDEN'] == '1';

const _pretty = JsonEncoder.withIndent('  ');

String prettyJson(Object? v) => '${_pretty.convert(v)}\n';

File fixtureFile(String name) => File('$kStorageFixturesDir/$name.json');

File goldenFile(String fileName) => File('$kStorageGoldenDir/$fileName');

/// Сверка с эталоном или его запись при `UPDATE_GOLDEN=1`.
void expectGolden(String fileName, String actual) {
  final f = goldenFile(fileName);
  if (updateGolden) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(actual);
    return;
  }
  expect(f.existsSync(), isTrue,
      reason: 'нет эталона ${f.path}: прогон с UPDATE_GOLDEN=1');
  expect(actual, f.readAsStringSync(),
      reason: 'расхождение с ${f.path} (UPDATE_GOLDEN=1 — перезаписать)');
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// Изолированный каталог приложения: пустое хранение, свои кэши.
class StorageSandbox {
  StorageSandbox._(this.root);

  final Directory root;

  String get docsPath => '${root.path}/docs';

  File get settingsFile => File('$docsPath/lxbox_settings.json');

  static Future<StorageSandbox> create() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('storage_golden_');
    for (final sub in const ['docs', 'support', 'tmp']) {
      await Directory('${dir.path}/$sub').create();
    }
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    // Метки пресетов и Направлений берутся из шаблона под активной локалью.
    LocaleController.I.setting = 'en';
    resetStorageCaches();
    return StorageSandbox._(dir);
  }

  Future<void> dispose() async {
    resetStorageCaches();
    try {
      if (root.existsSync()) await root.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  }

  /// Кладёт хранение фикстуры (если [storage]), тела подписок и наборы
  /// правил. Без [storage] — пустое хранение с теми же кэшами: так выглядит
  /// новая установка, которой бэкап приносит источники, а сеть — их тела.
  Future<void> seed(String name, {bool storage = true}) async {
    if (storage) {
      await settingsFile.writeAsBytes(await fixtureFile(name).readAsBytes());
    }
    final subs = Directory('$kStorageFixturesDir/sub_cache/$name');
    if (subs.existsSync()) {
      final re = RegExp(r'^sub_(\d+)\.txt$');
      for (final f in subs.listSync().whereType<File>()) {
        final m = re.firstMatch(f.uri.pathSegments.last);
        if (m == null) continue;
        await HttpCache.save(
          'https://example.com/sub/${m.group(1)}',
          await f.readAsString(),
          const {},
        );
      }
    }
    final sets = Directory('$kStorageFixturesDir/rule_sets/$name');
    if (sets.existsSync()) {
      final dest = Directory('$docsPath/rule_sets');
      await dest.create(recursive: true);
      for (final f in sets.listSync().whereType<File>()) {
        await f.copy('${dest.path}/${f.uri.pathSegments.last}');
      }
    }
    resetStorageCaches();
  }

  /// Временный каталог в тексте → [kSandboxPlaceholder].
  String normalize(String text) =>
      text.replaceAll(root.path, kSandboxPlaceholder);
}

void resetStorageCaches() {
  SettingsStorage.resetCacheForTesting();
  RuleSetDownloader.resetCacheForTesting();
}

/// Итог сборки для эталонов.
class GoldenBuild {
  GoldenBuild(this.configJson, this.warnings);

  /// `config.json` с отступами, пути песочницы нормализованы.
  final String configJson;

  /// `emitWarnings` сборки, в порядке появления.
  final List<String> warnings;

  Map<String, dynamic> get config =>
      jsonDecode(configJson) as Map<String, dynamic>;
}

/// Сборка конфига из текущего хранения песочницы тем же составом, что
/// `SubscriptionController._generate`: источники из хранения + регидрация
/// подписок из кэша тел, настройки из `SettingsStorage`, фиксированные
/// [kGoldenCoreVersion] и [kGoldenTailscaleStateRoot]. Сгенерированные сборкой
/// vars пишутся обратно, как у контроллера. Кэш хранения сбрасывается до
/// чтения — сборка видит диск, как после перезапуска.
Future<GoldenBuild> buildGoldenConfig(StorageSandbox box) async {
  resetStorageCaches();
  final controller = SubscriptionController();
  await controller.init();
  await controller.rehydrationDone;

  final settings = BuildSettings(
    userVars: await SettingsStorage.getAllVars(),
    enabledGroups: await SettingsStorage.getEnabledGroups(),
    customRules: await SettingsStorage.getCustomRules(),
    routeFinal: await SettingsStorage.getRouteFinal(),
    directions: await SettingsStorage.getDirections(),
    chains: await SettingsStorage.getChains(),
    coreVersion: kGoldenCoreVersion,
    tunApps: await SettingsStorage.getTunApps(),
    vpnMode: await SettingsStorage.getVpnMode(),
    idleSuspend: await SettingsStorage.getIdleSuspend(),
    idleSuspendReachable: await SettingsStorage.getIdleSuspendReachable(),
    passiveCheck: await SettingsStorage.getPassiveCheck(),
    tailscaleStateRoot: kGoldenTailscaleStateRoot,
  );
  final lists = controller.entries.map((e) => e.list).toList();
  final result = await buildConfig(lists: lists, settings: settings);
  for (final e in result.generatedVars.entries) {
    await SettingsStorage.setVar(e.key, e.value);
  }
  expect(result.validation.hasFatal, isFalse,
      reason: 'fatal-валидация: боевая сборка отказалась бы сохранять конфиг\n'
          '${result.validation.fatal.map((i) => i.renderEn()).join('\n')}');
  controller.dispose();
  return GoldenBuild(
    box.normalize(prettyJson(result.config)),
    [for (final w in result.emitWarnings) box.normalize(w)],
  );
}

/// Экспорт LX Backup из хранения песочницы — `BackupScreen._onLxExport`.
/// `exported_at` и `exported_by.version` нормализованы.
Future<({String json, List<LxBackupWarning> warnings})> exportGoldenLxBackup()
    async {
  final lists = await SettingsStorage.getServerLists();
  final rules = await SettingsStorage.getCustomRules();
  final vars = await SettingsStorage.getAllVars();
  final directions = await SettingsStorage.getDirections();
  final chains = await SettingsStorage.getChains();
  final routeFinal = await SettingsStorage.getRouteFinal();
  final exportWarnings = <LxBackupWarning>[];
  final recordVars = await loadRecordVarDecls();
  final dns = dnsToBackup(
    servers: await SettingsStorage.getDnsServers(),
    rules: await SettingsStorage.getDnsRulesList(),
    dnsFinal: vars['dns_final'] ?? '',
    strategy: vars['dns_strategy'] ?? '',
    defaultDomainResolver: vars['dns_default_domain_resolver'] ?? '',
    warnings: exportWarnings,
    recordVars: recordVars,
  );
  final warpAccount = await SettingsStorage.getWarpAccount();
  final masqueAccount = await SettingsStorage.getMasqueAccount();
  final warp = <Map<String, dynamic>>[
    if (warpAccount != null) warpAccountToBackup(warpAccount),
    if (masqueAccount != null) masqueAccountToBackup(masqueAccount),
  ];
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
  exportWarnings.addAll(built.warnings);

  final doc = jsonDecode(built.json) as Map<String, dynamic>;
  doc['exported_at'] = kGoldenExportedAt;
  final by = doc['exported_by'];
  if (by is Map<String, dynamic>) by['version'] = kGoldenExportedVersion;
  return (json: prettyJson(doc), warnings: exportWarnings);
}

/// Импорт LX Backup в хранение песочницы — тот же сервис, что у экрана
/// (`LxBackupImportService`: план превью, затем запись после подтверждения).
/// Возвращает разобранный файл (его `warnings` — то, что не применилось).
Future<LxBackupFile> importGoldenLxBackup(String raw) async {
  const importer = LxBackupImportService();
  final applied = await importer.apply(await importer.prepare(raw));
  return applied.file;
}

/// Warning бэкапа строкой для эталона.
String warningLine(LxBackupWarning w) => [
      w.code,
      if (w.kind.isNotEmpty) 'kind=${w.kind}',
      if (w.reason.isNotEmpty) 'reason=${w.reason}',
      w.detail,
    ].join(' | ');

/// Разница двух JSON-деревьев строками `путь: было → стало`.
///
/// Списки объектов с уникальным строковым `tag` сопоставляются по тегу;
/// прочие списки — по наибольшей общей подпоследовательности: вставка или
/// удаление элемента не сдвигает весь хвост. Удаление, за которым сразу идёт
/// вставка, считается правкой элемента `[было→стало]` и раскрывается дальше.
List<String> jsonDiff(Object? a, Object? b, [String path = r'$']) {
  final out = <String>[];
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      final p = '$path.$k';
      if (!a.containsKey(k)) {
        out.add('$p: <absent> → ${_show(b[k])}');
      } else if (!b.containsKey(k)) {
        out.add('$p: ${_show(a[k])} → <absent>');
      } else {
        out.addAll(jsonDiff(a[k], b[k], p));
      }
    }
    return out;
  }
  if (a is List && b is List) {
    final ia = _tagIndex(a);
    final ib = _tagIndex(b);
    if (ia != null && ib != null) {
      final orderA = [for (final t in ia.keys) if (ib.containsKey(t)) t];
      final orderB = [for (final t in ib.keys) if (ia.containsKey(t)) t];
      if (jsonEncode(orderA) != jsonEncode(orderB)) {
        out.add('$path: order ${_show(orderA)} → ${_show(orderB)}');
      }
      for (final t in ia.keys) {
        final p = '$path[tag=$t]';
        if (!ib.containsKey(t)) {
          out.add('$p: ${_show(ia[t])} → <absent>');
        } else {
          out.addAll(jsonDiff(ia[t], ib[t], p));
        }
      }
      for (final t in ib.keys) {
        if (!ia.containsKey(t)) {
          out.add('$path[tag=$t]: <absent> → ${_show(ib[t])}');
        }
      }
      return out;
    }
    return _sequenceDiff(a, b, path);
  }
  if (jsonEncode(a) != jsonEncode(b)) {
    out.add('$path: ${_show(a)} → ${_show(b)}');
  }
  return out;
}

String _show(Object? v) {
  final s = jsonEncode(v);
  return s.length > 160 ? '${s.substring(0, 157)}...' : s;
}

List<String> _sequenceDiff(List<Object?> a, List<Object?> b, String path) {
  final ea = [for (final e in a) jsonEncode(e)];
  final eb = [for (final e in b) jsonEncode(e)];
  final n = a.length;
  final m = b.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = ea[i] == eb[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  final dels = <int>[];
  final ins = <int>[];
  void flush() {
    final paired = dels.length < ins.length ? dels.length : ins.length;
    for (var x = 0; x < paired; x++) {
      out.addAll(jsonDiff(a[dels[x]], b[ins[x]], '$path[${dels[x]}→${ins[x]}]'));
    }
    for (var x = paired; x < dels.length; x++) {
      out.add('$path[${dels[x]}→]: ${_show(a[dels[x]])} → <absent>');
    }
    for (var x = paired; x < ins.length; x++) {
      out.add('$path[→${ins[x]}]: <absent> → ${_show(b[ins[x]])}');
    }
    dels.clear();
    ins.clear();
  }

  var i = 0;
  var j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && ea[i] == eb[j]) {
      flush();
      i++;
      j++;
    } else if (j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1])) {
      dels.add(i++);
    } else {
      ins.add(j++);
    }
  }
  flush();
  return out;
}

Map<String, Object?>? _tagIndex(List<Object?> list) {
  if (list.isEmpty) return null;
  final out = <String, Object?>{};
  for (final e in list) {
    if (e is! Map || e['tag'] is! String) return null;
    final t = e['tag'] as String;
    if (out.containsKey(t)) return null;
    out[t] = e;
  }
  return out;
}

/// Для сверки порядка ключей: JSON с отсортированными ключами.
Object? sortedKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: sortedKeys(v[k])};
  }
  if (v is List) return [for (final e in v) sortedKeys(e)];
  return v;
}
