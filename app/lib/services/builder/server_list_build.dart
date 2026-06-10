import '../../config/consts.dart';
import '../../models/emit_context.dart';
import '../../models/server_list.dart';
import '../tag_resolver.dart';

/// Сборка одной подписки в контекст `EmitContext`.
///
/// Живёт в builder-слое, чтобы модель (`lib/models/server_list.dart`)
/// осталась чистой data: без зависимостей на `SingboxEntry`/`EmitContext`.
extension ServerListBuild on ServerList {
  /// 1. Для каждого сервера решает, нужно ли пропустить детур.
  /// 2. Зовёт `server.getEntries(ctx, skipDetour)`.
  /// 3. На каждом entry применяет `_updateEntry`: allocateTag,
  ///    подмена поля `detour` по политике подписки.
  /// 4. Регистрирует entry в ctx: addEntry, selector/auto-списки по политике.
  void build(EmitContext ctx) {
    if (!enabled) return;
    // §073: replaceMode = override + replace toggle ON. Append mode
    // (default false) keeps raw chain (skipDetour: false) и подставляет
    // overrideDetour хвостом цепочки.
    final replaceMode = detourPolicy.overrideDetour.isNotEmpty &&
        detourPolicy.replaceDetourChain;
    final skipDetour = !detourPolicy.useDetourServers || replaceMode;

    for (final server in nodes) {
      final raw = server.getEntries(ctx, skipDetour: skipDetour);
      final main = raw.main;
      final detours = raw.detours;

      // Allocate tags (детуры первыми — чтобы main мог сослаться на tag).
      for (final d in detours) {
        d.map['tag'] = ctx.allocateTag(TagResolver.displayTag(tagPrefix, d.tag));
      }
      main.map['tag'] =
          ctx.allocateTag(TagResolver.displayTag(tagPrefix, main.tag));

      // Применить detour policy.
      if (replaceMode) {
        // REPLACE — цепочка дропнута (skipDetour=true), main → override.
        main.map['detour'] = detourPolicy.overrideDetour;
      } else if (!detourPolicy.useDetourServers) {
        main.map.remove('detour');
      } else if (detourPolicy.overrideDetour.isNotEmpty) {
        // §073 APPEND — нативная цепочка сохранена, override хвостом.
        if (detours.isEmpty) {
          // Цепочки нет в raw config → 1-hop (как replace).
          main.map['detour'] = detourPolicy.overrideDetour;
        } else {
          // node → detours.first → ... → detours.last → overrideDetour
          main.map['detour'] = detours.first.tag;
          detours.last.map['detour'] = detourPolicy.overrideDetour;
        }
      } else if (detours.isNotEmpty) {
        main.map['detour'] = detours.first.tag;
      }

      // Регистрация: outbounds/endpoints через sealed-switch внутри ctx.
      for (final e in raw.all) {
        ctx.addEntry(e);
      }

      // Preset-группы:
      //   - main без `⚙` префикса (обычный endpoint) — всегда в selector и auto;
      //   - main с `⚙` (detour-маркер из парсинга подписки / `TagResolver`;
      //     §094 убрал ручной node_settings toggle) — регистрируется по
      //     per-server политике, как обычные chained-detours. Default обе OFF →
      //     main-as-detour скрыт в selector и ✨auto, доступен только как звено.
      //   - chained-detours (raw.detours) — как раньше, по той же политике.
      final isMainAsDetour = main.tag.startsWith(kDetourTagPrefix);
      if (!isMainAsDetour) {
        ctx.addToSelectorTagList(main);
        ctx.addToAutoList(main);
      } else {
        if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(main);
        if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(main);
      }
      for (final d in detours) {
        if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(d);
        if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(d);
      }
    }
  }
}
