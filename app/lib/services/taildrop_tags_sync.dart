// §707 итер. 9 — производные множества итоговых тегов Taildrop.
//
// Настройки Taildrop узла — поля записи `disable_taildrop_commands` /
// `disable_taildrop_autosave` (свой сервер в корне и член папки, контракт
// 1.1.159): `true` = функция выключена, отсутствие = включена при Allow
// Taildrop. Kotlin сравнивает итоговый тег от ядра со строкой, поэтому Dart
// кладёт в зеркало `boxvpn_boot` два множества итоговых тегов ВЫКЛЮЧЕННЫХ
// (`setTaildropTags`). Пушится после успешной сборки конфига, при
// переключении галки и на старте.

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/node_spec.dart';
import '../models/server_list.dart';
import '../vpn/box_vpn_client.dart';
import 'app_log.dart';
import 'tag_resolver.dart';

/// Два множества итоговых тегов выключенных: `taildrop_commands_off_tags` и
/// `taildrop_autosave_off_tags` зеркала. Тега нет в множестве — включено.
@immutable
class TaildropTagSets {
  const TaildropTagSets({required this.commandsOff, required this.autosaveOff});

  final List<String> commandsOff;
  final List<String> autosaveOff;

  @override
  bool operator ==(Object other) =>
      other is TaildropTagSets &&
      listEquals(other.commandsOff, commandsOff) &&
      listEquals(other.autosaveOff, autosaveOff);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(commandsOff), Object.hashAll(autosaveOff));

  @override
  String toString() =>
      'TaildropTagSets(commandsOff: $commandsOff, autosaveOff: $autosaveOff)';
}

/// Узел Tailscale записи с её полями Taildrop и префиксом `tag_policy`.
typedef TaildropRecordNode = ({
  TailscaleSpec node,
  String prefix,
  bool commandsOff,
  bool autosaveOff,
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
            commandsOff: u.disableTaildropCommands,
            autosaveOff: u.disableTaildropAutosave,
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
            commandsOff: m.disableTaildropCommands,
            autosaveOff: m.disableTaildropAutosave,
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
/// значение с тегом ядра не совпадёт, и до следующей сборки ядро видит
/// умолчание «включено» (контракт 1.1.159).
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

/// Множества тегов выключенных для зеркала.
TaildropTagSets taildropTagSets(List<ServerList> lists,
    {Map<String, NodeSpec>? emitted}) {
  final commandsOff = <String>{};
  final autosaveOff = <String>{};
  for (final r in taildropRecordNodes(lists)) {
    if (!r.commandsOff && !r.autosaveOff) continue;
    final tag = taildropFinalTag(r, emitted);
    if (r.commandsOff) commandsOff.add(tag);
    if (r.autosaveOff) autosaveOff.add(tag);
  }
  return TaildropTagSets(
    commandsOff: commandsOff.toList()..sort(),
    autosaveOff: autosaveOff.toList()..sort(),
  );
}

/// Поля Taildrop записи узла по итоговому тегу [tag] в знаке записи
/// (`true` = выключено; тот же поиск, что у вкладки Network: префикс записи,
/// суффикс дедупа); `null` — у узла нет своей записи (подписка) или узел не
/// найден.
({int entryIndex, int? memberIndex, bool commandsOff, bool autosaveOff})?
    taildropRecordForTag(String tag, List<ServerList> lists,
        {Map<String, NodeSpec>? emitted}) {
  final nodes = taildropRecordNodes(lists);
  for (final r in nodes) {
    if (taildropFinalTag(r, emitted) == tag) {
      return (
        entryIndex: r.entryIndex,
        memberIndex: r.memberIndex,
        commandsOff: r.commandsOff,
        autosaveOff: r.autosaveOff,
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
    await BoxVpnClient().setTaildropTags(
        commandsOff: sets.commandsOff, autosaveOff: sets.autosaveOff);
  } catch (e) {
    AppLog.I.debug('taildrop tags: push skipped ($e)');
  }
}

/// §707 итер. 9 H (контракт 1.1.159) — старые файлы rc.3 (`lxbox_taildrop`
/// и пр.) удаляются без переноса: `autosave.<тег>` не читается, умолчание
/// новых полей — «включено». Один раз на каждом старте, пока файлы есть —
/// повтор безвреден.
Future<void> migrateLegacyTaildropPrefs({BoxVpnClient? client}) async {
  try {
    await (client ?? BoxVpnClient()).deleteLegacyPrefs();
  } catch (_) {
    // Канала нет — файлов тоже.
  }
}
