import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';

void main() {
  group('NodeWarning equality', () {
    test('same subclass + same fields == equal', () {
      expect(
        const UnknownObfsWarning('salamander'),
        const UnknownObfsWarning('salamander'),
      );
    });

    // §279 — равенство по runtimeType + полям данных (не по отрендеренной
    // строке): dedup-гранулярность та же, но переживает смену локали.
    test('same subclass + different fields != equal', () {
      expect(
        const UnknownObfsWarning('salamander') ==
            const UnknownObfsWarning('gecko'),
        isFalse,
      );
      expect(
        const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'a') ==
            const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'b'),
        isFalse,
      );
    });

    // SPEC 083 / §444 — предупреждение REALITY + не-chrome отпечаток: равенство
    // по значению, машинный рендер — английский ключ с подставленным именем;
    // текст советует chrome, а не утверждает подмену.
    test('RealityFingerprintWarning equality + renderEn', () {
      expect(const RealityFingerprintWarning('firefox'),
          const RealityFingerprintWarning('firefox'));
      expect(
          const RealityFingerprintWarning('firefox') ==
              const RealityFingerprintWarning('safari'),
          isFalse);
      expect(
          const RealityFingerprintWarning('firefox').renderEn(),
          'REALITY with uTLS fingerprint "firefox": Xray servers since '
          'v26.9.8 reject this ClientHello. If the connection fails, try '
          '"chrome".');
      // §468 — severity читается из реестра (`info` в контракте 1.1.2+).
      // Здесь реестр не загружен, и проверяется именно запасной путь:
      // незнакомый код не глушится, а остаётся `warning`.
      expect(const RealityFingerprintWarning('firefox').severity,
          WarningSeverity.warning,
          reason: 'реестр не загружен — фолбэк registrySeverity');
    });

    // §279 — XhttpResetReason: message() обязан воспроизводить дословно
    // те же English-фразы, что были free-text до enum'а.
    test('XhttpParamResetWarning renders verbatim from enum reason', () {
      expect(
        const XhttpParamResetWarning(
                'session_placement', XhttpResetReason.invalidEnumValue,
                value: 'bogus')
            .renderEn(),
        'XHTTP "session_placement" reset to default — value "bogus" is not '
        'a valid session_placement (would otherwise break the whole config).',
      );
      expect(
        const XhttpParamResetWarning(
                'uplink_http_method', XhttpResetReason.getRequiresPacketUp)
            .renderEn(),
        'XHTTP "uplink_http_method" reset to default — GET requires '
        'packet-up mode (would otherwise break the whole config).',
      );
    });

    test('different subclasses != equal', () {
      expect(
        const UnknownObfsWarning('salamander') ==
            const UnsupportedProtocolWarning('xhttp'),
        isFalse,
      );
    });

    test('severity maps per type', () {
      expect(const DialerProxyUnusableWarning('n', 't').severity,
          WarningSeverity.error);
      // §485 — коды реестра: severity из warnings.json, не константа класса.
      expect(
          const RegistryWarning(code: 'tls_insecure', path: 'tls.insecure')
              .severity,
          WarningSeverity.warning,
          reason: 'реестр не загружен — фолбэк registrySeverity');
      expect(
          const RegistryWarning(
                  code: 'flow_deprecated', path: 'flow', value: 'x')
              .severity,
          WarningSeverity.warning,
          reason: 'реестр не загружен — фолбэк registrySeverity');
    });

    test('exhaustive switch compiles', () {
      const NodeWarning w = UnknownObfsWarning('salamander');
      final label = switch (w) {
        UnsupportedProtocolWarning() => 'protocol',
        NaiveBuildTagWarning() => 'naive_build',
        XhttpParamResetWarning() => 'xhttp_reset',
        // §416 — header-placement без режима: дописан mode: packet-up
        XhttpModeForcedPacketUpWarning() => 'xhttp_mode_forced_packet_up',
        UnknownFingerprintWarning() => 'fingerprint',
        // SPEC 083 — REALITY принимает только chrome-семейство
        RealityFingerprintWarning() => 'reality_fingerprint',
        UnknownObfsWarning() => 'obfs_unknown',
        MissingObfsPasswordWarning() => 'obfs_no_password',
        // §368 — импорт sing-box JSON
        DetourCycleBrokenWarning() => 'detour_cycle',
        DetourTargetMissingWarning() => 'detour_missing',
        DetourToGroupWarning() => 'detour_group',
        DetourChainTooDeepWarning() => 'detour_deep',
        // §404 — импорт Xray JSON: недостижимый dialerProxy
        DialerProxyUnusableWarning() => 'dialer_proxy_unusable',
        SelectorAsAutoWarning() => 'selector_as_auto',
        GroupMemberMissingWarning() => 'group_member_missing',
        // §435 — только UI, кода контракта нет.
        SectionsRecordDroppedWarning() => 'sections_record_dropped',
        SectionsConflictWarning() => 'sections_conflict',
        Awg3HeaderKeyInvalidWarning() => 'awg3_header_key_invalid',
        Awg3PaddingTooShortWarning() => 'awg3_padding_too_short',
        Awg3RandomTrailersWideHeadersWarning() =>
          'awg3_random_trailers_wide_headers',
        PacketEncodingUnknownWarning() => 'packet_encoding_unknown',
        // §460 — санитайзер реестра: класс один на все свои коды, различает
        // их поле `code` (текст берётся из registry/warnings.json).
        RegistryWarning() => 'registry',
      };
      expect(label, 'obfs_unknown');
    });
  });

  // Коды, у которых рукописный класс снят: `byCode` обязан не только вернуть
  // `RegistryWarning`, но и переложить путь/значение под ИМЯ, которое код
  // объявил в `params` реестра. Без этого текст доехал бы до человека с
  // буквальным `{query_name}` — реестр тут не поможет, подстановку ставит
  // приложение.
  group('byCode — именованные параметры снятых классов', () {
    test('ech_ignored: query_name = имя параметра ссылки', () {
      final w = NodeWarning.byCode('ech_ignored',
          path: 'ech', value: 'encryptedsni.com') as RegistryWarning;
      expect(w.code, 'ech_ignored');
      expect(w.path, 'ech');
      expect(w.value, 'encryptedsni.com');
      expect(w.params['query_name'], 'ech');
    });

    test('ws_early_data_converted: max_early_data = что получилось', () {
      final w = NodeWarning.byCode('ws_early_data_converted',
          path: 'path', value: '2560') as RegistryWarning;
      expect(w.params['max_early_data'], '2560');
    });

    test('naive_extra_headers_invalid: entry = отброшенная пара', () {
      final w = NodeWarning.byCode('naive_extra_headers_invalid',
          path: 'extra-headers', value: 'no-colon') as RegistryWarning;
      expect(w.params['entry'], 'no-colon');
    });

    test('naive_padding_ignored: своего имени не нужно, хватает value', () {
      final w = NodeWarning.byCode('naive_padding_ignored',
          path: 'padding', value: '1') as RegistryWarning;
      expect(w.value, '1');
      expect(w.params, isEmpty);
    });

    // Контракт 1.1.33 переписал тексты обоих кодов AWG с `{path}`/`{value}`
    // и последствием для рукопожатия; классы сняты. Своего имени им не нужно
    // — оба плейсхолдера подставляются всегда (`text_params_implicit`).
    test('awg_header_invalid: RegistryWarning с путём и значением', () {
      final w = NodeWarning.byCode('awg_header_invalid',
          path: 'h1', value: '5-1') as RegistryWarning;
      expect(w.code, 'awg_header_invalid');
      expect(w.path, 'h1');
      expect(w.value, '5-1');
      expect(w.params, isEmpty);
    });

    test('awg3_field_invalid: RegistryWarning с путём и значением', () {
      final w = NodeWarning.byCode('awg3_field_invalid',
          path: 'content_padding_addition', value: '100-10') as RegistryWarning;
      expect(w.code, 'awg3_field_invalid');
      expect(w.path, 'content_padding_addition');
      expect(w.value, '100-10');
      expect(w.params, isEmpty);
    });

    // §279 — равенство по данным: два одинаковых кода на одном поле это одно
    // предупреждение, и дедуп разбора обязан их схлопнуть.
    test('одинаковые код+путь+значение равны', () {
      expect(
        NodeWarning.byCode('ech_ignored', path: 'ech', value: 'ip.gs'),
        NodeWarning.byCode('ech_ignored', path: 'ech', value: 'ip.gs'),
      );
    });
  });
}
