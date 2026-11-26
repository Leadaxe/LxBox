import 'package:flutter/material.dart';

import '../../../services/contract/rule_conditions.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/template_var_list.dart' show VarTextField;
import '../../../widgets/ui_helpers.dart';
import '../../../widgets/wifi_entry.dart';
import '../cond_labels.dart';
import '../cond_stack.dart';
import '../edit_controller.dart';
import '../normalizers.dart' as norm;
import '../validators.dart' as val;
import 'wifi_section.dart';

/// §757 волна 4 — тело правила: стопка условий через «и» и группы правил,
/// кнопка «+ Condition». Условия, их поля и порядок — из таблицы условий
/// ([CustomRuleEditController.table], условия формы LxBox); поля одного
/// условия — «любое из». Под-правила групп открываются отдельным экраном
/// ([SubRuleScreen]) — тот же редактор стопки, без предела глубины.
///
/// Правка идёт в модель формы ([CondStack]) через мутаторы контроллера; цель
/// и DNS-опции — только у корня (экран правила), здесь их нет.
class ConditionsSection extends StatelessWidget {
  const ConditionsSection({
    super.key,
    required this.stack,
    required this.assist,
  });

  final CondStack stack;
  final ConditionAssist assist;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final items = <Widget>[];
    void and() {
      if (items.isNotEmpty) items.add(const _AndLabel());
    }

    for (final f in stack.frames) {
      and();
      items.add(_CondFrameCard(
          key: ObjectKey(f), stack: stack, frame: f, assist: assist));
    }
    for (final g in stack.groups) {
      and();
      items.add(_GroupCard(
          key: ObjectKey(g), stack: stack, group: g, assist: assist));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              getLocalText.s("No conditions yet."),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ...items,
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: _AddConditionButton(stack: stack, controller: c),
        ),
      ],
    );
  }
}

/// §757 — действия полей, которым нужен BuildContext экрана: выбор
/// приложений, Wi-Fi текущей / сохранённой / вручную, подсказка разрешений.
class ConditionAssist {
  const ConditionAssist({
    required this.pickApps,
    required this.addCurrentWifi,
    required this.pickSavedWifi,
    required this.manualWifi,
    required this.onOpenWifiPermissions,
    this.wifiHint,
  });

  /// Выбор приложений: текущие пакеты → новый список (null — отмена).
  final Future<List<String>?> Function(List<String> selected) pickApps;
  final Future<List<WifiEntry>> Function() addCurrentWifi;
  final Future<List<WifiEntry>> Function() pickSavedWifi;
  final Future<List<WifiEntry>> Function() manualWifi;
  final VoidCallback onOpenWifiPermissions;
  final WifiHint? wifiHint;
}

