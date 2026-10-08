# §610 — Готовые User-Agent популярных клиентов в поле Custom User-Agent

| Поле | Значение |
|------|----------|
| Тип | F (доработка) |
| Статус | D (done) |
| Фича | [001-SUBSCRIPTIONS](../features/001-SUBSCRIPTIONS/FEATURE.md) → [fetch-identity](../features/001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.md) |
| Дата | 2026-10-07 |
| Связанные | §118 (глобальная идентичность), §289 (идентичность подписки), §292 |

## Проблема

Панель YouVPN (обращение wiz85 с 4PDA, 05–07.10.2026) выбирает формат
ответа по User-Agent:

| UA | Ответ |
|----|-------|
| `Happ/…`, `Streisand`, `Karing/…`, `v2raytun/android` | xray-JSON, ~179 КБ, полный |
| `LxBox-android/…`, `sing-box/…`, `SFA/…`, `v2rayNG/…`, `FlClash/…` | `vless://`-ссылки, ~23 КБ |
| `Hiddify/…`, `NekoBox/…`, `INCY/…` | `Forbidden` |

В ссылках панель выбрасывает ws `path` и `headers` (`X-Whitelist-Header`),
`alpn`, xhttp `path`/`host`/`mode`. Без них не подключаются узлы белых
списков, а это единственное, что проходит в мобильной сети. Наш разбор ни
при чём: в ссылках этих полей просто нет.

Обход уже есть: поле Custom User-Agent. С UA Happ панель отдаёт полный
JSON, мы его разбираем (проверено: 73 узла, включая urltest-группы и
hysteria2). Но пользователь не знает, какую строку туда вписать, а подсказка
под полем, наоборот, отговаривает от смены UA.

## Решение владельца (07.10.2026)

Поле UA сделать комбобоксом: можно вписать свою строку или выбрать готовую
строку популярного клиента.

## Что сделать

**Общий виджет.** Диалог правки UA сейчас дублируется:
`app_settings_screen.dart` `_editUserAgent` → `_editIdentityText` (глобальный)
и `subscription_detail_screen.dart` `_editIdentityUserAgent` →
`_editIdentityField` (подписка). Вынести диалог UA в один виджет
(например, `lib/widgets/user_agent_dialog.dart`, функция
`showUserAgentDialog(context, {required String initial}) → Future<String?>`)
и звать его из обоих мест. Остальные поля идентичности (HWID, x-device-*)
продолжают пользоваться старыми диалогами, их не трогать.

**Диалог.**
- Редактируемое поле ввода. Как раньше: пусто = дефолт, hint показывает
  `resolveSubscriptionUserAgent()`.
- Список пресетов (выпадающий список у поля, `DropdownMenu` с
  редактированием или `Autocomplete`; выбор за исполнителем, главное, чтобы
  свободный ввод сохранялся). Выбор пресета подставляет его строку в поле, и
  её можно дописать руками.
- Пресет «LxBox (default)» очищает поле.
- Save / Cancel и семантика результата как раньше: `trim`, пустая строка =
  дефолт, `null` = отмена.

**Пресеты** — константа в одном месте, например
`lib/services/subscription/user_agent.dart` → `kUserAgentPresets`
(список пар «подпись — строка»). Порядок:

| Подпись | Строка |
|---------|--------|
| LxBox (default) | *(пусто)* |
| Happ | `Happ/3.5.0` |
| v2RayTun | `v2raytun/android` |
| Streisand | `Streisand` |
| Karing | `Karing/1.1` |
| v2rayNG | `v2rayNG/1.10.0` |
| Hiddify | `Hiddify/2.5.7` |
| sing-box | `sing-box/1.12.0` |

Версии зафиксированы: панели узнают клиента по имени, версия почти никогда
не важна. Клиенты семейства Clash (Clash Verge, FlClash, mihomo) не
включаем: Clash YAML мы не разбираем (`SourceKind.clashYaml` — fallback).

**Подсказка под полем** (оба экрана, строка «Some panels return the config
by a substring…») переписывается на смысл: «Some panels pick the format by
User-Agent. If a subscription loads but nodes fail, try another client's UA
(for example Happ) — some panels send full configs only to specific apps.»
Старый ключ перевода удалить, новый перевести в `assets/l10n/{ru,zh}/ui.json`
по `docs/l10n.md`. Тексты UI только на английском, без §NNN.

**Документация.**
`docs/spec/features/001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.md` и
`.ru.md`: в описание поля UA добавить пресеты и сказать, что они нужны для
панелей, которые отдают полный формат только «своим» клиентам. В таблице
настроек `FEATURE.md`/`FEATURE.ru.md` (строка Custom User-Agent) дописать
«или пресет клиента». CHANGELOG → Unreleased: одна строка EN.

## Риски и краевые случаи

- Чужой UA — это маскировка под другой клиент. Панель с HWID-гейтом
  (Remnawave) при UA из своего whitelist и без `x-hwid` может отдать
  заглушку (память §310). Поэтому дефолт не меняется, пресет выбирает только
  сам пользователь.
- Слепок идентичности подписки при первом добавлении подписки не создаётся
  (§310). Поле подписки доступно только при включённом Custom identity, это
  поведение не трогаем.
- Строка, введённая вручную и совпавшая с пресетом, остаётся просто строкой.
  Отдельно «какой пресет выбран» не хранится, только сама строка.

## Проверка

- Юнит-тест на `kUserAgentPresets`: первый пресет пустой, строки уникальны,
  без переводов строк и управляющих символов.
- Виджет-тест диалога: выбор пресета подставляет строку; ручной ввод
  сохраняется; «LxBox (default)» даёт пустую строку; Cancel → `null`.
- Тесты гонять только по затронутым файлам; полный прогон делает CI.
- Ручная проверка на эмуляторе (не на телефоне владельца): подписка YouVPN
  с пресетом Happ после обновления содержит узел `admin.downloader-pet.xyz`
  с ws `path` и заголовком `X-Whitelist-Header`.

## Нерешённое

- Письмо YouVPN / автору панели: отдавать в ссылках `path`/`headers` или
  sing-box JSON для неизвестных UA — вне задачи, по решению владельца.
- Предупреждение «узел из ссылки, вероятно, неполный» (ws/xhttp без
  `path`) — отдельная задача, если владелец решит.
