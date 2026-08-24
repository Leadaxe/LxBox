import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/node_spec.dart';
import '../services/diagnostics/diagnostic_check.dart';
import '../services/diagnostics/node_diagnostics_runner.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';

/// §392 — вкладка Diagnostics: выпадающий список предопределённых чекеров,
/// кнопка запуска и СЫРОЙ ответ в поле ниже.
///
/// Общий виджет на все три экрана деталей узла (у каждого свои вкладки, но
/// диагностика одна и та же): разбор ноды подписки, настройки узла и просмотр
/// outbound'а собранного конфига.
///
/// Тело ответа не интерпретируется вовсе — пользователь читает то, что прислал
/// сервис. Формат чужого сервиса меняется — вкладка продолжает работать.
///
/// [node] — распарсенный узел; `null` для экранов, которые знают только тег в
/// собранном конфиге. Без него probe-ветка (диагностика при ВЫКЛЮЧЕННОМ VPN)
/// невозможна: временный конфиг не из чего собрать — тогда работает только
/// боевая ветка, а при выключенном туннеле показывается пояснение.
///
/// [liveTag] — тег узла в БОЕВОМ конфиге (с префиксом списка). По нему ядро
/// адресует узел, не переключая активный selector.
class NodeDiagnosticsTab extends StatefulWidget {
  const NodeDiagnosticsTab({
    super.key,
    required this.liveTag,
    this.node,
    this.header,
  });

  final NodeSpec? node;
  final String liveTag;

  /// §394 — блок, специфичный для ЭТОГО вида узла, над общей секцией «Check».
  /// Сейчас единственный такой блок — послойная проба цепочки (её показывает
  /// только экран просмотра outbound'а типа `chain`). Слот, а не ветка внутри
  /// вкладки: вкладка общая для трёх экранов, и знание о цепочках здесь
  /// пришлось бы сопровождать всем трём.
  final Widget? header;

  @override
  State<NodeDiagnosticsTab> createState() => _NodeDiagnosticsTabState();
}

class _NodeDiagnosticsTabState extends State<NodeDiagnosticsTab> {
  DiagnosticCheck _check = kDiagnosticChecks.first;
  NodeDiagnosticsRunner? _runner;
  bool _running = false;
  DiagnosticOutcome? _outcome;

  /// Причина, по которой прогон не состоялся (узел-группа, ядро без метода,
  /// не поднялась probe-сессия). Отличается от состоявшегося обмена с плохим
  /// статусом — тот лежит в [_outcome] и ошибкой не считается.
  String _error = '';

  @override
  void dispose() {
    // §286 — уход с экрана во время прогона: результат уже не нужен, а
    // probe-сессия не должна пережить экран.
    _runner?.cancel();
    super.dispose();
  }

  /// Прогон выбранного чекера через ЭТОТ узел.
  ///
  /// Реальный трафик через узел (и пробуждение спящего WG), поэтому зовётся
  /// только отсюда — из обработчика кнопки. Фоновых прогонов нет по
  /// требованию ядра (kernel SPEC 058 §5).
  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = '';
      _outcome = null;
    });
    final runner = NodeDiagnosticsRunner();
    _runner = runner;
    try {
      final outcome = await runner.run(
        widget.node,
        url: _check.url,
        liveTag: widget.liveTag,
      );
      if (!mounted) return;
      setState(() => _outcome = outcome);
    } on DiagnosticUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.reason) {
            'group' => getLocalText.s(
                "This is an auto-select node — it has no connection of its own. Open a member to diagnose it."),
            'no_node' => getLocalText.s(
                "Start the VPN to check this node from here, or open it from its subscription to check it with the VPN off."),
            _ => e.reason,
          });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = formatUserError(e).render());
    } finally {
      if (mounted) setState(() => _running = false);
      _runner = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = _outcome;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        if (widget.header != null) ...[
          widget.header!,
          const SizedBox(height: 24),
        ],
        _sectionHeader(getLocalText.s("Check"),
            getLocalText.s("Request is sent through this node"), theme),
        DropdownButtonFormField<String>(
          initialValue: _check.id,
          isExpanded: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            labelText: getLocalText.s("Endpoint"),
            prefixIcon: const Icon(Icons.travel_explore, size: 18),
          ),
          items: [
            for (final c in kDiagnosticChecks)
              DropdownMenuItem(
                value: c.id,
                child: Text(getLocalText.s(c.title),
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _running
              ? null
              : (id) {
                  final picked = kDiagnosticChecks.firstWhere(
                      (c) => c.id == id,
                      orElse: () => kDiagnosticChecks.first);
                  // Прошлый ответ относится к прошлому адресу — снимаем,
                  // чтобы он не читался как результат нового чекера.
                  setState(() {
                    _check = picked;
                    _outcome = null;
                    _error = '';
                  });
                },
        ),
        // Адрес виден ДО запуска: юзер знает, какому стороннему сервису
        // достанется exit-IP узла.
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: SelectableText(
            _check.url,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: _running ? null : () => unawaited(_run()),
          icon: _running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow),
          label: Text(
              _running ? getLocalText.s("Running…") : getLocalText.s("Run")),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        if (outcome != null) ...[
          const SizedBox(height: 16),
          _sectionHeader(
              getLocalText.s("Response"),
              // Через что реально шёл запрос: две ветки отвечают на РАЗНОЕ —
              // «узел сам по себе» vs «узел в живом ядре».
              outcome.source == DiagnosticSource.live
                  ? getLocalText.s(
                      "Through this node in the running core — not through your current route")
                  : getLocalText
                      .s("Through this node in a temporary core session"),
              theme),
          if (!outcome.ok)
            Text(
              outcome.result.error,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    // Не-2xx — результат, а не сбой: показываем статус ровно
                    // так же, как 200 (kernel SPEC 058 §2.1).
                    // l10n-exempt: HTTP-код + число мс, слов нет
                    '${outcome.result.status} · ${outcome.result.elapsedMs}ms',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: outcome.result.status >= 200 &&
                              outcome.result.status < 300
                          ? theme.colorScheme.primary
                          : theme.colorScheme.tertiary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: getLocalText.s("Copy"),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: outcome.result.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(getLocalText.s("Copied"))));
                  },
                ),
              ],
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                outcome.result.content.isEmpty
                    ? getLocalText.s("(empty response)")
                    : outcome.result.content,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
            if (outcome.result.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  getLocalText.s("Response was longer and got cut off."),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (outcome.result.remoteAddr.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  // Адрес ИЗНУТРИ туннеля (куда отрезолвилась цель), а не
                  // exit-IP узла — тот несёт само тело ответа.
                  getLocalText.s("Connected to %s from inside the tunnel",
                      outcome.result.remoteAddr),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _sectionHeader(String title, String description, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
