import 'package:flutter/material.dart';

/// §125 — отображение служебных нод (direct / auto) человекочитаемым
/// label'ом + иконкой вместо голого tag'а.
///
/// Тип берётся ТОЧНО из сохранённого конфига (`ParsedConfig.byTag[tag].type`),
/// а не по маске имени: `direct` → «Direct», `urltest` → «Auto». Так теги
/// auto-двойников (`vpn-1-auto`, ...) и `direct-out` подменяются надёжно,
/// без зависимости от их конкретного имени.
class SpecialNodeDisplay {
  const SpecialNodeDisplay({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

/// Возвращает display-подмену для служебной ноды по её outbound-[type] из
/// конфига, либо `null` для обычной прокси-ноды (показывается её tag как есть).
///
/// - `direct`  → «Direct» (прямой выход наружу).
/// - `urltest` → «Auto» (latency-test группа, авто-выбор быстрейшего).
SpecialNodeDisplay? specialNodeDisplayForType(String? outboundType) {
  switch (outboundType) {
    case 'direct':
      return const SpecialNodeDisplay(label: 'Direct', icon: Icons.public);
    case 'urltest':
      // ✨ — узнаваемая иконка auto (как был эмодзи в старом теге '✨auto').
      return const SpecialNodeDisplay(
          label: 'Auto', icon: Icons.auto_awesome);
    default:
      return null;
  }
}
