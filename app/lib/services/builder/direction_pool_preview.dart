/// §674 — превью фильтра Направления без поднятого туннеля.
///
/// Состав селектора `<tag>` определяет сборка конфига в Dart, а не ядро:
/// превью берёт пул кандидатов из того же сборщика ([buildDirectionPool]) по
/// снимку хранилища и источников. Снимок групп ядра для превью не нужен, и
/// превью работает одинаково при поднятом и опущенном туннеле.
///
/// Без побочных эффектов: хранилище только читается (засев пресетов, каталоги
/// Tailscale и прочие записи `_generate` здесь не делаются), сети нет,
/// состояние контроллеров не меняется.
library;

import 'dart:isolate';

import '../../controllers/subscription_controller/cache_rehydrate.dart'
    show ParseEnvSnapshot;
import '../../models/node_spec.dart' show NodeSpec;
import '../../models/parser_config.dart';
import '../../models/server_list.dart';
import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'build_config.dart';
import 'core_chain_capability.dart';

/// Настройки сборки из хранилища (только чтение). Общий источник для
/// `SubscriptionController._generate` и превью §674: превью обязано видеть
/// тот же вход сборки, иначе его пул разойдётся с составом селектора.
Future<BuildSettings> readStoredBuildSettings({
  String tailscaleStateRoot = '',
  Map<NodeSpec, String>? tailscaleStateDirs,
}) async =>
    BuildSettings(
      userVars: await SettingsStorage.getAllVars(),
      enabledGroups: await SettingsStorage.getEnabledGroups(),
      customRules: await SettingsStorage.getCustomRules(),
      routeFinal: await SettingsStorage.getRouteFinal(),
      directions: await SettingsStorage.getDirections(), // §125
      chains: await SettingsStorage.getChains(), // §393 C2
      // §393 C5 — гейт возможностей ядра живёт в СБОРКЕ, не в UI: цепочку
      // может добавить и Debug API, и restore бэкапа с новой машины, а
      // отвергнутый ядром конфиг оставит пользователя без VPN целиком.
      // Кэшируется на сессию — версия ядра вкомпилирована в APK и не меняется
      // (см. [CoreVersionCache]).
      coreVersion: await CoreVersionCache.ensure(BoxVpnClient().getCoreVersion),
      tunApps: await SettingsStorage.getTunApps(),
      vpnMode: await SettingsStorage.getVpnMode(),
      idleSuspend: await SettingsStorage.getIdleSuspend(), // §215
      idleSuspendReachable:
          await SettingsStorage.getIdleSuspendReachable(), // §272
      wgBuildMax: await SettingsStorage.getWgBuildMax(), // §542
      wgLazyBuild: await SettingsStorage.getWgLazyBuild(), // §542
      tailscaleStateRoot: tailscaleStateRoot,
      tailscaleStateDirs: tailscaleStateDirs,
    );

/// Списки источников так, как их видит сборка: §565 / задача 570 — выбор
/// члена групп ручного рода (`groupDefaults`) наложен на копии узлов.
List<ServerList> listsForBuild(Iterable<ServerList> lists) => [
      for (final l in lists)
        if (l is SubscriptionServers && l.groupDefaults.isNotEmpty)
          l.withGroupDefaultsApplied()
        else
          l,
    ];

/// Пул кандидатов Направлений по хранилищу: теги, из которых сборка
/// формирует состав `<tag>` до фильтра Направления. Считается в отдельном
/// isolate (тысячи узлов — заметная работа); ошибка воркера — откат на main,
/// а не пустое превью.
Future<List<String>> directionPoolPreview(Iterable<ServerList> lists) async {
  final input = DirectionPoolInput(
    lists: listsForBuild(lists),
    settings: await readStoredBuildSettings(),
    template: await TemplateLoader.load(),
  );
  final worker = directionPoolWorkerForTesting;
  if (worker != null) return worker(input);
  try {
    return await _poolInIsolate(input, ParseEnvSnapshot.capture());
  } catch (e) {
    AppLog.I.warning('Direction pool preview: worker failed ($e), main');
    return input.run();
  }
}

/// Тестовая подмена воркера (по умолчанию — isolate). `(input) => input.run()`
/// считает пул на main.
Future<List<String>> Function(DirectionPoolInput input)?
    directionPoolWorkerForTesting;

/// Вход воркера: всё, что нужно сборке до пула, уже прочитано на main.
final class DirectionPoolInput {
  const DirectionPoolInput({
    required this.lists,
    required this.settings,
    required this.template,
  });

  final List<ServerList> lists;
  final BuildSettings settings;
  final WizardTemplate template;

  Future<List<String>> run() =>
      buildDirectionPool(lists: lists, settings: settings, template: template);
}

Future<List<String>> _poolInIsolate(
        DirectionPoolInput input, ParseEnvSnapshot env) =>
    Isolate.run(() async {
      await env.install();
      return input.run();
    }, debugName: 'direction-pool');
