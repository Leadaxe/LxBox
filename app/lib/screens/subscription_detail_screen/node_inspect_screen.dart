import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/node_spec.dart';
import '../../models/template_vars.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/tag_resolver.dart';
import '../../widgets/node_diagnostics_tab.dart';

/// §302 — экран разбора одной ноды подписки: две вкладки.
///
/// - **JSON** — что нода превратится в конфиге (`emit`), то есть результат
///   парсинга. Тот же вид, что «View JSON» в node_settings / папке §234.
/// - **Source** — исходный фрагмент подписки, из которого нода собралась.
///   Для JSON-тел переключатель Compact/Extended: compact — сам outbound-
///   объект, extended — весь элемент как пришёл от провайдера (с dns/
///   inbounds/routing соседями). Для URI-тел источник один — строка.
///
/// Источник берём из `NodeSpec.sourceCompact/sourceExtended`, а НЕ из
/// `rawUri`: у JSON-нод последний — синтетическая заглушка (`xray://<tag>`).
class NodeInspectScreen extends StatefulWidget {
  const NodeInspectScreen({
    super.key,
    required this.node,
    this.tagPrefix = '',
  });

  final NodeSpec node;

  /// §392 — префикс тегов контейнера: в БОЕВОМ конфиге узел живёт под
  /// display-тегом («<префикс> <тег>»), и диагностика при включённом VPN
  /// адресует его именно так. Пусто = узел без префикса.
  final String tagPrefix;

  @override
  State<NodeInspectScreen> createState() => _NodeInspectScreenState();
}

class _NodeInspectScreenState extends State<NodeInspectScreen> {
  /// Показывать расширенный вид источника (весь элемент), а не только
  /// сам outbound. Доступно лишь когда расширенный вид есть и отличается.
  bool _extended = false;

  NodeSpec get _node => widget.node;

  String get _json => const JsonEncoder.withIndent('  ')
      .convert(_node.emit(TemplateVars.empty).map);

  /// Исходный фрагмент. Fallback на rawUri — для нод, распарсенных до
  /// появления полей источника (регидрация старого кэша).
  String get _source {
    final compact = _node.sourceCompact ?? _node.rawUri;
    if (!_extended) return compact;
    return _node.sourceExtended ?? compact;
  }

  bool get _hasExtended => (_node.sourceExtended ?? '').isNotEmpty;

  /// §307 — правила поменяли тело узла: есть что показать во вкладке
  /// Replacements. Пусто → вкладки нет вовсе (у большинства нод правил не
  /// было, пустая вкладка была бы шумом).
  bool get _hasReplacements => _node.ruleTrail.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final title = _node.label.isNotEmpty ? _node.label : _node.tag;
    final hasReplacements = _hasReplacements;
    return DefaultTabController(
      length: hasReplacements ? 4 : 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title.isEmpty ? _node.server : title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: getLocalText.s("JSON")),
              Tab(text: getLocalText.s("Source")),
              if (hasReplacements)
                Tab(text: getLocalText.s("Replacements")),
              // §392 — узел здесь распарсен, поэтому доступны ОБЕ ветки:
              // probe при выключенном VPN и боевое ядро при включённом.
              Tab(text: getLocalText.s("Diagnostics")),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _monoBody(context, _json),
            _sourceTab(context),
            if (hasReplacements) _replacementsTab(context),
            NodeDiagnosticsTab(
              node: _node,
              liveTag: TagResolver.displayTag(widget.tagPrefix, _node.tag),
            ),
          ],
        ),
      ),
    );
  }

  /// §302/§307 — что именно поменяли import-rules: следы замен из `ruleTrail`
  /// («tls.utls.fingerprint: firefox → chrome»), по одной на строку. Вкладка
  /// JSON рядом показывает уже итоговый вид — здесь видно, чем он отличается
  /// от разобранного оригинала.
  Widget _replacementsTab(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.edit_note, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  getLocalText.s(
                      "Import rules changed this node. The JSON tab shows the result."),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _monoBody(context, _node.ruleTrail.join('\n'))),
      ],
    );
  }

  Widget _sourceTab(BuildContext context) {
    final text = _source;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Переключатель вида источника — только когда расширенный вид есть
        // и реально отличается от компактного (URI-строки его не имеют).
        if (_hasExtended)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(getLocalText.s("Compact")),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(getLocalText.s("Extended")),
                ),
              ],
              selected: {_extended},
              onSelectionChanged: (s) => setState(() => _extended = s.first),
            ),
          ),
        if (_hasExtended)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              _extended
                  ? getLocalText.s("The whole element as the provider sent it")
                  : getLocalText.s("Just the outbound this node was built from"),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        Expanded(child: _monoBody(context, text)),
      ],
    );
  }

  Widget _monoBody(BuildContext context, String text) {
    if (text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            getLocalText.s("Nothing to show"),
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: getLocalText.s("Copy"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(getLocalText.s("Copied"))),
              );
            },
          ),
        ),
      ],
    );
  }
}
