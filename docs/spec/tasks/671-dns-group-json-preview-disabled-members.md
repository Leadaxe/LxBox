# 671 — Превью JSON у DNS-группы показывает выключенных членов

| Поле | Значение |
|------|----------|
| Статус | Done (2026-10-23; коммит `fix(671)`, см. `git log --grep 671`; на устройстве не проверено) |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 671` |
| Связанные спеки | [312F](312F-dns-group/spec.md) — DNS-группы, решение №3 (выключенный член снимается при сборке, хранилище не меняется) |

## Проблема

GitHub issue #171 п.18: «Routing > dns > shield > json preview not updating
when one of the dns servers disabled».

`dns_shield` — шаблонный DNS-сервер типа `group` (режим `fastest`, 6 членов,
`app/assets/wizard_template.json:365-382`), по умолчанию в final и resolver.
Пользователь выключает член (например `google_doh`) в списке серверов,
открывает shield → вкладка JSON: там по-прежнему 6 членов.

## Диагностика

- Сборка выключенного члена из группы снимает: `app/lib/services/builder/post_steps/dns_servers.dart:404`
  (причина `disabled`, предупреждение «DNS group 'dns_shield': member 'X'
  dropped (disabled)»), вызов фильтра `_filterDnsGroupMembers` на `:274/:340`.
  В ядро уходит 5 членов.
- Превью «sing-box server preview» (`app/lib/screens/dns_server_edit/tabs/json_tab.dart:66-82`)
  строит тело через `resolveTemplateDnsServerBody(wrapper, varValues:)` —
  подстановка переменных в тело шаблона, фильтра членов нет. Комментарий на
  `:70` обещает «Display = emit-форма», для групп это неверно.
- Для шаблонной группы это единственное место, где виден состав: форма членов
  только у inline-групп (`params_tab.dart:35`), пикер с пометкой
  «disabled — will be skipped» (`server_form_section.dart:286`) у shield не
  показывается.
- Блок «storage shape» (`json_tab.dart:89-90`) показывает запись самого
  shield и обновляется; его не трогать.

## Решение

- В превью «sing-box server preview» для серверов `type: group` прогонять
  `servers` через тот же критерий, что у сборщика: выключенные члены
  снимаются; логика не дублируется. Хранилище не меняется — решение 312F №3
  в силе.
- Под превью — строка со снятыми членами «Disabled, skipped at build: X, Y»
  (по образцу подписи пикера). Если снятых нет — строки нет.

Сделано:

- Из `app/lib/services/builder/post_steps/dns_servers.dart` вынесены чистые
  функции:
  - `dnsServerRefEmitted` (`:292`) — эмитится ли ref-запись: включена ИЛИ
    реферима пресетом ИЛИ правилом с DNS-опцией (§117 locked №7). Сборка
    вызывает её на `:225` вместо прежнего условия;
  - `dnsGroupMemberDropReason` (`:305`) — причина снятия члена (`itself`,
    `duplicate`, `unknown`, `dangling detour`, `disabled`) или `null`, тот же
    порядок проверок; `_filterDnsGroupMembers` вызывает её на `:459`;
  - `previewDnsGroupMembers` (`:328`) — состав группы для превью: `kept` и
    `disabled`. Член, которого редактор не знает (нет среди опций пикера —
    `fakeip`/`hosts`, удалённый тег), превью не судит и оставляет: полный
    ref-список и вторая линия (`detour`) видны только сборке.
- `app/lib/screens/dns_server_edit/tabs/json_tab.dart:89` — превью у группы
  (шаблонной и пресетной) прогоняет `servers` через `previewDnsGroupMembers`
  по `c.dnsMemberOptions` — тот же источник, что у пикера членов; строка под
  превью — `:140`, стиль подписи пикера (`server_form_section.dart:286`,
  11 sp, цвет `error`). Блок «storage shape» не тронут.
- `app/lib/screens/dns_settings_tab.dart:336` — `DnsMemberOption.enabled`
  считается через `dnsServerRefEmitted` (было `enabled || locked`, по смыслу
  то же), чтобы пикер, превью и сборка держали один критерий.
- Пересчёт: превью строится при каждой сборке вкладки из `dnsMemberOptions`;
  опции — снимок списка серверов на момент открытия редактора. Пока редактор
  открыт, `enabled` других серверов поменять нельзя (редактор — отдельный
  экран); после возврата и повторного открытия опции свежие.
- l10n: ключ «Disabled, skipped at build: %s» в `ru`/`zh` `ui.json`.

## Проверка

- Unit (`app/test/builder/dns_group_test.dart:135`, группа «§671 превью
  состава группы»): 6 членов, один выключен → 5 и `disabled = [c]`; все
  включены → 6, `disabled` пуст; выключенный под правилом/пресетом остаётся,
  паритет со сборкой `resolveDnsServersBodies` с `ruleReferencedTags`
  (`dns_servers.dart:225-229`); незнакомый редактору член остаётся,
  self/повтор снимаются. Прежние тесты фильтра группы зелёные — вынос
  поведения не изменил.
- Widget (`app/test/screens/dns_server_edit/json_tab_test.dart:131,146`):
  шаблонная группа `dns_shield` из 6 членов, `m3` выключен → в превью нет
  `"m3"`, строка «Disabled, skipped at build: m3»; все включены → 6 членов,
  строки нет.
- `ui_check --strict`, `hardcoded_check`, `flutter analyze` — чисто.
- На устройстве не проверено: Routing → DNS → выключить `google_doh` →
  открыть `dns_shield` → JSON: 5 членов и строка под превью.

## Docs to update

- `312F-dns-group/spec.md` — абзац про превью.
- CHANGELOG `[Unreleased]`.
