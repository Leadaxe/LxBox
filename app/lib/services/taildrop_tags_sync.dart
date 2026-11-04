// §707 итер. 9 — производные множества итоговых тегов Taildrop.
//
// Настройки Taildrop узла — поля записи `taildrop_commands` /
// `taildrop_autosave` (свой сервер в корне и член папки). Kotlin сравнивает
// итоговый тег от ядра со строкой, поэтому Dart кладёт в зеркало
// `boxvpn_boot` два множества итоговых тегов (`setTaildropTags`). Пушится
// после успешной сборки конфига, при переключении галки и на старте.

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../vpn/box_vpn_client.dart';
import 'app_log.dart';
import 'settings_storage.dart';
import 'tag_resolver.dart';

/// Два множества итоговых тегов: `taildrop_commands_tags` и
/// `taildrop_autosave_tags` зеркала.
@immutable
class TaildropTagSets {
  const TaildropTagSets({required this.commands, required this.autosave});

  final List<String> commands;
  final List<String> autosave;

  @override
  bool operator ==(Object other) =>
      other is TaildropTagSets &&
      listEquals(other.commands, commands) &&
      listEquals(other.autosave, autosave);

  @override
  int get hashCode => Object.hash(Object.hashAll(commands), Object.hashAll(autosave));

  @override
  String toString() => 'TaildropTagSets(commands: $commands, autosave: $autosave)';
}

/// Узел Tailscale записи с её полями Taildrop и префиксом `tag_policy`.
typedef TaildropRecordNode = ({
  TailscaleSpec node,
  String prefix,
  bool commands,
  bool autosave,
  int entryIndex,
  int? memberIndex,
});

/// Включённые узлы Tailscale своих записей (свой сервер и член папки).
/// Выключенная запись (сервер, папка или член) в конфиг не идёт — тега у
/// ядра нет, и в множества она не попадает. Подписка записи узла не имеет.
List<TaildropRecordNode> taildropRecordNodes(List<ServerList> lists) {
  final out = <TaildropRecordNode>[];
  for (var ei = 0; ei < lists.length; ei++) {
    final list = lists[ei];
    if (!list.enabled) continue;
    switch (list) {
      case UserServer u:
        for (final n in u.nodes) {
          if (n is! TailscaleSpec) continue;
          out.add((
            node: n,
            prefix: u.tagPrefix,
            commands: u.taildropCommands,
            autosave: u.taildropAutosave,
            entryIndex: ei,
            memberIndex: null,
          ));
        }
      case FolderServers f:
        for (var mi = 0; mi < f.members.length; mi++) {
          final m = f.members[mi];
          final n = m.node;
          if (!m.enabled || n is! TailscaleSpec) continue;
          out.add((
            node: n,
            prefix: f.tagPrefix,
            commands: m.taildropCommands,
            autosave: m.taildropAutosave,
            entryIndex: ei,
            memberIndex: mi,
          ));
        }
      default:
        break;
    }
  }
  return out;
}

/// Итоговый тег узла записи.
///
/// [emitted] — карта последней сборки «итоговый тег → узел»
/// (`SubscriptionController.lastEmittedTagMap`): тег, который сборка
/// присвоила именно этому узлу (с суффиксом дедупликации `-N`, если был).
/// Карты нет (до первой сборки за сессию) или узел в ней не найден по
/// идентичности — `TagResolver.displayTag(prefix, тег)`. При дедупе это
/// значение с тегом ядра не совпадёт, и галка не действует до следующей
/// сборки (безопасный отказ).
String taildropFinalTag(TaildropRecordNode r, Map<String, NodeSpec>? emitted) {
  final display = TagResolver.displayTag(r.prefix, r.node.tag);
  if (emitted == null || emitted.isEmpty) return display;
  if (identical(emitted[display], r.node)) return display;
  // Хвост дедупа `display-N`; алиасы хопов цепочки (тоже указывают на
  // владельца) этим шаблоном отсекаются.
  final dedup = RegExp('^${RegExp.escape(display)}-\\d+\$');
  for (final e in emitted.entries) {
    if (identical(e.value, r.node) && dedup.hasMatch(e.key)) return e.key;
  }
  return display;
}

