// §393 C7 — секция цепочек хопов на экране источников.
//
// Цепочка — ТРЕТИЙ ТИП ИСТОЧНИКА рядом с подпиской и сервером (§393 L5): она
// описывает МАРШРУТ, а не выбор между маршрутами, поэтому живёт здесь, а не
// среди Направлений.
//
// Отдельной секцией, а не строкой общего списка: цепочки лежат в настройках
// (`chains[]`), а не в `SubscriptionController.entries`, и их порядок
// НОРМАТИВЕН сам по себе — цепочка вправе сослаться только на объявленную
// ВЫШЕ. Смешав их с подписками в один reorderable-список, мы дали бы
// перетаскиванием подписки менять смысл ссылок между цепочками.
//
// Пока цепочек нет, секции нет вовсе: пустой заголовок над пустотой на экране,
// где у большинства пользователей цепочек не будет никогда, — только шум.
// Точка входа живёт в overflow-меню экрана («Add hop chain»).

import 'package:flutter/material.dart';

import '../../../models/source_chain.dart';
import '../../../services/l10n/locale_controller.dart';

class ChainsSection extends StatelessWidget {
  const ChainsSection({
    super.key,
    required this.chains,
    required this.onTap,
    required this.onToggle,
  });

  final List<SourceChain> chains;
  final void Function(SourceChain chain) onTap;
  final void Function(SourceChain chain) onToggle;

  @override
  Widget build(BuildContext context) {
    if (chains.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(getLocalText.s("Hop chains"),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
        ),
        for (final c in chains)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: SizedBox(
              width: 40,
              child: Switch(
                value: c.enabled,
                onChanged: (_) => onToggle(c),
              ),
            ),
            title: Text(
              c.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.enabled ? null : cs.onSurfaceVariant,
              ),
            ),
            // Тег + число позиций: тег — то, чем цепочка зовётся в конфиге и
            // в фильтрах Направлений, число хопов — единственное, что
            // отличает маршруты друг от друга с одного взгляда.
            subtitle: Text(
              '${c.tag} · ${getLocalText.plural("%d hops", c.hops.length)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            trailing: Icon(Icons.alt_route,
                size: 20, color: cs.onSurfaceVariant),
            onTap: () => onTap(c),
          ),
        Divider(height: 1, color: cs.outlineVariant),
      ],
    );
  }
}
