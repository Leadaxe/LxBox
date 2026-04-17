# 007 — Форматирование JSON в редакторе конфига

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## 1. Цель

При открытии редактора конфига (`ConfigScreen`) отображать JSON с отступами (pretty-printed) для удобного чтения и редактирования. При сохранении — конвертировать обратно в compact JSON для sing-box.

## 2. Поведение

- **Открытие**: `configRaw` → `json5Decode` → `JsonEncoder.withIndent('  ').convert()` → отображение в TextField
- **Сохранение**: текст из TextField → `canonicalJsonForSingbox()` → compact JSON → sing-box ядро
- **Ошибка парсинга при открытии**: показать как есть (raw текст), без форматирования

## 3. Реализация

Добавить в `config_parse.dart`:

```dart
String prettyJsonForDisplay(String raw) {
  try {
    final parsed = json5Decode(raw.trim());
    return JsonEncoder.withIndent('  ').convert(parsed);
  } catch (_) {
    return raw;
  }
}
```

В `ConfigScreen.initState()`: использовать `prettyJsonForDisplay()` вместо raw.

## 4. Критерии приёмки

- [x] JSON в редакторе отображается с отступами (2 пробела).
- [x] Сохранение работает корректно (compact JSON для ядра).
- [x] Невалидный JSON/JSON5 отображается as-is без краша.