class _AndLabel extends StatelessWidget {
  const _AndLabel();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Text(
          getLocalText.s("AND"),
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Рамка условия или группы — как рамка полей Name / Action: название в
/// разрыве рамки слева, за ним мельче связка (« · any of»), ✕ внутри рамки
/// справа на уровне первого поля.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.title,
    required this.onRemove,
    required this.children,
    this.caption,
  });

  final String title;
  final String? caption;
  final VoidCallback onRemove;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InputDecorator(
      isEmpty: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.fromLTRB(12, 14, 4, 10),
        label: Text.rich(
          TextSpan(
            text: title,
            children: [
              if (caption != null)
                TextSpan(
                  text: ' · ${caption!}',
                  style: t.textTheme.bodyMedium
                      ?.copyWith(color: t.colorScheme.outline),
                ),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
          IconButton(
            tooltip: getLocalText.s("Remove"),
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// ✕ рамки: непустую — после подтверждения, пустую — сразу.
Future<void> _confirmRemove(
  BuildContext context, {
  required bool filled,
  required String what,
  required VoidCallback remove,
}) async {
  if (!filled) {
    remove();
    return;
  }
  final ok = await showDeleteConfirmDialog(
    context,
    title: getLocalText.s("Remove %s?", what),
    message: getLocalText.s("What is filled in here will be lost."),
    confirmLabel: getLocalText.s("Remove"),
  );
  if (ok == true) remove();
}

class _CondFrameCard extends StatelessWidget {
  const _CondFrameCard({
    super.key,
    required this.stack,
    required this.frame,
    required this.assist,
  });

  final CondStack stack;
  final CondFrame frame;
  final ConditionAssist assist;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final cond = frame.cond;
    final cs = Theme.of(context).colorScheme;
    final title = condLabel(cond);
    final keys = cond.oneOf
        ? [
            cond.keys.firstWhere((k) => frame.raw.containsKey(k.key),
                orElse: () => cond.keys.first),
          ]
        : cond.keys;
    return _Frame(
      title: title,
      caption: !cond.oneOf && cond.keys.length > 1
          ? getLocalText.s("any of")
          : null,
      onRemove: () => _confirmRemove(
        context,
        filled: !condFrameEmpty(frame),
        what: title,
        remove: () => c.removeFrame(stack, frame),
      ),
      children: [
        // Ядро читает условие не на всех ОС (поле `platforms` таблицы).
        if (!cond.availableOn('android'))
          Text(getLocalText.s("Not available on this device"),
              style: TextStyle(fontSize: 11, color: cs.error)),
        if (cond.oneOf)
          DropdownButton<String>(
            value: keys.single.key,
            isDense: true,
            items: [
              for (final k in cond.keys)
                DropdownMenuItem(value: k.key, child: Text(condKeyLabel(k))),
            ],
            onChanged: (v) {
              if (v != null) c.setOneOfKey(frame, v);
            },
          ),
        for (final k in keys) _field(context, c, k, showLabel: !cond.oneOf),
        if (cond.id == CustomRuleEditController.kWifiConditionId)
          _wifiAssist(context, c),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    CustomRuleEditController c,
    RuleConditionKey k, {
    required bool showLabel,
  }) {
    final cs = Theme.of(context).colorScheme;
    final label = condKeyLabel(k);
    if (k.isBool) {
      return CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: frame.flag(k.key),
        onChanged: (v) => c.setFieldRaw(frame, k.key, v ?? false),
      );
    }
    if (condKeyIsChips(k)) {
      final selected = frame.chips(k.key);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel) _label(context, label),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final v in {...k.values, ...selected})
                FilterChip(
                  label: Text(v, style: const TextStyle(fontSize: 12)),
                  selected: selected.contains(v),
                  onSelected: (on) {
                    final next = [
                      for (final x in k.values)
                        if (x == v ? on : selected.contains(x)) x,
                      for (final x in selected)
                        if (!k.values.contains(x) && (x != v || on)) x,
                    ];
                    c.setFieldRaw(frame, k.key, next);
                  },
                ),
            ],
          ),
        ],
      );
    }
    final text = frame.text(k.key);
    final apps = frame.cond.id == CustomRuleEditController.kAppsConditionId &&
        k == frame.cond.keys.first;
    final inbound =
        frame.cond.id == CustomRuleEditController.kInboundConditionId;
    final choices = inbound ? c.inboundChoices : const <({String tag, String label})>[];
    String? error;
    if (norm.isRegexConditionKey(k.key)) {
      final bad = norm
          .normalizedRegexes(text)
          .where((r) => !val.isValidRegex(r))
          .firstOrNull;
      if (bad != null) error = getLocalText.s("Invalid regex: %s", bad);
    } else if (k.isRefs) {
      final bad = norm.splitLines(text).where((u) => !val.isValidUrl(u)).firstOrNull;
      if (bad != null) error = getLocalText.s("Not a URL: %s", bad);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel) _label(context, label),
          VarTextField(
            key: ValueKey('${k.key}#field'),
            label: '',
            value: text,
            maxLines: 8,
            hintText: k.isRefs
                // l10n-exempt: example URL, locale-independent
                ? 'https://example.com/rules.srs'
                : (k.placeholder.isEmpty ? null : k.placeholder),
            errorText: error,
            listMode: k.open || inbound,
            suggestions: k.open
                ? k.values
                : [for (final ch in choices) ch.tag],
            suggestionLabels: k.open
                ? const []
                : [for (final ch in choices) '${ch.tag} · ${ch.label}'],
            onChanged: (v) => c.setFieldRaw(frame, k.key, v),
          ),
          if (apps)
            TextButton.icon(
              icon: const Icon(Icons.apps, size: 16),
              label: Text(getLocalText.s("Choose apps"),
                  style: const TextStyle(fontSize: 12)),
              onPressed: () async {
                final picked = await assist.pickApps(norm.splitLines(text));
                if (picked == null) return;
                c.setFieldRaw(frame, k.key, picked.join('\n'));
              },
            ),
          if (k.isRefs)
            Text(
              getLocalText.s(
                  "A rule set may hold its own ports and processes. To combine it with other conditions by OR, use a rule group."),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  /// Wi-Fi: текущая сеть, сохранённые, вручную — строки SSID / BSSID
  /// дописываются в поля условия; подсказка, почему SSID не читается.
  Widget _wifiAssist(BuildContext context, CustomRuleEditController c) {
    final keys = frame.cond.keys;
    Future<void> add(Future<List<WifiEntry>> Function() source) async {
      final entries = await source();
      if (entries.isEmpty || keys.isEmpty) return;
      void append(RuleConditionKey k, Iterable<String> values) {
        final lines = norm.splitLines(frame.text(k.key));
        var changed = false;
        for (final v in values) {
          if (v.isEmpty || lines.contains(v)) continue;
          lines.add(v);
          changed = true;
        }
        if (changed) c.setFieldRaw(frame, k.key, lines.join('\n'));
      }

      // Первое поле условия — имена сетей, второе — точки доступа.
      append(keys.first, entries.map((e) => e.ssid));
      if (keys.length > 1) append(keys[1], entries.map((e) => e.bssid));
    }

    Widget button(IconData icon, String label, VoidCallback onPressed) =>
        OutlinedButton.icon(
          icon: Icon(icon, size: 16),
          label: Text(label),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(fontSize: 12),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              button(Icons.my_location, getLocalText.s("Add current"),
                  () => add(assist.addCurrentWifi)),
              button(Icons.history, getLocalText.s("Pick saved"),
                  () => add(assist.pickSavedWifi)),
              button(Icons.edit, getLocalText.s("Manual"),
                  () => add(assist.manualWifi)),
            ],
          ),
          if (assist.wifiHint != null)
            WifiHintLine(
                hint: assist.wifiHint!, onTap: assist.onOpenWifiPermissions),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    super.key,
    required this.stack,
    required this.group,
    required this.assist,
  });

  final CondStack stack;
  final CondGroup group;
  final ConditionAssist assist;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final title = getLocalText.s("Rule group");
    return _Frame(
      title: title,
      caption:
          group.any ? getLocalText.s("any of") : getLocalText.s("all of"),
      onRemove: () => _confirmRemove(
        context,
        filled: group.toNode() != null,
        what: title,
        remove: () => c.removeGroup(stack, group),
      ),
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceChip(
              label: Text(getLocalText.s("all of")),
              selected: !group.any,
              onSelected: (_) => c.setGroupAny(group, false),
            ),
            ChoiceChip(
              label: Text(getLocalText.s("any of")),
              selected: group.any,
              onSelected: (_) => c.setGroupAny(group, true),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text(getLocalText.s("Not")),
              selected: group.not,
              onSelected: (v) => c.setGroupNot(group, v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < group.rules.length; i++) ...[
          if (i > 0)
            Center(
              child: Text(
                group.any ? getLocalText.s("OR") : getLocalText.s("AND"),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          _subRuleTile(context, c, i),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(getLocalText.s("Rule")),
            onPressed: () {
              final r = c.addSubRule(group);
              _openSubRule(context, c, r, group.rules.length);
            },
          ),
        ),
      ],
    );
  }

  Widget _subRuleTile(
      BuildContext context, CustomRuleEditController c, int i) {
    final r = group.rules[i];
    final title = getLocalText.s("Rule %d", i + 1);
    final summary = stackSummary(r);
    return ListTile(
      key: ObjectKey(r),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(summary.isEmpty ? getLocalText.s("Empty") : summary,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _openSubRule(context, c, r, i + 1),
      trailing: IconButton(
        tooltip: getLocalText.s("Remove"),
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => _confirmRemove(
          context,
          filled: r.toNode() != null,
          what: title,
          remove: () => c.removeSubRule(group, r),
        ),
      ),
    );
  }

  void _openSubRule(BuildContext context, CustomRuleEditController c,
      CondStack r, int number) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubRuleScreen(
        controller: c,
        stack: r,
        title: getLocalText.s("Rule %d", number),
        assist: assist,
      ),
    ));
  }
}

