import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

import 'engine_test_setup.dart';

/// §459 (контракт §24.2 п. 7.11) — `vmess.security` = enum ядра.
///
/// `sing-vmess@v0.2.8` `client.go:42-54` принимает ровно шесть значений и на
/// любом другом возвращает `ErrUnsupportedSecurityType` — фатал на ВЕСЬ
/// конфиг, а не на один узел. Раньше парсер пропускал `aes-128-ctr` (ядро его
/// не знает) и схлопывал рабочий `aes-128-cfb` в `auto`.
///
/// Все три входа (URI v2rayN `scy`, sing-box JSON, Xray JSON) идут через одну
/// воронку [normalizeVmessSecurity].
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  String vmessUri(String scy) {
    final cfg = jsonEncode({
      'v': '2',
      'ps': 'N',
      'add': 'h.example',
      'port': '443',
      'id': '11111111-2222-3333-4444-555555555555',
      'aid': '0',
      'scy': scy,
      'net': 'tcp',
    });
    return 'vmess://${base64.encode(utf8.encode(cfg))}';
  }

  String singbox(String security) => (parseSingboxEntry({
        'type': 'vmess',
        'tag': 'v',
        'server': 'h.example',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'security': security,
      })! as VmessSpec)
          .security;

  String xray(String security) => parseXrayElement({
        'remarks': 'X',
        'outbounds': [
          {
            'tag': 'v',
            'protocol': 'vmess',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {
                      'id': '11111111-2222-3333-4444-555555555555',
                      'security': security,
                    }
                  ],
                }
              ],
            },
            'streamSettings': {'network': 'tcp'},
          },
        ],
      }).whereType<VmessSpec>().single.security;

  group('normalizeVmessSecurity — enum ядра', () {
    test('шесть значений ядра проходят как есть', () {
      for (final m in kVmessSecurityMethods) {
        expect(normalizeVmessSecurity(m), m);
      }
      expect(kVmessSecurityMethods, {
        'auto',
        'none',
        'zero',
        'aes-128-cfb',
        'aes-128-gcm',
        'chacha20-poly1305',
      });
    });

    test('trim + lower', () {
      expect(normalizeVmessSecurity('  AES-128-CFB '), 'aes-128-cfb');
      expect(normalizeVmessSecurity('AUTO'), 'auto');
    });

    test('алиас chacha20-ietf-poly1305 → chacha20-poly1305', () {
      expect(normalizeVmessSecurity('chacha20-ietf-poly1305'),
          'chacha20-poly1305');
      expect(normalizeVmessSecurity('CHACHA20-IETF-POLY1305'),
          'chacha20-poly1305');
    });

    test('пусто / null / undefined → auto', () {
      for (final v in ['', '   ', 'null', 'undefined', 'NULL']) {
        expect(normalizeVmessSecurity(v), 'auto', reason: 'v="$v"');
      }
    });

    test('вне enum (в т.ч. aes-128-ctr) → auto', () {
      for (final v in ['aes-128-ctr', 'aes-256-gcm', 'rc4', 'x']) {
        expect(normalizeVmessSecurity(v), 'auto', reason: 'v="$v"');
      }
    });
  });

  group('все три входа идут через воронку', () {
    test('URI v2rayN scy', () {
      expect((parseUri(vmessUri('aes-128-ctr'))! as VmessSpec).security, 'auto');
      expect((parseUri(vmessUri('AES-128-CFB'))! as VmessSpec).security,
          'aes-128-cfb');
      expect(
          (parseUri(vmessUri('chacha20-ietf-poly1305'))! as VmessSpec).security,
          'chacha20-poly1305');
      expect((parseUri(vmessUri(''))! as VmessSpec).security, 'auto');
    });

    test('sing-box JSON', () {
      expect(singbox('aes-128-ctr'), 'auto');
      expect(singbox('AES-128-CFB'), 'aes-128-cfb');
      expect(singbox('chacha20-ietf-poly1305'), 'chacha20-poly1305');
      expect(singbox(''), 'auto');
    });

    test('Xray JSON', () {
      expect(xray('aes-128-ctr'), 'auto');
      expect(xray('AES-128-CFB'), 'aes-128-cfb');
      expect(xray('chacha20-ietf-poly1305'), 'chacha20-poly1305');
      expect(xray(''), 'auto');
    });
  });
}
