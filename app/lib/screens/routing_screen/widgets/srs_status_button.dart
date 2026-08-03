import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../models/parser_config.dart';

/// ☁-кнопка статуса SRS для `CustomRuleSrs`-правила. Показывает спиннер при
/// загрузке, ✅ если файл закэширован, ☁ если нет.
///
/// §366 — когда файл уже скачан, рядом появляется кнопка ⟳ (ручное
/// обновление). ☁ остаётся индикатором «скачано / не скачано»: пока файла
/// нет, обновлять нечего и ⟳ не показывается.
class SrsStatusButton extends StatelessWidget {
  const SrsStatusButton({
    super.key,
    required this.rule,
    required this.downloading,
    required this.cached,
    required this.onPressed,
    this.onRefresh,
  });

  final CustomRule rule;
  final bool downloading;
  final bool cached;
  final VoidCallback onPressed;

  /// §366 — ручное обновление уже скачанного `.srs`. Null → кнопка ⟳ не
  /// рисуется (напр. на экранах, где обновление не предусмотрено).
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (downloading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }
    // NB: без tooltip — иначе long-press на иконке показывает тултип и
    // перехватывает контекст-меню родительского GestureDetector.
    final cloud = IconButton(
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(
        cached ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
        color: cached ? Colors.green : cs.onSurfaceVariant,
      ),
      onPressed: onPressed,
    );
    final refresh = onRefresh;
    if (!cached || refresh == null) return cloud;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        cloud,
        IconButton(
          iconSize: 18,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(Icons.update, color: cs.onSurfaceVariant),
          onPressed: refresh,
        ),
      ],
    );
  }
}

/// ☁-кнопка для preset-правил с remote rule_set'ами. "cached" = все
/// remote rule_set'ы пресета имеют локальный `.srs` (spec §011 compliance,
/// task 011).
class PresetSrsStatusButton extends StatelessWidget {
  const PresetSrsStatusButton({
    super.key,
    required this.rule,
    required this.preset,
    required this.downloading,
    required this.cached,
    required this.onTap,
    required this.onLongPress,
    this.onRefresh,
  });

  final CustomRulePreset rule;
  final SelectableRule preset;
  final bool downloading;
  final bool cached;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// §366 — ручное обновление всех скачанных rule-set'ов пресета. Дублирует
  /// пункт long-press меню явной кнопкой: меню не находят.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (downloading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }
    // Намеренно InkWell, а не IconButton внутри GestureDetector — GestureDetector
    // с HitTestBehavior.opaque перехватывал tap ДО IconButton.onPressed. InkWell
    // получает и tap, и long-press одним нодом.
    final cloud = SizedBox(
      width: 32,
      height: 32,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Icon(
          cached ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
          size: 18,
          color: cached ? Colors.green : cs.onSurfaceVariant,
        ),
      ),
    );
    final refresh = onRefresh;
    if (!cached || refresh == null) return cloud;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        cloud,
        SizedBox(
          width: 32,
          height: 32,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: refresh,
            child: Icon(Icons.update,
                size: 18, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