/// §757 — сводка под-правила: подписи его условий и групп.
String stackSummary(CondStack s) => [
      for (final f in s.frames)
        if (!condFrameEmpty(f)) condLabel(f.cond),
      for (final g in s.groups)
        if (g.toNode() != null) getLocalText.s("Rule group"),
    ].join(' · ');

class _AddConditionButton extends StatelessWidget {
  const _AddConditionButton({required this.stack, required this.controller});

  final CondStack stack;
  final CustomRuleEditController controller;

  static const _group = '\u0000group';

  @override
  Widget build(BuildContext context) {
    final conds = controller.conditionsToAdd(stack);
    return PopupMenuButton<String>(
      tooltip: getLocalText.s("Add condition"),
      onSelected: (id) {
        if (id == _group) {
          controller.addGroup(stack);
          return;
        }
        final cond = controller.table.condition(id);
        if (cond != null) controller.addCondition(stack, cond);
      },
      itemBuilder: (_) => [
        for (final cond in conds)
          PopupMenuItem(value: cond.id, child: Text(condLabel(cond))),
        if (conds.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem(
            value: _group, child: Text(getLocalText.s("Rule group"))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add,
                size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 4),
            Text(getLocalText.s("Condition"),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// §757 — экран под-правила группы: та же стопка условий (рекурсивно, без
/// предела глубины). Цели и DNS-опций нет — они только у корня. Правка идёт
/// в модель формы сразу; «назад» возвращает к группе.
class SubRuleScreen extends StatelessWidget {
  const SubRuleScreen({
    super.key,
    required this.controller,
    required this.stack,
    required this.title,
    required this.assist,
  });

  final CustomRuleEditController controller;
  final CondStack stack;
  final String title;
  final ConditionAssist assist;

  @override
  Widget build(BuildContext context) {
    return CustomRuleEditScope(
      notifier: controller,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
          children: [
            ConditionsSection(stack: stack, assist: assist),
          ],
        ),
      ),
    );
  }
}
