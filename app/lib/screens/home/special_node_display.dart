import 'package:flutter/material.dart';

import '../../services/template_loader.dart';

/// §125/§267 — отображение служебных нод (direct / auto / block) человекочитаемым
/// label'ом + иконкой вместо голого tag'а.
///
/// Тип берётся ТОЧНО из сохранённого конфига (`ParsedConfig.byTag[tag].type`),
/// а не по маске имени. Так теги auto-двойников (`vpn-1-auto`, ...) и `direct-out`
/// подменяются надёжно, без зависимости от их конкретного имени.
///
/// §267 — служебная нода описана в шаблоне (`group_templates.magic_nodes`) по
/// role-ключу. Здесь ветвимся по role (см. `_roleForOutboundType` — маппинг
/// sing-box outbound-type → role). `label` — зеркало `magic_nodes.*.title`
/// (`Auto`/`Direct`/`Block`); иконка остаётся в коде (IconData не сериализуется
/// в шаблон и тришейкается компилятором).
class SpecialNodeDisplay {
  const SpecialNodeDisplay({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

/// Маппинг sing-box outbound-`type` → role служебной ноды `magic_nodes`.
/// `null` — обычная прокси-нода (не служебная).
String? _roleForOutboundType(String? outboundType) {
  switch (outboundType) {
    case 'urltest':
      return 'auto';
    case 'direct':
      return 'direct';
    case 'block':
      return 'block';
    default:
      return null;
  }
}

/// Возвращает display-подмену для служебной ноды по её outbound-[type] из
/// конфига, либо `null` для обычной прокси-ноды (показывается её tag как есть).
///
/// - `direct`  → «Direct» (прямой выход наружу).
/// - `urltest` → «Auto» (latency-test группа, авто-выбор быстрейшего).
/// - `block`   → «Block» (дроп трафика, §201).
SpecialNodeDisplay? specialNodeDisplayForType(String? outboundType) {
  final role = _roleForOutboundType(outboundType);
  if (role == null) return null;
  // §279 Phase 2 — титул берём из локализованного шаблона (`MagicNode.title`),
  // хардкод-зеркало осталось только fallback'ом на холодный кэш (до первого
  // TemplateLoader.load; при смене локали кэш прогрет ДО notifyListeners).
  final title = TemplateLoader.cachedOrNull()?.groupTemplates.magicNodes[role]
      ?.title;
  switch (role) {
    case 'direct':
      return SpecialNodeDisplay(
          label: _orFallback(title, 'Direct'), icon: Icons.public);
    case 'auto':
      // ✨ — узнаваемая иконка auto (как был эмодзи в старом теге '✨auto').
      return SpecialNodeDisplay(
          label: _orFallback(title, 'Auto'), icon: Icons.auto_awesome);
    case 'block':
      return SpecialNodeDisplay(
          label: _orFallback(title, 'Block'), icon: Icons.block);
    default:
      return null;
  }
}

String _orFallback(String? title, String fallback) =>
    (title == null || title.isEmpty) ? fallback : title;
