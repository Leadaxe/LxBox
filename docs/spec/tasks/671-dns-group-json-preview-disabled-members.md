# 671 — Превью JSON у DNS-группы показывает выключенных членов

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-23 |
| Дата конца | — |
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
  `servers` через тот же критерий, что у сборщика (`_filterDnsGroupMembers`
  или вынесенный из него чистый предикат «член эмитится»): выключенные члены
  снимаются. Логику не дублировать — вынести предикат/функцию из
  `dns_servers.dart` и переиспользовать.
- Под превью — строка со снятыми членами: «Disabled, skipped at build: X, Y»
  (по образцу подписи пикера). Если снятых нет — строки нет.
- Превью пересчитывается при открытии вкладки и при изменении `enabled` любого
  сервера, пока редактор открыт (подписка на тот же источник, что у пикера
  членов `dnsMemberOptions`).
- Хранилище не меняется — решение 312F №3 в силе.

## Проверка

- Unit: группа с 6 членами, один выключен → превью 5 членов + строка
  «skipped». Все включены → 6, строки нет. Член, на который ссылается
  пресет/правило, обрабатывается как у сборщика (`dns_servers.dart:225-229`).

## Docs to update

- `312F-dns-group/spec.md` — абзац про превью.
- CHANGELOG `[Unreleased]`.
