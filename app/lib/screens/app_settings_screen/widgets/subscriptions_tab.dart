import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';

/// §118 — App Settings → Subscriptions tab. Глобальные настройки HTTP-фетча
/// подписок: авто-обновление, кастомный User-Agent, HWID + device-meta
/// (Remnawave `x-hwid`/`x-device-os`/`x-ver-os`/`x-device-model`).
///
/// Stateless — значения и колбэки приходят от `_AppSettingsScreenState`
/// (паттерн как у [GeneralTab]). Отображает **effective** значения meta
/// (override > device-дефолт); сам override правится в edit-диалоге родителя.
class SubscriptionsTab extends StatelessWidget {
  const SubscriptionsTab({
    super.key,
    required this.loaded,
    required this.padding,
    required this.autoUpdateSubs,
    required this.onAutoUpdateSubsChanged,
    required this.userAgent,
    required this.defaultUserAgent,
    required this.onEditUserAgent,
    required this.sendHwid,
    required this.onSendHwidChanged,
    required this.hwid,
    required this.deviceOs,
    required this.verOs,
    required this.deviceModel,
    required this.onEditHwid,
    required this.onRegenerateHwid,
    required this.onEditDeviceOs,
    required this.onEditVerOs,
    required this.onEditDeviceModel,
  });

  final bool loaded;
  final EdgeInsets padding;

  final bool autoUpdateSubs;
  final ValueChanged<bool> onAutoUpdateSubsChanged;

  /// Пусто = дефолтный брендированный UA (показан как плейсхолдер).
  final String userAgent;
  final String defaultUserAgent;
  final VoidCallback onEditUserAgent;

  final bool sendHwid;
  final ValueChanged<bool> onSendHwidChanged;

  /// Effective-значения заголовков (override > device-дефолт).
  final String hwid;
  final String deviceOs;
  final String verOs;
  final String deviceModel;

  final VoidCallback onEditHwid;
  final VoidCallback onRegenerateHwid;
  final VoidCallback onEditDeviceOs;
  final VoidCallback onEditVerOs;
  final VoidCallback onEditDeviceModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListView(
      padding: padding,
      children: [
        Text(context.l.appSettingsSubsAutoUpdateHeader,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsSubsAutoUpdateTitle),
          subtitle: Text(context.l.appSettingsSubsAutoUpdateSubtitle),
          secondary: const Icon(Icons.cloud_sync_outlined),
          value: autoUpdateSubs,
          onChanged: loaded ? onAutoUpdateSubsChanged : null,
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsSubsFetchIdentityHeader,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: Text(context.l.appSettingsSubsUaTitle),
          subtitle: Text(
            userAgent.isEmpty
                ? context.l.appSettingsSubsUaDefault(defaultUserAgent)
                : userAgent,
            style: TextStyle(
              fontStyle: userAgent.isEmpty ? FontStyle.italic : null,
            ),
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: loaded ? onEditUserAgent : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            context.l.appSettingsSubsUaNote,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        SwitchListTile(
          title: Text(context.l.appSettingsSubsSendHwidTitle),
          subtitle: Text(context.l.appSettingsSubsSendHwidSubtitle),
          secondary: const Icon(Icons.devices_outlined),
          value: sendHwid,
          onChanged: loaded ? onSendHwidChanged : null,
        ),
        if (sendHwid) ...[
          _editRow(
            context,
            icon: Icons.tag,
            label: 'HWID · x-hwid',
            value: hwid,
            monospace: true,
            onEdit: onEditHwid,
            extra: IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: context.l.commonRegenerate,
              onPressed: loaded ? onRegenerateHwid : null,
            ),
          ),
          _editRow(context,
              icon: Icons.android, label: 'x-device-os', value: deviceOs,
              onEdit: onEditDeviceOs),
          _editRow(context,
              icon: Icons.numbers, label: 'x-ver-os', value: verOs,
              onEdit: onEditVerOs),
          _editRow(context,
              icon: Icons.phone_android,
              label: 'x-device-model',
              value: deviceModel,
              onEdit: onEditDeviceModel),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              context.l.appSettingsSubsHeadersNote,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  Widget _editRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onEdit,
    bool monospace = false,
    Widget? extra,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(
        value.isEmpty ? context.l.appSettingsSubsEmptyValue : value,
        style: TextStyle(
          fontFamily: monospace ? 'monospace' : null,
          fontSize: monospace ? 12 : null,
          color: value.isEmpty
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extra,
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: context.l.commonEdit,
            onPressed: loaded ? onEdit : null,
          ),
        ],
      ),
    );
  }
}
