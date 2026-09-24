# Корпус публичных подписок — прогон разбора

Контракт: `1.1.52`. Подписок: 68. Узлов: 73938.

Сгенерировано `tool/public_subs/run.dart`; править руками незачем — перезапишется. Методика: `docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md`.

## По подпискам

| id | вид | узлов | типы | отбраковки | предупреждения | мс |
|---|---|--:|---|---|---|--:|
| `01-github-vless-universal` | uri_lines | 97 | `vless`&nbsp;97 | — | `reality_fp_not_chrome`&nbsp;5, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 585 |
| `02-github-vless-lite` | uri_lines | 97 | `vless`&nbsp;97 | `provider_banner_link`&nbsp;4 | `reality_fp_not_chrome`&nbsp;5, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 258 |
| `03-github-vless` | uri_lines | 0 | — | `provider_banner_link`&nbsp;3 | — | 9 |
| `04-github-vless-reality-white-lists-rus-mobile` | uri_lines | 27 | `vless`&nbsp;20, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 64 |
| `05-github-white-cidr-ru-checked` | uri_lines | 5 | `vless`&nbsp;5 | — | — | 5 |
| `06-github-black-vless-rus-mobile` | uri_lines | 142 | `vless`&nbsp;126, `hysteria2`&nbsp;9, `vmess`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;15, `tls_insecure`&nbsp;5, `tls_not_applicable_quic`&nbsp;5, `uri_param_unknown`&nbsp;5, `unknown_key`&nbsp;2 | 173 |
| `07-github-byewhitelists2` | uri_lines | 1031 | `vless`&nbsp;1031 | — | `reality_fp_not_chrome`&nbsp;351, `uri_param_unknown`&nbsp;2 | 1774 |
| `08-github-whitelist` | uri_lines | 45 | `vless`&nbsp;45 | — | `uri_param_unknown`&nbsp;5, `tls_insecure`&nbsp;1 | 43 |
| `09-github-26` | uri_lines | 4669 | `vless`&nbsp;4640, `shadowsocks`&nbsp;15, `hysteria2`&nbsp;7, `trojan`&nbsp;6, `vmess`&nbsp;1 | `field_missing`&nbsp;95, `ss_method_invalid`&nbsp;7, `provider_banner_link`&nbsp;5, `transport_header_unsupported`&nbsp;1 | `uri_param_unknown`&nbsp;489, `reality_fp_not_chrome`&nbsp;485, `field_missing`&nbsp;41, `tls_alpn_item_invalid`&nbsp;14, `ws_early_data_converted`&nbsp;5, `unknown_key`&nbsp;5, `ss_method_legacy`&nbsp;4, `field_conflict`&nbsp;1 | 5228 |
| `10-github-whitelist` | uri_lines | 63 | `vless`&nbsp;48, `hysteria2`&nbsp;15 | — | `tls_insecure`&nbsp;16, `tls_not_applicable_quic`&nbsp;4 | 104 |
| `11-github-blacklist` | uri_lines | 3052 | `vless`&nbsp;2980, `hysteria2`&nbsp;37, `shadowsocks`&nbsp;29, `trojan`&nbsp;6 | `field_missing`&nbsp;12 | `tls_insecure`&nbsp;34, `tls_not_applicable_quic`&nbsp;6, `ech_ignored`&nbsp;3 | 2431 |
| `12-github-kizyakbeta7` | uri_lines | 94 | `vless`&nbsp;74, `hysteria2`&nbsp;20 | `service_record_ignored`&nbsp;1 | `reality_fp_not_chrome`&nbsp;8, `tls_insecure`&nbsp;6, `uri_param_unknown`&nbsp;6, `tls_not_applicable_quic`&nbsp;1, `utls_fp_unknown`&nbsp;1, `field_conflict`&nbsp;1 | 111 |
| `13-github-kizyakbeta6` | uri_lines | 31 | `vless`&nbsp;25, `hysteria2`&nbsp;6 | — | `reality_fp_not_chrome`&nbsp;13, `tls_not_applicable_quic`&nbsp;1 | 29 |
| `14-github-kizyakbeta6bl` | uri_lines | 34 | `hysteria2`&nbsp;17, `trojan`&nbsp;10, `vmess`&nbsp;7 | — | `tls_insecure`&nbsp;16, `uri_param_unknown`&nbsp;7, `tls_not_applicable_quic`&nbsp;5, `unknown_key`&nbsp;2 | 25 |
| `15-github-rkn-white-list` | uri_lines | 101 | `vless`&nbsp;101 | — | `reality_fp_not_chrome`&nbsp;7, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 82 |
| `16-github-aetrisvpn` | uri_lines | 114 | `vless`&nbsp;91, `shadowsocks`&nbsp;19, `vmess`&nbsp;4 | — | `uri_param_unknown`&nbsp;35, `unknown_key`&nbsp;28, `ss_method_legacy`&nbsp;3, `reality_fp_not_chrome`&nbsp;3, `tls_insecure`&nbsp;2, `field_conflict`&nbsp;1 | 101 |
| `17-github-configs` | uri_lines | 217 | `vless`&nbsp;206, `vmess`&nbsp;8, `trojan`&nbsp;3 | — | `uri_param_unknown`&nbsp;11, `unknown_key`&nbsp;8, `reality_fp_not_chrome`&nbsp;6, `tls_insecure`&nbsp;3, `ws_early_data_converted`&nbsp;1 | 185 |
| `18-github-whitelist-all` | uri_lines | 316 | `vless`&nbsp;316 | `vless_encryption_invalid`&nbsp;2 | `reality_fp_not_chrome`&nbsp;26, `tls_alpn_item_invalid`&nbsp;20, `uri_param_unknown`&nbsp;9 | 259 |
| `19-github-bypass-all` | uri_lines | 702 | `vless`&nbsp;582, `trojan`&nbsp;50, `shadowsocks`&nbsp;50, `vmess`&nbsp;20 | — | `uri_param_unknown`&nbsp;145, `unknown_key`&nbsp;75, `utls_fp_unknown`&nbsp;72, `reality_fp_not_chrome`&nbsp;50, `ws_early_data_converted`&nbsp;37, `tls_insecure`&nbsp;1 | 580 |
| `20-github-bypass-1` | uri_lines | 300 | `vless`&nbsp;267, `trojan`&nbsp;28, `vmess`&nbsp;4, `shadowsocks`&nbsp;1 | — | `utls_fp_unknown`&nbsp;29, `uri_param_unknown`&nbsp;20, `ws_early_data_converted`&nbsp;20, `reality_fp_not_chrome`&nbsp;11, `unknown_key`&nbsp;5 | 249 |
| `21-github-bypass-2` | uri_lines | 300 | `vless`&nbsp;225, `shadowsocks`&nbsp;44, `vmess`&nbsp;16, `trojan`&nbsp;15 | — | `uri_param_unknown`&nbsp;92, `unknown_key`&nbsp;70, `reality_fp_not_chrome`&nbsp;34, `ws_early_data_converted`&nbsp;10, `utls_fp_unknown`&nbsp;2, `tls_insecure`&nbsp;1 | 212 |
| `22-github-bypass-3` | uri_lines | 299 | `vless`&nbsp;265, `trojan`&nbsp;17, `shadowsocks`&nbsp;11, `vmess`&nbsp;6 | `field_missing`&nbsp;1 | `uri_param_unknown`&nbsp;78, `utls_fp_unknown`&nbsp;50, `reality_fp_not_chrome`&nbsp;36, `unknown_key`&nbsp;34, `ws_early_data_converted`&nbsp;29 | 204 |
| `23-github-bypass-4` | uri_lines | 300 | `vless`&nbsp;275, `trojan`&nbsp;16, `shadowsocks`&nbsp;6, `vmess`&nbsp;3 | — | `utls_fp_unknown`&nbsp;50, `uri_param_unknown`&nbsp;37, `ws_early_data_converted`&nbsp;30, `reality_fp_not_chrome`&nbsp;17, `unknown_key`&nbsp;3, `tls_insecure`&nbsp;1 | 216 |
| `24-github-bypass-5` | uri_lines | 300 | `vless`&nbsp;299, `trojan`&nbsp;1 | — | `uri_param_unknown`&nbsp;1166, `reality_fp_not_chrome`&nbsp;21 | 238 |
| `25-github-bypass-6` | uri_lines | 300 | `vless`&nbsp;178, `shadowsocks`&nbsp;92, `vmess`&nbsp;16, `trojan`&nbsp;14 | — | `uri_param_unknown`&nbsp;89, `unknown_key`&nbsp;45, `reality_fp_not_chrome`&nbsp;32, `tls_insecure`&nbsp;4, `utls_fp_unknown`&nbsp;1 | 175 |
| `26-github-russia-whitelist` | uri_lines | 2107 | `vless`&nbsp;2079, `trojan`&nbsp;16, `hysteria2`&nbsp;8, `shadowsocks`&nbsp;4 | `transport_header_unsupported`&nbsp;79 | `uri_param_unknown`&nbsp;327, `reality_fp_not_chrome`&nbsp;86, `ws_early_data_converted`&nbsp;50, `tls_insecure`&nbsp;40, `ech_ignored`&nbsp;14, `field_missing`&nbsp;10, `utls_fp_unknown`&nbsp;2, `tls_alpn_item_invalid`&nbsp;1, `field_conflict`&nbsp;1 | 1550 |
| `27-github-ru-white-all-white` | uri_lines | 6048 | `vless`&nbsp;5332, `shadowsocks`&nbsp;575, `trojan`&nbsp;97, `hysteria2`&nbsp;44 | `transport_header_unsupported`&nbsp;56, `field_missing`&nbsp;2, `vless_encryption_invalid`&nbsp;2, `ss_method_invalid`&nbsp;1 | `reality_fp_not_chrome`&nbsp;486, `uri_param_unknown`&nbsp;386, `tls_insecure`&nbsp;129, `field_missing`&nbsp;26, `ss_method_legacy`&nbsp;16, `xhttp_param_reset`&nbsp;16, `ws_early_data_converted`&nbsp;13, `vision_with_transport`&nbsp;11, `tls_alpn_item_invalid`&nbsp;9, `utls_fp_unknown`&nbsp;1 | 4912 |
| `28-github-whitelist` | uri_lines | 354 | `vless`&nbsp;348, `shadowsocks`&nbsp;5, `vmess`&nbsp;1 | — | `reality_fp_not_chrome`&nbsp;22, `uri_param_unknown`&nbsp;17, `unknown_key`&nbsp;7 | 384 |
| `29-github-blacklist` | uri_lines | 109 | `vless`&nbsp;109 | — | — | 85 |
| `30-github-non-ru` | uri_lines | 45 | `vless`&nbsp;45 | — | — | 30 |
| `31-github-ping-tested` | uri_lines | 117 | `vless`&nbsp;117 | — | `reality_fp_not_chrome`&nbsp;3 | 110 |
| `32-github-top-600` | uri_lines | 49 | `vless`&nbsp;49 | — | — | 36 |
| `33-github-229` | uri_lines | 229 | `vless`&nbsp;169, `shadowsocks`&nbsp;45, `hysteria2`&nbsp;8, `vmess`&nbsp;7 | — | `uri_param_unknown`&nbsp;64, `unknown_key`&nbsp;49, `reality_fp_not_chrome`&nbsp;21, `ss_method_legacy`&nbsp;4 | 318 |
| `34-github-antinet` | uri_lines | 1109 | `vless`&nbsp;783, `trojan`&nbsp;188, `vmess`&nbsp;59, `hysteria2`&nbsp;39, `shadowsocks`&nbsp;34, `anytls`&nbsp;4, `socks`&nbsp;1, `wireguard`&nbsp;1 | `scheme_unsupported`&nbsp;14, `field_missing`&nbsp;7, `transport_header_unsupported`&nbsp;1 | `uri_param_unknown`&nbsp;193, `reality_fp_not_chrome`&nbsp;102, `unknown_key`&nbsp;95, `ws_early_data_converted`&nbsp;88, `tls_insecure`&nbsp;21, `xhttp_param_reset`&nbsp;8, `ss_method_legacy`&nbsp;2, `wgconf_dns_ignored`&nbsp;1, `awg_mtu_clamped`&nbsp;1 | 1803 |
| `35-github-premium` | uri_lines | 200 | `vless`&nbsp;154, `shadowsocks`&nbsp;38, `hysteria2`&nbsp;7, `trojan`&nbsp;1 | — | `reality_fp_not_chrome`&nbsp;15, `tls_alpn_item_invalid`&nbsp;7, `tls_insecure`&nbsp;6, `ss_method_legacy`&nbsp;3, `uri_param_unknown`&nbsp;3 | 196 |
| `36-github-alive-full` | uri_lines | 720 | `vless`&nbsp;662, `shadowsocks`&nbsp;37, `vmess`&nbsp;18, `trojan`&nbsp;3 | `transport_header_unsupported`&nbsp;9 | `uri_param_unknown`&nbsp;121, `unknown_key`&nbsp;89, `reality_fp_not_chrome`&nbsp;36, `tls_insecure`&nbsp;4, `field_missing`&nbsp;3, `reality_short_id_invalid`&nbsp;2 | 844 |
| `37-github-sub` | uri_lines | 3966 | `vless`&nbsp;2791, `shadowsocks`&nbsp;965, `vmess`&nbsp;210 | `field_missing`&nbsp;103, `transport_header_unsupported`&nbsp;59, `ss_method_invalid`&nbsp;18, `form_unrecognized`&nbsp;2, `provider_banner_link`&nbsp;2 | `uri_param_unknown`&nbsp;3270, `unknown_key`&nbsp;419, `reality_fp_not_chrome`&nbsp;174, `field_missing`&nbsp;82, `ws_early_data_converted`&nbsp;72, `tls_insecure`&nbsp;70, `utls_fp_unknown`&nbsp;48, `ech_ignored`&nbsp;13, `ss_method_legacy`&nbsp;13, `tls_alpn_item_invalid`&nbsp;1, `vision_with_transport`&nbsp;1 | 2445 |
| `38-codeberg-vless-universal` | uri_lines | 97 | `vless`&nbsp;97 | — | `reality_fp_not_chrome`&nbsp;5, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 78 |
| `39-moshub-list-universal` | uri_lines | 97 | `vless`&nbsp;97 | — | `reality_fp_not_chrome`&nbsp;5, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 70 |
| `40-gitverse-list-universal` | uri_lines | 97 | `vless`&nbsp;97 | — | `reality_fp_not_chrome`&nbsp;5, `uri_param_unknown`&nbsp;3, `field_conflict`&nbsp;1 | 65 |
| `41-gitlab-vless-reality-white-lists-rus-mobile` | uri_lines | 27 | `vless`&nbsp;20, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 17 |
| `42-bitbucket-vless-reality-white-lists-rus-mobile` | uri_lines | 27 | `vless`&nbsp;20, `hysteria2`&nbsp;7 | — | `reality_fp_not_chrome`&nbsp;7, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 15 |
| `47-domain-whitelist` | uri_lines | 131 | `vless`&nbsp;115, `hysteria2`&nbsp;15, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;5, `tls_insecure`&nbsp;3, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 71 |
| `48-domain-1` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 2635 |
| `49-domain-2` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 2487 |
| `50-domain-whitelist` | uri_lines | 131 | `vless`&nbsp;115, `hysteria2`&nbsp;15, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;5, `tls_insecure`&nbsp;3, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 89 |
| `51-domain-other` | uri_lines | 4325 | `vless`&nbsp;3480, `shadowsocks`&nbsp;313, `trojan`&nbsp;267, `hysteria2`&nbsp;255, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;90, `reality_fp_not_chrome`&nbsp;72, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;10, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 3146 |
| `52-domain-1` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 2822 |
| `53-domain-2` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 4834 |
| `54-gitverse-whitelist` | uri_lines | 135 | `vless`&nbsp;135 | `transport_header_unsupported`&nbsp;7, `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;16, `uri_param_unknown`&nbsp;4 | 127 |
| `55-gitverse-other` | uri_lines | 1248 | `vless`&nbsp;850, `shadowsocks`&nbsp;356, `trojan`&nbsp;42 | `transport_header_unsupported`&nbsp;13, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;86, `reality_fp_not_chrome`&nbsp;23, `tls_insecure`&nbsp;17, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 1088 |
| `56-gitverse-1` | uri_lines | 1383 | `vless`&nbsp;985, `shadowsocks`&nbsp;356, `trojan`&nbsp;42 | `transport_header_unsupported`&nbsp;20, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;90, `reality_fp_not_chrome`&nbsp;39, `tls_insecure`&nbsp;17, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 1724 |
| `57-gitverse-2` | uri_lines | 1383 | `vless`&nbsp;985, `shadowsocks`&nbsp;356, `trojan`&nbsp;42 | `transport_header_unsupported`&nbsp;20, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;90, `reality_fp_not_chrome`&nbsp;39, `tls_insecure`&nbsp;17, `field_missing`&nbsp;12, `ss_method_legacy`&nbsp;1 | 1622 |
| `58-domain-whitelist` | uri_lines | 131 | `vless`&nbsp;115, `hysteria2`&nbsp;15, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;5, `tls_insecure`&nbsp;3, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 93 |
| `59-domain-other` | uri_lines | 4325 | `vless`&nbsp;3480, `shadowsocks`&nbsp;313, `trojan`&nbsp;267, `hysteria2`&nbsp;255, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;112, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;90, `reality_fp_not_chrome`&nbsp;72, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;10, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 3600 |
| `60-domain-1` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 3627 |
| `61-domain-2` | uri_lines | 4456 | `vless`&nbsp;3595, `shadowsocks`&nbsp;314, `hysteria2`&nbsp;270, `trojan`&nbsp;267, `tuic`&nbsp;5, `anytls`&nbsp;5 | `form_unrecognized`&nbsp;431, `provider_banner_link`&nbsp;2, `scheme_unsupported`&nbsp;1, `transport_header_unsupported`&nbsp;1 | `tls_insecure`&nbsp;115, `ss_method_legacy`&nbsp;91, `uri_param_unknown`&nbsp;91, `reality_fp_not_chrome`&nbsp;77, `utls_fp_unknown`&nbsp;13, `tls_not_applicable_quic`&nbsp;11, `ech_ignored`&nbsp;5, `tuic_udp_relay_mode_invalid`&nbsp;2 | 5825 |
| `62-domain-whitelist-etoneya-baby` | uri_lines | 131 | `vless`&nbsp;115, `hysteria2`&nbsp;15, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;5, `tls_insecure`&nbsp;3, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 133 |
| `63-domain-whitelist` | uri_lines | 131 | `vless`&nbsp;115, `hysteria2`&nbsp;15, `shadowsocks`&nbsp;1 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;5, `tls_insecure`&nbsp;3, `tls_not_applicable_quic`&nbsp;1, `uri_param_unknown`&nbsp;1 | 192 |
| `64-domain-gen` | uri_lines | 255 | `vless`&nbsp;247, `hysteria2`&nbsp;6, `shadowsocks`&nbsp;2 | `provider_banner_link`&nbsp;1 | `reality_fp_not_chrome`&nbsp;18, `uri_param_unknown`&nbsp;5, `tls_not_applicable_quic`&nbsp;4, `tls_insecure`&nbsp;1 | 353 |
| `65-codeberg-sub` | uri_lines | 50 | `vless`&nbsp;46, `hysteria2`&nbsp;4 | — | `reality_fp_not_chrome`&nbsp;16, `uri_param_unknown`&nbsp;2 | 42 |
| `66-gitverse-wl` | uri_lines | 1678 | `vless`&nbsp;1657, `shadowsocks`&nbsp;17, `trojan`&nbsp;2, `hysteria2`&nbsp;1, `vmess`&nbsp;1 | `field_missing`&nbsp;9, `ss_method_invalid`&nbsp;2 | `reality_fp_not_chrome`&nbsp;284, `uri_param_unknown`&nbsp;52, `field_missing`&nbsp;12, `tls_insecure`&nbsp;7, `unknown_key`&nbsp;5, `ss_method_legacy`&nbsp;4, `ws_early_data_converted`&nbsp;2 | 2642 |
| `67-domain-working-configs` | uri_lines | 132 | `vless`&nbsp;124, `vmess`&nbsp;6, `trojan`&nbsp;2 | `service_record_ignored`&nbsp;1 | `uri_param_unknown`&nbsp;19, `unknown_key`&nbsp;7, `reality_fp_not_chrome`&nbsp;7, `field_missing`&nbsp;2, `tls_insecure`&nbsp;2 | 141 |
| `68-gitverse-outlinevpn-outlinevpn` | uri_lines | 275 | `vless`&nbsp;253, `trojan`&nbsp;22 | — | `reality_fp_not_chrome`&nbsp;41, `ws_early_data_converted`&nbsp;9, `uri_param_unknown`&nbsp;4, `ech_ignored`&nbsp;2, `tls_alpn_item_invalid`&nbsp;1, `tls_insecure`&nbsp;1 | 912 |
| `69-domain-api-php` | uri_lines | 0 | — | — | — | 1 |
| `70-gitverse-flux-bypass-all-782661` | uri_lines | 1302 | `vless`&nbsp;1268, `trojan`&nbsp;32, `shadowsocks`&nbsp;2 | `field_missing`&nbsp;67, `ss_method_invalid`&nbsp;15, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;749, `reality_fp_not_chrome`&nbsp;72, `field_missing`&nbsp;59, `type_invalid`&nbsp;2 | 1492 |
| `71-domain-bypass-all` | uri_lines | 1302 | `vless`&nbsp;1268, `trojan`&nbsp;32, `shadowsocks`&nbsp;2 | `field_missing`&nbsp;67, `ss_method_invalid`&nbsp;15, `provider_banner_link`&nbsp;1 | `uri_param_unknown`&nbsp;749, `reality_fp_not_chrome`&nbsp;72, `field_missing`&nbsp;59, `type_invalid`&nbsp;2 | 2045 |
| `72-gitverse-alive-full` | uri_lines | 720 | `vless`&nbsp;662, `shadowsocks`&nbsp;37, `vmess`&nbsp;18, `trojan`&nbsp;3 | `transport_header_unsupported`&nbsp;9 | `uri_param_unknown`&nbsp;121, `unknown_key`&nbsp;89, `reality_fp_not_chrome`&nbsp;36, `tls_insecure`&nbsp;4, `field_missing`&nbsp;3, `reality_short_id_invalid`&nbsp;2 | 1191 |

## Ноль узлов (2)

- `03-github-vless` — вид `uri_lines`, отбраковки: `provider_banner_link`&nbsp;3
- `69-domain-api-php` — вид `uri_lines`

## Виды тел

| код | число |
|---|--:|
| `uri_lines` | 68 |

## Коды отбраковок

| код | число |
|---|--:|
| `form_unrecognized` | 3450 |
| `field_missing` | 363 |
| `transport_header_unsupported` | 282 |
| `ss_method_invalid` | 58 |
| `provider_banner_link` | 42 |
| `scheme_unsupported` | 22 |
| `vless_encryption_invalid` | 4 |
| `service_record_ignored` | 2 |

## Коды предупреждений

| код | число |
|---|--:|
| `uri_param_unknown` | 9300 |
| `reality_fp_not_chrome` | 3400 |
| `tls_insecure` | 1355 |
| `unknown_key` | 1037 |
| `ss_method_legacy` | 780 |
| `ws_early_data_converted` | 366 |
| `utls_fp_unknown` | 360 |
| `field_missing` | 333 |
| `tls_not_applicable_quic` | 120 |
| `ech_ignored` | 72 |
| `tls_alpn_item_invalid` | 53 |
| `xhttp_param_reset` | 24 |
| `tuic_udp_relay_mode_invalid` | 16 |
| `vision_with_transport` | 12 |
| `field_conflict` | 10 |
| `reality_short_id_invalid` | 4 |
| `type_invalid` | 4 |
| `awg_mtu_clamped` | 1 |
| `wgconf_dns_ignored` | 1 |

## Типы узлов

| код | число |
|---|--:|
| `vless` | 62547 |
| `shadowsocks` | 5613 |
| `trojan` | 2826 |
| `hysteria2` | 2454 |
| `vmess` | 412 |
| `anytls` | 44 |
| `tuic` | 40 |
| `socks` | 1 |
| `wireguard` | 1 |

## Покрытие: протокол × транспорт × security

| протокол | транспорт | security | узлов |
|---|---|---|--:|
| vless | none | reality | 31240 |
| vless | ws | tls | 16131 |
| shadowsocks | none | none | 5613 |
| vless | ws | none | 5050 |
| vless | grpc | reality | 4674 |
| hysteria2 | none | tls | 2454 |
| trojan | ws | tls | 2224 |
| vless | none | tls | 2037 |
| vless | xhttp | reality | 945 |
| vless | grpc | tls | 656 |
| trojan | none | tls | 580 |
| vless | xhttp | tls | 553 |
| vless | none | none | 390 |
| vless | http | tls | 318 |
| vmess | none | none | 218 |
| vless | http | reality | 178 |
| vless | grpc | none | 145 |
| vmess | ws | tls | 141 |
| vless | httpupgrade | none | 82 |
| vless | httpupgrade | tls | 65 |
| vmess | ws | none | 50 |
| vless | http | none | 49 |
| anytls | none | tls | 44 |
| tuic | none | tls | 40 |
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