/// Множества тегов для зеркала.
TaildropTagSets taildropTagSets(List<ServerList> lists,
    {Map<String, NodeSpec>? emitted}) {
  final commands = <String>{};
  final autosave = <String>{};
  for (final r in taildropRecordNodes(lists)) {
    if (!r.commands && !r.autosave) continue;
    final tag = taildropFinalTag(r, emitted);
    if (r.commands) commands.add(tag);
    if (r.autosave) autosave.add(tag);
  }
  return TaildropTagSets(
    commands: commands.toList()..sort(),
    autosave: autosave.toList()..sort(),
  );
}

/// Поля Taildrop записи узла по итоговому тегу [tag] (тот же поиск, что у
/// вкладки Network: префикс записи, суффикс дедупа); `null` — у узла нет
/// своей записи (подписка) или узел не найден.
({int entryIndex, int? memberIndex, bool commands, bool autosave})?
    taildropRecordForTag(String tag, List<ServerList> lists,
        {Map<String, NodeSpec>? emitted}) {
  final nodes = taildropRecordNodes(lists);
  for (final r in nodes) {
    if (taildropFinalTag(r, emitted) == tag) {
      return (
        entryIndex: r.entryIndex,
        memberIndex: r.memberIndex,
        commands: r.commands,
        autosave: r.autosave,
      );
    }
  }
  return null;
}

bool? _autosaveSupported;

/// Тесты: ответ «Android 10+» без device_info.
@visibleForTesting
set debugTaildropAutosaveSupported(bool? v) => _autosaveSupported = v;

/// Сохранение в Downloads без разрешений — Android 10+ (MediaStore).
Future<bool> taildropAutosaveSupported() async {
  final cached = _autosaveSupported;
  if (cached != null) return cached;
  var ok = false;
  try {
    if (Platform.isAndroid) {
      ok = (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 29;
    }
  } catch (_) {
    ok = false;
  }
  return _autosaveSupported = ok;
}

/// Тесты: перехват пуша вместо канала.
@visibleForTesting
Future<bool> Function(TaildropTagSets sets)? debugTaildropTagsSink;

/// Посчитать множества по [lists] и отдать в зеркало `boxvpn_boot`.
/// Best-effort: канала нет (тесты, не Android) — молча.
Future<void> pushTaildropTags(List<ServerList> lists,
    {Map<String, NodeSpec>? emitted}) async {
  final sets = taildropTagSets(lists, emitted: emitted);
  final sink = debugTaildropTagsSink;
  if (sink != null) {
    await sink(sets);
    return;
  }
  try {
    await BoxVpnClient()
        .setTaildropTags(commands: sets.commands, autosave: sets.autosave);
  } catch (e) {
    AppLog.I.debug('taildrop tags: push skipped ($e)');
  }
}

/// §707 итер. 9 H — перенос из rc.3: теги с `autosave.*` старого файла
/// `lxbox_taildrop` → поле `taildrop_autosave: true` записи с тем же
/// итоговым тегом; затем старые файлы удаляются (`deleteLegacyPrefs`, один
/// раз на каждом старте, пока файлы есть — повтор безвреден). Возвращает
/// число отмеченных записей.
Future<int> migrateLegacyTaildropPrefs({BoxVpnClient? client}) async {
  final vpn = client ?? BoxVpnClient();
  List<String> tags;
  try {
    tags = await vpn.taildropLegacyAutosaveTags();
  } catch (_) {
    return 0;
  }
  var marked = 0;
  if (tags.isNotEmpty) {
    final want = tags.toSet();
    final lists = [...await SettingsStorage.getServerLists()];
    for (final r in taildropRecordNodes(lists)) {
      if (r.autosave || !want.contains(taildropFinalTag(r, null))) continue;
      final list = lists[r.entryIndex];
      final mi = r.memberIndex;
      if (list is UserServer && mi == null) {
        lists[r.entryIndex] = list.copyWith(taildropAutosave: true);
      } else if (list is FolderServers && mi != null) {
        final members = [...list.members];
        members[mi] = members[mi].copyWith(taildropAutosave: true);
        lists[r.entryIndex] = list.copyWith(members: members);
      } else {
        continue;
      }
      marked++;
    }
    if (marked > 0) {
      await SettingsStorage.saveServerLists(lists);
      AppLog.I.info('taildrop: autosave moved to $marked node record(s)');
    }
  }
  try {
    await vpn.deleteLegacyPrefs();
  } catch (_) {
    // Канала нет — файлов тоже.
  }
  return marked;
}
