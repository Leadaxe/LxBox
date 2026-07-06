part of '../settings_storage.dart';

// §125 — Каналы роутинга (`channels[]`) для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`. Паттерн read-весь-объект → mutate-copy → rewrite-atomically
// идентичен `network.dart:_setGroupPing` (эталон per-group storage).
//
// `channels[]` заменяет `enabled_groups[]` (deprecated) и статичные
// `template.presetGroups` как source-of-truth состава каналов. Миграция
// (`_migrateChannelsIfNeeded`) на первом запуске seed'ит channels из template.

Future<List<Channel>> _getChannels() async {
  final data = await _load();
  final raw = data['channels'] as List<dynamic>? ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(Channel.fromJson).toList();
}

Future<void> _setChannels(List<Channel> channels, {bool flush = true}) async {
  final data = await _load();
  data['channels'] = channels.map((c) => c.toJson()).toList();
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113 — config-significant
  if (flush) await _save();
}

/// Первый свободный 'vpn-N' (N∈2..10; vpn-1 всегда существует инвариантом).
/// throws [StateError] при лимите [kMaxChannels].
Future<Channel> _addChannel({String? label}) async {
  final channels = (await _getChannels()).toList();
  if (channels.length >= kMaxChannels) {
    throw StateError('channel limit ($kMaxChannels) reached');
  }
  final used = channels.map((c) => c.tag).toSet();
  final tag = [for (var i = 2; i <= kMaxChannels; i++) 'vpn-$i']
      .firstWhere((t) => !used.contains(t));
  // §198 — дефолтный label с цифрой-в-кружке по номеру (VPN ②…VPN ⑩).
  final defaultLabel = defaultChannelLabel(channelNumberOf(tag) ?? 0);
  final ch = Channel(tag: tag, label: label ?? defaultLabel, enabled: true);
  channels.add(ch);
  await _setChannels(channels);
  return ch;
}

Future<void> _updateChannel(Channel channel) async {
  final channels = (await _getChannels()).toList();
  final i = channels.indexWhere((c) => c.tag == channel.tag);
  if (i < 0) throw StateError('channel not found: ${channel.tag}');
  // §202 — переход enabled: true → false делает канал невалидной мишенью
  // (как удаление): билдер деградирует только ВЫХЛОП конфига, а route_final /
  // custom-rule outbound в storage остаются висеть на выключенном теге →
  // «надо идти пересохранять». Лечим storage сразу (route_final / правило →
  // vpn-1). Решение B (28.06.2026): необратимо — повторное включение канала
  // НЕ воскрешает старую ссылку (правила привязаны к активной конфигурации).
  final wasEnabled = channels[i].enabled;
  channels[i] = channel;
  if (wasEnabled && !channel.enabled) {
    await _setChannels(channels, flush: false); // единый flush в _healChannelRefs
    await _healChannelRefs(channel.tag);
  } else {
    await _setChannels(channels);
  }
}

/// Удалить канал. vpn-1 неудаляем (throws). Любая ссылка на удалённый tag
/// (route_final / custom-rule outbound) немедленно переводится на 'vpn-1'
/// для UI-консистентности; билдер дополнительно схлопывает dangling при сборке
/// (§172-паттерн), так что детур/прочее тоже деградирует.
Future<void> _deleteChannel(String tag) async {
  if (tag == 'vpn-1') throw StateError('vpn-1 is not deletable');
  final channels = (await _getChannels()).toList()
    ..removeWhere((c) => c.tag == tag);
  await _setChannels(channels, flush: false); // один flush в _healChannelRefs
  await _healChannelRefs(tag);
}

