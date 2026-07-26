import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/models/tunnel_status.dart';

/// §309 — разведение running (`configRaw`) и pending (`pendingConfigRaw`).
///
/// Корень бага: при живом туннеле пересборка перетирала `configRaw`, хотя ядро
/// продолжало крутить старый конфиг. Список нод приходит из памяти ядра
/// (`ccGroups`, §122), а resolve тега шёл по уже переписанному конфигу — UI
/// смешивал два среза и отдавал `Not found` на видимую в списке ноду.
void main() {
  String cfg(List<String> tags) => jsonEncode({
        'outbounds': [
          for (final t in tags) {'tag': t, 'type': 'vless'},
        ],
      });

  final running = cfg(['L: ⚡Франция']);
  final rebuilt = cfg(['L: zФранция']); // import-rule §302: ⚡ → z

  group('§309 инвариант pending ⟺ configChangedNeedRestart', () {
    test('пустой state — pending null, флага нет', () {
      final s = HomeState();
      expect(s.pendingConfigRaw, isNull);
      expect(s.configChangedNeedRestart, isFalse);
    });

    test('выставленный pending поднимает флаг', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt);
      expect(s.configChangedNeedRestart, isTrue);
    });

    test('промоушен гасит флаг и переносит конфиг в actual', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt)
          .promotePendingConfig();
      expect(s.configRaw, rebuilt);
      expect(s.pendingConfigRaw, isNull);
      expect(s.configChangedNeedRestart, isFalse);
    });

    test('промоушен без pending идемпотентен', () {
      final s = HomeState(configRaw: running);
      expect(s.promotePendingConfig().configRaw, running);
      expect(s.promotePendingConfig().pendingConfigRaw, isNull);
    });

    test('markRunningConfigStale — флаг без смены конфига (§076 native-тоглы)',
        () {
      final s = HomeState(configRaw: running).markRunningConfigStale();
      expect(s.configChangedNeedRestart, isTrue);
      expect(s.configRaw, running, reason: 'сам JSON не менялся');
      expect(s.pendingConfigRaw, running);
    });

    test('markRunningConfigStale sticky — не затирает реальный pending', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt)
          .markRunningConfigStale();
      expect(s.pendingConfigRaw, rebuilt,
          reason: 'более раннюю реальную пересборку терять нельзя');
    });
  });

  group('§309 configModel строится от actual', () {
    test('РЕГРЕСС: при живом pending resolve идёт по конфигу ядра', () {
      // Ровно сценарий бага: ядро крутит '⚡Франция' (и отдаёт этот тег в
      // списке нод), пересборка уже переписала его в 'zФранция'.
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: running,
        pendingConfigRaw: rebuilt,
      );

      // Тег из списка (= из ядра) обязан резолвиться — иначе «Not found»
      // на ноду, видимую строкой выше.
      expect(s.configModel['L: ⚡Франция'], isNotNull);
      expect(s.configModel.outboundChain('L: ⚡Франция'), isNotEmpty);

      // Тег из ещё не применённой пересборки в actual-модели отсутствовать
      // и должен — ядро о нём не знает.
      expect(s.configModel['L: zФранция'], isNull);
    });

    test('после промоушена resolve переезжает на новый тег', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configRaw: running,
        pendingConfigRaw: rebuilt,
      ).promotePendingConfig();

      expect(s.configModel['L: zФранция'], isNotNull);
      expect(s.configModel['L: ⚡Франция'], isNull);
    });
  });

  group('§309 editableConfigRaw / hasConfig', () {
    test('редактор показывает pending при живом туннеле', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt);
      expect(s.editableConfigRaw, rebuilt,
          reason: 'иначе правки юзера «пропадали» бы до рестарта');
    });

    test('без pending редактор показывает actual', () {
      expect(HomeState(configRaw: running).editableConfigRaw, running);
    });

    test('hasConfig учитывает и actual, и pending', () {
      expect(HomeState().hasConfig, isFalse);
      expect(HomeState(configRaw: running).hasConfig, isTrue);
      expect(HomeState(pendingConfigRaw: rebuilt).hasConfig, isTrue);
    });
  });

  group('§309 copyWith', () {
    test('pending сбрасывается явным null (не _unset)', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt)
          .copyWith(pendingConfigRaw: null);
      expect(s.pendingConfigRaw, isNull);
    });

    test('copyWith без pending его не трогает', () {
      final s = HomeState(configRaw: running, pendingConfigRaw: rebuilt)
          .copyWith(busy: true);
      expect(s.pendingConfigRaw, rebuilt);
    });

    test('configModel пересобирается только при смене configRaw', () {
      final s = HomeState(configRaw: running);
      final same = s.copyWith(busy: true);
      expect(identical(same.configModel, s.configModel), isTrue,
          reason: '§091 — лишний jsonDecode на каждый copyWith недопустим');

      final changed = s.copyWith(configRaw: rebuilt);
      expect(identical(changed.configModel, s.configModel), isFalse);
    });
  });
}
