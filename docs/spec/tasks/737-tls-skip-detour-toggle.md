# 737 — TLS-настройки и узлы с detour: подписи вместо галки

| | |
|---|---|
| **Статус** | Done |
| **Дата** | 2026-11-15 |
| **Повод** | слово владельца: «tls — должна быть галка не применять к тем, у кого detour» |
| **Связанные** | [636 — TLS-политика по уровням](636-tls-settings-per-node-folder-subscription.md), [664](664-reality-tls-inherited-label-effective.md) / [665 — REALITY и фрагментация](665-tls-fragment-inherits-everywhere-reality-too.md), [729 — `lx.sniff_guard`](729-sniff-guard-block.md), контракт 1.1.84 (`detour_with_tls_fragment`), 1.1.170 |

## Docs to update

- эта задача
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Changed

## Problem

Владелец хочет у TLS-настроек галку «не применять к узлам, у которых есть detour».
TLS-настройки приложения — четыре ручки раздела «TLS Fragmentation» (шаблон
`app/assets/wizard_template.json:408–416`, переменные `tls_fragment`,
`tls_record_fragment`, `tls_fragment_fallback_delay`, `tls_mixed_case_sni`) и их
переопределения на источнике (подписка / папка) и узле (`TlsPolicy`,
`app/lib/models/tls_policy.dart:5–33`). Других TLS-ручек у пользователя нет.

## Как есть (факты по коду, develop `b02ee9c0`)

### Сборка: под detour не применяется ничего, выключателя нет

- `applyMixedCaseSni` пропускает любой outbound с ключом `detour` —
  `app/lib/services/builder/post_steps/tls_transforms.dart:26`.
- `applyTlsFragment` — то же, `tls_transforms.dart:97`. Ни одна из трёх ручек
  фрагментации (`fragment`, `record_fragment`, `fallback_delay`) узлу с detour
  не дописывается.
- Оба шага идут **после** проставления detour и после уступок
  `applyDetourYields` — `app/lib/services/builder/build_config.dart:875–886`.
  Значит, к этому моменту `detour` уже есть у **всех** видов: личный detour
  узла, detour источника (override и append), звено цепочки, detour из тела
  подписки, detour на Направление. Шаги смотрят только на наличие ключа и не
  различают, откуда он взялся и куда ведёт.
- Проверка узлов (probe) — те же два шага, тот же пропуск:
  `app/lib/services/probe/probe_config.dart:522–527` (detour источника
  проставлен раньше, `probe_config.dart:452–453`).
- Только `outbounds`: у `endpoints` (WireGuard и т. п.) TLS нет, шаги их не
  трогают.

**Гипотеза «поведение уже такое, зашито жёстко» — подтверждена.**

### Явный `tls.fragment` в теле узла под detour снимается нормой контракта

- `applyDetourYields` (`tls_transforms.dart:142–157`) → `yieldToBuildDetour`
  (`app/lib/services/builder/detour_yields.dart:10–46`): `tls.fragment` из
  тела снимается с кодом `detour_with_tls_fragment`; осиротевший
  `fragment_fallback_delay` уходит следом, если нет `record_fragment`.
- Норма — контракт 1.1.84, связь `conflicts {with: detour}` у поля
  `fragment`: `app/contract/registry/tls.json:669–676`. Текст предупреждения —
  `docs/contract/warnings.md:575–592`: под detour разрез «не помогает против
  DPI», явный ключ «выводит узел из-под sniff guard» и добавляет паузу 500 мс
  на сегмент.
- Исключение — авторское тело (§577, пользователь сам правил JSON узла):
  уступка мягкая, `tls.fragment` **остаётся**, предупреждение помечено
  «(not applied)» (`detour_yields.dart:16–18`, `build_config.dart:875–878`).
  То есть «применить фрагментацию под detour» уже можно — руками в JSON узла.
- `tls.record_fragment` и `server_name` из тела под detour не снимаются.

**Гипотеза подтверждена**, с уточнением про авторское тело.

### Ядро: под detour решает `lx.sniff_guard` (задача 729)

