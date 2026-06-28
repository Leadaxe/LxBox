// §204 — единый источник набора строк секции «Routing» для detail-sheet'ов
// Conns и Profiler. Унифицирует РОВНО routing-блок: какие строки показывать и в
// каком порядке (Route / Rule / Chain / Detour / Outbound / Outbound type).
//
// Намеренно НЕ виджет: разные sheet'ы рендерят строки своим row-builder'ом
// (`_copyRow` с тап-копированием + своим стилем). Здесь — только ДАННЫЕ (что
// показывать), чтобы не тащить общий рендер через два разных контекста (copy/
// search-семантика, footer, Close-кнопка у Conns остаются у каждого свои).
//
// Источник истины нотации Route-строки — §181 (`⇒ внутри / : выход / →
// снаружи`); `CcConnection.routingLineOf` и `TrafficEvent.routingLineOf` дают
// идентичную строку (один источник chains/detours из ядра).

/// Одна строка секции Routing: подпись + значение. Пустые `value` отсеиваются
/// вызывающим (его row-builder возвращает null на пустую строку).
class RoutingRow {
  const RoutingRow(this.label, this.value);
  final String label;
  final String value;
}

/// Набор строк секции «Routing», единый для Conns и Profiler. Поля приходят уже
/// извлечёнными из соответствующей модели (`CcConnection` / `TrafficEvent`) —
/// см. вызовы в detail-sheet'ах.
///
/// - [route]        — §181 routing-строка (`routingLineOf()` без compact).
/// - [rule]         — правило (пустое → "final").
/// - [chain]        — outbound-цепочка `[node, …selectors]` (как от ядра).
/// - [detour]       — detour-ось `[detour, …наружу]`.
/// - [outbound]     — финальный узел (для conn — отдельное поле; для event —
///                    `outboundChain.first`). Пусто → строка скрыта.
/// - [outboundType] — тип финального outbound (selector/urltest/vless/…).
List<RoutingRow> routingRows({
  required String route,
  required String rule,
  required List<String> chain,
  required List<String> detour,
  String outbound = '',
  String outboundType = '',
}) {
  return [
    RoutingRow('Route', route),
    RoutingRow('Rule', rule.isNotEmpty ? rule : 'final'),
    RoutingRow('Chain', chain.join(' / ')),
    RoutingRow('Detour', detour.join(' → ')),
    RoutingRow('Outbound', outbound),
    RoutingRow('Outbound type', outboundType),
  ];
}
