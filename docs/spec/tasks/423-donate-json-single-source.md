# §423 — donate.json: единственный источник `app/assets/donate.json`

**Тип:** таска (поверх §362; зеркало §422 для ленты)
**Статус:** реализовано; юниты §362 зелёные; device-verify не требуется — путь запроса и docstring, логика загрузки не менялась
**Связано:** §362 (донат-попап), §422 (та же схема для `support.json`)

---

## Проблема

Способы поддержки жили в двух файлах: `docs/donate.json` (раздача с GitHub)
и `app/assets/donate.json` (bundled-копия на первый запуск офлайн). Копию
держали руками, и она разошлась: в `docs/` был актуальный комментарий, в
`assets/` — старый. Методы совпадали случайно.

## Решение (владелец, 05.09.2026)

Один файл — `app/assets/donate.json`. Он бандлится в APK и он же раздаётся по
`raw.githubusercontent.com/Leadaxe/LxBox/main/app/assets/donate.json`.
`docs/donate.json` удалён (`git mv` с сохранением актуального содержимого).

**Гейта `auto_check_updates` нет и не нужен:** запрос идёт только когда
пользователь сам открыл About → Support; фоновых обращений у попапа нет.
Порядок источников как был: сеть → кэш `donate_cache_json` → bundled.

**Старые версии** ≤ 2.22.0 читают `docs/donate.json` → 404 → кэш → своя
bundled-копия. Попап не пустеет ни в одном случае.

## Код

| Файл | Изменение |
|---|---|
| `app/assets/donate.json` | содержимое `docs/donate.json`, `$schema_comment` переписан под единый источник |
| `docs/donate.json` | удалён |
| `app/lib/services/donate_methods.dart` | `_url` → `main/app/assets/donate.json`; docstring |
| `app/pubspec.yaml`, `app/test/services/donate_methods_test.dart` | комментарии |
| `docs/FDROID.md`, `docs/README.md`, `docs/BUILD.md`, `docs/spec/tasks/422-…md` | путь файла |

## Docs to update

- [x] `CHANGELOG.md` — Unreleased → Changed (вместе с §422)
- [x] `docs/FDROID.md`, `docs/README.md`, `docs/BUILD.md`
