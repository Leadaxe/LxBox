import 'package:flutter/material.dart';

import '../filter_widgets.dart';
import '../node_filter_view_model.dart';
import '../node_list_presenter.dart';

/// §048 / §095 / §096 — Filter panel (expanded), tabbed.
///
/// Layout (Filter mode — стат-полоса и Nodes-хедер скрыты родителем):
/// - **табы** Regex / Protocol / Subscribes / Settings сверху + ✕ закрытия
///   (→ [togglePanel]) — с точкой на табе, где есть активный фильтр;
/// - **сводка активных фильтров** чипами (`InputChip`: tap → нужный таб,
///   ✕ → снять фильтр; «!» в лейбле = инверсия, §096);
/// - контент активного таба (авто-высота — рендерим только его, не TabBarView):
///   у regex/protocol/subscriptions ведущий `!`-negate ([NegateToggle]),
///   detour — tri-state на Settings.
class FilterPanel extends StatefulWidget {
  const FilterPanel({
    super.key,
    required this.filter,
    required this.emojis,
    required this.availableProtocols,
    required this.subOptions,
  });

  final NodeFilterViewModel filter;
  final List<String> emojis;
  final List<String> availableProtocols;
  final List<(String, String)> subOptions;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel>
    with SingleTickerProviderStateMixin {
  // Regex=0 · Protocol=1 · Subscribes=2 · Settings=3.
  late final TabController _tab = TabController(length: 4, vsync: this);

  NodeFilterViewModel get f => widget.filter;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _subName(String id) {
    for (final (sid, name) in widget.subOptions) {
      if (sid == id) return name;
    }
    return id;
  }

  /// Макс. ширина чипа: обрезаем лейбл до 15 символов + «…» (имена подписок
  /// бывают длинные).
  static String _truncate(String s, [int max = 15]) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  /// Сводка активных фильтров: tap по чипу → его таб, ✕ → снять.
  List<Widget> _summaryChips() {
    final chips = <Widget>[];
    // §096 — префикс инверсии в лейбле чипа («!VLESS», «!/pat/»).
    String neg(bool invert) => invert ? '!' : '';
    if (f.regexActive) {
      chips.add(InputChip(
        label: Text(
            '${neg(f.regexInvert)}/${_truncate(f.regexController.text)}/'),
        onPressed: () => _tab.animateTo(0),
        onDeleted: f.clearRegex,
      ));
    }
    for (final proto in f.enabledProtocols) {
      chips.add(InputChip(
        label: Text('${neg(f.protocolsInvert)}${protoLabel(proto)}'),
        onPressed: () => _tab.animateTo(1),
        onDeleted: () => f.toggleProtocol(proto),
      ));
    }
    for (final id in f.enabledSubscriptions) {
      chips.add(InputChip(
        label: Text('${neg(f.subscriptionsInvert)}${_truncate(_subName(id))}'),
        onPressed: () => _tab.animateTo(2),
        onDeleted: () => f.toggleSubscription(id),
      ));
    }
    final ms = f.activeMaxPingMs;
    if (ms != null) {
      chips.add(InputChip(
        label: Text('≤${ms}ms'),
        onPressed: () => _tab.animateTo(3),
        onDeleted: f.clearPing,
      ));
    }
    // §096 — чип когда detour-фильтр включён (дефолт «показать всё» чипа не
    // даёт): ⊘ = скрыт detour, ⚙ = только detour. tap → Settings, ✕ → выкл
    // фильтр (вернуть «показать всё»).
    if (f.detourActive) {
      chips.add(InputChip(
        tooltip: f.detourHide ? 'Detour скрыт' : 'Только detour',
        label: f.detourHide
            ? _gearOffIcon()
            : const Icon(Icons.settings, size: 18),
        onPressed: () => _tab.animateTo(3),
        onDeleted: () => f.setDetourEnabled(false),
      ));
    }
    if (f.nonMatchingHidden) {
      chips.add(InputChip(
        tooltip: 'Non-matching hidden',
        label: const Icon(Icons.visibility_off, size: 18),
        onPressed: () => _tab.animateTo(3),
        onDeleted: () => f.setShowNonMatching(true),
      ));
    }
    return chips;
  }

  /// Перечёркнутая шестерёнка = «detour скрыт» (⚙ без перечёркивания = только
  /// detour). Используется в чипе-сводке detour-фильтра.
  Widget _gearOffIcon() {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.settings, size: 17, color: c),
          Transform.rotate(
            angle: -0.785, // -45°
            child: Container(width: 22, height: 2, color: c),
          ),
        ],
      ),
    );
  }

  Widget _dotTab(String label, bool active) {
    return Tab(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (active) ...[
            const SizedBox(width: 5),
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Colors.amber,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );

  Widget _tabContent(int index) {
    switch (index) {
      case 0: // Regex → поле regex (ТОЛЬКО тут) + эмодзи-чипы под ним
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RegexFilterField(
              controller: f.regexController,
              onChanged: f.onRegexChanged,
              valid: f.regexValid,
              invert: f.regexInvert,
              onInvertToggle: f.toggleRegexInvert,
              onClear: f.clearRegex,
            ),
            if (widget.emojis.isNotEmpty) ...[
              const SizedBox(height: 8),
              EmojiChipsRow(
                emojis: widget.emojis,
                onTap: f.onEmojiChipTap,
                selected: f.selectedEmojis,
              ),
            ],
          ],
        );
      case 1: // Protocol
        return widget.availableProtocols.isEmpty
            ? _hint('Нет протоколов')
            : MultiSelectChipsRow(
                options: [
                  for (final p in widget.availableProtocols) (p, protoLabel(p)),
                ],
                enabled: f.enabledProtocols,
                onToggle: f.toggleProtocol,
                invert: f.protocolsInvert,
                onInvertToggle: f.toggleProtocolsInvert,
              );
      case 2: // Subscribes
        return widget.subOptions.isEmpty
            ? _hint('Нет подписок')
            : MultiSelectChipsRow(
                options: widget.subOptions,
                enabled: f.enabledSubscriptions,
                onToggle: f.toggleSubscription,
                invert: f.subscriptionsInvert,
                onInvertToggle: f.toggleSubscriptionsInvert,
              );
      default: // Settings — ping + detour tri-state + non-matching
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PingFilterField(
              controller: f.pingController,
              onChanged: f.onPingChanged,
              enabled: f.pingEnabled,
              onEnabledChanged: f.setPingEnabled,
              onClear: f.clearPing,
            ),
            // §096 — detour: чекбокс-enable + [!] (hide↔only). Чекбокс ВЫКЛ
            // (старт) = показать всё (фильтр off, [!] серый/неактивен); ВКЛ →
            // [!] ON = скрыть detour, OFF = только detour. Лейбл = итог-режим.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: f.detourEnabled,
                      onChanged: (v) => f.setDetourEnabled(v ?? false),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 2),
                  NegateToggle(
                    // §096 — [!] независим от чекбокса: отражает _detourHide
                    // (красный = hide, дефолт ON) и всегда переключаем, даже
                    // при выкл-фильтре (две ортогональные оси, как в спеке).
                    active: f.detourHide,
                    onToggle: f.toggleDetourHide,
                    tooltip: 'Скрыть detour (вкл) / только detour (выкл)',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      !f.detourEnabled
                          ? 'Show all servers'
                          : (f.detourHide
                              ? 'Hide detour servers'
                              : 'Show only detour servers'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            FilterCheckboxRow(
              label: 'Show non-matching (dimmed)',
              value: f.showNonMatching,
              onChanged: f.setShowNonMatching,
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = _summaryChips();
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(128))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // §095 — табы СВЕРХУ + ✕ закрытия справа.
          Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tab,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: [
                    _dotTab('Regex', f.regexActive),
                    _dotTab('Protocol', f.protocolActive),
                    _dotTab('Subscribes', f.subscriptionActive),
                    _dotTab('Settings', f.settingsActive),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close filters',
                visualDensity: VisualDensity.compact,
                onPressed: f.togglePanel,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          // Сводка активных фильтров (tap=таб, ✕=снять) — горизонтальный скролл.
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < summary.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    summary[i],
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
          // Рендерим только активный таб → авто-высота (не TabBarView).
          AnimatedBuilder(
            animation: _tab,
            builder: (_, _) => _tabContent(_tab.index),
          ),
        ],
      ),
    );
  }
}
