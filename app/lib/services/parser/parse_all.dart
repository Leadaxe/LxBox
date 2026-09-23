import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../contract/parse_warnings.dart';
import '../contract/registry.dart';
import 'body_decoder.dart';
import 'engine/document.dart';
import 'ini_parser.dart';
import 'json_parsers.dart';
import 'singbox_config.dart';
import 'uri_parsers.dart';

/// Парсинг декодированного тела в список узлов (§3.3).
///
/// Ошибки отдельных строк — null-skip, не throw. Верхнеуровневый exhaustive
/// switch гарантирует, что новый тип DecodedBody сломает компиляцию.
///
/// §243/§456 — [nameHint] (имя файла при импорте, тег записи при чтении
/// хранения, поле Tag редактора) прокидывается только в INI-ветки: у INI нет
/// собственного имени (кроме комментария под `[Peer]`, который сильнее).
/// URI-строки и JSON несут имена сами — hint игнорируют.
///
/// §404 / D-088 — [dropped] (необязательный) собирает причины ОТБРАКОВКИ
/// целых записей тела: узел был узнан и осознанно отвергнут (недостижимый
/// `dialerProxy`), а не «не распознан вовсе». Возвращаемый список узлов о
/// таких записях не рассказывает по построению — их в нём нет, — а когда
/// подписка вырождается в пустую, причина не доезжает и до
/// `nodes.first.warnings`. Параметр не меняет поведения ни одного текущего
/// вызывающего (все передают его `null`) и нужен конформанс-раннеру корпуса:
/// конверт контракта несёт `dropped[]` наравне с `nodes[]`.
///
/// §460 W2a — узкая общая воронка разбора: ЧЕРЕЗ НЕЁ проходят все входы
/// (тела подписок, URI-строки, sing-box/Xray JSON, INI, серверы и члены
/// папок — `ServerList`, `SourceRecord`, контроллер подписок), и здесь же
/// узел получает предупреждения реестра контракта
/// ([annotateAllWithRegistry]). Тело узла при этом не меняется — чистит
/// по-прежнему гард сборки.
///
/// §472 шаг 1 — у JSON-входа проходов ДВА, и порядок между ними значим:
///
///  1. [annotateAllFromRawBody] — санитайзер по ДОСЛОВНОЙ карте провайдера
///     (`rawSource`, §455). Он видит то, что типизированный парсер уже снял:
///     ключ вне схемы, `flow` из чёрного списка, TLS-поле, запрещённое схеме.
///     Его коды несут `path` и `value`.
///  2. [annotateAllWithRegistry] — санитайзер по `emit()` модели. Он видит
///     то, чего в дословной карте не было: значения, которые ПОСТАВИЛ разбор
///     (нормализация, дефолты `all_or_nothing`), и всё тело URI/INI-узла,
///     у которого дословной карты нет вовсе.
///
/// Первым идёт дословный: при совпадении пары `(code, path)` остаётся запись,
/// которая пришла раньше, а дословная точнее — её `value` называет то, что
/// лежало в теле, а не то, во что разбор это превратил.
///
/// Поскольку разбор идёт заново при каждой загрузке узла из хранения (узел
/// хранится текстом `rawSource`), предупреждения переживают перезагрузку по
/// построению: их никто не сериализует, они каждый раз считаются заново.
List<NodeSpec> parseAll(
  DecodedBody decoded, {
  String? nameHint,
  List<NodeWarning>? dropped,
}) {
  final nodes = _parseAll(decoded, nameHint: nameHint, dropped: dropped);

  // §477 — проход по дословной карте выносит и ВЕРДИКТ О ЗАПИСИ, а не только
  // коды полей: `on_invalid: drop_node` значит, что ядро эту запись не примет
  // и не стартует НА ВСЁМ конфиге (ровно случай #147 — одна негодная строка
  // `encryption` в одном узле подписки). Такой узел обязан исчезнуть из
  // списка здесь же, при разборе: до гарда сборки он дожил бы только затем,
  // чтобы быть снятым там, а до тех пор стоял бы в списке рабочим.
  //
  // Где это делается — тут, а не внутри прохода: `dropped[]` принадлежит
  // `parseAll`, и конверт контракта (D-088) различает «запись отвергли» и
  // «тело не распознано» именно этим списком.
  final byRegistry = annotateAllFromRawBody(nodes);
  if (byRegistry.isNotEmpty) {
    nodes.removeWhere(byRegistry.contains);
    // Причина — код реестра, который проход уже поставил на узел, плюс тег
    // записи: `dropped[].ref` контракта называет именно тег outbound'а
    // (corpus/README), а не человеческое имя.
    dropped?.addAll(byRegistry.map(_dropReasonOf));
  }

  annotateAllWithRegistry(nodes);
  return nodes;
}

