import '../../config/consts.dart';
import '../../models/emit_context.dart';
import '../../models/server_list.dart';

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
    final skipDetour =
        !detourPolicy.useDetourServers || detourPolicy.overrideDetour.isNotEmpty;

    for (final server in nodes) {
      final raw = server.getEntries(ctx, skipDetour: skipDetour);
      final main = raw.main;
      final detours = raw.detours;

      // Allocate tags (детуры первыми — чтобы main мог сослаться на tag).
      for (final d in detours) {
        d.map['tag'] = ctx.allocateTag(_withPrefix(d.tag));
      }
      main.map['tag'] = ctx.allocateTag(_withPrefix(main.tag));

      // Применить detour policy (только main ссылается на детур).
      if (detourPolicy.overrideDetour.isNotEmpty) {
        main.map['detour'] = detourPolicy.overrideDetour;
      } else if (!detourPolicy.useDetourServers) {
        main.map.remove('detour');
      } else if (detours.isNotEmpty) {
        main.map['detour'] = detours.first.tag;
      }

      // Регистрация: outbounds/endpoints через sealed-switch внутри ctx.
      for (final e in raw.all) {
        ctx.addEntry(e);
      }

      // Preset-группы:
      //   - main без `⚙` префикса (обычный endpoint) — всегда в selector и auto;
      //   - main с `⚙` (сам юзер пометил ноду как detour-сервер, см. toggle
      //     в node_settings_screen) — регистрируется по per-server политике,
      //     как обычные chained-detours. Default обе OFF → main-as-detour
      //     скрыт в selector и ✨auto, доступен только как звено цепочки.
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

  String _withPrefix(String base) =>
      tagPrefix.isEmpty ? base : '$tagPrefix $base';
}
