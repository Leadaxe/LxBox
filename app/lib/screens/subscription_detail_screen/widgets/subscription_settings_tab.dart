import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/channel.dart';
import '../../../models/server_list.dart';
import '../../../services/subscription/input_helpers.dart';
import '../../../widgets/detour_target_picker.dart' show detourChannelDisplay;
import '../detour_mode.dart';
import '../subscription_detail_format.dart';

/// Settings tab: tag-prefix field, detour-mode radio group (+ sub-options) and
/// the subscription-info block. Extracted verbatim from `_buildSettingsTab` /
/// `_buildSubscriptionInfo`. All mutation/persist/dialog logic stays in the
/// screen and is wired in via the callbacks below.
class SubscriptionSettingsTab extends StatelessWidget {
  const SubscriptionSettingsTab({
    super.key,
    required this.entry,
    this.folderMode = false,
    this.channels = const [],
    this.detourPathHopsOf,
    required this.hasDetour,
    required this.detourMode,
    required this.onTagPrefixChanged,
    required this.onSetDetourMode,
    required this.onRegisterDetourServersChanged,
    required this.onRegisterDetourInAutoChanged,
    required this.onShowOverrideDetourPicker,
    required this.onReplaceDetourChainChanged,
    required this.onCopyUrl,
    required this.onShowIntervalPicker,
    required this.onRefreshNow,
    required this.onEditSource,
  });

  final SubscriptionEntry entry;

  /// §239 — true для папки (§234): адаптированные detour-тексты («servers'
  /// own detours» вместо «subscription detour servers»).
  final bool folderMode;

  /// §248 — каналы для подписи «⚙ <label>» канальной override-цели
  /// (экран грузит SettingsStorage.getChannels и передаёт сюда).
  final List<Channel> channels;

  /// §252 — разворот цели в цепочку хопов «как пакет пойдёт» (detourPathHops
  /// с controller'ом экрана). null → показываем один хоп (как раньше).
  final List<String> Function(String stored)? detourPathHopsOf;
  final bool hasDetour;
  final DetourMode detourMode;

  final ValueChanged<String> onTagPrefixChanged;
  final ValueChanged<DetourMode> onSetDetourMode;
  final ValueChanged<bool> onRegisterDetourServersChanged;
  final ValueChanged<bool> onRegisterDetourInAutoChanged;
  final VoidCallback onShowOverrideDetourPicker;
  final ValueChanged<bool> onReplaceDetourChainChanged;
  final VoidCallback onCopyUrl;
  final VoidCallback onShowIntervalPicker;
  final VoidCallback onRefreshNow;
  final VoidCallback onEditSource; // §129 — сменить источник (online↔file)

  /// §248 — подпись override-цели: тег detour-канала (или его auto-двойника)
  /// → «⚙ <label>»; канал не найден → сырой тег. Интра-омоним папки (bare-тег
  /// собственного члена) побеждает канал-тёзку — это ссылка на члена
  /// (приоритет bareIndex в FolderDetourPlan), показываем как тег.
  String _overrideDisplay() {
    final stored = entry.overrideDetour;
    final list = entry.list;
    if (folderMode && list is FolderServers) {
      for (final m in list.members) {
        if (m.node?.tag == stored) return stored;
      }
    }
    return detourChannelDisplay(stored, channels);
  }

