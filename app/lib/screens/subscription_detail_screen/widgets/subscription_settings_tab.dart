import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/channel.dart';
import '../../../models/server_list.dart';
import '../../../services/l10n/l10n.dart';
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
        Text(context.l.subTagPrefixTitle, style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 4),
        Text(
          folderMode
              ? context.l.subTagPrefixBodyFolder
              : context.l.subTagPrefixBodySubscription,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextFormField(
            initialValue: entry.tagPrefix,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: context.l.subPrefixLabel,
              hintText: context.l.subPrefixHint,
              isDense: true,
            ),
            onChanged: onTagPrefixChanged,
          ),
        ),
        const SizedBox(height: 24),
        if (hasDetour) ...[
          Text(context.l.subDetourServersTitle, style: theme.textTheme.titleSmall?.copyWith(
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
                    ? context.l.subUseOwnDetours
                    : context.l.subUseSubDetours),
                subtitle: Text(folderMode
                    ? context.l.subUseOwnDetoursSub
                    : context.l.subUseSubDetoursSub),
              ),
              // §096 — register-тоглы под Use (нативные детуры используются).
              if (detourMode == DetourMode.use) _registerToggles(context),
              RadioListTile<DetourMode>(
                value: DetourMode.override,
                title: Text(context.l.subAddDetour),
                subtitle: Text(entry.overrideDetour.isEmpty
                    ? context.l.subAddDetourAppendSub
                    : entry.replaceDetourChain
                        ? context.l.subReplaceAllArrow(_overrideDisplay())
                        : context.l.subFillMissingArrow(_overrideDisplay())),
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
                    title: Text(context.l.subOutbound),
                    subtitle: Text(entry.overrideDetour.isEmpty
                        ? context.l.subTapToChoose
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
                        title: Text(context.l.subReplaceAll),
                        subtitle: Text(folderMode
                            ? context.l.subReplaceAllSubFolder
                            : context.l.subReplaceAllSubSubscription),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: Text(context.l.subFillMissing),
                        subtitle: Text(folderMode
                            ? context.l.subFillMissingSubFolder
                            : context.l.subFillMissingSubSubscription),
                      ),
                    ]),
                  ),
                ),
                // §096 — в режиме Fill missing (append) нативные детуры
                // подписки сохраняются в цепочке → register-тоглы
                // осмысленны и тут.
                if (!entry.replaceDetourChain) _registerToggles(context),
              ],
              RadioListTile<DetourMode>(
                value: DetourMode.none,
                title: Text(context.l.subDontUseDetour),
                subtitle: Text(context.l.subDontUseDetourSub),
              ),
            ]),
          ),
        ] else ...[
          // §111 — у подписки нет родных detour-цепочек: полный radio
          // (Use/Add/None) вырождается — Use≡None, register-тоглы и Replace
          // неприменимы. Вместо него один пикер поверх тех же полей
          // DetourPolicy: выбор тага → useDetourServers=true + override
          // (builder: APPEND на пустой цепочке = 1-hop), None → override=''.
          Text(context.l.subDetourTitle, style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const SizedBox(height: 4),
          Text(
            folderMode
                ? context.l.subNoDetoursFolderBody
                : context.l.subNoDetoursSubscriptionBody,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.alt_route, size: 20),
            title: Text(context.l.subDetourPickerTitle),
            subtitle: Text(entry.overrideDetour.isEmpty
                ? context.l.subDetourNoneDirect
                // detour — ВХОДНОЙ (трафик идёт через него ПЕРВЫМ, потом в
                // ноды подписки, потом наружу). §252 — полная цепочка «как
                // пакет пойдёт»: цель → её собственный detour → … (та же
                // детализация, что у одиночного сервера в Node Settings).
                : context.l.subDetourPathPreview(_overridePath())),
            trailing: const Icon(Icons.chevron_right),
            onTap: onShowOverrideDetourPicker,
          ),
        ],
        if (entry.list is SubscriptionServers) ...[
          const SizedBox(height: 24),
          Text(context.l.subSubscriptionHeader, style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )),
          const Divider(),
          _buildSubscriptionInfo(context, theme),
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
  Widget _registerToggles(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Column(children: [
          SwitchListTile(
            title: Text(context.l.subRegisterDetourServers),
            subtitle: Text(context.l.subRegisterDetourServersSub),
            value: entry.registerDetourServers,
            onChanged: onRegisterDetourServersChanged,
          ),
          SwitchListTile(
            title: Text(context.l.subRegisterDetourInAuto),
            subtitle: Text(context.l.subRegisterDetourInAutoSub),
            value: entry.registerDetourInAuto,
            onChanged: onRegisterDetourInAutoChanged,
          ),
        ]),
      );

  Widget _buildSubscriptionInfo(BuildContext context, ThemeData theme) {
    final list = entry.list as SubscriptionServers;
    final cs = theme.colorScheme;
    final label = statusLabel(context.l, list);
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
            // l10n-exempt: 'URL' is locale-invariant
            title: Text(isFile ? context.l.subSourceLocalFileTitle : 'URL'),
            subtitle: Text(isFile ? entry.displayName : list.url,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: isFile
                ? const Icon(Icons.edit, size: 18)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.content_copy, size: 18),
                        tooltip: context.l.subCopyUrl,
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
          title: Text(context.l.subUpdateIntervalTitle),
          subtitle: Text(switch (list.updateIntervalHours) {
            < 0 => context.l.subIntervalDontAutoLong,
            0 => context.l.subIntervalNeverRespectLong,
            final h => context.l.subIntervalHoursLong(h, intervalHuman(context.l, h)),
          }),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: onShowIntervalPicker,
        ),
        ListTile(
          leading: Icon(statusIcon(list), size: 20, color: color),
          title: Text(label, style: TextStyle(color: color)),
          subtitle: Text(subscriptionStatusSubtitle(context.l, list)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: OutlinedButton.icon(
            onPressed: onRefreshNow,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(context.l.subRefreshNow),
          ),
        ),
      ],
    );
  }
}
