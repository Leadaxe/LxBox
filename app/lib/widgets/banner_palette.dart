import 'package:flutter/material.dart';

/// §206 — единый источник theme-aware цветов для всех плашек/предупреждений
/// в приложении. Раньше каждая плашка хардкодила `Colors.amber.shadeXXX`, что
/// ломалось в тёмной теме (светлый текст на светлом amber-фоне нечитаем). Здесь
/// цвета деривятся из семантических токенов `ColorScheme` — Material сам держит
/// контраст в light/dark. Любая новая плашка должна брать цвета отсюда, а не
/// заводить свои `Colors.*`.
///
/// `app_banner.dart` (home) использует тот же принцип через `ColorScheme`
/// напрямую — этот модуль выносит его в переиспользуемый helper для остальных
/// экранов (DNS settings, resolver picker, stats и т.д.).
enum BannerSeverity { info, warning, error, success }

/// Набор согласованных цветов одной плашки: фон, рамка, основной текст/иконка,
/// и цвет для action-кнопок (чуть ярче на тёмном фоне).
class BannerColors {
  const BannerColors({
    required this.background,
    required this.border,
    required this.foreground,
    required this.action,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final Color action;
}

/// Возвращает theme-aware цвета для заданной severity.
///
/// `info`/`error` берутся из семантических токенов `ColorScheme` (они корректны
/// в обеих темах из коробки). `warning`/`success` зафиксированы явными light/dark
/// пресетами (amber/green) — тема приложения построена через `ColorScheme.fromSeed`,
/// где производные `tertiary`/`secondary` НЕ гарантированно жёлтый/зелёный, а
/// warning должен читаться именно как «жёлтое предупреждение». Это и есть единое
/// место light/dark-пресетов: меняем тут — меняется во всех плашках.
BannerColors bannerColors(BuildContext context, BannerSeverity severity) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  switch (severity) {
    case BannerSeverity.info:
      return BannerColors(
        background: cs.primaryContainer,
        border: cs.onPrimaryContainer.withValues(alpha: 0.35),
        foreground: cs.onPrimaryContainer,
        action: cs.onPrimaryContainer,
      );
    case BannerSeverity.error:
      return BannerColors(
        background: cs.errorContainer,
        border: cs.onErrorContainer.withValues(alpha: 0.35),
        foreground: cs.onErrorContainer,
        action: cs.onErrorContainer,
      );
    case BannerSeverity.warning:
      // Тёмная тема: глубокий полупрозрачный янтарный фон + светлый текст.
      // Светлая: классический amber.shade100 + тёмный текст.
      return BannerColors(
        background: isDark
            ? Colors.amber.shade900.withValues(alpha: 0.18)
            : Colors.amber.shade100,
        border: isDark ? Colors.amber.shade700 : Colors.amber.shade400,
        foreground: isDark ? Colors.amber.shade100 : Colors.amber.shade900,
        action: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
      );
    case BannerSeverity.success:
      return BannerColors(
        background: isDark
            ? Colors.green.shade900.withValues(alpha: 0.18)
            : Colors.green.shade100,
        border: isDark ? Colors.green.shade700 : Colors.green.shade400,
        foreground: isDark ? Colors.green.shade100 : Colors.green.shade900,
        action: isDark ? Colors.green.shade200 : Colors.green.shade900,
      );
  }
}

/// Цвет одиночной иконки (без фоновой плашки) — напр. ⚠ в заголовке поля или
/// в таб-баре, на обычном `surface`-фоне. В отличие от [bannerColors] (который
/// даёт `on*Container` для контраста с контейнером), здесь нужен «акцентный»
/// токен на фоне surface. Theme-aware. Заменяет россыпь `Colors.amber.shade700`.
Color bannerIconColor(BuildContext context, BannerSeverity severity) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return switch (severity) {
    BannerSeverity.info => cs.primary,
    BannerSeverity.error => cs.error,
    BannerSeverity.warning =>
      isDark ? Colors.amber.shade300 : Colors.amber.shade800,
    BannerSeverity.success =>
      isDark ? Colors.green.shade300 : Colors.green.shade700,
  };
}
