// ignore_for_file: depend_on_referenced_packages

// Сброс глобального состояния процесса между тест-файлами.
//
// В CI тест-файлы идут сборками (`tool/gen_test_bundles.dart`): много файлов в
// одном изоляте. Тесты писались под свежий изолят на файл, поэтому всё, что
// живёт дольше файла (статики, синглтоны `.I`, подменённые платформенные
// реализации, моки каналов, незавершённые future-замки), сборка обязана
// вернуть к состоянию свежего процесса перед каждым файлом и после него.
//
// Новый глобальный кэш в lib, который тест может испачкать, — сброс сюда
// (`@visibleForTesting`-метод в lib, поведение приложения не меняется).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/screens/home/widgets/node_list.dart'
    show resetPoolBadgeCache;
import 'package:lxbox/screens/mixin_edit_screen.dart';
import 'package:lxbox/services/app_info_cache.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/automation/event_emitter.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/core_reject/core_reject_runner.dart'
    show resetCoreRejectRunnerForTesting;
import 'package:lxbox/services/core_reject/core_reject_state.dart';
import 'package:lxbox/services/crash_banner_state.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/donate_methods.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/install_source.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup_slice.dart'
    show overrideBackupFieldsForTesting;
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/platform_channels.dart';
import 'package:lxbox/services/rule_set_downloader.dart';
import 'package:lxbox/services/selector_info.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/sources.dart'
    show fetchBackoffsForTesting;
import 'package:lxbox/services/subscription/subscription_identity.dart';
import 'package:lxbox/services/support/active_time_tracker.dart';
import 'package:lxbox/services/support/support_message.dart';
import 'package:lxbox/services/support/support_state.dart';
import 'package:lxbox/services/tailscale_state/state_store.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/services/url_launcher.dart';
import 'package:lxbox/services/usage_region.dart';
import 'package:lxbox/services/warp/warp_endpoint_picker.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';
import 'package:lxbox/services/workspaces/workspace_store.dart';
import 'package:lxbox/widgets/lx_code_editor.dart';

/// Каналы, которые тесты мокают через `setMockMethodCallHandler` /
/// `setMockStreamHandler`. Мок без снятия переживает файл.
const _mockedChannels = <String>[
  PlatformChannels.methods,
  PlatformChannels.statusEvents,
  PlatformChannels.utils,
  PlatformChannels.wifiHistory,
  PlatformChannels.coreLog,
  PlatformChannels.ccStatus,
  PlatformChannels.ccOutbounds,
  PlatformChannels.ccGroups,
  PlatformChannels.ccConnections,
  PlatformChannels.ccDns,
  PlatformChannels.ccTailscale,
  PlatformChannels.ccTailscalePing,
  'plugins.flutter.io/path_provider',
];

bool _captured = false;
late PathProviderPlatform _pathProvider;
HttpOverrides? _bindingHttpOverrides;

/// Снимок «свежего процесса» до первого файла: исходная реализация
/// path_provider и HttpOverrides тестового биндинга. Зовёт сборка первой
/// строкой `main()`, до объявления тестов.
void captureTestGlobals() {
  if (_captured) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  _pathProvider = PathProviderPlatform.instance;
  _bindingHttpOverrides = HttpOverrides.current;
  _captured = true;
}

/// Вернуть глобальное состояние к состоянию свежего изолята.
///
/// [binding] — файл работает с тестовым биндингом (`testWidgets`,
/// `TestWidgetsFlutterBinding`). Биндинг подменяет `HttpOverrides` (любой
/// HTTP-запрос — 400); файлу без биндинга (живой `HttpServer` на loopback)
/// подмена не нужна, в одиночном прогоне её у него нет.
void resetTestGlobals({bool binding = true}) {
  captureTestGlobals();

  // Платформа: path_provider, HTTP, моки каналов.
  PathProviderPlatform.instance = _pathProvider;
  HttpOverrides.global = binding ? _bindingHttpOverrides : null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in _mockedChannels) {
    messenger.setMockMessageHandler(name, null);
  }

  // Хранилище и его производные кэши.
  SettingsStorage.resetCacheForTesting();
  SettingsStorage.nodeListTwoColumns.value = true;
  ConfigDirtyCheck.resetForTesting();
  SubscriptionController.debugTailscaleStateRoot = null;
  SubscriptionController.debugCoreStopped = null;
  RuleSetDownloader.resetCacheForTesting();
  WorkspaceStore.I.resetForTesting();
  WorkspaceController.I.resetForTesting();
  TailscaleStateStore.I.resetForTesting();

  // Реестр контракта и секции разбора.
  ContractRegistry.I.resetForTesting();
  MapperSections.I.resetForTesting();
  overrideBackupFieldsForTesting(null);

  // Синглтоны состояния.
  AppLog.I.resetForTesting();
  SelectorInfo.I.resetForTesting();
  TrafficProfiler.I.resetForTesting();
  CoreRejectState.I.resetForTest();
  resetCoreRejectRunnerForTesting();
  CrashBannerState.I.resetForTest();
  ActiveTimeTracker.I.resetForTesting();
  SupportState.I.resetCacheForTesting();
  SupportMessageService.I
    ..httpClientForTesting = null
    ..appVersionForTesting = null;
  DonateMethods.I
    ..resetCacheForTesting()
    ..httpClientForTesting = null;
  AutomationEventEmitter.I.debugConfigureForTest();
  DebugRegistry.I
    ..home = null
    ..sub = null
    ..autoUpdater = null;
  HapticService.I.enabled = true;
  LocaleController.I.resetForTesting();

  // Статические кэши и подмены.
  UrlLauncher.resetTelevisionCacheForTesting();
  UsageRegion.resetForTest();
  UsageRegion.detectorOverride = null;
  AppInfoCache.resetForTest();
  InstallSourceResolver.resetForTest();
  WarpEndpointPicker.resetForTest();
  CoreVersionCache.resetForTest();
  fetchBackoffsForTesting = null;
  SubscriptionIdentity.userAgentOverride = '';
  SubscriptionIdentity.sendHwid = false;
  SubscriptionIdentity.hwid = '';
  SubscriptionIdentity.deviceOsOverride = '';
  SubscriptionIdentity.verOsOverride = '';
  SubscriptionIdentity.deviceModelOverride = '';
  SubscriptionIdentity.osVersion = '';
  SubscriptionIdentity.deviceModel = '';
  resetPoolBadgeCache();
  LxCodeEditorState.debugResetMagnifier();
  MixinEditScreen.debugResetSuggest();
}
