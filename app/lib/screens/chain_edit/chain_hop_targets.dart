// §393 C7 — сбор целей, которые можно поставить позицией цепочки.
//
// Порт `collectChainHopCandidates` лаунчера (`source_chain_hops.go`),
// переложенный на источники данных мобилы.
//
// ОТКУДА БЕРЁМ. У лаунчера есть кэш превью подписок; у мобилы аналог —
// ПОСЛЕДНИЙ СОБРАННЫЙ КОНФИГ ([ParsedConfig]). Он лучше кэша превью тем, что
// теги в нём ОКОНЧАТЕЛЬНЫЕ: префикс подписки уже приклеен, дубли уже
// уникализированы аллокатором (§351). Позиция цепочки — это ссылка на тег в
// конфиге, и брать её из чего-либо, кроме конфига, значило бы предлагать
// пользователю имена, которых в конфиге не будет.
//
// Отсюда же берутся `reality` и `detour` кандидатов: и то, и другое — свойства
// СОБРАННОГО outbound'а, а не строки подписки.

import '../../models/config_node.dart';
import '../../models/direction.dart';
import '../../models/source_chain.dart';
import 'chain_hop_candidate.dart';

/// Служебный тег шаблона, законный первой позицией: «первый хоп без прокси».
/// Блокировка (`block`) позицией смысла не имеет и не предлагается.
const String kChainBuiltinDirect = 'direct-out';

/// §393 C7 — всё, на что цепочка [selfTag] вправе сослаться.
///
/// Порядок: Направления → служебные → другие цепочки → узлы. Первые три
/// объявлены пользователем и осмысленны как маршрут; узлов сотни, и порядок
/// подписки для выбора бесполезен — они идут по алфавиту.
///
/// [selfTag] исключается: ядро отвергает цепочку, содержащую саму себя.
///
/// [chains] — ВЕСЬ список цепочек в порядке объявления. Стоящие НИЖЕ
/// редактируемой помечаются [ChainHopCandidate.below]: сборка разрешает
/// ссылку только вверх по списку, и форма обязана предупредить, а не дать
/// молча собрать позицию, которая деградирует цепочку целиком.
List<ChainHopCandidate> collectChainHopTargets({
  required ParsedConfig config,
  required List<Direction> directions,
  required List<SourceChain> chains,
  required String selfTag,
}) {
  final seen = <String>{};
  final out = <ChainHopCandidate>[];

  void add(ChainHopCandidate c) {
    final tag = c.tag.trim();
    if (tag.isEmpty || tag == selfTag || !seen.add(tag)) return;
    out.add(c);
  }

  // Направления — первыми: пользователь думает о маршруте именно в них.
  // Выключенные не берём: в конфиг они не попадут, а ссылка на отсутствующий
  // тег не даст стартовать ядру.
  for (final d in directions) {
    if (!d.enabled) continue;
    // §248/§393 — в предложения пикера идут только detour-Направления
    // (галка = «можно выбирать промежуточной целью»); остальные остаются
    // кандидатами-знанием для валидации существующих позиций.
    add(ChainHopCandidate(
        tag: d.tag,
        kind: ChainHopKind.direction,
        offered: d.isDetour,
        displayLabel: d.displayLabel,
        subline: d.tag));
  }

  // Директива оператора 25.08: direct-out, группы и цепочки в ПРЕДЛОЖЕНИЯ
  // пикера не идут (позиция = detour-Направление или сервер). Кандидатами-
  // знанием остаются: существующие позиции этих видов валидны и показываются.
  add(const ChainHopCandidate(
      tag: kChainBuiltinDirect, kind: ChainHopKind.builtin, offered: false));

  // Другие цепочки. НЕ прячем те, что ниже (сценарий рабочий — их можно
  // передвинуть), а помечаем: спрятать значило бы оставить пользователя
  // гадать, почему нужной цепочки нет в списке.
  var belowSelf = false;
  for (final c in chains) {
    if (c.tag == selfTag) {
      belowSelf = true;
      continue;
    }
    if (!c.enabled) continue;
    add(ChainHopCandidate(
      tag: c.tag,
      kind: ChainHopKind.chain,
        offered: false,
      below: belowSelf,
    
        displayLabel: c.tag,
        subline: '${c.hops.length}',));
  }

  // Узлы и группы собранного конфига. Служебные (`direct`/`block`/`dns`) не
  // предлагаем: `direct-out` уже добавлен выше как осмысленная первая
  // позиция, остальные позицией не бывают.
  final nodes = <ChainHopCandidate>[];
  for (final n in config.byTag.values) {
    if (n.tag == selfTag || seen.contains(n.tag)) continue;
    if (n.type == 'direct' || n.type == 'block' || n.type == 'dns') continue;
    // Сама цепочка в конфиге — уже узел `type: chain`; она приехала выше из
    // списка источников, где известен ещё и порядок объявления.
    if (n.type == kChainOutboundType) continue;
    final isGroup = n.type == 'selector' || n.type == 'urltest';
    nodes.add(ChainHopCandidate(
      tag: n.tag,
      kind: isGroup ? ChainHopKind.group : ChainHopKind.node,
      // Reality живёт в собранном outbound'е (`tls.reality.enabled`), и
      // `securityLabel` — уже вычисленный ответ на тот же вопрос.
      reality: n.securityLabel != null && n.securityLabel!.startsWith('Reality'),
      detour: (n.detour ?? '').isNotEmpty,
      outboundType: n.type,
      // transportLabel у masque — это и есть vhttp ('h3'/'h2'/'auto',
      // пусто → дефолт ядра h3), см. ConfigNode._deriveTransport.
      masqueVhttp: n.type == 'masque' ? (n.transportLabel ?? 'h3') : '',
      subline: _nodeSubline(n, isGroup: isGroup),
      offered: !isGroup,
    ));
  }
  nodes.sort((a, b) => a.tag.compareTo(b.tag));
  for (final n in nodes) {
    add(n);
  }

  return out;
}

/// Разобран ли снимок целей.
///
/// Пустой конфиг и «в подписках нет ни одного узла» здесь неразличимы, и это
/// осознанно: второе — тоже не повод объявлять позиции потерянными, пока
/// конфиг не собран ни разу.
bool chainTargetsKnown(ParsedConfig config) => config.byTag.isNotEmpty;


/// Сабстрока узла/группы для пикера: данные из собранного конфига,
/// как в detour-пикере — `TYPE · server:port`, у группы `type · N членов`.
String _nodeSubline(ConfigNode n, {required bool isGroup}) {
  if (isGroup) {
    final members = n.raw['outbounds'];
    final count = members is List ? members.length : 0;
    return '${n.type} · $count';
  }
  final server = n.raw['server'];
  final port = n.raw['server_port'];
  final addr = (server is String && server.isNotEmpty)
      ? (port == null ? server : '$server:$port')
      : '';
  return [n.type.toUpperCase(), if (addr.isNotEmpty) addr].join(' · ');
}
