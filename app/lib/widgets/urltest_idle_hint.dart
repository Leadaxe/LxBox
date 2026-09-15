import 'package:flutter/material.dart';

import '../services/core_duration.dart';
import '../services/l10n/locale_controller.dart';

/// §442 — до чего сборка поднимет `idle_timeout`: строка [interval], если он
/// больше [idleTimeout], иначе null. Значения — действующие, какими уйдут в
/// хранение (пустое поле уже заменено умолчанием формы). Разбор тем же
/// хелпером, что у санитайзера (правила ядра, суффикс `d`); нераспознанное —
/// без подсказки, санитайзер его тоже не трогает.
String? urltestIdleRaiseTarget(String interval, String idleTimeout) {
  final iv = parseCoreDurationNanos(interval);
  final idle = parseCoreDurationNanos(idleTimeout);
  if (iv == null || idle == null || iv <= 0 || idle <= 0) return null;
  return iv > idle ? interval : null;
}

/// §442 — серая подсказка под полями interval / idle timeout: сохранить
/// можно, санитайзер сборки поднимет idle_timeout до [target]. Подсказка, а
/// не ошибка — говорит, что окажется в конфиге. Показывать, только когда
/// [urltestIdleRaiseTarget] вернул значение.
class UrltestIdleRaiseHint extends StatelessWidget {
  const UrltestIdleRaiseHint({super.key, required this.target});

  final String target;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.info_outline, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
              getLocalText.s(
                  "Idle timeout will be raised to %s when the config is built",
                  target),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ),
      ],
    );
  }
}
