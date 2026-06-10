import 'package:flutter/material.dart';

/// Тонкий баннер фонового прогресса под connect-controls: спиннер + текст
/// текущей операции подписок. Показывается пока `SubscriptionController` busy
/// и есть непустой `progressMessage`.
class ProgressBanner extends StatelessWidget {
  const ProgressBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