/// Перевод dangling-ссылок на канал → 'vpn-1'. Вызывается, когда канал
/// перестаёт быть валидной route-мишенью: удалён (§125 F4.5) ИЛИ выключен
/// (§202). Без flush до конца — атомарный финальный `_save()`.
Future<void> _healChannelRefs(String deletedTag) async {
  // route_final
  final routeFinal = await SettingsStorage.getRouteFinal();
  if (routeFinal == deletedTag) {
    await SettingsStorage.saveRouteFinal('vpn-1', flush: false);
  }
  // custom-rule outbounds — kind-agnostic через общие `outbound`/`withOutbound`:
  // inline/srs — поле `outbound`; preset — override `varsValues['outbound']`
  // (§033 Expansion §5), без heal он уезжал в expandPreset dangling-тегом →
  // fatal DanglingOutboundRef, VPN не стартует; json — '' (deletedTag всегда
  // непустой 'vpn-N', не сматчит). reject/direct-out — не channel-tag'и, под
  // deletedTag не подпадут. Build-time страховки для rule-outbound НЕТ
  // (healDanglingDetours §172 чинит только detour-поля, валидатор §141 P0.1
  // блокирует, не лечит) — storage-heal здесь единственное самолечение.
  final rules = await SettingsStorage.getCustomRules();
  var changed = false;
  final healed = rules.map((r) {
    if (r.outbound == deletedTag) {
      changed = true;
      return r.withOutbound('vpn-1');
    }
    return r;
  }).toList();
  if (changed) {
    await SettingsStorage.saveCustomRules(healed, flush: false);
  }
  await _save();
}

// ---------------------------------------------------------------------------
// §125 F0.3 — Миграция enabled_groups[] → channels[] (one-shot, first-run seed).
//
// Guard-ключ `channels_migrated` (паттерн `_hasDefaultsSeeded`). Принимает
// template.presetGroups параметром (storage-слой не знает про template —
// вызывается из main() init с готовым шаблоном). Идемпотентна: повторный вызов
// при уже существующем `channels` или поднятом флаге — no-op.
// ---------------------------------------------------------------------------

Future<void> _migrateChannelsIfNeeded(List<PresetGroup> presets) async {
  final data = await _load();
  if (data['channels'] is List) return; // уже есть — не трогаем
  if (data['channels_migrated'] == true) return; // мигрировано (пусто) — не пересеивать

  final enabled = await SettingsStorage.getEnabledGroups(); // legacy set
  final channels = <Channel>[];
  for (final p in presets) {
    if (p.tag == kAutoOutboundTag) continue; // глобальный ✨auto НЕ канал
    final isEnabled = p.tag == 'vpn-1'
        ? true // vpn-1 форсим (продуктовый инвариант)
        : (enabled.isEmpty ? p.defaultEnabled : enabled.contains(p.tag));
    final auto = p.addOutbounds.contains(kAutoOutboundTag)
        ? _seedAutoFromTemplate(presets)
        : null;
    channels.add(Channel.seedFromPreset(p, enabled: isEnabled, auto: auto));
  }

  data['channels'] = channels.map((c) => c.toJson()).toList();
  data['channels_migrated'] = true;
  SettingsStorage._cache = data;
  await _save();
}

/// `ChannelAuto` из глобального ✨auto-пресета (его urltest-опции). Значения —
/// из `presetGroups` где tag == ✨auto. ВНИМАНИЕ: `options` здесь — СЫРОЙ
/// template (`@urltest_*`-плейсхолдеры НЕ резолвены — var-substitution идёт
/// позже, в билдере). Поэтому значения могут быть `"@urltest_tolerance"`-строкой,
/// числом ИЛИ числом-в-строке. Парсим терпимо: нерезолвенный `@`-плейсхолдер
/// или мусор → дефолт. idle_timeout="30m", interrupt=false (мягкий urltest).
ChannelAuto _seedAutoFromTemplate(List<PresetGroup> presets) {
  final autoPreset = presets.where((p) => p.tag == kAutoOutboundTag).firstOrNull;
  final opts = autoPreset?.options ?? const {};

  // Строка-значение, но не нерезолвенный `@var`-плейсхолдер.
  String? str(Object? v) {
    if (v is! String || v.isEmpty || v.startsWith('@')) return null;
    return v;
  }

  // tolerance из num / числа-в-строке; плейсхолдер/мусор → null.
  int? toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String && !v.startsWith('@')) return int.tryParse(v.trim());
    return null;
  }

  return ChannelAuto(
    url: str(opts['url']) ?? 'https://cp.cloudflare.com/generate_204',
    interval: str(opts['interval']) ?? '5m',
    tolerance: toInt(opts['tolerance']) ?? 50,
    idleTimeout: '30m',
    interruptExistConnections: false,
  );
}