- С ядра lx.34 (пин сейчас `v1.14.4-lx.35`,
  `app/lib/services/builder/core_chain_capability.dart:152`) разрез ClientHello
  под detour ядро само не включает; это делает блок `lx.sniff_guard`, который
  пишет LxBox (`app/lib/services/builder/sniff_guard.dart`, спека 729).
- Умолчания блока: путь через `direct`, `ssh`, `socks` стартует **без**
  защиты, остальные релеи — с защитой; узловые ключи сильнее блока
  (729: «явный ключ узла выключил бы для него блок»).
- Описание поля в реестре (`tls.json:676`: «record_fragment, который ядро при
  detour включает само») устарело с lx.34 — теперь это делает `sniff_guard`.
  Не наш файл, заметка лаунчеру.

### Интерфейс

- Экран узла: под заголовком TLS при `_underDetour` — «Not applied: traffic goes
  through a detour first. There the core's sniff guard decides (Core settings).»
  (`app/lib/screens/node_settings_screen.dart:1094–1103`). **Подтверждено.**
- Но `_underDetour` (`node_settings_screen.dart:1080–1086`) знает только личный
  detour и override папки. Не видит: detour из тела узла, звено цепочки,
  append источника. В этих случаях подписи нет, хотя сборка ручки не применяет.
- TLS-секция источника (`.../subscription_settings_tab.dart:379–396`,
  `TlsPolicyTiles` из `app/lib/widgets/tls_policy_tiles.dart`) и глобальный
  раздел «TLS Fragmentation» (описание шаблона: «Default for all servers»)
  про detour не говорят ничего. **Подтверждено.** Пользователь, включивший
  фрагментацию на подписке с detour-цепочкой, не узнает, что на её узлах она
  не действует.

### Где фрагментация под detour имеет смысл, а где нет

| Первый хоп detour | Видит ли DPI ClientHello узла | Смысл ручек под detour |
|---|---|---|
| зашифрованный релей (vless, vmess, trojan, ss, hy2, WG, AWG…) | нет, он внутри туннеля | нет; `fragment` только добавляет паузу и выводит узел из-под sniff guard |
| `direct`, Направление с выбранным `direct` | да, как у прямого узла | **есть** |
| `socks` / `http` без TLS (в т. ч. локальный прокси) | да, на участке до прокси | частично: `record_fragment` и mixed-case SNI доезжают, разрез по TCP-сегментам прокси перекладывает |
| `ssh` | нет | нет |

Сейчас для строк 2–3 узел остаётся и без ручек TLS, и без sniff guard
(умолчание блока для `direct`/`socks` — «без защиты»): ClientHello с настоящим
SNI уходит в сеть как есть. Это единственный случай, где выключение пропуска
реально что-то даёт. Для Направления сборка не знает, какой член будет выбран
(селектор переключается на лету).

## Варианты

### (1) Явная галка, по умолчанию включена — поведение не меняется

Галка «Don't apply to servers with a detour» в разделе «TLS Fragmentation».
Включена — как сейчас. Выключена — четыре ручки применяются по обычному
наследованию узел → источник → глобально и к узлам с любым detour; уступка
`detour_with_tls_fragment` для дописанного сборкой флага не делается.

- Где живёт: **глобально**, одна переменная (предложение имени
  `tls_skip_detour`). Наследование по уровням (`TlsPolicy.skipDetour`) —
  возможно, но см. вопрос 2.
- Контракт: норма 1.1.84 говорит «сборка не эмитит узловой fragment у outbound
  с detour» — общая с лаунчером. Выключенная галка эту норму нарушает → нужен
  запрос лаунчеру: новая переменная в `registry/vars.json` (`in: both` или
  `mobile`), исключение в связи `conflicts {with: detour}` «если
  `tls_skip_detour = false`», текст в `warnings.md`. Без согласия лаунчера —
  только мобильная переменная с пометкой расхождения.
- Ядро: явный `fragment`/`record_fragment` на узле под detour выключает для
  него `sniff_guard` и добавляет паузу `fallback_delay` (500 мс по умолчанию).
  Под зашифрованным релеем это только вред; под `direct`/`socks` — то, что
  нужно.
