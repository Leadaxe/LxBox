// §393 D1 — СТРОКА источника-цепочки в общем списке источников.
//
// Цепочка — ТАКОЙ ЖЕ ИСТОЧНИК, как подписка, одиночный сервер и папка
// (директива оператора 24.08; так же у лаунчера — `source_tab`, один список).
// Поэтому она рисуется не отдельной секцией, а обычным рядом ТОГО ЖЕ вида:
// grab-strip слева, тумблер, заголовок, подзаголовок `tag · N hops`, справа —
// иконка типа (как `Icons.dns` у одиночного сервера и `Icons.folder_outlined`
// у папки). И перетаскивается наравне со всеми.
//
// Прежняя отдельная секция «Цепочки хопов» над подписками отвергнута: она
// говорила пользователю, что цепочка — что-то другое, чем остальные
// источники, и заодно делала её порядок отдельным от общего.
//
// Строение виджета повторяет [SubscriptionEntryTile] дословно (IntrinsicHeight
// → Row → grab-strip + Column(tile, Divider)): оба ряда живут в ОДНОМ
// `ReorderableListView`, и разойтись в высоте строки или в положении полосы
// захвата им нельзя — это была бы видимая «другая» строка.

import 'package:flutter/material.dart';

import '../../../models/source_chain.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/reorder_grab_strip.dart';

class ChainEntryTile extends StatelessWidget {
  const ChainEntryTile({
    super.key,
    required this.chain,
    required this.dragIndex,
    required this.onTap,
    required this.onToggle,
  });

  final SourceChain chain;

  /// Индекс в `ReorderableListView` для drag-старта (§098) — тот же счёт, что
  /// у подписок: список общий.
  final int dragIndex;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: Switch(
          value: chain.enabled,
          onChanged: (_) => onToggle(),
        ),
      ),
      title: Text(
        chain.tag,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: chain.enabled ? null : cs.onSurfaceVariant,
        ),
      ),
      // Тег + число позиций: тег — то, чем цепочка зовётся в конфиге и в
      // фильтрах Направлений, число хопов — единственное, что отличает
      // маршруты друг от друга с одного взгляда.
      subtitle: Text(
        '${chain.tag} · ${getLocalText.plural("%d hops", chain.hops.length)}',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
      trailing: Icon(Icons.route, size: 20, color: cs.onSurfaceVariant), // §393 — route: цепочка = маршрут (alt_route — развилка, смысл Направления)
      onTap: onTap,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: dragIndex),
          Expanded(
            child: Column(
              children: [
                tile,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
