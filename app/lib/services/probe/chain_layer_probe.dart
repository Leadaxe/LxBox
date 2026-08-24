// §394 — послойная проба цепочки: сколько стоит КАЖДЫЙ хоп маршрута.
//
// Паритет с лаунчером (`ui/servers_node_info_chain.go`, `core/chain_probe.go`,
// `core/debugapi/chain_endpoints.go`). Инструмент отладки обязан отвечать
// ОДИНАКОВО на обеих платформах: пользователь приходит с одной и той же
// цепочкой и одним и тем же вопросом «где рвётся», и две разные картинки
// означали бы, что одна из них врёт.
//
// ЧТО МЕРИТСЯ. Не хоп по отдельности — его измерить нельзя: позиция i
// недостижима иначе как через i-1. Меряются ПРЕФИКСЫ маршрута («слои»): путь
// от клиента до позиции k включительно. Цена хопа — разность соседних
// префиксов, и она всегда вычитание, а не замер.
//
// СХЕМА ТЕГОВ — ЯДРА, не наша. `Chain.Start` регистрирует внутренний outbound
// на каждую позицию под тегом `<chain>#<i>` (`protocol/chain/chain.go:135`,
// `hopTag`), и `outboundManager.Outbound(tag)` резолвит внутренние наравне с
// обычными (`adapter/outbound/manager.go:219`) — значит `urlTestOutbound` их
// видит. Лаунчер собирает тот же тег общим `config.ChainLayerTag`
// (`core/config/chain_validate.go:100`); [chainLayerTag] здесь — третья копия
// ОДНОЙ схемы, и разойтись ей нельзя: разъехавшись, она молча мерила бы не то
// (тег не найден → «outbound or endpoint not found», а не цену хопа).
//
// ПОЧЕМУ ТОЛЬКО ПРИ ЖИВОМ VPN. Обычная проба узла (§236) поднимает временную
// probe-сессию из синтетического конфига, и это здесь не работает: позиции
// цепочки — ссылки на теги СОБРАННОГО конфига (Направления, группы подписок,
// другие цепочки), которые появляются только после полной сборки. Собрать
// «маленький конфиг из одной цепочки» нельзя, не собрав конфиг целиком.
// Вдобавок внутренние теги `#i` существуют только в рантайме ядра — ровно то
// же ограничение, что у лаунчера, где проба живёт на работающем ядре.
// Поэтому при выключенном туннеле честно возвращается [ChainProbeUnavailable]
// с причиной `vpn_down`, а не пустые прочерки.

import '../../models/tunnel_status.dart';
import '../../vpn/box_vpn_client.dart';
import '../../vpn/cc_channel.dart';
import 'probe_controller.dart';
import 'probe_lifecycle.dart';

/// Служебный тег префикса цепочки: путь от клиента до позиции [pos]
/// включительно.
///
/// Порт `config.ChainLayerTag` лаунчера; первоисточник — `Chain.hopTag` ядра.
/// Схема ОДНА на три реализации, поэтому и здесь она живёт одной функцией, а
/// не склейкой по месту вызова: склейка расходится незаметно.
String chainLayerTag(String chainTag, int pos) => '$chainTag#$pos';

/// Замер одного слоя.
class ChainLayerResult {
  const ChainLayerResult({
    required this.pos,
    required this.tag,
    required this.probeTag,
    this.cumulativeMs = 0,
    this.error = '',
    this.notReached = false,
  });

  /// Индекс позиции в цепочке (0-based, как в `hops`).
  final int pos;

  /// Тег позиции — то, что стоит в `outbounds[pos]` узла цепочки.
  final String tag;

  /// Служебный тег, которым слой спрашивался у ядра (`<chain>#<pos>`).
  final String probeTag;

  /// НАКОПИТЕЛЬНАЯ задержка: весь путь до этой позиции включительно.
  /// Значима только при пустом [error] и `notReached == false`.
  final int cumulativeMs;

  /// Текст ЯДРА. Не переписывается и не проглатывается: «медленно» и «не
  /// поднялось» — разные диагнозы, и второй ядро формулирует само, зная
  /// позицию и путь до неё.
  final String error;

  /// Слой не пробовали: предыдущий слой оборвался, и всё за ним недостижимо
  /// по построению. Отдельный признак, а не пустая ошибка: «не дошли» и «не
  /// ответил» — разные вещи, и мерить второй слой после обрыва первого
  /// значит тратить бюджет на заведомо мёртвый путь.
  final bool notReached;

  bool get ok => error.isEmpty && !notReached;
}

/// Итог послойного прогона.
class ChainProbeReport {
  const ChainProbeReport({
    required this.chainTag,
    required this.layers,
    required this.url,
    required this.timeoutMs,
  });

  final String chainTag;
  final List<ChainLayerResult> layers;

  /// Чем и с каким бюджетом мерили — те же, что у обычной пробы узла.
  final String url;
  final int timeoutMs;

