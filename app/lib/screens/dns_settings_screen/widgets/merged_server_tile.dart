import 'package:flutter/material.dart';

import '../../../vpn/cc_channel.dart';
import '../resolved_server.dart';
import 'dns_badge.dart';
import '../../../services/l10n/locale_controller.dart';

/// §044: единый builder через typed `ResolvedServer`. Никаких Map['_kind'] —
/// classification через typed accessors на ResolvedServer.
///
/// §117 задача 4 (locked decision №8): тайл ужат до switch (enabled) +
/// title/subtitle + badge; **тап → полноэкранный редактор**
/// (`openDnsServerEditor`). Инлайн-тюнер и иконки edit/reset/delete
/// переехали в редактор (Params/JSON + AppBar-actions).
///
/// §117 lifecycle (locked №7): `locked` (сервер реферится активным пресетом
/// ИЛИ routing-правилом с DNS-опцией) — enabled-switch заблокирован и
/// показывается включённым (build force-include), в subtitle
/// «used by <пресет/правило>» с замком.
class MergedServerTile extends StatelessWidget {
  const MergedServerTile({
    super.key,
    required this.entry,
    required this.onToggleEnabled,
    required this.onTap,
    this.liveGroup,
  });

  final ResolvedServer entry;
  final void Function(String tag, bool value) onToggleEnabled;

  /// Тап по тайлу — открыть редактор сервера.
  final void Function(String tag) onTap;

  /// §312 — live-состояние DNS-группы от ядра (SPEC 035); null = туннель
  /// down / ядро без метода / сервер не группа. Рисуется доп. строкой.
  final CcDnsGroup? liveGroup;

  @override
  Widget build(BuildContext context) {
    final type = entry.body['type']?.toString() ?? '';
    final addr = entry.body['server']?.toString() ?? '';
    final theme = Theme.of(context);
    final locked = entry.locked;

    // Короткие labels (§044).
    final (String badgeText, Color badgeColor) = switch (entry.kind) {
      ServerKind.template => (
        getLocalText.s("Template"),
        theme.colorScheme.tertiary,
      ),
      ServerKind.preset => (
        getLocalText.s("Preset"),
        theme.colorScheme.primary,
      ),
      ServerKind.inline =>
        entry.isOverridden
            ? (
                getLocalText.s("Overridden"),
                theme.colorScheme.error.withValues(alpha: 0.9),
              )
            : (getLocalText.s("User"), theme.colorScheme.secondary),
    };

    // §312 — у группы вместо адреса: режим + число членов.
    final groupInfo = type == 'group'
        ? ' · ${(entry.body['mode'] as String?) ?? 'stable'}'
              ' · ${(entry.body['servers'] as List?)?.length ?? 0}'
        : '';
    final subtitleLine =
        '${entry.tag} · $type$groupInfo${addr.isNotEmpty ? ' · $addr' : ''}'
        '${entry.presetLabel != null && entry.presetLabel!.isNotEmpty ? ' · ${entry.presetLabel}' : ''}';

    return Card(
      child: ListTile(
        onTap: () => onTap(entry.tag),
        leading: SizedBox(
          width: 40,
          child: Switch(
            // §117: locked-сервер build force-include'ит — показываем ON.
            value: entry.enabled || locked,
            onChanged: locked ? null : (v) => onToggleEnabled(entry.tag, v),
          ),
        ),
        title: Text(
          entry.description.isNotEmpty ? entry.description : entry.tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: entry.enabled || locked
                ? null
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleLine,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (locked)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 12,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    getLocalText.s("used by %s", entry.lockedByLabel),
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            // §312 — live-состояние группы (pull на открытии экрана).
            if (liveGroup != null) _LiveGroupLine(liveGroup!),
          ],
        ),
        trailing: DnsBadge(badgeText, badgeColor),
      ),
    );
  }
}

/// §312 — компактная live-строка состояния DNS-группы (SPEC 035): текущая
/// цель + по каждому члену чистота/ошибки/RTT. Wrap — членов может быть
/// много; данные — снапшот на открытии экрана (решение №2, без таймера).
class _LiveGroupLine extends StatelessWidget {
  const _LiveGroupLine(this.g);
  final CcDnsGroup g;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (g.current.isNotEmpty)
            Text(
              // l10n-exempt: compact live-status arrow
              '→ ${g.current}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          for (final m in g.members)
            Text(
              _memberLabel(m),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: m.clean ? cs.onSurfaceVariant : cs.error,
              ),
            ),
        ],
      ),
    );
  }

  /// `google ✓ 12ms ●` / `quad9 ✗2 (34s)`. Wire-теги и цифры — не переводим.
  String _memberLabel(CcDnsGroupMember m) {
    final b = StringBuffer(m.tag);
    if (m.clean) {
      b.write(' ✓'); // ✓
      if (m.lastRttMs > 0) b.write(' ${m.lastRttMs}ms');
      if (g.mode == 'fastest' && m.liveWins > 0) b.write(' w${m.liveWins}');
    } else {
      b.write(' ✗${m.liveErrors}'); // ✗N
      if (m.lastErrorAgeMs >= 0) {
        b.write(' (${(m.lastErrorAgeMs / 1000).round()}s)');
      }
    }
    if (m.current) b.write(' ●'); // ●
    return b.toString();
  }
}
