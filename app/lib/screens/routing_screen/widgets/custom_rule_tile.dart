import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/outbound_picker.dart';
import '../../../widgets/reorder_grab_strip.dart';
import '../routing_screen_helpers.dart';

/// Один tile custom-rule на табе Rules (spec §030): drag-handle, switch,
/// имя, ☁-статус (опционально), outbound-picker и subtitle. Вся state-логика
/// (download/enable/reorder/edit/delete) живёт в экране и приходит сюда
/// колбэками — поведение идентично исходному `_buildCustomRuleTile`.
class CustomRuleTile extends StatelessWidget {
  const CustomRuleTile({
    super.key,
    required this.index,
    required this.rule,
    required this.displayName,
    required this.options,
    required this.subtitle,
    required this.pickerValue,
    required this.pickerDisabled,
    this.showOutbound = true,
    this.touchesDns = false,
    this.locked = false,
    this.sortable = true,
    this.canDelete = true,
    this.originLabel,
    this.dimmed = false,
    required this.statusButton,
    required this.onTap,
    required this.onLongPressStart,
    required this.onSwitchChanged,
    required this.onOutboundChanged,
  });

  final int index;
  final CustomRule rule;

  /// §279 (§3.5.1) — live display-имя (label пресета из локализованного
  /// шаблона + порядковый суффикс копии; для inline/srs — `rule.name`).
  /// Резолвится экраном (`ruleDisplayName`), тайл только рендерит.
  final String displayName;

  final List<RoutingOutboundOption> options;
  final String subtitle;
  final String pickerValue;
  final bool pickerDisabled;

  /// Рисовать ли outbound-picker. False для DNS-only пресетов (напр. FakeIP),
  /// которым нечего роутить — picker был бы мёртвым (см.
  /// [SelectableRule.hasOutboundAffordance]).
  final bool showOutbound;

  /// §231 — правило вносит изменения в DNS (DNS-сервер/правило). Рисует чип
  /// «DNS» рядом с именем: глядя на список, видно, что правило связано с DNS
  /// Settings. Пресет → `SelectableRule.touchesDns`; inline/srs →
  /// `dnsMirrorActive || forceIpv4Active` (§256 — Force IPv4 тоже DNS-аспект).
  final bool touchesDns;

  /// §264 — locked-пресет (traffic-processing): свич disabled, контекст-меню
  /// (delete) недоступно. Продуктовый инвариант — правило нельзя
  /// выключить/удалить.
  final bool locked;

  /// §370 — можно ли двигать правило drag'ом (`ui.isSortable`). Ортогонально
  /// [locked]: `locked` про «нельзя выключить/удалить», `sortable` про
  /// «нельзя двигать». У traffic-processing false оба, но флага два.
  final bool sortable;

  /// §435 — можно ли удалить строку long-press меню. False у правила узла:
  /// удаление и правка — только через узел (NODE_SECTIONS.md §7). Явный
  /// флаг, а не перегрузка [locked]: locked ещё и гасит свич, а тумблер
  /// узловой строки живой.
  final bool canDelete;

  /// §435 — пометка происхождения («from node <тег>») у правила узла;
  /// null — корневое правило, строки нет.
  final String? originLabel;

  /// §435 — приглушить строку: узел или его источник выключен, в конфиг
  /// правило не попадает. Тумблер остаётся живым — пользователь видит, куда
  /// правило встанет, когда узел включат (паритет с лаунчером).
  final bool dimmed;

  /// ☁-кнопка статуса (SRS либо preset) — null если правилу не нужен SRS.
  ///
  /// §366 — время последнего обновления в тайле намеренно НЕ показывается:
  /// список правил про маршрутизацию, а не про состояние кэша. Дата и кнопка
  /// обновления живут внутри правила, в редакторе.
  final Widget? statusButton;

  /// null — у строки нет редактора (tap ничего не делает).
  final VoidCallback? onTap;
  final ValueChanged<Offset> onLongPressStart;
  final ValueChanged<bool> onSwitchChanged;
  final ValueChanged<String> onOutboundChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = rule.enabled && !dimmed;
    final subtitleColor = active ? cs.primary : cs.onSurfaceVariant;

    final content = GestureDetector(
      onTap: onTap,
      // §264 — locked: контекст-меню (delete/reorder) недоступно.
      // §435 — узловая строка (canDelete: false) меню не имеет.
      onLongPressStart: locked || !canDelete
          ? null
          : (d) => onLongPressStart(d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Switch(
                  value: rule.enabled,
                  // §264 — locked-пресет нельзя выключить (disabled свич).
                  onChanged: locked ? null : onSwitchChanged,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: active ? null : cs.onSurfaceVariant,
                      )),
                ),
                ?statusButton,
                if (!showOutbound)
                  const SizedBox.shrink()
                else if (pickerDisabled)
                  Icon(Icons.warning_amber_outlined,
                      color: cs.error, size: 18)
                else
                  OutboundPicker(
                    value: pickerValue,
                    options: options
                        .map((o) =>
                            OutboundOption(value: o.tag, label: o.label))
                        .toList(),
                    onChanged: onOutboundChanged,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 64, right: 8, bottom: 4),
              child: Row(
                children: [
                  if (rule.kind == CustomRuleKind.preset) ...[
                    Icon(Icons.lock_outline,
                        size: 12, color: subtitleColor),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(subtitle,
                        style:
                            TextStyle(fontSize: 12, color: subtitleColor),
                        overflow: TextOverflow.ellipsis),
                  ),
                  // §247 — значок ✳: у правила resolve-опция (action сложнее
                  // простого outbound). Просто маркер, деталей в списке нет.
                  if (rule.resolveActive) ...[
                    const SizedBox(width: 6),
                    Text('✳',
                        style: TextStyle(
                            fontSize: 12,
                            color: active ? cs.primary : cs.onSurfaceVariant)),
                  ],
                  // §231 — чип «DNS» справа на нижней строке, под outbound-пикером.
                  if (touchesDns) ...[
                    const SizedBox(width: 6),
                    _dnsChip(cs, active),
                  ],
                ],
              ),
            ),
            // §435 — происхождение правила узла + подсказка, если узел
            // выключен. Отдельная строка под подзаголовком, не чип: тег
            // бывает длинным (префикс папки + имя).
            if (originLabel != null)
              Padding(
                padding: const EdgeInsets.only(left: 64, right: 8, bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right,
                        size: 12, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(originLabel!,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (dimmed) ...[
                      const SizedBox(width: 6),
                      Text(getLocalText.s("node is disabled"),
                          style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: cs.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // §370 — несортируемое правило не двигается: вместо grab-strip
          // пустой отступ (ширина = 18 + margin 6×2, выравнивание с tile).
          if (!sortable)
            const SizedBox(width: 30)
          else
            ReorderGrabStrip(index: index),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // §435 — приглушение целиком (свич, имя, подзаголовок);
                // Opacity не гасит hit-test, тумблер остаётся живым.
                dimmed ? Opacity(opacity: 0.55, child: content) : content,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// §231 — компактный бейдж «DNS»: правило трогает DNS-настройки. Приглушён,
  /// когда правило выключено.
  Widget _dnsChip(ColorScheme cs, bool enabled) {
    final c = enabled ? cs.primary : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 12, color: c),
          const SizedBox(width: 3),
          // l10n-exempt: acronym, same in all locales
          Text('DNS',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: c)),
        ],
      ),
    );
  }
}
