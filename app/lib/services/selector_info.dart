import 'package:flutter/foundation.dart' show visibleForTesting;

// §251 — держатель «какие теги — селекторы и что они сейчас выбрали».
//
// Ядро отдаёт цепочки (`chains`/`detours`) плоскими списками строк без ролей;
// элемент-селектор в detour-оси всегда идёт непосредственно перед своим
// выбором. Чтобы UI мог схлопнуть пару в `селектор (выбор)` (§251), нужен
// признак «эта строка — селектор». Признак — живые данные приложения, не
// regex: теги групп от ядра (+ их текущий selected) с fallback'ом на Направления
// из storage, когда туннель не поднят.
//
// Паттерн — `RuleNameResolver.I` (§165): пассивный синглтон-держатель,
// обновляется из HomeController. Осознанное исключение из принципа «модель
// vpn не знает про резолвер» (см. `CcConnection.routingLineOf`): продевать
// набор селекторов параметром через все call-site'ы + argless-getter
// `routingLine` (dump-writer) хуже, чем держатель без зависимостей.
class SelectorInfo {
  SelectorInfo._();
  static final SelectorInfo I = SelectorInfo._();

  /// Теги групп эмитированного конфига (push от ядра). Заменяется целиком
  /// на каждый push — снапшот авторитетен, теги ПРОШЛЫХ конфигов не копятся
  /// (иначе обычная нода-омоним удалённого Направления фолдилась бы ложно).
  final Set<String> _kernelTags = <String>{};

  /// Storage-fallback (Направления §125 + двойники): фолд работает и до первого
  /// подключения. Тоже replace-семантика — refreshDirectionLabels зовётся
  /// после каждого редактирования Направлений, удалённое Направление уходит сразу.
  final Set<String> _fallbackTags = <String>{};

  /// tag → текущий выбранный outbound. Только при поднятом туннеле; на
  /// disconnect протухает и чистится (`clearSelected`), теги остаются.
  final Map<String, String> _selected = <String, String>{};

  /// Push групп от ядра: полный снапшот тегов и выборов (замещение целиком).
  void setGroups(Map<String, String> tagToSelected) {
    _kernelTags
      ..clear()
      ..addAll(tagToSelected.keys);
    _selected
      ..clear()
      ..addAll(tagToSelected);
  }

  /// Storage-fallback: актуальные Направления целиком (замещение). Выборы не
  /// трогаем — storage их не знает.
  void setFallbackTags(Iterable<String> tags) {
    _fallbackTags
      ..clear()
      ..addAll(tags);
  }

  /// Туннель down: выборы протухли. Теги НЕ чистим — история (профайлер,
  /// закрытые conns) продолжает фолдиться корректно до следующего
  /// push'а/refresh'а.
  void clearSelected() => _selected.clear();

  bool isSelector(String tag) =>
      _kernelTags.contains(tag) || _fallbackTags.contains(tag);

  /// Текущий выбор селектора; null = неизвестен (туннель down / не группа).
  String? selectedOf(String tag) => _selected[tag];

  /// Полный сброс — только для тестов (синглтон делится между test-кейсами).
  @visibleForTesting
  void resetForTesting() {
    _kernelTags.clear();
    _fallbackTags.clear();
    _selected.clear();
  }
}

/// §251 — схлопывание пар «селектор + его выбор» в один элемент
/// `селектор (выбор)`. Элемент, являющийся известным селектором, поглощает
/// СЛЕДУЮЩИЙ (в цепочках ядра выбор идёт сразу за селектором).
///
/// Фолд идёт СПРАВА НАЛЕВО: выбор селектора может сам быть селектором
/// (Направление в режиме AUTO → его urltest-двойник → узел) — тогда пары
/// вкладываются: `vpn-4 (vpn-4-auto (узел))`, и реальный узел не остаётся
/// «лишним хопом». Селектор последним элементом (без выбора рядом) не
/// трогается. Исходный список не мутируется.
List<String> foldSelectorPairs(List<String> chain) {
  if (chain.length < 2) return chain;
  final out = <String>[];
  String? carry;
  for (var i = chain.length - 1; i >= 0; i--) {
    final t = chain[i];
    if (carry != null && SelectorInfo.I.isSelector(t)) {
      carry = '$t ($carry)'; // селектор поглощает уже-сфолженный выбор
    } else {
      if (carry != null) out.add(carry);
      carry = t;
    }
  }
  if (carry != null) out.add(carry);
  return out.reversed.toList();
}
