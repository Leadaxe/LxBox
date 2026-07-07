import 'package:flutter/material.dart';

import '../../../widgets/reorder_grab_strip.dart';
import '../dns_body_dialogs.dart';
import '../dns_format.dart';
import 'dns_badge.dart';

/// §117 (решение №6) — атомарная mirror-группа в списке DNS Rules.
///
/// Содержимое (DNS-правила пресетов + mirror'ы routing-правил с DNS-опцией)
/// упорядочено **строго по routing-правилам** и внутри не реордерится.
/// Сама группа — один элемент ReorderableListView: standalone-правила можно
/// ставить только выше или ниже неё целиком.
class DnsMirrorGroupCard extends StatelessWidget {
  const DnsMirrorGroupCard({
    super.key,
    required this.children,
    this.dragIndex,
  });

  /// Под-строки группы (preset-тайлы + mirror-строки) в порядке
  /// routing-правил.
  final List<Widget> children;

  /// Display-индекс для drag'а группы целиком. null = позиция группы не
  /// персистится (нет kind:preset записей-якорей) — grab-strip не рисуем.
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // §117-fix: Stack+Positioned grab-strip вместо IntrinsicHeight+Row.
    // `ListTile`-дети группы под IntrinsicHeight занижают высоту и режут низ
    // контента при переносе заголовка (overflow). Stack даёт карточке
    // натуральную высоту по контенту.
    final card = Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Icon(Icons.alt_route,
                    size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'From routing rules · ordered as in Routing',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...children,
          const SizedBox(height: 4),
        ],
      ),
    );

    if (dragIndex == null) return card;
    // Полоса 18px + горизонтальные margin 6+6 = 30px gutter слева.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: card,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: ReorderGrabStrip(index: dragIndex!),
        ),
      ],
    );
  }
}

/// §117 — единый тайл строки внутри [DnsMirrorGroupCard]. Унифицирует оба
/// источника DNS-mirror'а, чтобы выглядели одинаково:
/// - **preset** — DNS-аспект bundle-пресета (§061-запись в `dns.rules`);
/// - **rule** — DNS-опция обычного routing-правила (задача 3, `cr.dns`).
///
/// Вид как у preset-тайла: switch + превью `rule_set` + плашка-источник
/// (`preset`/`rule`). Switch тогглит **только DNS-аспект** источника
/// (routing-часть живёт отдельно). Тап → read-only превью эмитимого DNS-rule.
class DnsMirrorTile extends StatelessWidget {
  const DnsMirrorTile({
    super.key,
    required this.title,
    required this.previewBodies,
    required this.sourceKind, // 'preset' | 'rule'
    required this.enabled,
    required this.onToggle,
    this.note,
  });

  final String title;

  /// Эмитимые DNS-rule тела (`rule_set` + `server` + package/wifi) — для
  /// превью-подзаголовка и read-only диалога по тапу. §253: пресет может
  /// нести несколько правил (switch тогглит блок атомарно); rule-источник
  /// передаёт `[body]`.
  final List<Map<String, dynamic>> previewBodies;

  /// `'preset'` | `'rule'` — плашка-источник + label в диалоге.
  final String sourceKind;

  final bool enabled;

  /// §257: null → свитч не рисуется (пресет без магической var `dns_enable`
  /// — тумблера у него нет, DNS-блок жив пока routing on).
  final ValueChanged<bool>? onToggle;

  /// Доп-пометка в подзаголовке (srs-каузат / пропавший сервер).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (String badgeText, Color badgeColor) = sourceKind == 'preset'
        ? ('preset', cs.primary)
        : ('rule', cs.secondary);
    final preview = formatRulesPreview(previewBodies, kind: sourceKind);
    final subtitle = (note != null && note!.isNotEmpty)
        ? '$preview · $note'
        : preview;
    return Card(
      child: ListTile(
        onTap: () =>
            showRuleBodyDialog(context, title, sourceKind, previewBodies),
        // §257: пресет без var `dns_enable` тумблера не имеет — вместо
        // серого свитча (читался бы как «выключено») нейтральная иконка.
        leading: onToggle == null
            ? Icon(Icons.dns_outlined, size: 22, color: cs.onSurfaceVariant)
            : Switch(value: enabled, onChanged: onToggle),
        title: Text(
          title.isNotEmpty ? title : '(unnamed rule)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled ? null : cs.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
          // §253: по 2 строки на правило — многоправильный пресет (AAAA-гейт
          // + маршрут у ru-direct) не прячет второе правило за ellipsis'ом.
          maxLines: previewBodies.length > 1 ? 2 * previewBodies.length : 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: DnsBadge(badgeText, badgeColor),
      ),
    );
  }
}

/// §257 — данные одной под-строки DNS-аспекта в [DnsRuleAspectsTile].
class DnsAspectRow {
  const DnsAspectRow({
    required this.body,
    required this.enabled,
    required this.onToggle,
    this.note,
  });

  /// Эмитимое DNS-rule тело аспекта — превью-подзаголовок + диалог по тапу.
  final Map<String, dynamic> body;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final String? note;
}

/// §257 — объединённый блок DNS-аспектов ОДНОГО пользовательского правила
/// (inline/srs) внутри [DnsMirrorGroupCard]. Правило может нести до двух
/// независимых DNS-аспектов — каждый со своим свитчем:
/// - «Server» — mirror на dedicated DNS-сервер (`RuleDns.enabled`, §117);
/// - «Force IPv4» — AAAA-глушилка (`RuleDns.forceIpv4`, §256).
/// Общий заголовок = имя правила (владелец: один блок, не две карточки).
class DnsRuleAspectsTile extends StatelessWidget {
  const DnsRuleAspectsTile({
    super.key,
    required this.title,
    this.serverRow,
    this.forceIpv4Row,
  });

  final String title;
  final DnsAspectRow? serverRow;
  final DnsAspectRow? forceIpv4Row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.isNotEmpty ? title : '(unnamed rule)',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                DnsBadge('rule', cs.secondary),
              ],
            ),
          ),
          if (serverRow != null) _aspectRow(context, 'Server', serverRow!),
          if (forceIpv4Row != null)
            _aspectRow(context, 'Force IPv4 (drop AAAA)', forceIpv4Row!),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _aspectRow(BuildContext context, String label, DnsAspectRow row) {
    final cs = Theme.of(context).colorScheme;
    final preview = formatRulePreview(row.body, kind: 'rule');
    final subtitle = (row.note != null && row.note!.isNotEmpty)
        ? '$preview · ${row.note}'
        : preview;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: () =>
          showRuleBodyDialog(context, '$title · $label', 'rule', row.body),
      leading: Switch(value: row.enabled, onChanged: row.onToggle),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          color: row.enabled ? null : cs.onSurfaceVariant,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 11,
          color: cs.onSurfaceVariant,
          fontFamily: 'monospace',
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
