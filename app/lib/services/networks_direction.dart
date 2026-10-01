import '../models/config_node.dart';
import '../vpn/cc_channel.dart' show CcTailscaleStatus;
import 'contract/body_sanitizer.dart' show exitCapableByRegistry;

/// Задача 579 — псевдо-направление NETWORKS главного экрана.
///
/// Показывает узлы, которые не попали ни в один список выбора: запись в
/// `endpoints[]` собранного конфига, тип `tailscale`, реестр не считает узел
/// выходом (`exit_capable_when` ложно — в теле нет `exit_node`). В конфиг и
/// хранилище не пишется; группы с таким тегом у ядра нет.

/// Название в перечне направлений. Не переводится.
const String kNetworksLabel = 'NETWORKS'; // l10n-exempt: fixed name

/// Значение пункта NETWORKS в перечне направлений. Не тег: символ U+0001 в
/// теге группы пользователь не задаст, поэтому настоящее направление с тегом
/// `NETWORKS` с псевдо-направлением не совпадёт.
const String kNetworksDirectionValue = '\u0001networks';

final Expando<List<String>> _cache = Expando<List<String>>('networks579');

/// Теги узлов NETWORKS в порядке конфига. Пусто — псевдо-направления нет.
/// Результат кешируется на экземпляр [model] (он неизменяем, §091).
List<String> networksNodeTags(ParsedConfig model) =>
    _cache[model] ??= List.unmodifiable([
      for (final n in model.nodes)
        if (n.kind == 'endpoint' &&
            n.type == 'tailscale' &&
            !exitCapableByRegistry(n.raw))
          n.tag,
    ]);

/// Что показать в строке узла NETWORKS на месте задержки.
enum TailnetStateKind {
  /// VPN выключен: состояния нет.
  none,

  /// VPN включён, записи об узле от ядра ещё нет.
  starting,

  /// `BackendState` = `Running`.
  running,

  /// `BackendState` = `NeedsLogin`.
  signInNeeded,

  /// `BackendState` = `Stopped`.
  stopped,

  /// Прочее значение: показывается `StateText` ядра как есть.
  other,
}

class TailnetRowState {
  const TailnetRowState(this.kind, [this.text = '']);

  final TailnetStateKind kind;

  /// Текст ядра для [TailnetStateKind.other] (`StateText`, пустой —
  /// `BackendState`).
  final String text;

  /// Цвет предупреждения: вход не выполнен или узел остановлен.
  bool get isWarning =>
      kind == TailnetStateKind.signInNeeded || kind == TailnetStateKind.stopped;

  @override
  bool operator ==(Object other) =>
      other is TailnetRowState && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'TailnetRowState($kind, $text)';
}

/// Состояние строки узла [tag] по записям потока ядра [byTag].
TailnetRowState tailnetRowState({
  required bool tunnelUp,
  required String tag,
  required Map<String, CcTailscaleStatus> byTag,
}) {
  if (!tunnelUp) return const TailnetRowState(TailnetStateKind.none);
  final s = byTag[tag];
  if (s == null) return const TailnetRowState(TailnetStateKind.starting);
  switch (s.backendState) {
    case 'Running':
      return const TailnetRowState(TailnetStateKind.running);
    case 'NeedsLogin':
      return const TailnetRowState(TailnetStateKind.signInNeeded);
    case 'Stopped':
      return const TailnetRowState(TailnetStateKind.stopped);
  }
  return TailnetRowState(
    TailnetStateKind.other,
    s.stateText.isNotEmpty ? s.stateText : s.backendState,
  );
}
