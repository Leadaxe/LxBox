# §631 — Просмотр правила и DNS-сервера: JSON без подсветки

| Поле | Значение |
|------|----------|
| Тип | Дефект |
| Статус | D (done), выпущено в v2.25.13 |
| Дата | 2026-10-12 |
| Связанные | §624 (все JSON-поля на sora-editor), §053 (вкладка View правила), §117 (JSON tab DNS-сервера) |

## Проблема

Вкладка **View** редактора правила (в том числе правила из пресета) показывает
два JSON-блока — «storage shape» и «sing-box config preview» — обычным текстом:
без подсветки, без прокрутки вбок, с собственной серой рамкой, которая не
похожа на остальные JSON-поля приложения после §624.

Тот же блок, скопированный по образцу («паттерн `ViewTab`»), — на вкладке
**JSON** редактора DNS-сервера для `template`/`preset` (превью read-only).

## Диагностика

- `app/lib/screens/custom_rule_edit/tabs/view_tab.dart` — оба блока:
  `Container` + `SingleChildScrollView` + `SelectableText(monospace)`.
- `app/lib/screens/dns_server_edit/tabs/json_tab.dart` — то же для
  `storageJson` и `resolvedJson`; редактируемое тело `inline`-сервера уже
  на `LxTextCodeField` (§624), пропущены только read-only блоки.
- §624 переводил поля с `TextField`/`re_editor`; просмотрщики на
  `SelectableText` в перечень не попали. Для read-only JSON есть готовый
  `LxJsonView` (`app/lib/widgets/lx_code_editor.dart`): подсветка, подпись
  слева и кнопки справа в строке над рамкой (`header`, `actions`).

## Решение

В обоих файлах блоки заменены на `LxJsonView`:

- «storage shape» — `height: 180` (прежний `maxHeight`), подпись → `header`,
  кнопка Copy → `actions`;
- превью — без высоты внутри `Expanded`, как было; предупреждения сборки
  правила остаются над просмотрщиком.

Тексты подписей и кнопка Copy без изменений. Тест
`test/screens/dns_server_edit/json_tab_test.dart` читает содержимое из
`LxJsonView.text` вместо `SelectableText.data`.

## Риски и граничные случаи

- Вне Android `LxJsonView` рисует заглушку-`TextField` — тесты строятся.
- Блок «storage shape» теперь фиксированной высоты 180 вместо «до 180»: у
  короткой записи под текстом остаётся пустое место рамки.
- Нативный view в `Expanded` на вкладке с `TabBarView`: горизонтальный
  свайп внутри поля не листает вкладки при `wordWrap: false` (§624) — у
  просмотрщика без `stickyHeaders` перенос строк включён, свайп вкладок
  работает как у JSON-поля правила.

## Проверка

- `dart analyze` по трём файлам — чисто.
- `flutter test test/screens/dns_server_edit/json_tab_test.dart` — 2/2.
- Ручная (эмулятор): Routing → правило из пресета → View — оба блока с
  подсветкой; DNS → серверный пресет → JSON — то же.
