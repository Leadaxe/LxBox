import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';

/// §323 — реакция подписки на авто-обновление: персист поля, агрегация
/// действий за проход апдейтера и гейт «состав не изменился» в
/// `saveParsedConfig`.
///
/// `AutoUpdater.maybeUpdateAll` и `HomeController.saveParsedConfig` целиком в
/// юнит-тесте не поднимаются (первый ходит в сеть через
/// `SubscriptionController`, второй — в native-каналы). Поэтому агрегация и
/// гейт проверяются на копиях той же логики, как в §311
/// `running_config_epoch_test.dart`; персист поля — на реальной модели.

SubscriptionServers _sub({
  SubscriptionOnUpdateAction action = SubscriptionOnUpdateAction.rebuild,
}) =>
    SubscriptionServers(
      id: 'sub-1',
      name: 'sub',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      onUpdateAction: action,
    );

void main() {
  group('§323 модель: onUpdateAction персистится', () {
    test('дефолт — rebuild, ключ в JSON не пишется', () {
      final json = _sub().toJson();
      expect(json.containsKey('on_update_action'), isFalse,
          reason: 'дефолт не должен раздувать JSON');
      final back = ServerList.fromJson(json) as SubscriptionServers;
      expect(back.onUpdateAction, SubscriptionOnUpdateAction.rebuild);
    });

    test('не-дефолт переживает round-trip (§221 — едет в backup)', () {
      for (final a in [
        SubscriptionOnUpdateAction.reload,
        SubscriptionOnUpdateAction.none,
      ]) {
        final json = _sub(action: a).toJson();
        expect(json['on_update_action'], a.name);
        final back = ServerList.fromJson(json) as SubscriptionServers;
        expect(back.onUpdateAction, a, reason: '$a потерялся на round-trip');
      }
    });

    test('copyWith сохраняет значение, когда его не передали', () {
      final s = _sub(action: SubscriptionOnUpdateAction.reload);
      expect(s.copyWith(name: 'renamed').onUpdateAction,
          SubscriptionOnUpdateAction.reload);
    });

    test('мусор/отсутствие в JSON → дефолт rebuild (толерантный парс)', () {
      for (final raw in [null, 'bogus', 42, true]) {
        expect(SubscriptionOnUpdateAction.fromJson(raw),
            SubscriptionOnUpdateAction.rebuild,
            reason: 'raw=$raw должен деградировать в дефолт');
      }
    });

    test('старая запись без ключа читается как rebuild (миграции нет)', () {
      final legacy = <String, dynamic>{
        'type': 'subscription',
        'id': 'old',
        'name': 'old',
        'enabled': true,
        'tag_prefix': '',
        'detour_policy': const <String, dynamic>{},
        'url': 'https://example.com/x',
      };
      final back = ServerList.fromJson(legacy) as SubscriptionServers;
      expect(back.onUpdateAction, SubscriptionOnUpdateAction.rebuild);
    });
  });

  group('§323 агрегация действий за проход апдейтера', () {
    /// Копия решения из `AutoUpdater.maybeUpdateAll`: реакции копятся за весь
    /// проход и применяются один раз. Иначе три обновившиеся подписки дали бы
    /// три пересборки (и до трёх разрывов туннеля).
    // §331 (ревью) — на вход агрегатору попадают ТОЛЬКО подписки, у которых
    // `refreshEntry` вернул «состав изменился». Успешный фетч с тем же
    // списком нод в агрегацию не входит вовсе (иначе часовой тик гонял бы
    // пересборку впустую) — это гейтится ДО switch'а, см. maybeUpdateAll.
    ({bool rebuild, bool reload}) aggregate(
        List<SubscriptionOnUpdateAction> refreshedOk) {
      var rebuild = false;
      var reload = false;
      for (final a in refreshedOk) {
        switch (a) {
          case SubscriptionOnUpdateAction.reload:
            reload = true;
            rebuild = true;
          case SubscriptionOnUpdateAction.rebuild:
            rebuild = true;
          case SubscriptionOnUpdateAction.none:
            break;
        }
      }
      return (rebuild: rebuild, reload: reload);
    }

    test('ни одна не обновилась → реакции нет', () {
      expect(aggregate(const []), (rebuild: false, reload: false));
    });

    test('только none → ничего не делаем', () {
      expect(
        aggregate(const [
          SubscriptionOnUpdateAction.none,
          SubscriptionOnUpdateAction.none,
        ]),
        (rebuild: false, reload: false),
      );
    });

    test('rebuild не тянет за собой reload', () {
      expect(aggregate(const [SubscriptionOnUpdateAction.rebuild]),
          (rebuild: true, reload: false));
    });

    test('reload побеждает: одна просит применить — применяем всем', () {
      // Подписки едут в ОДИН общий конфиг, порознь их не применить.
      expect(
        aggregate(const [
          SubscriptionOnUpdateAction.none,
          SubscriptionOnUpdateAction.rebuild,
          SubscriptionOnUpdateAction.reload,
        ]),
        (rebuild: true, reload: true),
      );
    });

    test('три reload-подписки → один reload, не три', () {
      final r = aggregate(const [
        SubscriptionOnUpdateAction.reload,
        SubscriptionOnUpdateAction.reload,
        SubscriptionOnUpdateAction.reload,
      ]);
      expect(r, (rebuild: true, reload: true));
    });
  });

  group('§323 гейт «состав не изменился» в saveParsedConfig', () {
    /// Копия строки из `config_io.dart`. До §323 было
    /// `(changed && tunnelUp) || prev` — sticky prev переживал пересборку,
    /// давшую конфиг, идентичный работающему, и плашка висела без причины
    /// (типовой случай: подписка раз в час отдаёт тот же список нод).
    bool needRestart(
            {required bool changed,
            required bool tunnelUp,
            required bool prev}) =>
        changed && (tunnelUp || prev);

    test('изменился при живом туннеле → плашка', () {
      expect(needRestart(changed: true, tunnelUp: true, prev: false), isTrue);
    });

    test('РЕГРЕСС §323: не изменился → плашка ГАСНЕТ, а не остаётся sticky', () {
      expect(needRestart(changed: false, tunnelUp: true, prev: true), isFalse,
          reason: 'saved == running ⇒ running не устарел, история не важна');
    });

    test('не изменился и флага не было → плашки нет', () {
      expect(needRestart(changed: false, tunnelUp: true, prev: false), isFalse);
    });

    test('§116 сохранён: изменился при VPN down, но флаг уже был → остаётся', () {
      // Реальное изменение, ещё не применённое рестартом, не теряем.
      expect(needRestart(changed: true, tunnelUp: false, prev: true), isTrue);
    });

    test('изменился при VPN down без прежнего флага → плашки нет', () {
      expect(needRestart(changed: true, tunnelUp: false, prev: false), isFalse);
    });
  });

  group('§323 решение о reload после пересборки', () {
    /// Копия гейтов из `_reactToSubscriptionUpdate`: reload'им только когда
    /// режим просит, туннель поднят и конфиг реально разошёлся с running.
    bool shouldReload({
      required bool reloadRequested,
      required bool tunnelUp,
      required bool configChangedNeedRestart,
    }) =>
        reloadRequested && tunnelUp && configChangedNeedRestart;

    test('режим reload + туннель up + конфиг разошёлся → reload', () {
      expect(
          shouldReload(
              reloadRequested: true,
              tunnelUp: true,
              configChangedNeedRestart: true),
          isTrue);
    });

    test('конфиг идентичен running → НЕ рвём туннель на 3с', () {
      expect(
          shouldReload(
              reloadRequested: true,
              tunnelUp: true,
              configChangedNeedRestart: false),
          isFalse);
    });

    test('туннель не поднят → reload не нужен, подхватится на Start', () {
      expect(
          shouldReload(
              reloadRequested: true,
              tunnelUp: false,
              configChangedNeedRestart: true),
          isFalse);
    });

    test('режим rebuild → туннель не трогаем даже при расхождении', () {
      expect(
          shouldReload(
              reloadRequested: false,
              tunnelUp: true,
              configChangedNeedRestart: true),
          isFalse);
    });
  });
}
