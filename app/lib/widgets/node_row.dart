import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home/special_node_display.dart';
import '../screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'node_view_item.dart';
import '../services/l10n/locale_controller.dart';
// §535 — CcEndpointState: имена состояний endpoint'а приходят из ядра.
import '../vpn/cc_channel.dart' show CcEndpointState;

/// One row в node list на главной screen'е. Read-only widget от
/// [NodeViewItem] data + callbacks.
///
/// Specs:
/// - §068 — extract view-model class (item-based constructor вместо 14
///   explicit args)
/// - §048 — `item.matches == false` → render с opacity 0.4 (single source
///   of opacity, magic 0.4 не утекает в caller)
class NodeRow extends StatelessWidget {
  const NodeRow({
    super.key,
    required this.item,
    required this.onHighlight,
    required this.onActivate,
    required this.onPing,
    this.onCopyUri,
    this.onViewJson,
    this.onRunUrltest,
    this.onSelectServer,
    this.onViewPool,
    this.onSickTap,
    this.onToggleEndpoint,
  });

  final NodeViewItem item;
  final VoidCallback onHighlight;
  final VoidCallback onActivate;
  final VoidCallback onPing;

  /// Called when user wants the original URI (vless://, wireguard://, …).
  final VoidCallback? onCopyUri;
  final VoidCallback? onViewJson;

  /// Non-null only for URLTest group tags — triggers `/group/<tag>/delay`
  /// которое forces sing-box re-test всех members и update `now`.
  final VoidCallback? onRunUrltest;

  /// §203 — non-null только для auto/urltest-ноды с текущим выбором
  /// (`urltestNow`): «Select server» в меню → подсветка + scroll к выбранному
  /// сервером тегу. Иначе null → пункт меню скрыт.
  final VoidCallback? onSelectServer;

  /// §208 — non-null только для auto-ноды round_robin-Направления: «View pool» в меню
  /// → попап с текущим составом пула (getPool). Иначе null → пункт скрыт.
  final VoidCallback? onViewPool;

  /// §355 — тап по ⚠-метке корня беды ([NodeViewItem.isSickRoot]) — caller
  /// открывает sheet со списком пострадавших. null при isSickRoot=false.
  final VoidCallback? onSickTap;

  /// §557 (ядро SPEC 106) — «Turn off» / «Turn on» в меню. Non-null только
  /// для WG/AWG-узла (ядро отдало `endpointState`) при живом туннеле; иначе
  /// пункта нет. Направление переключения — по [NodeViewItem.endpointState].
  final VoidCallback? onToggleEndpoint;

  /// Right-side delay label (или PING… / ERR), цвет по latency.
  ///
  /// §325 — префикс `~` («приблизительно») у замера из другого Направления: число
  /// показано как ориентир, но получено чужим тестом (ping-URL и таймаут
  /// резолвятся per-group, §040). Значок текстовый и однознаковый намеренно —
  /// бейдж узкий и моноширинный, иконка сломала бы выравнивание колонки.
  String get _delayLabel {
    // §557 — выключенный узел (SPEC 106) отвергает дайлы: провал замера тут
    // не сбой узла. Вместо пинга, таймаута и PING… — нейтральный прочерк,
    // слева подпись «off».
    if (_isDisabled) return '—'; // l10n-exempt: dash placeholder, not text
    if (item.pingBusy) return 'PING…';
    final delay = item.delay;
    if (delay == null) return '';
    final prefix = item.delayIsForeign ? '~' : '';
    return delay < 0 ? '${prefix}ERR' : '$prefix${delay}MS';
  }

  /// §535/§540 (ядро SPEC 097) — однословная подпись состояния WG/AWG-
  /// endpoint'а: `up` / `sleep` / `down` / `off` (§557, выключен вручную). Детали (полное состояние ядра и
  /// простой) — в свойствах узла. Узел в `down` — это НЕ таймаут: ядро
  /// поднимет его на первом дайле за 0,5–1 с. Пусто = узел не endpoint,
  /// состояние неизвестно или идёт сборка (`building`).
  bool get _isDisabled => item.endpointState == CcEndpointState.disabled;