  /// §252 — цепочка хопов цели по ходу пакета (или один хоп, если экран не
  /// прокинул разворот).
  String _overridePath() {
    final hops = detourPathHopsOf?.call(entry.overrideDetour);
    if (hops == null || hops.isEmpty) return _overrideDisplay();
    return hops.join(' → ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Tag prefix', style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 4),
        Text(
          folderMode
              ? 'Prefix applied to every server tag in this folder '
                  '(e.g. "BL:" → "BL: Frankfurt"). Lets a routing channel '
                  'match the whole folder by regex.'
              : 'Prefix applied to every tag from this subscription '
                  '(e.g. "BL:" → "BL: Frankfurt"). Used to distinguish servers '
                  'from different subscriptions and resolve name collisions.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextFormField(
            initialValue: entry.tagPrefix,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Prefix',
              hintText: 'empty = no prefix',
              isDense: true,
            ),
            onChanged: onTagPrefixChanged,
          ),
        ),
        const SizedBox(height: 24),
        if (hasDetour) ...[
          Text('Detour servers', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          // Тернарный mode (radio): три mutually-exclusive варианта над парой
          // полей entry.{useDetourServers, overrideDetour}. Mapping:
          //   use      → useDetour=true,  override=''
          //   override → useDetour=true,  override='<tag>'
          //   none     → useDetour=false, override=''
          // register'ы (sub-options для mode=use) хранятся независимо, не
          // обнуляются при переключении mode'а — юзер вернётся в use, флаги
          // на месте.
          RadioGroup<DetourMode>(
            groupValue: detourMode,
            onChanged: (m) => onSetDetourMode(m!),
            child: Column(children: [
              RadioListTile<DetourMode>(
                value: DetourMode.use,
                title: Text(folderMode
                    ? "Use servers' own detours"
                    : 'Use subscription detour servers'),
                subtitle: Text(folderMode
                    ? 'Members connect through their personal detours'
                    : 'Nodes connect through detour servers'),
              ),
              // §096 — register-тоглы под Use (нативные детуры используются).
              if (detourMode == DetourMode.use) _registerToggles(),
              RadioListTile<DetourMode>(
                value: DetourMode.override,
                title: const Text('Add detour'),
                subtitle: Text(entry.overrideDetour.isEmpty
                    ? 'Append an outbound to the end of the chain'
                    : entry.replaceDetourChain
                        ? 'Replace all → ${_overrideDisplay()}'
                        : 'Fill missing → ${_overrideDisplay()}'),
              ),
              // Sub-tiles под «Add detour»: outbound picker + выбор режима.
              // §073/§245: тот же bool replaceDetourChain, но вместо
              // невнятного toggle — два явных radio-режима:
              //   Replace all  → replaceDetourChain=true  (дропнуть цепочки)
              //   Fill missing → replaceDetourChain=false (default, append)
              if (detourMode == DetourMode.override) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: ListTile(
                    title: const Text('Outbound'),
                    subtitle: Text(entry.overrideDetour.isEmpty
                        ? '(tap to choose)'
                        : _overrideDisplay()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onShowOverrideDetourPicker,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: RadioGroup<bool>(
                    groupValue: entry.replaceDetourChain,
                    onChanged: (v) => onReplaceDetourChainChanged(v!),
                    child: Column(children: [
                      RadioListTile<bool>(
                        value: true,
                        title: const Text('Replace all'),
                        subtitle: Text(folderMode
                            ? 'Drop existing detours — every member '
                                'connects through this outbound'
                            : 'Drop existing detours — every node '
                                'connects through this outbound'),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: const Text('Fill missing'),
                        subtitle: Text(folderMode
                            ? 'Members with their own detour keep it; '
                                'this outbound is set only where none '
                                'is defined'
                            : 'Nodes with their own detour keep it; '
                                'this outbound is set only where none '
                                'is defined'),
                      ),
                    ]),
                  ),
                ),
                // §096 — в режиме Fill missing (append) нативные детуры
                // подписки сохраняются в цепочке → register-тоглы
                // осмысленны и тут.
                if (!entry.replaceDetourChain) _registerToggles(),
              ],
              const RadioListTile<DetourMode>(
                value: DetourMode.none,
                title: Text("Don't use detour servers"),
                subtitle: Text('Nodes connect directly, detour skipped'),
              ),
            ]),
          ),
        ] else ...[
          // §111 — у подписки нет родных detour-цепочек: полный radio
          // (Use/Add/None) вырождается — Use≡None, register-тоглы и Replace
          // неприменимы. Вместо него один пикер поверх тех же полей
          // DetourPolicy: выбор тага → useDetourServers=true + override
          // (builder: APPEND на пустой цепочке = 1-hop), None → override=''.
          Text('Detour', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const SizedBox(height: 4),
          Text(
            folderMode
                ? 'Servers in this folder have no detours yet. You can still '
                    'route all of them through one of your servers, or set '
                    'personal detours per server (tap a server on the '
                    'Servers tab).'
                : 'This subscription has no detour servers of its own. You can '
                    'still route all its nodes through one of your servers.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.alt_route, size: 20),
            title: const Text('Detour server'),
            subtitle: Text(entry.overrideDetour.isEmpty
                ? 'None — nodes connect directly'
                // detour — ВХОДНОЙ (трафик идёт через него ПЕРВЫМ, потом в
                // ноды подписки, потом наружу). §252 — полная цепочка «как
                // пакет пойдёт»: цель → её собственный detour → … (та же
                // детализация, что у одиночного сервера в Node Settings).
                : 'Phone → ${_overridePath()} → Nodes → Internet'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onShowOverrideDetourPicker,
          ),
        ],
        if (entry.list is SubscriptionServers) ...[
          const SizedBox(height: 24),
          Text('Subscription', style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          _buildSubscriptionInfo(theme),
        ],
      ],
    );
  }

  /// §096/§026 — register-тоглы detour-серверов. Показываются когда нативные
  /// детуры в игре: режим **Use** ИЛИ **Add detour + Fill missing** (append).
  /// Прячутся при Replace all / None (нативных детуров нет — регистрировать
  /// нечего).
  /// Делают detour-сервера видимыми как ноды (selector) / в ✨auto. Флаги
  /// хранятся независимо от режима — переключение Use↔Add detour их не теряет.
  Widget _registerToggles() => Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Column(children: [
          SwitchListTile(
            title: const Text('Register detour servers'),
            subtitle: const Text(
                'Add detour servers to proxy groups (visible in node list)'),
            value: entry.registerDetourServers,
            onChanged: onRegisterDetourServersChanged,
          ),
          SwitchListTile(
            title: const Text('Register detour in auto group'),
            subtitle: const Text(
                'Include detour servers in auto-proxy-out urltest'),
            value: entry.registerDetourInAuto,
            onChanged: onRegisterDetourInAutoChanged,
          ),
        ]),
      );

  Widget _buildSubscriptionInfo(ThemeData theme) {
    final list = entry.list as SubscriptionServers;
    final cs = theme.colorScheme;
    final label = statusLabel(list);
    final color = statusColor(list, cs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // §129 — источник подписки. Клик по строке → сменить источник
        // (online URL ↔ файл). Для онлайн — copy-иконка справа (копировать URL);
        // для файла показываем имя (снапшот в кэше, сырого URL нет).
        Builder(builder: (context) {
          final isFile = isFileSubscription(list.url);
          return ListTile(
            leading: Icon(isFile ? Icons.insert_drive_file_outlined : Icons.link,
                size: 20),
            title: Text(isFile ? 'Source: local file' : 'URL'),
            subtitle: Text(isFile ? entry.displayName : list.url,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: isFile
                ? const Icon(Icons.edit, size: 18)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 18),
                        tooltip: 'Copy URL',
                        visualDensity: VisualDensity.compact,
                        onPressed: onCopyUrl,
                      ),
                      const Icon(Icons.edit, size: 18),
                    ],
                  ),
            onTap: onEditSource,
          );
        }),
        // §129 — Update interval: -1 = никогда (игнор сервера); 0 = respect
        // server (сами не по расписанию); >0 = раз в N часов.
        ListTile(
          leading: const Icon(Icons.sync, size: 20),
          title: const Text('Update interval'),
          subtitle: Text(switch (list.updateIntervalHours) {
            < 0 => "Don't auto-update (manual only)",
            0 => 'Never (respect server) — manual only unless server sets one',
            final h => '${h}h (auto-refresh every ${intervalHuman(h)})',
          }),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: onShowIntervalPicker,
        ),
        ListTile(
          leading: Icon(statusIcon(list), size: 20, color: color),
          title: Text(label, style: TextStyle(color: color)),
          subtitle: Text(subscriptionStatusSubtitle(list)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: OutlinedButton.icon(
            onPressed: onRefreshNow,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh now'),
          ),
        ),
      ],
    );
  }
}
