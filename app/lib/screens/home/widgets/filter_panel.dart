import 'package:flutter/material.dart';

import '../filter_widgets.dart';
import '../node_filter_view_model.dart';
import '../node_list_presenter.dart';

/// §048 / §095 — Filter panel (expanded), tabbed.
///
/// Layout (Filter mode — стат-полоса и Nodes-хедер скрыты родителем):
/// - **строка поиска** (regex) всегда сверху + ✕ закрытия (→ [togglePanel]);
/// - **сводка активных фильтров** чипами (`InputChip`: tap → нужный таб,
///   ✕ → снять фильтр);
/// - **табы** Regex / Protocol / Subscribes / Settings — с точкой на табе,
///   где есть активный фильтр;
/// - контент активного таба (авто-высота — рендерим только его, не TabBarView).
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
    if (f.regexActive) {
      chips.add(InputChip(
        label: Text('/${_truncate(f.regexController.text)}/'),
        onPressed: () => _tab.animateTo(0),
        onDeleted: f.clearRegex,
      ));
    }
    for (final proto in f.enabledProtocols) {
      chips.add(InputChip(
        label: Text(protoLabel(proto)),
        onPressed: () => _tab.animateTo(1),
        onDeleted: () => f.toggleProtocol(proto),
      ));
    }
    for (final id in f.enabledSubscriptions) {
      chips.add(InputChip(
        label: Text(_truncate(_subName(id))),
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
    // §095 — visibility-тоглы как чипы (tap → Settings, ✕ → вернуть показ).
    if (f.detourHidden) {
      chips.add(InputChip(
        tooltip: 'Detour servers hidden',
        label: _gearOffIcon(),
        onPressed: () => _tab.animateTo(3),
        onDeleted: () => f.setShowDetour(true),
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

  /// Перечёркнутая шестерёнка = «detour скрыт» (⚙ = detour-маркер приложения).
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
              enabled: f.regexEnabled,
              onEnabledChanged: f.setRegexEnabled,
              invert: f.regexInvert,
              onInvertChanged: f.setRegexInvert,
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
              );
      case 2: // Subscribes
        return widget.subOptions.isEmpty
            ? _hint('Нет подписок')
            : MultiSelectChipsRow(
                options: widget.subOptions,
                enabled: f.enabledSubscriptions,
                onToggle: f.toggleSubscription,
              );
      default: // Settings — ping + visibility toggles
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
            FilterCheckboxRow(
              label: 'Show detour servers',
              value: f.showDetour,
              onChanged: f.setShowDetour,
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
