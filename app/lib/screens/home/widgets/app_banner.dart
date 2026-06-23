import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/home_state.dart';

/// §116 — единый banner-механизм для home. Принцип: **баннер = чистая
/// проекция наблюдаемого состояния**. Не отдельный стор и не императивный
/// контроллер с замыканиями — источники правды это существующие notifier'ы
/// (`HomeState`/`SubscriptionController`), баннеры деривятся из них на каждый
/// rebuild через [activeBanners]. Единственная реальная машинерия —
/// центральный auto-dismiss таймер в [BannerStack] (раньше размазан в
/// `_onControllerChange`). Подробности — docs/spec/tasks/116.
///
/// SnackBar'ы (низ, `ScaffoldMessenger`) — иной UX (event vs state) и вне
/// скоупа: их гоняет Flutter.

enum BannerPalette { info, warning, error }

/// Декриптор плашки — чистые данные, без поведения. `autoDismiss == null` →
/// persistent (живёт, пока его guard в [activeBanners] истинен). `onDismiss`
/// (если задан) рисует крестик и вызывается auto-dismiss таймером.
class AppBanner {
  const AppBanner({
    required this.key,
    required this.message,
    required this.icon,
    required this.palette,
    this.autoDismiss,
    this.onTap,
    this.onDismiss,
  });

  final String key;
  final String message;
  final IconData icon;
  final BannerPalette palette;
  final Duration? autoDismiss;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;
}

/// Действия, которые плашки диспатчат. Строятся в `home_controls` (есть
/// context/controller) и прокидываются сюда, чтобы [activeBanners] оставалась
/// чистой функцией без UI-зависимостей.
class BannerActions {
  const BannerActions({
    required this.onRebuild,
    required this.onConfirmStop,
    required this.onClearError,
  });

  final VoidCallback onRebuild;
  final VoidCallback onConfirmStop;
  final VoidCallback onClearError;
}

/// Чистая проекция: состояние → упорядоченный список активных плашек. Guard'ы
/// и есть «условия» (untilCondition/untilReload — это просто «пока guard
/// истинен»). Порядок стабильный (как в исходном home_controls). `configDirty`/
/// `busy` приходят из `SubscriptionController` плоскими bool'ами — функция
/// чистая и тестируется без контроллера.
List<AppBanner> activeBanners(
  HomeState s, {
  required bool configDirty,
  required bool busy,
  required BannerActions actions,
}) {
  final a = actions;
  final out = <AppBanner>[];
  if (configDirty && !busy) {
    out.add(AppBanner(
      key: 'settings_changed',
      message: 'Settings changed — tap to rebuild config',
      icon: Icons.build_circle_outlined,
      palette: BannerPalette.info,
      onTap: a.onRebuild,
    ));
  }
  // §076: «restart» показываем только когда rebuild уже сделан
  // (configDirty=false) но running config устарел.
  if (s.tunnelUp && s.configChangedNeedRestart && !configDirty) {
    out.add(AppBanner(
      key: 'restart',
      message: 'Config changed — restart VPN to apply',
      icon: Icons.info_outline,
      palette: BannerPalette.warning,
      onTap: a.onConfirmStop,
    ));
  }
  // §116 — конфиг не прочёлся при живом туннеле: постоянная ошибка, тап =
  // рестарт (в этом app «restart VPN» = confirmStop → юзер стартует заново).
  if (s.configLoadError) {
    out.add(AppBanner(
      key: 'config_load_error',
      message: 'Config loading error',
      icon: Icons.restart_alt,
      palette: BannerPalette.error,
      onTap: a.onConfirmStop,
    ));
  }
  if (s.lastError.isNotEmpty) {
    out.add(AppBanner(
      key: 'last_error',
      message: s.lastError,
      icon: Icons.error_outline,
      palette: BannerPalette.error,
      autoDismiss: const Duration(seconds: 15),
      onDismiss: a.onClearError,
    ));
  }
  return out;
}

/// Рендерит список плашек + централизованно держит auto-dismiss таймеры
/// (по `key`; перезапускаются, если у того же ключа сменился `message` —
/// новая ошибка ресетит 15с). Таймеры отменяются при исчезновении ключа и в
/// `dispose`.
class BannerStack extends StatefulWidget {
  const BannerStack({super.key, required this.banners});

  final List<AppBanner> banners;

  @override
  State<BannerStack> createState() => _BannerStackState();
}

class _BannerStackState extends State<BannerStack> {
  final Map<String, ({Timer timer, String forMessage})> _timers = {};

  @override
  void initState() {
    super.initState();
    _reconcileTimers();
  }

  @override
  void didUpdateWidget(BannerStack old) {
    super.didUpdateWidget(old);
    _reconcileTimers();
  }

  void _reconcileTimers() {
    final present = {for (final b in widget.banners) b.key: b};
    // Снять таймеры исчезнувших ключей.
    _timers.removeWhere((k, e) {
      if (!present.containsKey(k)) {
        e.timer.cancel();
        return true;
      }
      return false;
    });
    // Запустить/перезапустить таймеры для autoDismiss-плашек.
    for (final b in widget.banners) {
      final d = b.autoDismiss;
      if (d == null) continue;
      final existing = _timers[b.key];
      if (existing != null && existing.forMessage == b.message) continue;
      existing?.timer.cancel();
      _timers[b.key] = (
        timer: Timer(d, () {
          _timers.remove(b.key);
          if (mounted) b.onDismiss?.call();
        }),
        forMessage: b.message,
      );
    }
  }

  @override
  void dispose() {
    for (final e in _timers.values) {
      e.timer.cancel();
    }
    super.dispose();
  }

  ({Color bg, Color fg}) _colors(ColorScheme cs, BannerPalette p) =>
      switch (p) {
        BannerPalette.info => (bg: cs.primaryContainer, fg: cs.onPrimaryContainer),
        BannerPalette.warning =>
          (bg: cs.tertiaryContainer, fg: cs.onTertiaryContainer),
        BannerPalette.error => (bg: cs.errorContainer, fg: cs.onErrorContainer),
      };

  @override
  Widget build(BuildContext context) {
    if (widget.banners.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in widget.banners) ...[
          const SizedBox(height: 8),
          _row(context, cs, b),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, ColorScheme cs, AppBanner b) {
    final c = _colors(cs, b.palette);
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(b.icon, size: 16, color: c.fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(b.message,
                style: TextStyle(fontSize: 13, color: c.fg)),
          ),
          if (b.onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(Icons.close, size: 18, color: c.fg),
              onPressed: b.onDismiss,
            ),
        ],
      ),
    );
    if (b.onTap == null) return content;
    // §163 — `behavior: opaque`: ловить тап по ВСЕЙ площади плашки, включая
    // padding и пустую зону справа от короткого текста. Дефолтный
    // `deferToChild` регистрирует тап лишь при попадании точно в непрозрачный
    // child (иконку/текст), из-за чего «tap to rebuild config» не реагировал
    // на нажатие по большей части ширины (жалобы юзеров).
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: b.onTap,
      child: content,
    );
  }
}
