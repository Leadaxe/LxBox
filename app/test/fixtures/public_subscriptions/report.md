# Корпус публичных подписок — прогон разбора

Контракт: `1.1.107`. Подписок: 69. Узлов: 60588.

Сгенерировано `tool/public_subs/run.dart`; править руками незачем — перезапишется. Методика: `docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md`.

## По подпискам

| id | вид | узлов | типы | отбраковки | предупреждения | мс |
|---|---|--:|---|---|---|--:|
| `01-github-vless-universal` | uri_lines | 95 | `vless`&nbsp;95 | — | `reality_fp_not_chrome`&nbsp;5, `duplicates_collapsed`&nbsp;2, `field_conflict`&nbsp;1 | 591 |
| `02-github-vless-lite` | uri_lines | 95 | `vless`&nbsp;95 | `provider_banner_link`&nbsp;4 | `reality_fp_not_chrome`&nbsp;5, `duplicates_collapsed`&nbsp;2, `field_conflict`&nbsp;1 | 212 |
| `03-github-vless` | uri_lines | 0 | — | `provider_banner_link`&nbsp;3 | — | 5 |
| `04-github-vless-reality-white-lists-rus-mobile` | uri_lines | 25 | `vless`&nbsp;18, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `duplicates_collapsed`&nbsp;2, `reality_fp_random_pinned`&nbsp;1, `tls_not_applicable_quic`&nbsp;1 | 44 |
| `05-github-white-cidr-ru-checked` | uri_lines | 5 | `vless`&nbsp;5 | — | — | 4 |
| `06-github-black-vless-rus-mobile` | uri_lines | 132 | `vless`&nbsp;116, `hysteria2`&nbsp;9, `vmess`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;14, `duplicates_collapsed`&nbsp;10, `tls_insecure`&nbsp;5, `tls_not_applicable_quic`&nbsp;5, `uri_param_unknown`&nbsp;5, `reality_fp_random_pinned`&nbsp;4, `unknown_key`&nbsp;2 | 124 |
| `07-github-byewhitelists2` | uri_lines | 485 | `vless`&nbsp;485 | — | `reality_fp_not_chrome`&nbsp;215, `duplicates_collapsed`&nbsp;134, `reality_fp_random_pinned`&nbsp;50 | 505 |
| `08-github-whitelist` | uri_lines | 24 | `vless`&nbsp;24 | — | `duplicates_collapsed`&nbsp;13, `tls_insecure`&nbsp;1, `reality_fp_random_pinned`&nbsp;1, `uri_param_unknown`&nbsp;1 | 18 |
| `09-github-26` | uri_lines | 4669 | `vless`&nbsp;4640, `shadowsocks`&nbsp;15, `hysteria2`&nbsp;7, `trojan`&nbsp;6, `vmess`&nbsp;1 | `field_missing`&nbsp;95, `ss_method_invalid`&nbsp;7, `provider_banner_link`&nbsp;5, `transport_header_unsupported`&nbsp;1 | `reality_fp_random_pinned`&nbsp;586, `reality_fp_not_chrome`&nbsp;485, `uri_param_unknown`&nbsp;427, `field_missing`&nbsp;41, `tls_alpn_item_invalid`&nbsp;14, `ws_early_data_converted`&nbsp;5, `unknown_key`&nbsp;5, `ss_method_legacy`&nbsp;4, `field_conflict`&nbsp;1 | 1749 |
| `10-github-whitelist` | uri_lines | 56 | `vless`&nbsp;45, `hysteria2`&nbsp;11 | — | `reality_fp_random_pinned`&nbsp;26, `tls_insecure`&nbsp;14, `duplicates_collapsed`&nbsp;7, `tls_not_applicable_quic`&nbsp;2 | 29 |
| `11-github-blacklist` | uri_lines | 2865 | `vless`&nbsp;2802, `hysteria2`&nbsp;32, `shadowsocks`&nbsp;27, `trojan`&nbsp;4 | `form_unrecognized`&nbsp;12 | `duplicates_collapsed`&nbsp;183, `reality_fp_random_pinned`&nbsp;119, `tls_insecure`&nbsp;27, `tls_not_applicable_quic`&nbsp;6, `ech_ignored`&nbsp;3 | 1025 |
| `12-github-kizyakbeta7` | uri_lines | 73 | `vless`&nbsp;61, `hysteria2`&nbsp;12 | `service_record_ignored`&nbsp;1 | `duplicates_collapsed`&nbsp;18, `reality_fp_not_chrome`&nbsp;8, `tls_insecure`&nbsp;5, `utls_fp_unknown`&nbsp;1, `field_conflict`&nbsp;1 | 49 |
| `13-github-kizyakbeta6` | uri_lines | 30 | `vless`&nbsp;24, `hysteria2`&nbsp;6 | — | `reality_fp_not_chrome`&nbsp;13, `reality_fp_random_pinned`&nbsp;3, `duplicates_collapsed`&nbsp;1, `tls_not_applicable_quic`&nbsp;1 | 14 |
| `14-github-kizyakbeta6bl` | uri_lines | 33 | `hysteria2`&nbsp;16, `trojan`&nbsp;10, `vmess`&nbsp;7 | — | `tls_insecure`&nbsp;16, `tls_not_applicable_quic`&nbsp;5, `uri_param_unknown`&nbsp;5, `unknown_key`&nbsp;2, `duplicates_collapsed`&nbsp;1 | 11 |
| `15-github-rkn-white-list` | uri_lines | 97 | `vless`&nbsp;97 | — | `reality_fp_not_chrome`&nbsp;6, `duplicates_collapsed`&nbsp;4, `reality_fp_random_pinned`&nbsp;1, `field_conflict`&nbsp;1 | 51 |
| `16-github-aetrisvpn` | uri_lines | 114 | `vless`&nbsp;91, `shadowsocks`&nbsp;19, `vmess`&nbsp;4 | — | `uri_param_unknown`&nbsp;32, `unknown_key`&nbsp;28, `reality_fp_random_pinned`&nbsp;19, `ss_method_legacy`&nbsp;3, `reality_fp_not_chrome`&nbsp;3, `tls_insecure`&nbsp;2, `field_conflict`&nbsp;1 | 38 |
| `17-github-configs` | uri_lines | 206 | `vless`&nbsp;198, `vmess`&nbsp;5, `trojan`&nbsp;3 | — | `duplicates_collapsed`&nbsp;11, `uri_param_unknown`&nbsp;6, `reality_fp_not_chrome`&nbsp;6, `unknown_key`&nbsp;5, `reality_fp_random_pinned`&nbsp;5, `tls_insecure`&nbsp;3, `ws_early_data_converted`&nbsp;1 | 71 |
| `18-github-whitelist-all` | uri_lines | 188 | `vless`&nbsp;188 | `vless_encryption_invalid`&nbsp;2 | `duplicates_collapsed`&nbsp;47, `reality_fp_not_chrome`&nbsp;25, `reality_fp_random_pinned`&nbsp;22, `tls_alpn_item_invalid`&nbsp;4, `uri_param_unknown`&nbsp;1 | 114 |
| `19-github-bypass-all` | uri_lines | 621 | `vless`&nbsp;507, `trojan`&nbsp;49, `shadowsocks`&nbsp;45, `vmess`&nbsp;20 | — | `uri_param_unknown`&nbsp;132, `unknown_key`&nbsp;75, `utls_fp_unknown`&nbsp;71, `duplicates_collapsed`&nbsp;66, `reality_fp_not_chrome`&nbsp;42, `ws_early_data_converted`&nbsp;36, `reality_fp_random_pinned`&nbsp;17, `tls_insecure`&nbsp;1 | 241 |
| `20-github-bypass-1` | uri_lines | 286 | `vless`&nbsp;254, `trojan`&nbsp;27, `vmess`&nbsp;4, `shadowsocks`&nbsp;1 | — | `utls_fp_unknown`&nbsp;29, `ws_early_data_converted`&nbsp;20, `uri_param_unknown`&nbsp;14, `duplicates_collapsed`&nbsp;13, `reality_fp_not_chrome`&nbsp;10, `reality_fp_random_pinned`&nbsp;6, `unknown_key`&nbsp;5 | 84 |
| `21-github-bypass-2` | uri_lines | 262 | `vless`&nbsp;191, `shadowsocks`&nbsp;40, `vmess`&nbsp;16, `trojan`&nbsp;15 | — | `uri_param_unknown`&nbsp;88, `unknown_key`&nbsp;70, `duplicates_collapsed`&nbsp;32, `reality_fp_not_chrome`&nbsp;28, `reality_fp_random_pinned`&nbsp;10, `ws_early_data_converted`&nbsp;10, `utls_fp_unknown`&nbsp;2, `tls_insecure`&nbsp;1 | 88 |
| `22-github-bypass-3` | uri_lines | 277 | `vless`&nbsp;243, `trojan`&nbsp;17, `shadowsocks`&nbsp;11, `vmess`&nbsp;6 | `form_unrecognized`&nbsp;1 | `uri_param_unknown`&nbsp;78, `utls_fp_unknown`&nbsp;50, `unknown_key`&nbsp;34, `reality_fp_not_chrome`&nbsp;31, `ws_early_data_converted`&nbsp;29, `duplicates_collapsed`&nbsp;19, `reality_fp_random_pinned`&nbsp;6 | 92 |
| `23-github-bypass-4` | uri_lines | 281 | `vless`&nbsp;256, `trojan`&nbsp;16, `shadowsocks`&nbsp;6, `vmess`&nbsp;3 | — | `utls_fp_unknown`&nbsp;50, `uri_param_unknown`&nbsp;37, `ws_early_data_converted`&nbsp;30, `duplicates_collapsed`&nbsp;19, `reality_fp_not_chrome`&nbsp;14, `reality_fp_random_pinned`&nbsp;5, `unknown_key`&nbsp;3, `tls_insecure`&nbsp;1 | 93 |
| `24-github-bypass-5` | uri_lines | 25 | `vless`&nbsp;24, `trojan`&nbsp;1 | — | `uri_param_unknown`&nbsp;23, `duplicates_collapsed`&nbsp;10, `reality_fp_not_chrome`&nbsp;6 | 98 |
| `25-github-bypass-6` | uri_lines | 279 | `vless`&nbsp;159, `shadowsocks`&nbsp;90, `vmess`&nbsp;16, `trojan`&nbsp;14 | — | `uri_param_unknown`&nbsp;60, `unknown_key`&nbsp;45, `reality_fp_not_chrome`&nbsp;30, `duplicates_collapsed`&nbsp;13, `reality_fp_random_pinned`&nbsp;6, `tls_insecure`&nbsp;4, `utls_fp_unknown`&nbsp;1 | 76 |
| `26-github-russia-whitelist` | uri_lines | 2107 | `vless`&nbsp;2079, `trojan`&nbsp;16, `hysteria2`&nbsp;8, `shadowsocks`&nbsp;4 | `transport_header_unsupported`&nbsp;79 | `uri_param_unknown`&nbsp;314, `reality_fp_not_chrome`&nbsp;86, `reality_fp_random_pinned`&nbsp;78, `ws_early_data_converted`&nbsp;50, `tls_insecure`&nbsp;40, `ech_ignored`&nbsp;14, `field_missing`&nbsp;10, `utls_fp_unknown`&nbsp;2, `tls_alpn_item_invalid`&nbsp;1, `field_conflict`&nbsp;1 | 661 |
| `27-github-ru-white-all-white` | uri_lines | 4025 | `vless`&nbsp;3650, `shadowsocks`&nbsp;260, `trojan`&nbsp;93, `hysteria2`&nbsp;22 | `transport_header_unsupported`&nbsp;56, `field_missing`&nbsp;2, `vless_encryption_invalid`&nbsp;2, `ss_method_invalid`&nbsp;1 | `duplicates_collapsed`&nbsp;1007, `reality_fp_not_chrome`&nbsp;399, `uri_param_unknown`&nbsp;248, `reality_fp_random_pinned`&nbsp;219, `tls_insecure`&nbsp;118, `field_missing`&nbsp;22, `ss_method_legacy`&nbsp;14, `ws_early_data_converted`&nbsp;13, `tls_alpn_item_invalid`&nbsp;2, `xhttp_param_reset`&nbsp;1, `utls_fp_unknown`&nbsp;1 | 1799 |
| `28-github-whitelist` | uri_lines | 191 | `vless`&nbsp;185, `shadowsocks`&nbsp;5, `vmess`&nbsp;1 | — | `duplicates_collapsed`&nbsp;76, `reality_fp_not_chrome`&nbsp;18, `reality_fp_random_pinned`&nbsp;15, `uri_param_unknown`&nbsp;9, `unknown_key`&nbsp;7 | 101 |
| `29-github-blacklist` | uri_lines | 106 | `vless`&nbsp;106 | — | `duplicates_collapsed`&nbsp;3 | 28 |
| `30-github-non-ru` | uri_lines | 45 | `vless`&nbsp;45 | — | `reality_fp_random_pinned`&nbsp;4 | 13 |
| `31-github-ping-tested` | uri_lines | 117 | `vless`&nbsp;117 | — | `reality_fp_random_pinned`&nbsp;10, `reality_fp_not_chrome`&nbsp;3 | 30 |
| `32-github-top-600` | uri_lines | 49 | `vless`&nbsp;49 | — | `reality_fp_random_pinned`&nbsp;4 | 14 |
| `33-github-229` | uri_lines | 70 | `vless`&nbsp;45, `shadowsocks`&nbsp;19, `vmess`&nbsp;4, `hysteria2`&nbsp;2 | — | `duplicates_collapsed`&nbsp;42, `uri_param_unknown`&nbsp;32, `unknown_key`&nbsp;28, `reality_fp_not_chrome`&nbsp;11, `ss_method_legacy`&nbsp;3 | 102 |
| `34-github-antinet` | uri_lines | 642 | `vless`&nbsp;379, `trojan`&nbsp;157, `vmess`&nbsp;48, `hysteria2`&nbsp;28, `shadowsocks`&nbsp;26, `anytls`&nbsp;2, `socks`&nbsp;1, `wireguard`&nbsp;1 | `scheme_unsupported`&nbsp;14, `form_unrecognized`&nbsp;7, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;225, `uri_param_unknown`&nbsp;126, `unknown_key`&nbsp;78, `ws_early_data_converted`&nbsp;46, `reality_fp_not_chrome`&nbsp;38, `tls_insecure`&nbsp;14, `reality_fp_random_pinned`&nbsp;9, `ss_method_legacy`&nbsp;2, `wgconf_dns_ignored`&nbsp;1, `awg_mtu_clamped`&nbsp;1 | 547 |
| `35-github-premium` | uri_lines | 153 | `vless`&nbsp;115, `shadowsocks`&nbsp;31, `hysteria2`&nbsp;6, `trojan`&nbsp;1 | — | `duplicates_collapsed`&nbsp;28, `reality_fp_not_chrome`&nbsp;14, `reality_fp_random_pinned`&nbsp;11, `tls_insecure`&nbsp;6, `ss_method_legacy`&nbsp;3, `tls_alpn_item_invalid`&nbsp;3, `uri_param_unknown`&nbsp;2 | 51 |
| `36-github-alive-full` | uri_lines | 595 | `vless`&nbsp;552, `shadowsocks`&nbsp;27, `vmess`&nbsp;13, `trojan`&nbsp;3 | `transport_header_unsupported`&nbsp;9 | `duplicates_collapsed`&nbsp;118, `uri_param_unknown`&nbsp;98, `unknown_key`&nbsp;69, `reality_fp_random_pinned`&nbsp;53, `reality_fp_not_chrome`&nbsp;35, `tls_insecure`&nbsp;4, `field_missing`&nbsp;3, `reality_short_id_invalid`&nbsp;2 | 272 |
| `37-github-sub` | uri_lines | 2891 | `vless`&nbsp;2201, `shadowsocks`&nbsp;577, `vmess`&nbsp;113 | `field_missing`&nbsp;103, `transport_header_unsupported`&nbsp;59, `ss_method_invalid`&nbsp;18, `form_unrecognized`&nbsp;2, `provider_banner_link`&nbsp;2 | `uri_param_unknown`&nbsp;2140, `duplicates_collapsed`&nbsp;575, `unknown_key`&nbsp;294, `reality_fp_not_chrome`&nbsp;144, `reality_fp_random_pinned`&nbsp;70, `ws_early_data_converted`&nbsp;67, `tls_insecure`&nbsp;59, `field_missing`&nbsp;59, `utls_fp_unknown`&nbsp;48, `ss_method_legacy`&nbsp;13, `ech_ignored`&nbsp;10, `tls_alpn_item_invalid`&nbsp;1 | 1067 |
| `38-codeberg-vless-universal` | uri_lines | 95 | `vless`&nbsp;95 | — | `reality_fp_not_chrome`&nbsp;5, `duplicates_collapsed`&nbsp;2, `field_conflict`&nbsp;1 | 42 |
| `39-moshub-list-universal` | uri_lines | 95 | `vless`&nbsp;95 | — | `reality_fp_not_chrome`&nbsp;5, `duplicates_collapsed`&nbsp;2, `field_conflict`&nbsp;1 | 38 |
| `40-gitverse-list-universal` | uri_lines | 95 | `vless`&nbsp;95 | — | `reality_fp_not_chrome`&nbsp;5, `duplicates_collapsed`&nbsp;2, `field_conflict`&nbsp;1 | 38 |
| `41-gitlab-vless-reality-white-lists-rus-mobile` | uri_lines | 25 | `vless`&nbsp;18, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `duplicates_collapsed`&nbsp;2, `reality_fp_random_pinned`&nbsp;1, `tls_not_applicable_quic`&nbsp;1 | 11 |
| `42-bitbucket-vless-reality-white-lists-rus-mobile` | uri_lines | 25 | `vless`&nbsp;18, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `duplicates_collapsed`&nbsp;2, `reality_fp_random_pinned`&nbsp;1, `tls_not_applicable_quic`&nbsp;1 | 9 |
| `47-domain-whitelist` | uri_lines | 95 | `vless`&nbsp;83, `hysteria2`&nbsp;11, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;31, `reality_fp_not_chrome`&nbsp;4, `tls_insecure`&nbsp;3, `reality_fp_random_pinned`&nbsp;1 | 40 |
| `48-domain-1` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1337 |
| `49-domain-2` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1187 |
| `50-domain-whitelist` | uri_lines | 95 | `vless`&nbsp;83, `hysteria2`&nbsp;11, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;31, `reality_fp_not_chrome`&nbsp;4, `tls_insecure`&nbsp;3, `reality_fp_random_pinned`&nbsp;1 | 40 |
| `51-domain-other` | uri_lines | 3583 | `vless`&nbsp;2817, `shadowsocks`&nbsp;313, `trojan`&nbsp;258, `hysteria2`&nbsp;185, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;592, `tls_insecure`&nbsp;109, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;67, `reality_fp_random_pinned`&nbsp;31, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1183 |
| `52-domain-1` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1187 |
| `53-domain-2` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1266 |
| `54-gitverse-whitelist` | uri_lines | 112 | `vless`&nbsp;112 | `transport_header_unsupported`&nbsp;7, `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;15, `reality_fp_random_pinned`&nbsp;10, `duplicates_collapsed`&nbsp;10, `uri_param_unknown`&nbsp;1 | 69 |
| `55-gitverse-other` | uri_lines | 818 | `vless`&nbsp;439, `shadowsocks`&nbsp;347, `trojan`&nbsp;32 | `transport_header_unsupported`&nbsp;13, `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;201, `reality_fp_random_pinned`&nbsp;58, `uri_param_unknown`&nbsp;46, `reality_fp_not_chrome`&nbsp;21, `tls_insecure`&nbsp;16, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 531 |
| `56-gitverse-1` | uri_lines | 922 | `vless`&nbsp;543, `shadowsocks`&nbsp;347, `trojan`&nbsp;32 | `transport_header_unsupported`&nbsp;20, `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;208, `reality_fp_random_pinned`&nbsp;67, `uri_param_unknown`&nbsp;47, `reality_fp_not_chrome`&nbsp;36, `tls_insecure`&nbsp;16, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 491 |
| `57-gitverse-2` | uri_lines | 922 | `vless`&nbsp;543, `shadowsocks`&nbsp;347, `trojan`&nbsp;32 | `transport_header_unsupported`&nbsp;20, `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;208, `reality_fp_random_pinned`&nbsp;67, `uri_param_unknown`&nbsp;47, `reality_fp_not_chrome`&nbsp;36, `tls_insecure`&nbsp;16, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 568 |
| `58-domain-whitelist` | uri_lines | 95 | `vless`&nbsp;83, `hysteria2`&nbsp;11, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;31, `reality_fp_not_chrome`&nbsp;4, `tls_insecure`&nbsp;3, `reality_fp_random_pinned`&nbsp;1 | 41 |
| `59-domain-other` | uri_lines | 3583 | `vless`&nbsp;2817, `shadowsocks`&nbsp;313, `trojan`&nbsp;258, `hysteria2`&nbsp;185, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;592, `tls_insecure`&nbsp;109, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;67, `reality_fp_random_pinned`&nbsp;31, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1202 |
| `60-domain-1` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1156 |
| `61-domain-2` | uri_lines | 3678 | `vless`&nbsp;2900, `shadowsocks`&nbsp;314, `trojan`&nbsp;258, `hysteria2`&nbsp;196, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `duplicates_collapsed`&nbsp;623, `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `reality_fp_not_chrome`&nbsp;71, `reality_fp_random_pinned`&nbsp;32, `uri_param_unknown`&nbsp;20, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;7, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 1208 |
| `62-domain-whitelist-etoneya-baby` | uri_lines | 95 | `vless`&nbsp;83, `hysteria2`&nbsp;11, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;31, `reality_fp_not_chrome`&nbsp;4, `tls_insecure`&nbsp;3, `reality_fp_random_pinned`&nbsp;1 | 38 |
| `63-domain-whitelist` | uri_lines | 95 | `vless`&nbsp;83, `hysteria2`&nbsp;11, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;31, `reality_fp_not_chrome`&nbsp;4, `tls_insecure`&nbsp;3, `reality_fp_random_pinned`&nbsp;1 | 36 |
| `64-domain-gen` | uri_lines | 193 | `vless`&nbsp;185, `hysteria2`&nbsp;6, `shadowsocks`&nbsp;2 | `provider_banner_link`&nbsp;1 | `duplicates_collapsed`&nbsp;46, `reality_fp_not_chrome`&nbsp;17, `reality_fp_random_pinned`&nbsp;16, `tls_not_applicable_quic`&nbsp;4, `tls_insecure`&nbsp;1 | 98 |
| `65-codeberg-sub` | uri_lines | 28 | `vless`&nbsp;27, `hysteria2`&nbsp;1 | — | `duplicates_collapsed`&nbsp;15, `reality_fp_not_chrome`&nbsp;7 | 19 |
| `66-gitverse-wl` | uri_lines | 1588 | `vless`&nbsp;1569, `shadowsocks`&nbsp;15, `trojan`&nbsp;2, `hysteria2`&nbsp;1, `vmess`&nbsp;1 | `field_missing`&nbsp;9, `ss_method_invalid`&nbsp;2 | `reality_fp_random_pinned`&nbsp;370, `reality_fp_not_chrome`&nbsp;274, `duplicates_collapsed`&nbsp;71, `uri_param_unknown`&nbsp;14, `field_missing`&nbsp;12, `tls_insecure`&nbsp;7, `unknown_key`&nbsp;5, `ss_method_legacy`&nbsp;4, `ws_early_data_converted`&nbsp;2 | 578 |
| `67-domain-working-configs` | uri_lines | 132 | `vless`&nbsp;124, `vmess`&nbsp;6, `trojan`&nbsp;2 | `service_record_ignored`&nbsp;1 | `uri_param_unknown`&nbsp;18, `unknown_key`&nbsp;7, `reality_fp_not_chrome`&nbsp;7, `reality_fp_random_pinned`&nbsp;3, `field_missing`&nbsp;2, `tls_insecure`&nbsp;2 | 53 |
| `68-gitverse-outlinevpn-outlinevpn` | uri_lines | 165 | `vless`&nbsp;152, `trojan`&nbsp;13 | — | `duplicates_collapsed`&nbsp;60, `reality_fp_not_chrome`&nbsp;17, `ws_early_data_converted`&nbsp;9, `uri_param_unknown`&nbsp;2, `reality_fp_random_pinned`&nbsp;2, `ech_ignored`&nbsp;2, `tls_alpn_item_invalid`&nbsp;1, `tls_insecure`&nbsp;1 | 69 |
| `69-domain-api-php` | uri_lines | 0 | — | — | — | 0 |
| `70-gitverse-flux-bypass-all-782661` | uri_lines | 1302 | `vless`&nbsp;1268, `trojan`&nbsp;32, `shadowsocks`&nbsp;2 | `field_missing`&nbsp;67, `ss_method_invalid`&nbsp;15, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;746, `reality_fp_random_pinned`&nbsp;89, `reality_fp_not_chrome`&nbsp;72, `field_missing`&nbsp;59, `type_invalid`&nbsp;2 | 376 |
| `71-domain-bypass-all` | uri_lines | 1302 | `vless`&nbsp;1268, `trojan`&nbsp;32, `shadowsocks`&nbsp;2 | `field_missing`&nbsp;67, `ss_method_invalid`&nbsp;15, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;746, `reality_fp_random_pinned`&nbsp;89, `reality_fp_not_chrome`&nbsp;72, `field_missing`&nbsp;59, `type_invalid`&nbsp;2 | 454 |
| `72-gitverse-alive-full` | uri_lines | 595 | `vless`&nbsp;552, `shadowsocks`&nbsp;27, `vmess`&nbsp;13, `trojan`&nbsp;3 | `transport_header_unsupported`&nbsp;9 | `duplicates_collapsed`&nbsp;118, `uri_param_unknown`&nbsp;98, `unknown_key`&nbsp;69, `reality_fp_random_pinned`&nbsp;53, `reality_fp_not_chrome`&nbsp;35, `tls_insecure`&nbsp;4, `field_missing`&nbsp;3, `reality_short_id_invalid`&nbsp;2 | 256 |
| `73-github-full` | uri_lines | 251 | `vless`&nbsp;232, `shadowsocks`&nbsp;17, `vmess`&nbsp;2 | — | `reality_fp_random_pinned`&nbsp;46, `duplicates_collapsed`&nbsp;23, `uri_param_unknown`&nbsp;19, `unknown_key`&nbsp;14, `reality_fp_not_chrome`&nbsp;12, `tls_insecure`&nbsp;10, `ss_method_legacy`&nbsp;2, `field_conflict`&nbsp;1 | 80 |

## Ноль узлов (2)

- `03-github-vless` — вид `uri_lines`, отбраковки: `provider_banner_link`&nbsp;3
- `69-domain-api-php` — вид `uri_lines`

## Виды тел

| код | число |
|---|--:|
| `uri_lines` | 69 |

## Коды отбраковок

| код | число |
|---|--:|
| `form_unrecognized` | 3470 |
| `field_missing` | 343 |
| `transport_header_unsupported` | 282 |
| `ss_method_invalid` | 58 |
| `provider_banner_link` | 42 |
| `scheme_unsupported` | 22 |
| `vless_encryption_invalid` | 4 |
| `service_record_ignored` | 2 |

## Коды предупреждений

| код | число |
|---|--:|
| `duplicates_collapsed` | 8728 |
| `uri_param_unknown` | 5822 |
| `reality_fp_not_chrome` | 2931 |
| `reality_fp_random_pinned` | 2491 |
| `tls_insecure` | 1299 |
| `unknown_key` | 845 |
| `ss_method_legacy` | 779 |
| `utls_fp_unknown` | 359 |
| `ws_early_data_converted` | 318 |
| `field_missing` | 306 |
| `tls_not_applicable_quic` | 82 |
| `ech_ignored` | 69 |
| `tls_alpn_item_invalid` | 26 |
| `tuic_udp_relay_mode_invalid` | 16 |
| `field_conflict` | 11 |
| `reality_short_id_invalid` | 4 |
| `type_invalid` | 4 |
| `awg_mtu_clamped` | 1 |
| `wgconf_dns_ignored` | 1 |
| `xhttp_param_reset` | 1 |

## Типы узлов

| код | число |
|---|--:|
| `vless` | 50925 |
| `shadowsocks` | 4824 |
| `trojan` | 2676 |
| `hysteria2` | 1789 |
| `vmess` | 290 |
| `anytls` | 42 |
| `tuic` | 40 |
| `socks` | 1 |
| `wireguard` | 1 |

## Покрытие: протокол × транспорт × security

| протокол | транспорт | security | узлов |
|---|---|---|--:|
| vless | none | reality | 23980 |
| vless | ws | tls | 14616 |
| shadowsocks | none | none | 4824 |
| vless | ws | none | 4544 |
| vless | grpc | reality | 3310 |
| trojan | ws | tls | 2154 |
| hysteria2 | none | tls | 1789 |
| vless | none | tls | 1570 |
| vless | xhttp | reality | 878 |
| vless | grpc | tls | 579 |
| trojan | none | tls | 500 |
| vless | xhttp | tls | 393 |
| vless | none | none | 323 |
| vless | http | tls | 264 |
| vmess | none | none | 134 |
| vless | grpc | none | 129 |
| vless | http | reality | 128 |
| vmess | ws | tls | 122 |
| vless | httpupgrade | none | 73 |
| vless | httpupgrade | tls | 56 |
| vless | http | none | 48 |
| anytls | none | tls | 42 |
| tuic | none | tls | 40 |
| vmess | ws | none | 31 |
| vless | xhttp | none | 29 |
| trojan | httpupgrade | tls | 12 |
| trojan | xhttp | tls | 8 |
| vless | ws | reality | 5 |
| socks | none | none | 1 |
| trojan | grpc | tls | 1 |
| trojan | none | none | 1 |
| vmess | httpupgrade | tls | 1 |
| vmess | none | tls | 1 |
| vmess | xhttp | tls | 1 |
| wireguard | none | none | 1 |
