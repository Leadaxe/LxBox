import '../models/direction.dart';
import '../models/config_node.dart';
import 'selector_info.dart';

/// §258 — рантайм-цепочка detour по СОБРАННОМУ конфигу.
///
/// В отличие от §252 `detourPathHops` (разворот storage-значения detour —
/// превью в редакторах, до сборки) здесь источник — эмитированный конфиг
/// (`ParsedConfig`, §091): detour-поля как их видит ядро, плюс живые выборы
/// селекторов (`SelectorInfo`, §251). Используется Overview-вкладкой
/// View-экрана ноды.

/// Потолок хопов экспансии (страховка вместе с `seen`-set; собранный конфиг
/// после §254 циклов не содержит, но guard остаётся).
const int kMaxRuntimeHops = 12;

/// Типы групповых outbound'ов: не терминальны — продолжаем через текущий
/// выбор селектора.
const Set<String> _kGroupTypes = {'selector', 'urltest'};

/// §258 — один хоп рантайм-цепочки.
class RuntimeHop {
  const RuntimeHop({
    required this.tag,
    required this.type,
    this.direction,
    this.viaSelection = false,
  });

  /// Config-тег хопа.
  final String tag;

  /// `type` из конфига; '' = тега нет в конфиге (обрыв цепочки).
  final String type;

  /// Направление §125, если хоп — Направление (совпал `tag` или `autoTag`); null = нода.
  final Direction? direction;

  /// Хоп достигнут через ТЕКУЩИЙ выбор селектора (не через detour-поле) —
  /// динамическая часть пути, сменится вместе с выбором.
  final bool viaSelection;

  bool get isDirection => direction != null;

  /// Тег отсутствует в собранном конфиге (битая ссылка / чужой конфиг).
  bool get isUnknown => type.isEmpty;

  /// Групповой outbound (selector/urltest).
  bool get isGroup => _kGroupTypes.contains(type);
}

/// Направление §125 по config-тегу: сам селектор (`c.tag`) или его urltest-двойник
/// (`c.autoTag`). null = не Направление. Смотрим ВСЕ Направления (и выключенные):
/// config-тег, равный тегу Направления, и есть Направление — билдер дедуплицирует
/// коллизии `allocateTag`-суффиксом (tradeoff-патологию см. spec 258).
Direction? directionForTag(String tag, List<Direction> directions) {
  for (final c in directions) {
    if (tag == c.tag || tag == c.autoTag) return c;
  }
  return null;
}

/// §258 — рантайм-цепочка от [tag] в ПОРЯДКЕ ПАКЕТА (§252): самый глубокий
/// транспорт (вплотную к телефону) первым, сам [tag] — последним.
///
/// Экспансия идёт вглубь (`self → его detour → …`); групповой хоп
/// (selector/urltest) продолжается через текущий выбор [selectedOf]
/// (default — `SelectorInfo.I.selectedOf`, инъекция для тестов). Выбор
/// неизвестен (туннель down) → цепочка обрывается на группе — вызывающий
/// видит это по `hops.first.isGroup` (обрыв всегда на глубоком, Phone-краю).
/// Тег вне конфига → хоп с `type == ''` и обрыв.
List<RuntimeHop> runtimeChainOf(
  String tag,
  ParsedConfig config, {
  required List<Direction> directions,
  String? Function(String tag)? selectedOf,
}) {
  final selected = selectedOf ?? SelectorInfo.I.selectedOf;
  final hops = <RuntimeHop>[];
  final seen = <String>{};
  String? cur = tag;
  var via = false;
  // §344 — пустой тег = выбора нет (round_robin-группа, §322): обрыв, как и
  // на null. `selectedOf` инъектируется в тестах — контракт держим здесь.
  while (cur != null &&
      cur.isNotEmpty &&
      hops.length < kMaxRuntimeHops &&
      seen.add(cur)) {
    final node = config[cur];
    hops.add(RuntimeHop(
      tag: cur,
      type: node?.type ?? '',
      direction: directionForTag(cur, directions),
      viaSelection: via,
    ));
    if (node == null) break; // тег вне конфига — дальше идти некуда
    if (_kGroupTypes.contains(node.type)) {
      cur = selected(cur); // null (туннель down) → обрыв на группе
      via = true;
    } else {
      cur = node.detour;
      via = false;
    }
  }
  // Экспансия шла вглубь; физически пакет идёт из глубины наружу —
  // разворачиваем в порядок пакета (зеркало §252 detourPathHops).
  return hops.reversed.toList();
}