  /// Цена хопа [i]: разность соседних префиксов, отрицательная сведена к нулю.
  ///
  /// `null` = цены нет: первый слой (не с чем вычитать), слой с ошибкой, слой
  /// после ошибки (опорной точки нет). Ноль вместо `null` читался бы как
  /// «хоп бесплатный», хотя он попросту не измерен.
  ///
  /// Отрицательную сводим к нулю по той же причине, что лаунчер
  /// (`chainDelayText`): «этот хоп ускорил маршрут» — утверждение, из
  /// которого пользователю нечего извлечь, а шум в десятки мс между двумя
  /// пробами нормален.
  int? deltaAt(int i) {
    if (i <= 0 || i >= layers.length) return null;
    final cur = layers[i];
    final prev = layers[i - 1];
    if (!cur.ok || !prev.ok) return null;
    final cost = cur.cumulativeMs - prev.cumulativeMs;
    return cost < 0 ? 0 : cost;
  }
}

/// Прогон невозможен как таковой (в отличие от слоя с ошибкой — тот
/// нормальный результат и приезжает внутри отчёта).
class ChainProbeUnavailable implements Exception {
  const ChainProbeUnavailable(this.reason);

  /// Машинный код: `vpn_down` | `not_a_chain` | `no_positions`.
  final String reason;

  /// Туннель выключен — цепочки в рантайме нет.
  bool get isVpnDown => reason == 'vpn_down';

  @override
  String toString() => reason;
}

/// Послойная проба цепочки через БОЕВОЕ ядро.
class ChainLayerProbe {
  ChainLayerProbe({CcChannel? cc, BoxVpnClient? vpn})
      : _cc = cc ?? CcChannel.instance,
        _vpn = vpn ?? BoxVpnClient();

  final CcChannel _cc;
  final BoxVpnClient _vpn;

  bool _cancelled = false;

  /// §286 — отмена кооперативная, как у [ProbeRunner]: уход с экрана и stop
  /// VPN гасят прогон, который иначе доигрывал бы слои в пустоту.
  void cancel() => _cancelled = true;

  /// Меряет слои цепочки [chainTag] с позициями [hops].
  ///
  /// [hops] — позиции В ПОРЯДКЕ ПАКЕТА, как они лежат в `outbounds` узла
  /// цепочки СОБРАННОГО конфига. Именно оттуда, а не из списка источников:
  /// ядро запустило то, что собрано, и мерить надо позиции работающей
  /// цепочки. Расходится — значит конфиг ушёл вперёд без перезапуска, и
  /// цифры относились бы к маршруту, которого в ядре нет.
  ///
  /// ПОСЛЕДОВАТЕЛЬНО, а не пулом (в отличие от пробы папки): слой k+1 идёт
  /// ЧЕРЕЗ тот же путь, что слой k, и параллельный прогон поднимал бы одни и
  /// те же туннели одновременно, искажая замеры друг друга.
  ///
  /// Бюджет и URL — из тех же `ping_options`, что у обычной пробы узла
  /// ([ProbeController.resolvePingOptions]): расхождение с кнопкой теста
  /// сделало бы «почему цифры разные» ложной загадкой.
  Future<ChainProbeReport> run(
    String chainTag, {
    required List<String> hops,
    String? url,
    int? timeoutMs,
  }) async {
    _cancelled = false;
    final canceller = ProbeLifecycle.I.register(cancel);
    try {
      if (hops.isEmpty) throw const ChainProbeUnavailable('no_positions');

      final vpnUp = (await _vpn.getVpnStatus()) == TunnelStatus.connected;
      if (!vpnUp) throw const ChainProbeUnavailable('vpn_down');

      final opts = await ProbeController.resolvePingOptions(
        overrideUrl: url,
        overrideTimeoutMs: timeoutMs,
      );

      final layers = <ChainLayerResult>[];
      var broken = false;
      for (var i = 0; i < hops.length; i++) {
        final probeTag = chainLayerTag(chainTag, i);
        // Обрыв на слое k делает все следующие недостижимыми ПО ПОСТРОЕНИЮ —
        // не «вероятно мёртвыми», а именно недостижимыми: пакет до них не
        // доходит. Мерить их значило бы потратить бюджет на выяснение того,
        // что уже известно, и показать вторую ошибку, которая ничего не
        // добавляет к первой.
        if (broken || _cancelled) {
          layers.add(ChainLayerResult(
            pos: i,
            tag: hops[i],
            probeTag: probeTag,
            notReached: true,
          ));
          continue;
        }
        final r = await _cc.urlTestOutbound(
          probeTag,
          link: opts.url,
          timeoutMs: opts.timeoutMs,
        );
        if (!r.ok) broken = true;
        layers.add(ChainLayerResult(
          pos: i,
          tag: hops[i],
          probeTag: probeTag,
          cumulativeMs: r.ok ? r.delay : 0,
          error: r.error,
        ));
      }
      return ChainProbeReport(
        chainTag: chainTag,
        layers: layers,
        url: opts.url,
        timeoutMs: opts.timeoutMs,
      );
    } finally {
      ProbeLifecycle.I.deregister(canceller);
    }
  }
}

/// Позиции цепочки [chainTag] из СОБРАННОГО конфига, либо `null`, если такого
/// узла там нет или он не цепочка.
///
/// Источник — `outbounds` узла типа `chain`: у ядра это и есть список
/// позиций, и брать его из списка источников значило бы показать маршрут,
/// который пользователь набрал, вместо того, который сейчас работает.
List<String>? chainHopsFromConfig(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  if (raw['type'] != 'chain') return null;
  final list = raw['outbounds'];
  if (list is! List) return null;
  return [
    for (final h in list)
      if (h is String) h,
  ];
}
