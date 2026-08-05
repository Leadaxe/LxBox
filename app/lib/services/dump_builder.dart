import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/debug_entry.dart';
import '../models/server_list.dart';
import 'app_log.dart';
import 'debug/debug_registry.dart';
import 'exit_info_reader.dart';
import 'logcat_reader.dart';
import 'oom_reports.dart';
import 'settings_storage.dart';
import 'stderr_reader.dart';
import 'version_info.dart';
import '../vpn/box_vpn_client.dart';

/// Собирает единый файл-дамп для репорта: конфиг + логи + подписки +
/// переменные — всё в одном JSON-файле. Пишет в temp, возвращает path
/// (дальше UI шлёт через Share.shareXFiles).
class DumpBuilder {
  DumpBuilder._();

  static Future<String> build() async {
    final now = DateTime.now();

    String? config;
    try {
      final raw = await BoxVpnClient().getConfig();
      if (raw.isNotEmpty && raw != '{}') config = raw;
    } catch (_) {}

    // §378 — версия ядра. До §378 она попадала в пак только случайно: полем
    // внутри oom/crash-снимков. Нет снимков — нечем отличить репорт на старом
    // ядре от репорта на текущем. `Libbox.version()` статический, туннель для
    // него поднимать не нужно; null остаётся только если канал не ответил.
    String? coreVersion;
    try {
      final v = await BoxVpnClient().getCoreVersion();
      if (v.isNotEmpty) coreVersion = v;
    } catch (_) {}

    // §207 — goroutine stack-дамп встраиваем в пак ТОЛЬКО при активном
    // туннеле (без ядра `Libbox.dumpStacks()` нечего дампить). CPU-профиль
    // в JSON не кладём — бинарь .pb шарится отдельным файлом.
    String? goroutinesStack;
    try {
      if ((await BoxVpnClient().getVpnStatus()).isUp) {
        final s = await BoxVpnClient().dumpGoroutines();
        if (s.isNotEmpty) goroutinesStack = s;
      }
    } catch (_) {}

    final vars = await SettingsStorage.getAllVars();
    // Берём live `ServerList`'ы из `SubscriptionController` через
    // DebugRegistry — там после `init()` уже распарсены `nodes` (тело
    // подписки → NodeSpec'ы с warnings'ами). Persisted-снапшот через
    // `SettingsStorage.getServerLists()` сериализует подписки **без**
    // nodes (ноды живут только в памяти после parseFromSource), поэтому
    // dump из storage всегда давал `_node_count: 0` для подписок. Live —
    // ровно то что юзер видит в UI и что используется при build'е конфига.
    //
    // Fallback на storage если registry ещё не bind'ился (Debug API
    // стартует до HomeScreen.initState — ранний dump через debug-API
    // не должен падать).
    final liveSub = DebugRegistry.I.sub;
    final List<ServerList> lists = liveSub != null
        ? liveSub.entries.map((e) => e.list).toList()
        : await SettingsStorage.getServerLists();
    // §038 — четыре канала диагностики:
    // - канал A: stderr.log (Go panic-stacktrace из libbox перед SIGABRT'ом)
    // - канал B: ApplicationExitInfo (системный rationale смерти + tombstone)
    // - канал C: persistent AppLog (warning+error JVM-events до краха,
    //   уже подгружены в AppLog.I с fromPreviousSession=true).
    // - канал D: logcat tail (system-level логи нашего процесса —
    //   AndroidRuntime FATAL EXCEPTION, libc/DEBUG/tombstoned для NATIVE,
    //   art/linker для class-load failures). UID-фильтрован logd'ом.
    final stderr = await StderrReader.read();
    final exitInfo = await ExitInfoReader.read();
    final logcatTail = await LogcatReader.tail();
    // §316 — вся история Go-паник ядра одной кнопкой. Канал A выше отдаёт
    // только ТЕКУЩИЙ репорт; архив ядро складывает в `crash_reports/` и
    // раньше в пак не попадал вовсе.
    final crashArchive = await _crashArchive();
    // §318 — снимки oom-killer'а ядра. Второй автоматический канал улик по
    // памяти: снят самим ядром в момент проблемы, до §318 в пак не попадал.
    final oomReports = await _oomReports();

    final dump = <String, dynamic>{
      'generated_at': now.toIso8601String(),
      'app': 'lxbox',
      // §378 — чем собран пак. `app_version` — versionName (`X.Y.Z`),
      // `app_build` — versionCode: по §379 последняя цифра кодирует ABI
      // (0/1/2/4, см. docs/FDROID.md), то есть отвечает на «какой именно APK
      // стоит», а остальные разряды — версию и стадию (rc / релиз / hotfix).
      'app_version': VersionInfo.I.version,
      'app_build': VersionInfo.I.buildNumber,
      'core_version': coreVersion,
      'vars': vars,
      'server_lists': lists.map(_sanitizeList).toList(),
      'config': config == null ? null : _tryDecode(config),
      'debug_log': AppLog.I.entries.map(_entryJson).toList(),
      'stderr_log': stderr,
      'crash_archive': crashArchive,
      'oom_reports': oomReports,
      'exit_info': exitInfo,
      'logcat_tail': logcatTail,
      'goroutines_stack': goroutinesStack,  // §207 — null если туннель не активен
    };

    final dir = await getTemporaryDirectory();
    final stamp =
        now.toIso8601String().replaceAll(':', '-').substring(0, 19);
    final file = File('${dir.path}/lxbox-dump-$stamp.json');
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(dump));
    return file.path;
  }

  /// §316 — архивные краш-репорты ядра с содержимым. Текущий репорт сюда
  /// НЕ кладём: он уже уехал в `stderr_log` отдельным полем.
  ///
  /// Тело каждого файла режем: Go-паника с сотней горутин бывает на сотни
  /// KB, а решает всё голова трейса (паникующая горутина идёт первой).
  /// Обрезанное помечаем явно, чтобы читающий не гадал, почему трейс
  /// обрывается на полуслове.
  static const _crashBodyLimit = 64 * 1024;

  static Future<List<Map<String, Object?>>> _crashArchive() async {
    try {
      final reports =
          (await CrashReports.list()).where((r) => !r.isCurrent).toList();
      final out = <Map<String, Object?>>[];
      for (final r in reports) {
        String? content;
        try {
          content = await File(r.path).readAsString();
        } catch (_) {
          // Файл исчез между list() и чтением — пропускаем тело, метаданные
          // всё ещё полезны (был краш в такое-то время).
        }
        final truncated =
            content != null && content.length > _crashBodyLimit;
        out.add({
          'name': r.name,
          'mtime': r.mtime.toUtc().toIso8601String(),
          'size': r.size,
          if (r.coreVersion != null) 'core_version': r.coreVersion,
          if (truncated) 'truncated': true,
          'content':
              truncated ? content.substring(0, _crashBodyLimit) : content,
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// §318 — OOM-снимки ядра: ТОЛЬКО метаданные, без тел.
  ///
  /// Тела не кладём осознанно: вес снимка — бинарные pprof-профили, в JSON
  /// им не место, а `go.log` снимка дублирует общий лог. Кому нужны профили
  /// — share конкретного снимка со вкладки OOM. Здесь важно другое: сам
  /// факт, что killer срабатывал, и цифры памяти в этот момент.
  static Future<List<Map<String, Object?>>> _oomReports() async {
    try {
      return [
        for (final r in await OomReports.list())
          {
            'name': r.name,
            'mtime': r.mtime.toUtc().toIso8601String(),
            'size': r.size,
            if (r.coreVersion != null) 'core_version': r.coreVersion,
            if (r.memoryUsage != null) 'memory_usage': r.memoryUsage,
            if (r.heapInuse != null) 'heap_inuse': r.heapInuse,
            if (r.numGoroutine != null) 'num_goroutine': r.numGoroutine,
          },
      ];
    } catch (_) {
      return const [];
    }
  }

  /// `ServerList.toJson()` + node tags (без полного NodeSpec, чтобы файл
  /// не раздуло для подписок с 200+ узлами). Если нужен полный recreate —
  /// есть url, тело тянется заново.
  static Map<String, dynamic> _sanitizeList(ServerList l) {
    final j = l.toJson();
    j['_node_tags'] = l.nodes.map((n) => n.tag).toList();
    j['_node_count'] = l.nodes.length;
    return j;
  }

  static dynamic _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return s;
    }
  }

  static Map<String, dynamic> _entryJson(DebugEntry e) => {
        'time': e.time.toIso8601String(),
        'level': e.level.name,
        'source': e.source == DebugSource.core ? 'core' : 'app',
        'message': e.message,
        if (e.fromPreviousSession) 'prev_session': true,
      };
}
