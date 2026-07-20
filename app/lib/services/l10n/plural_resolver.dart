// §285 — plural-resolver'ы для getLocalText. Выбирают строку-форму из
// plural-объекта словаря по числу. Набор форм (`forms`) диктует, какие ключи
// value-объект обязан содержать (CI-гейт ui_check сверяет по нему).

/// Стратегия выбора plural-формы по числу. Регистрируется per-язык в
/// LocaleController._applyLocale (ru → RuPluralResolver, иначе En).
abstract class PluralResolver {
  /// Ключи plural-форм, которые resolver ждёт в value-объекте.
  Set<String> get forms;

  /// Выбор строки-формы по числу из plural-объекта. `n` — num: для целочисленных
  /// работают CLDR-правила по разрядам, дробные уходят в `other` (там где язык
  /// это различает).
  String select(Map<String, String> forms, num n);
}

/// Английский: `one` (n==1) / `other`. Тривиальный, служит fallback-контролем.
class EnPluralResolver implements PluralResolver {
  const EnPluralResolver();

  @override
  Set<String> get forms => const {'one', 'other'};

  @override
  String select(Map<String, String> forms, num n) =>
      forms[n == 1 ? 'one' : 'other'] ?? forms['other'] ?? '';
}

/// Русский по CLDR: one/few/many/other. Дробные → other.
///
///   n%10==1 && n%100!=11          → one   (1, 21, 31, ... но не 11)
///   n%10 in 2..4 && n%100 not 12..14 → few (2..4, 22..24, ... но не 12..14)
///   иначе                          → many  (0, 5..20, 25..30, ...)
///   не целое                       → other (1.5)
class RuPluralResolver implements PluralResolver {
  const RuPluralResolver();

  @override
  Set<String> get forms => const {'one', 'few', 'many', 'other'};

  @override
  String select(Map<String, String> forms, num n) {
    String pick;
    // Дробные (n != целое) → other: у русского нет разрядной формы для дробей.
    if (n is! int && n != n.truncate()) {
      pick = 'other';
    } else {
      final i = n.abs().truncate();
      final mod10 = i % 10;
      final mod100 = i % 100;
      if (mod10 == 1 && mod100 != 11) {
        pick = 'one';
      } else if (mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14)) {
        pick = 'few';
      } else {
        pick = 'many';
      }
    }
    // Дефолт-цепочка на случай неполного plural-объекта (не должно при зелёном
    // CI, но resolver никогда не бросает).
    return forms[pick] ?? forms['other'] ?? forms['many'] ?? '';
  }
}
