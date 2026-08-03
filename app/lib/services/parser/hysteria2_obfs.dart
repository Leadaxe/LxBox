import '../../models/node_warning.dart';

/// §358 — нормализация hysteria2-обфускации к словарю ядра.
///
/// КОРЕНЬ БАГА (#53): эмиттер писал секцию `obfs` только для `salamander`,
/// и `gecko` молча терялся — ядро поднимало plain QUIC, сервер такие пакеты
/// дропает. Нода «подключена», трафика нет.
///
/// Почему нормализуем на входе, а не на эмите: ядро валидирует obfs строго
/// и роняет ВЕСЬ конфиг, а не одну ноду.
///
/// * тип вне `enum:"salamander,gecko"` → `Hysteria2Obfs.MarshalJSON` вернёт
///   «unknown obfs type» (option/hysteria2.go) — конфиг не соберётся;
/// * пустой пароль при любом типе → «missing obfs password»
///   (protocol/hysteria2/outbound.go) — fatal при создании outbound.
///
/// Правило то же, что у §281: битое значение отбрасываем и предупреждаем,
/// ноду сохраняем. Обфускация — клиентская обёртка поверх рабочего сервера;
/// выкидывать всю ноду из-за неё = терять живой сервер.

/// Зеркало `enum:"salamander,gecko"` из `option/hysteria2.go`. При бампе
/// ядра сверять с `_Hysteria2Obfs.Type`.
const Set<String> kHysteria2ObfsTypes = {'salamander', 'gecko'};

/// Результат нормализации: тип, который ядро примет (`''` — без обфускации),
/// и пароль к нему (пустой при сброшенном типе).
typedef Hysteria2Obfs = ({String type, String password});

/// Канонизирует пару (тип, пароль). Сброшенный тип плюсует варнинг в
/// [warnings] (`null` — молчаливый режим, для путей без аккумулятора).
Hysteria2Obfs normalizeHysteria2Obfs(
  String rawType,
  String password,
  List<NodeWarning>? warnings,
) {
  final type = rawType.trim().toLowerCase();
  if (type.isEmpty) return (type: '', password: '');
  if (!kHysteria2ObfsTypes.contains(type)) {
    warnings?.add(UnknownObfsWarning(rawType.trim()));
    return (type: '', password: '');
  }
  if (password.isEmpty) {
    warnings?.add(MissingObfsPasswordWarning(type));
    return (type: '', password: '');
  }
  return (type: type, password: password);
}
