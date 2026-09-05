import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';

import '../../config/consts.dart';
import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../../models/source_chain.dart' show kChainOutboundType;
import '../json_clone.dart';
import '../parser/uri_utils.dart' show isValidRealityPublicKey;
import '../parser/utls_fingerprint.dart';
import '../settings_storage.dart' show SettingsStorage, TunAppsConfig;
import 'preset_expand.dart';
import 'rule_set_registry.dart';

// Barrel stitching the post-step part files into one library via `part`/`part of`.
// Каждый part = один шаг sing-box config post-processing'а.
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
part 'post_steps/heal_preset_tag_prefix.dart';
part 'post_steps/heal_dangling_resolve_servers.dart';
part 'post_steps/heal_dangling_dns_resolvers.dart';
part 'post_steps/heal_legacy_dns_strategy.dart';
part 'post_steps/heal_unknown_utls_fingerprints.dart';
part 'post_steps/heal_invalid_reality.dart';
part 'post_steps/sanitize_outbound_graph.dart';
