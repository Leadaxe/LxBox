# Фичи

Спецификации функциональности: пользовательские сценарии, поведение UI/ядра, ограничения, критерии готовности.

**Имя папки:** `NNN <название с пробелами>` — см. [`../README.md`](../README.md). Внутри — `spec.md`, при необходимости `plan.md` и `tasks.md`.

## Индекс

| # | Папка | Кратко | Статус |
|---|-------|--------|--------|
| 001 | [`001 mobile stack/`](001%20mobile%20stack/) | Стек: Flutter + нативный VPN + libbox | ✓ Реализовано |
| 002 | [`002 mvp scope/`](002%20mvp%20scope/) | MVP: Start–Stop / группы / узлы (Android) | ✓ Реализовано |
| 003 | [`003 servers tab/`](003%20servers%20tab/) | Clash API, группа, узлы, одиночный ping | ✓ Реализовано |
| 004 | [`004 subscription parser/`](004%20subscription%20parser/) | Парсер подписок: fetch, decode, parse (порт из singbox-launcher) | ✓ Реализовано |
| 005 | [`005 config generator/`](005%20config%20generator/) | Генератор конфига: wizard template + vars + подписки → sing-box config | ✓ Реализовано |
| 006 | [`006 subscription and settings ui/`](006%20subscription%20and%20settings%20ui/) | UI подписок и настроек на мобильном | ✓ Реализовано |
| 007 | [`007 config editor improvements/`](007%20config%20editor%20improvements/) | Форматирование JSON в редакторе конфига | ✓ Реализовано |
| 008 | [`008 ping and node management/`](008%20ping%20and%20node%20management/) | Mass ping, расширенное контекстное меню, цветовая индикация задержки | ✓ Реализовано |
| 009 | [`009 dark theme and ux/`](009%20dark%20theme%20and%20ux/) | Dark theme, сортировка нод, pull-to-refresh, быстрый доступ к настройкам | ✓ Реализовано |
| 010 | [`010 quick start and auto refresh/`](010%20quick%20start%20and%20auto%20refresh/) | Quick Start (Get Free VPN), авто-обновление подписок, метаданные | ✓ Реализовано |
| 011 | [`011 local ruleset cache/`](011%20local%20ruleset%20cache/) | Локальный кэш remote .srs rule set файлов | ✓ Реализовано |
| 012 | [`012 xray json array/`](012%20xray%20json%20array/) | Парсер Xray JSON Array + chained proxy (jump) | ✓ Реализовано |
| 013 | [`013 native vpn service/`](013%20native%20vpn%20service/) | Нативный VPN-сервис, удаление flutter_singbox_vpn | ✓ Реализовано |
| 014 | [`014 subscription detail view/`](014%20subscription%20detail%20view/) | Detail screen подписки с нодами, rename, delete | ✓ Реализовано |
| 015 | [`015 rule outbound selection/`](015%20rule%20outbound%20selection/) | Выбор outbound для каждого правила, route.final | ✓ Реализовано |
| 016 | [`016 routing screen/`](016%20routing%20screen/) | Отдельный экран Routing (groups + rules + outbounds) | ✓ Реализовано |