/// §477 — причина отбраковки узла реестром: код `error`, который проход по
/// дословной карте поставил на узел, с приписанным тегом записи.
///
/// Кодов `error` на узле может оказаться несколько; берётся ПЕРВЫЙ — порядок
/// их постановки и есть порядок `body.order` реестра, то есть первый говорит
/// о самом раннем поле тела. Ни одного не нашлось — вердикт пришёл, а кода
/// нет, и назвать причину нечем: тогда остаётся сам тег.
NodeWarning _dropReasonOf(NodeSpec node) {
  for (final w in node.warnings) {
    if (w is! RegistryWarning) continue;
    if (ContractRegistry.I.textFor(w.code)?.severity != 'error') continue;
    return RegistryWarning(
      code: w.code,
      path: w.path,
      value: w.value,
      params: w.params,
      ownerTag: node.tag,
    );
  }
  return RegistryWarning(code: 'type_invalid', ownerTag: node.tag);
}

List<NodeSpec> _parseAll(
  DecodedBody decoded, {
  String? nameHint,
  List<NodeWarning>? dropped,
}) {
  return switch (decoded) {
    // §302/§454/§456 — источник узла (`rawSource`) проставляют сами парсеры:
    // для URI-строк это строка, для INI — сам INI-текст (тег — поле записи),
    // для JSON — объект outbound'а.
    UriLines(lines: final ls) => _parseUriLines(ls, dropped),
    IniConfig(text: final t) => _parseIniConfigs([t], nameHint: nameHint, dropped: dropped),
    // §110 — Amnezia vpn://: каждый контейнер → INI → нода (null-skip).
    // §243 — hint с индексным суффиксом (`hint`, `hint 2`, …): фрагмент
    // теперь «собственное имя» raw, суффикс-логика addMembersToFolder до
    // таких нод не дойдёт — разводим коллизии здесь.
    AmneziaConfig(iniTexts: final ts) => _parseIniConfigs(
        ts,
        nameHint: nameHint,
        dropped: dropped,
        indexedHint: true,
      ),
    JsonConfig() => _parseJson(decoded, dropped),
    // §506 — тело не опознано ВОВСЕ: раньше ветка отдавала пустой список и
    // причина декодера («vpn://: payload is neither qCompress nor JSON»,
    // «no parseable content») наружу не выходила. Пользователь видел «0
    // серверов» без единого слова о том, почему.
    //
    // Код `core_rejected` взят намеренно: его текст — «техническое сообщение:
    // {reason}», то есть ровно форма «причина от нижнего слоя, дословно». Это
    // код УРОВНЯ ЗАПИСИ, `path` у него нет — здесь записи нет вовсе, тело
    // целиком и есть запись.
    DecodeFailure(reason: final r) => _decodeFailed(r, dropped),
  };
}

/// §506 — тело не декодировано: причина декодера в `dropped[]`, узлов нет.
List<NodeSpec> _decodeFailed(String reason, List<NodeWarning>? dropped) {
  dropped?.add(RegistryWarning(code: 'core_rejected', params: {'reason': reason}));
  return const <NodeSpec>[];
}

List<NodeSpec> _parseUriLines(List<String> lines, List<NodeWarning>? dropped) {
  final nodes = <NodeSpec>[];
  for (final l in lines) {
    final verdict = XrayDropVerdict();
    final n = parseUri(l, dropped: verdict);
    if (n != null) {
      nodes.add(n);
    } else if (verdict.reason != null) {
      dropped?.add(verdict.reason!);
    }
  }
  return nodes;
}

