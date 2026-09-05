# §422 — Support-лента: сеть только с согласия на проверку обновлений, bundled-копия как стартовый кэш

**Тип:** таска (поверх §356/§357)
**Статус:** реализовано, юниты зелёные (support_message_test 4 кейса fetch + parity-тест); device-verify не требуется — ветвление чисто в сервисе, UI не менялся
**Связано:** §356 (лента), §362 (донат: тот же паттерн asset+кэш, но БЕЗ гейта), §379/F-Droid (онбординг-вопрос `auto_check_updates`, issue #61)

---

## Проблема

Ревьюер F-Droid (duckniii, #61, 30.08.2026) увидел запрос на
`raw.githubusercontent.com` при выключенной проверке обновлений. Это
`docs/support.json` — лента §356. До этой таски она ходила в сеть при каждом
запуске процесса с поднятым туннелем, независимо от онбординг-ответа и даже
когда все сообщения прочитаны; кэш `cache_json` был только офлайн-фолбэком.
Отключить это пользователь не мог.

## Решение (владелец, 05.09.2026)

Один тумблер на всё «в сеть за нашими файлами» — уже существующий
`auto_check_updates` (вопрос первого запуска «Check for updates?»):

| Согласие | Порядок источников ленты |
|---|---|
| `auto_check_updates = true` | сеть → кэш → bundled-копия → null |
| `auto_check_updates = false` | кэш → bundled-копия → null; **ни одного запроса** |

**Bundled-копия** — `app/assets/support.json`, байт-в-байт снимок
`docs/support.json` на момент сборки. Нужна, чтобы лента работала у тех, кто
ответил «Skip»: очередь, пороги наработки и тексты живут из APK, ссылки —
на момент релиза. Копия **не пишется в `cache_json`**: как только согласие
появится, придёт свежая лента, а не переписанный из asset снимок.

Отдельного тумблера «не показывать ленту» не делаем: кнопки «Later» (снуз
10 ч наработки) и «Got it» остаются как были, а вопрос ревьюера был про
сеть, не про показ.

## Код

| Файл | Изменение |
|---|---|
| `app/lib/services/support/support_message.dart` | `fetchOrCached`: гейт `SettingsStorage.getAutoCheckUpdates()` перед `_fetch()`; `_fetch()` вынесен; после кэша — `rootBundle.loadString('assets/support.json')`; общий `_parse` |
| `app/assets/support.json` | новая копия `docs/support.json` |
| `app/pubspec.yaml` | asset зарегистрирован |
| `app/lib/screens/home_screen.dart` | docstring `_maybeShowSupport`: гейт внутри сервиса, экран не ветвится |
| `app/test/services/support_message_test.dart` | setUp даёт согласие; «ни сети, ни кэша» теперь → asset; +2 кейса: без согласия клиент не вызывается (кэш / asset), asset не попадает в кэш |
| `app/test/services/support_asset_parity_test.dart` | новый: `assets/support.json == ../docs/support.json`, иначе CI красный |

Гейт живёт **в сервисе**, а не в `home_screen`: Debug API `/support/preview` и
любой будущий вызов получают то же поведение автоматически.

## Что НЕ изменилось

- `LXBOX_SUPPORT_URL` (dart-define для тестовой кампании) работает только при
  согласии — тестовый APK включает проверку обновлений.
- Ретрай 30 с в `_maybeShowSupport` при закрытой сети не срабатывает: сервис
  отвечает мгновенно из кэша/asset.
- Остальные три запроса на `raw.githubusercontent.com` без гейта, как были:
  `docs/latest.json` (сам под флагом), `docs/donate.json` (только при
  открытии About), `public-servers-manifest.json` (только экран публичных
  тест-серверов). Все три — по явному действию пользователя, не фоновые.

## Грабля, ради которой parity-тест

`assets/donate.json` (§362) отстал от `docs/donate.json` — файлы разные,
никто не заметил. Для ленты это значило бы, что F-Droid-пользователь без
согласия получает не ту очередь, которую автор выложил. Тест ловит на CI.
Правишь `docs/support.json` → `cp docs/support.json app/assets/support.json`.

## Docs to update

- [x] `CHANGELOG.md` — Unreleased → Changed
- [x] `docs/FDROID.md` — абзац про сетевые запросы и согласие
- [ ] ответ в #61 — после пуша, со ссылкой на коммит