  String get _endpointStateLabel {
    final st = item.endpointState;
    // §557 — выключен вручную: отдельная подпись, не сон и не «down».
    if (st == CcEndpointState.disabled) return getLocalText.s("off");
    if (st == CcEndpointState.up) return getLocalText.s("up");
    if (st == CcEndpointState.asleep) return getLocalText.s("sleep");
    if (CcEndpointState.isNotBuilt(st) || st == CcEndpointState.down) {
      return getLocalText.s("down");
    }
    return '';
  }

  Widget _endpointStateLabelText(String label, Color color) => Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontStyle: FontStyle.italic,
          color: color,
        ),
      );

  Color? _delayColor(BuildContext context) {
    if (_isDisabled) return null; // §557 — прочерк нейтральным цветом
    final delay = item.delay;
    if (delay == null || item.pingBusy) return null;
    final Color base;
    if (delay < 0) {
      base = Theme.of(context).colorScheme.error;
    } else if (delay < 200) {
      base = Colors.green;
    } else if (delay < 500) {
      base = Colors.orange;
    } else {
      base = Theme.of(context).colorScheme.error;
    }
    // §325 — чужой замер приглушаем: цветовая шкала остаётся читаемой (видно,
    // что «зелёный»), но бейдж не спорит за внимание со своими, актуальными.
    return item.delayIsForeign ? base.withValues(alpha: 0.55) : base;
  }

  /// `[ACTIVE] [protocol]              [50MS]` — left part flex, ping right-aligned.
  Widget _buildSubtitleRow(BuildContext context, ColorScheme cs) {
    final hasActive = item.active;
    final hasArrow = item.urltestNow != null && item.urltestNow!.isNotEmpty;
    // §322 — у группы автовыбора вместо протокола метка режима, и живёт она
    // слева от стрелки: «🔀 [15/7] → 🇩🇪 Германия».
    final auto = item.autoGroupLabel;
    final hasAuto = auto != null && auto.isNotEmpty;
    final hasProto = !hasAuto &&
        item.protocolLabel != null &&
        item.protocolLabel!.isNotEmpty;
    final notificationWarnings = item.notificationWarnings;
    final hasNotificationBadge = notificationWarnings != null &&
        notificationWarnings.isNotEmpty;
    // §201 — у block нет осмысленного delay (всегда ERR): бейдж не рисуем.
    final dl = _isBlock ? '' : _delayLabel;
    // §535 — подпись «узел не поднят / спит» живёт в левой части строки:
    // правый бейдж узкий и моноширинный, фраза туда не влезает.
    final stateLabel = _isBlock ? '' : _endpointStateLabel;

    if (!hasActive &&
        !hasArrow &&
        !hasProto &&
        !hasAuto &&
        !hasNotificationBadge &&
        stateLabel.isEmpty &&
        dl.isEmpty) {
      return const SizedBox.shrink();
    }

    final Widget? activePill = hasActive
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              getLocalText.s("ACTIVE"),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.green.shade700,
                letterSpacing: 0.5,
              ),
            ),
          )
        : null;

    final Widget? arrow = (hasArrow || hasAuto)
        ? Text(
            [
              if (hasAuto) auto,
              if (hasArrow) '→ ${item.urltestNow}',
            ].join(' '),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: cs.onSurfaceVariant,
            ),
          )
        : null;

    // §557 — выключенный узел: «off» оранжевым (тот же оранжевый, что у
    // пинга 200–500 мс), курсивом, как соседние up/sleep/down.
    final Widget? endpointStateText = stateLabel.isEmpty
        ? null
        : Flexible(
            child: _endpointStateLabelText(
                stateLabel, _isDisabled ? Colors.orange : cs.onSurfaceVariant),
          );

    final Widget? proto = (hasProto || hasNotificationBadge)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasNotificationBadge)
                NodeInfoBadge(notificationWarnings, showTopSeverity: true),
              if (hasProto)
                Flexible(
                  child: Text(
                    item.protocolLabel!,
                    // §199 — транспорт уступает серверу: обрезается ellipsis'ом,
                    // не переполняет (внутри Flexible).
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
            ],
          )
        : null;

    final right = dl.isEmpty
        ? const SizedBox.shrink()
        : Text(
            dl,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: _delayColor(context) ?? cs.onSurfaceVariant,
            ),
          );

    // Пинг (`right`) ВСЕГДА прижат к правому краю строки. Вся левая часть
    // (active / arrow / proto) живёт в одном Expanded, который съедает остаток
    // ширины и толкает пинг вправо — без конкуренции flex-ов между proto и
    // Spacer'ом (из-за неё пинг раньше всплывал в середину строки).
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (activePill != null) ...[
                  activePill,
                  const SizedBox(width: 6),
                ],
                // §199 — в строке auto/urltest ВАЖЕН выбранный сервер
                // (`→ <node>`): он держит место (flex:3), транспорт (proto)
                // уступает по остаточному принципу (flex:1) — обрезается/
                // исчезает первым при нехватке ширины.
                if (arrow != null)
                  Flexible(
                    flex: 3,
                    fit: FlexFit.loose,
                    child: Padding(
                      padding: EdgeInsets.only(right: proto != null ? 6 : 0),
                      child: arrow,
                    ),
                  ),
                if (proto != null)
                  Flexible(
                    flex: 1,
                    fit: FlexFit.loose,
                    child: proto,
                  ),
                // §535 — состояние endpoint'а идёт последним в левой части:
                // при нехватке ширины уступает протоколу и выбранному серверу.
                if (endpointStateText != null) ...[
                  if (proto != null || arrow != null)
                    const SizedBox(width: 6),
                  endpointStateText,
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          right,
        ],
      ),
    );
  }

  // §125 — служебная нода (direct/auto): по типу из конфига, не по маске имени.
  /// §125/§322 — служебная нода (direct/auto-двойник/block): подменённое имя
  /// и иконка. urltest-группа §322 сюда НЕ входит — она показывает своё имя,
  /// хотя тип у неё тот же `urltest` (различитель — тег Направления, `isDirectionAuto`).
  bool get _isSpecial => _special != null;

  SpecialNodeDisplay? get _special {
    final s = specialNodeDisplayForType(item.outboundType);
    if (s == null) return null;
    if (item.outboundType == 'urltest' && !item.isDirectionAuto) return null;
    return s;
  }

  // §201 — block: дропает трафик, urltest всегда ERR. Не пингуем и не
  // показываем delay-бейдж (был бы всегда «ERR»).
  bool get _isBlock => item.outboundType == 'block';

  Future<void> _openLongPressMenu(BuildContext context) async {
    // §201 — block не пингуется (всегда ERR): пункт Ping disabled.
    final canPing = item.tunnelUp && !item.busy && !item.pingBusy && !_isBlock;
    final canActivate = item.tunnelUp && !item.busy && !item.active;
    // §322 — у группы автовыбора ссылки для копирования нет: её члены —
    // узлы своего контейнера (§439: запись `kind: auto`, а не текст). Гейт по
    // ТИПУ, а не по `_isSpecial`: группа §322 из
    // «спец»-категории выведена намеренно (своё имя, своё место в списке).
    final showCopy = !_isSpecial && item.outboundType != 'urltest';
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;

    final a = box.localToGlobal(Offset.zero);
    final b = box.localToGlobal(box.size.bottomRight(Offset.zero));
    final position = RelativeRect.fromRect(
      Rect.fromPoints(a, b),
      Offset.zero & overlay.size,
    );
    final chosen = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'ping',
          enabled: canPing,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.speed_outlined,
              size: 20,
              color: canPing ? null : Theme.of(context).disabledColor,
            ),
            title: Text(getLocalText.s("Ping")),
          ),
        ),
        PopupMenuItem<String>(
          value: 'activate',
          enabled: canActivate,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.play_circle_outline,
              size: 20,
              color: canActivate ? null : Theme.of(context).disabledColor,
            ),
            title: Text(getLocalText.s("Use this node")),
          ),
        ),
        if (onRunUrltest != null)
          PopupMenuItem<String>(
            value: 'run_urltest',
            enabled: item.tunnelUp && !item.busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.auto_awesome,
                size: 20,
                color: (item.tunnelUp && !item.busy)
                    ? null
                    : Theme.of(context).disabledColor,
              ),
              title: Text(getLocalText.s("Run URLTest")),
            ),
          ),
        // §203 — «Select server»: только для auto/urltest-ноды с текущим
        // выбором (onSelectServer != null). Подсвечивает и скроллит к серверу,
        // который urltest выбрал быстрейшим.
        if (onSelectServer != null)
          PopupMenuItem<String>(
            value: 'select_server',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.my_location, size: 20),
              title: Text(getLocalText.s("Select server")),
            ),
          ),
        // §208 — «View pool»: только для auto-ноды round_robin-Направления
        // (onViewPool != null). Попап со слотами пула (getPool).
        if (onViewPool != null)
          PopupMenuItem<String>(
            value: 'view_pool',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.hub_outlined, size: 20),
              title: Text(getLocalText.s("View pool")),
            ),
          ),
        if (onToggleEndpoint != null)
          PopupMenuItem<String>(
            value: 'toggle_endpoint',
            enabled: !item.busy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _isDisabled
                    ? Icons.power_settings_new
                    : Icons.power_off_outlined,
                size: 20,
                color: item.busy ? Theme.of(context).disabledColor : null,
              ),
              title: Text(_isDisabled
                  ? getLocalText.s("Turn on")
                  : getLocalText.s("Turn off")),
            ),
          ),
        if (onViewJson != null) const PopupMenuDivider(),
        if (onViewJson != null)
          // §258 — экран стал Overview/JSON, пункт переименован в View
          // details (внутреннее значение 'view_json' не трогаем).
          PopupMenuItem<String>(
            value: 'view_json',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline, size: 20),
              title: Text(getLocalText.s("View details")),
            ),
          ),
        if (showCopy) const PopupMenuDivider(),
        if (showCopy && onCopyUri != null)
          PopupMenuItem<String>(
            value: 'copy_uri',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link, size: 20),
              title: Text(getLocalText.s("Copy URI")),
            ),
          ),
        // §099 — Copy JSON / detour / server+detour перенесены в View JSON.
      ],
    );
    if (!context.mounted) return;
    switch (chosen) {
      case 'ping':
        onPing();
      case 'select_server':
        onSelectServer?.call();
      case 'view_pool':
        onViewPool?.call();
      case 'activate':
        onActivate();
      case 'run_urltest':
        if (onRunUrltest != null) onRunUrltest!();
      case 'copy_uri':
        if (onCopyUri != null) onCopyUri!();
      case 'view_json':
        if (onViewJson != null) onViewJson!();
      case 'toggle_endpoint':
        onToggleEndpoint?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canActivate = item.tunnelUp && !item.busy && !item.active;

    final content = Material(
      color: item.highlighted
          ? colorScheme.primaryContainer.withAlpha(55)
          : (_isSpecial ? colorScheme.secondaryContainer.withAlpha(40) : null),
      child: InkWell(
        onTap: onHighlight,
        onLongPress: () => unawaited(_openLongPressMenu(context)),
        child: SizedBox(
          height: 56,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: (item.active || item.highlighted) ? 3 : 0,
                color: (item.active || item.highlighted)
                    ? colorScheme.primary
                    : Colors.transparent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Builder(builder: (context) {
                      // §125 — служебные ноды (direct/auto) показываем
                      // подменённым label'ом + иконкой; тип берём ТОЧНО из
                      // конфига (item.outboundType), не по маске имени.
                      final special = _special;
                      final displayText = special?.label ?? item.tag;
                      return Row(
                        children: [
                          if (special != null) ...[
                            Icon(special.icon,
                                size: 18, color: colorScheme.primary),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              displayText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    fontWeight: item.active
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                            ),
                          ),
                          // §355 — корень беды: мёртвая нода, от которой
                          // зависят DNS/ноды. Тап → sheet со списком.
                          if (item.isSickRoot) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: onSickTap,
                              child: Icon(Icons.warning_amber_rounded,
                                  size: 18, color: colorScheme.error),
                            ),
                          ],
                        ],
                      );
                    }),
                    _buildSubtitleRow(context, colorScheme),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                tooltip: item.active
                    ? getLocalText.s("Active")
                    : getLocalText.s("Use node"),
                onPressed: canActivate ? onActivate : null,
                icon: Icon(
                  item.active ? Icons.check_circle : Icons.play_circle_outline,
                  size: 22,
                  color: item.active
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );

    // §048 — single source of opacity. Caller передаёт `matches` через
    // `NodeViewItem`, widget сам решает как render себя в matching/non-matching
    // состоянии. Magic 0.4 не утекает в caller.
    return Opacity(
      opacity: item.matches ? 1.0 : 0.4,
      child: content,
    );
  }
}