List<NodeSpec> _parseIniConfigs(
  List<String> texts, {
  String? nameHint,
  List<NodeWarning>? dropped,
  bool indexedHint = false,
}) {
  final nodes = <NodeSpec>[];
  for (var i = 0; i < texts.length; i++) {
    final hint = indexedHint ? _indexedHint(nameHint, i) : nameHint;
    final verdict = XrayDropVerdict();
    final n = parseWireguardIni(texts[i], nameHint: hint, dropped: verdict);
    if (n != null) {
      nodes.add(n);
    } else if (verdict.reason != null) {
      dropped?.add(verdict.reason!);
    }
  }
  return nodes;
}

// Суффикс — по индексу КОНТЕЙНЕРА, не произведённой ноды: при null-skip
// битого среднего контейнера в нумерации остаётся дыра («hint», «hint 3»).
// Намеренно: имя каждой ноды стабильно привязано к своему контейнеру и не
// съезжает, когда соседний контейнер перестаёт парситься.
String? _indexedHint(String? hint, int i) {
  final h = hint?.trim() ?? '';
  if (h.isEmpty) return null;
  return i == 0 ? h : '$h ${i + 1}';
}

/// §321 P2 — сколько payload-серверов описывает элемент. Служебные
/// (`freedom`/`blackhole`/`dns`) не в счёт: они есть в каждом элементе и
/// сортировку бы обнулили.
int _payloadCount(Map<String, dynamic> element) {
  final obs = element['outbounds'];
  if (obs is! List) return 0;
  const service = {'freedom', 'blackhole', 'dns', 'loopback'};
  return obs
      .whereType<Map<String, dynamic>>()
      .where((o) => !service.contains(o['protocol']?.toString() ?? ''))
      .length;
}

List<NodeSpec> _parseJson(JsonConfig j, List<NodeWarning>? out) {
  // §480 — ОБХОД ЭЛЕМЕНТОВ ВЕДЁТ РЕЕСТР. Ветка документа называет и вид
  // источника элемента (`mapper`), и путь к элементам (`elements`); движок
  // достаёт по нему группы. Прежний рукописный `switch` по форме документа
  // был второй копией того же знания: вид источника уже опознан данными, а
  // путь к его элементам оставался ветвями здесь.
  //
  // §483 — ветка есть у ЛЮБОГО опознанного документа, включая опознанный без
  // реестра (`_detectLegacySource`), и второго обхода под запасной путь
  // больше нет: формы те же, различать их незачем.
  //
  // Группами, а не плоским списком: границы конфига несут смысл для дедупа
  // (§404) и владения именем (§342).
  final source = j.source;
  final spec = source.elements;
  final mapper = source.mapper;
  // Вид без маппера узлов не даёт по определению (Clash, нераспознанный
  // JSON): ноль узлов, как и прежде.
  if (mapper == null || spec == null) return const [];

  // Форма документа не та, что объявлена веткой, — обойти нечем.
  final groups = DocumentRegistry.groupsFor(spec, j.value);
  if (groups == null || groups.isEmpty) return const [];

  return mapper == 'xray'
      ? _parseXrayDocument(groups, out)
      : parseSingboxConfigs(groups);
}