- Бэкап: глобальная `vars` — уходит в бэкап сама, если объявлена в контракте;
  на уровнях — ключ в объекте `tls` (схема терпит неизвестные ключи,
  `additionalProperties: true`), но объявить в `BACKUP.md` — тоже лаунчеру.
- Цена: средняя. Файлы: `tls_transforms.dart`, `build_config.dart`,
  `probe_config.dart`, `detour_yields.dart`, `wizard_template.json`,
  `settings_storage.dart`, `lx_backup.dart`, подписи в
  `node_settings_screen.dart`, l10n, тесты сборки/пробы.

### (2) Галки нет — только подписи

Поведение остаётся жёстким, интерфейс перестаёт врать:
- глобальный раздел: в описание «Not applied to servers with a detour: there the
  core's sniff guard decides.»;
- TLS-секция источника: та же строка, если у источника есть detour (override,
  append или цепочки);
- экран узла: `_underDetour` учитывает все виды detour (тело, звено, append).

Контракт не трогается, запроса лаунчеру нет, бэкап не меняется. Цена малая:
`node_settings_screen.dart`, `subscription_settings_tab.dart`,
`wizard_template.json` (описание), l10n.

### (3) Применять по типу первого хопа, без галки

Сборка применяет ручки TLS под detour, если первый хоп незашифрованный
(`direct`, `socks`, `http` без TLS), и пропускает под зашифрованным — та же
логика, что у `sniff_guard`. Detour на Направление — пропуск (член не известен
на сборке) или «применять, если в Направлении есть `direct`». Закрывает
единственную реальную дыру (строки 2–3 таблицы) без ручки, которую большинство
не поймёт. Контракт: меняется норма 1.1.84 → запрос лаунчеру. Цена: выше (1),
плюс тесты на типы хопов.

## Решение

Владелец 15.11.2026: «тогда делать ничего не надо, надо просто написать в
интерфейсе», «тогда галка не нужна». Выбран вариант (2): поведение сборки,
пробы и норма контракта не меняются, галки нет; варианты (1) и (3) отклонены.

Подписи (английский — ключ, переводы `ru`/`zh`):

- **Глобально** — описание раздела «TLS Fragmentation»
  (`app/assets/wizard_template.json`, `assets/l10n/*/template.json`):
  дописано «Not applied to servers with a detour: there the core's sniff guard
  decides.»
- **Источник** — подзаголовок TLS-секции подписки и папки
  (`subscription_settings_tab.dart`): дописано «Not applied to servers with a
  detour.» Всегда, а не только при detour у источника: detour бывает у
  отдельных узлов (тело, личный, звено), и строка верна в любом случае.
- **Узел** — `node_settings_screen.dart`: при распознанном detour
  (`_underDetour`) как раньше — подзаголовок плюс «Not applied: traffic goes
  through a detour first…». Без него подзаголовок «Override the global TLS
  settings for this server. Not applied if the server has a detour.» —
  покрывает detour из тела узла и звено цепочки, которые `_underDetour` не
  видит. Расширять `_underDetour` не стали: статичная строка закрывает те же
  случаи без нового кода.

Контракт, бэкап, лаунчер — без изменений, запросов нет.

## Макет

```
Core → TLS Fragmentation
  Splits the TLS handshake so it carries no single-packet signature.
  Default for all servers; override per server, folder or subscription.
  Not applied to servers with a detour: there the core's sniff guard decides.

Подписка / папка → Settings → TLS
  Override the global TLS settings for all servers of this subscription.
  Not applied to servers with a detour.

Узел → TLS (detour не распознан экраном)
  Override the global TLS settings for this server. Not applied if the
  server has a detour.
```

## Verification

- `dart run tool/l10n/ui_check.dart --strict`, `template_check.dart --strict` —
  0 failures, 0 warnings; `dart analyze` двух экранов — без замечаний.
- Эмулятор не гоняли: правка только текстов.

## Unresolved / follow-up

- Устаревшая формулировка `tls.json:676` про record_fragment ядра под detour —
  заметка лаунчеру при следующем запросе.
