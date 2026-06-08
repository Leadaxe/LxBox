import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../settings_storage.dart' show SettingsStorage, TunAppsConfig;
import 'preset_expand.dart';
import 'rule_set_registry.dart';

// §089: post_steps split by responsibility (behavior-preserving).
// Single library composed via `part`/`part of` — все приватные хелперы и
// публичный API остаются в одной библиотеке, поэтому importers и тесты не
// меняются. Каждый part = один шаг sing-box config post-processing'а,
// порядок и трансформы сохранены 1:1.
//
//   - tls_transforms.dart — applyMixedCaseSni / applyTlsFragment (§028)
//   - tun_packages.dart   — applyTunPackages (§046)
//   - dns_rules.dart      — applyCustomDns / resolveDnsRulesList (§061+§033)
//   - custom_rules.dart   — applyPresetBundles / applyCustomRules /
//                           applyAllCustomRules / _outboundToRoute (§030+§062)
//   - dns_servers.dart    — resolveDnsServersList / resolveDnsServersBodies
//                           (§043+§044)
part 'post_steps/tls_transforms.dart';
part 'post_steps/tun_packages.dart';
part 'post_steps/dns_rules.dart';
part 'post_steps/custom_rules.dart';
part 'post_steps/dns_servers.dart';