/// §310/§321/§342/§404 — СБОРКА ДОКУМЕНТА Xray из его элементов.
///
/// Вынесена из `switch` целиком, без правок: способ ДОБРАТЬСЯ до элементов
/// теперь называет реестр, а что с ними делать дальше — порядок узлов, дедуп,
/// владение именем — принадлежит сборке документа и остаётся кодом.
List<NodeSpec> _parseXrayDocument(
  List<Map<String, dynamic>> elements,
  List<NodeWarning>? out,
) {
      // §310 — элемент массива даёт N узлов (кроме dialer-целей), а не один
      // «main». Порядок узлов внутри элемента задаёт парсер.
      // §321 P4 / §404 D-086 — накопитель ПОДПИСЕЙ дедупа на всю подписку
      // (эмиссия узла без tag/detour + подпись пути дозвона). Между подписками
      // дедуп НЕ работает намеренно: разные источники = разные
      // tag_prefix/detour_policy, схлопывать их нельзя.
      final seen = <String>{};
      // §321 P6 — таблица синонимов копится по ВСЕЙ подписке: тег провайдера
      // → ключ ПУЛА (`nodeIdentityKey`, грубая четвёрка). §322 резолвит по ней
      // состав пула, написанный на чужих тегах (`selector: ["proxy"]`).
      // Гранулярность тут намеренно другая, чем у дедупа: `selector` называет
      // СЕРВЕР, а не конкретную запись подписки, и подпись §404 (которая
      // разводит два SNI одного сервера) растащила бы состав пула.
      final synonyms = <String, String>{};
      // §404 / D-085 — причины отбраковки узлов с недостижимым релеем, которым
      // не нашлось носителя внутри своего элемента (в элементе не выжил
      // никто). Вешаем их на первый узел подписки: причина обязана дойти до
      // пользователя, иначе узел исчезает молча.
      final dropped = <NodeWarning>[];

      // §342 — ДВА прохода: «кто даёт узлу имя» и «в каком порядке узлы идут»
      // — разные задачи, и раньше они решались одной сортировкой.
      //
      // Проход 1 (черновой, узлы выбрасываются) — элементы от одиночных к
      // многоузловым, ровно как в §321 P2: право выпустить сервер достаётся
      // элементу с осмысленным `remarks` («🇩🇪⚡Германия»), а не пулу («Лучший
      // сервер» с техническими тегами). Здесь же копится таблица синонимов
      // (§321 P6). Побочно узнаём владельца каждой идентичности — `owner`.
      //
      // Проход 2 (боевой) — элементы строго в порядке файла; элемент выпускает
      // только те серверы, которые закреплены за ним в проходе 1. Имена те же,
      // что и до §342, а позиции — авторские. Раньше сортировка была
      // единственным проходом, и её побочный эффект переставлял подписку
      // целиком (на боевой 37-элементной — все 37 позиций, «🚀Авто | Лучший
      // сервер» уезжал с первого места в конец), хотя порядок часто осмыслен:
      // автор ставит рекомендуемый узел первым.
      // Сортировка обязана быть СТАБИЛЬНОЙ (спека §321: связки — в порядке
      // файла), а List.sort в Dart стабилен только до ~32 элементов (дальше
      // quicksort). Индекс в компараторе делает порядок связок детерминированно
      // авторским на подписке любого размера (боевой кейс §342 — 37 элементов).
      final indexed = elements.asMap().entries.toList()
        ..sort((a, b) {
          final byPayload =
              _payloadCount(a.value).compareTo(_payloadCount(b.value));
          return byPayload != 0 ? byPayload : a.key.compareTo(b.key);
        });
      final priming = [for (final e in indexed) e.value];
      final owner = <String, Map<String, dynamic>>{};
      for (final e in priming) {
        final before = seen.toSet();
        parseXrayElement(e, seen: seen, synonyms: synonyms);
        for (final id in seen.difference(before)) {
          owner[id] = e;
        }
      }
      final nodes = elements
          .expand((e) => parseXrayElement(
                e,
                // `seen` этого прохода — свой: общий накопитель уже полон, и
                // дедуп-`continue` съел бы все узлы. Ownership из прохода 1
                // передаём через `ownedBy`.
                seen: <String>{},
                synonyms: synonyms,
                ownedBy: (sig) => identical(owner[sig], e),
                dropped: dropped,
              ))
          .toList();
      // §404 P3 — то, что осталось в `dropped`, носителя в своём элементе не
      // нашло. Последний носитель — первый узел подписки; если и его нет,
      // подписка пустая и сообщать некому (та же документированная дыра, что
      // у §321 P5).
      // D-088 — отбраковка едет наружу ЦЕЛИКОМ, независимо от того, нашёлся ли
      // ей носитель среди узлов: конверт контракта различает «запись отвергли»
      // и «тело не распознано», а `nodes.first.warnings` этого различия не
      // несёт и на пустой подписке пропадает совсем.
      out?.addAll(dropped);
      if (dropped.isNotEmpty && nodes.isNotEmpty) {
        for (final w in dropped) {
          if (!nodes.first.warnings.contains(w)) nodes.first.warnings.add(w);
        }
      }
      return nodes;
}
