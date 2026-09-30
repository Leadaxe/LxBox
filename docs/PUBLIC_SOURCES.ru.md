# Реестр публичных серверов

[English version](PUBLIC_SOURCES.md)

**Список собран для индивидуального тестирования клиента L×Box — чтобы
проверить, как он разбирает подписки, протоколы и транспорты.** Серверы
принадлежат третьим лицам. Проект L×Box их не держит, не проверяет и не
рекомендует. Доступность, скорость и безопасность никто не гарантирует: узел
может не работать, тормозить или записывать ваш трафик. Пользоваться этими
подписками можно только в соответствии с законом своей страны (см.
[Назначение и условия использования](../README.ru.md#назначение-и-условия-использования)).

Дата проверки — **30.09.2026**. Источник попал в список, только если в этот день
выполнялись все три условия:

- ссылка на подписку отвечает `200`, тело не пустое;
- L×Box находит в ней хотя бы один узел;
- репозиторий обновлялся за последние 14 дней.

Подключение к узлам не проверялось. Число узлов — результат разбора в L×Box
снимков от 24–30.09.2026; живые списки меняются примерно раз в час. Частота
обновления прикинута по истории коммитов каждого файла за 27–30.09.

## Сводка

| Репозиторий | Файлы подписок | Протоколы | Узлов | Обновление |
|---|---|---|---|---|
| [zieng2/wl](https://github.com/zieng2/wl) | [vless_universal.txt](https://raw.githubusercontent.com/zieng2/wl/main/vless_universal.txt), [vless_lite.txt](https://raw.githubusercontent.com/zieng2/wl/main/vless_lite.txt) | VLESS | 95, 95 | раз в час |
| [igareck/vpn-configs-for-russia](https://github.com/igareck/vpn-configs-for-russia) | [Vless-Reality-White-Lists-Rus-Mobile.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt), [WHITE-CIDR-RU-checked.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/WHITE-CIDR-RU-checked.txt), [BLACK_VLESS_RUS_mobile.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt) | VLESS, Hysteria2, VMess | 25, 5, 132 | примерно раз в час |
| [hussaroff/lte-universal-checked](https://github.com/hussaroff/lte-universal-checked) | [whitelist.txt](https://raw.githubusercontent.com/hussaroff/lte-universal-checked/refs/heads/main/whitelist.txt) | VLESS | 24 | раз в 3–4 ч |
| [RKPchannel/RKP_bypass_configs](https://github.com/RKPchannel/RKP_bypass_configs) | [whitelist.txt](https://raw.githubusercontent.com/RKPchannel/RKP_bypass_configs/refs/heads/main/whitelist.txt), [blacklist.txt](https://raw.githubusercontent.com/RKPchannel/RKP_bypass_configs/refs/heads/main/blacklist.txt) | VLESS, Hysteria2, Shadowsocks, Trojan | 56, 2865 | раз в ~2 ч |
| [Maskkost93/kizyak-vpn-4.0](https://github.com/Maskkost93/kizyak-vpn-4.0) | [kizyakbeta7.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta7.txt), [kizyakbeta6.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta6.txt), [kizyakbeta6BL.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta6BL.txt) | VLESS, Hysteria2, Trojan, VMess | 73, 30, 33 | раз в 2–3 ч |
| [AirLinkVPN1/AirLinkVPN](https://github.com/AirLinkVPN1/AirLinkVPN) | [rkn_white_list](https://raw.githubusercontent.com/AirLinkVPN1/AirLinkVPN/refs/heads/main/rkn_white_list) | VLESS | 97 | раз в час |
| [flaafix/AetrisVPN-white-list-lite](https://github.com/flaafix/AetrisVPN-white-list-lite) | [AetrisVPN.txt](https://raw.githubusercontent.com/flaafix/AetrisVPN-white-list-lite/refs/heads/main/AetrisVPN.txt) | VLESS, Shadowsocks, VMess | 114 | раз в ~5 ч |
| [flaafix/AetrisVPN-black-list](https://github.com/flaafix/AetrisVPN-black-list) | [configs.txt](https://raw.githubusercontent.com/flaafix/AetrisVPN-black-list/refs/heads/main/configs.txt) | VLESS, VMess, Trojan | 206 | раз в ~5 ч |
| [ksenkovsolo/HardVPN-bypass-WhiteLists-](https://github.com/ksenkovsolo/HardVPN-bypass-WhiteLists-) | [WHITELIST-ALL.txt](https://raw.githubusercontent.com/ksenkovsolo/HardVPN-bypass-WhiteLists-/refs/heads/main/vpn-lte/WHITELIST-ALL.txt) | VLESS | 188 | нерегулярно |
| [whoahaow/rjsxrd](https://github.com/whoahaow/rjsxrd) | [bypass-all.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-all.txt), [bypass-1](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-1.txt), [-2](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-2.txt), [-3](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-3.txt), [-4](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-4.txt), [-5](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-5.txt), [-6](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-6.txt) | VLESS, Trojan, Shadowsocks, VMess | 621; 286, 262, 277, 281, 25, 279 | раз в час (bypass-all, bypass-1), остальные реже |
| [kort0881/vpn-checker-backend](https://github.com/kort0881/vpn-checker-backend) | [ru_white_all_WHITE.txt](https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_WHITE.txt) | VLESS, Shadowsocks, Trojan, Hysteria2 | 4025 | раз в ~6 ч |
| [LimeHi/LimeVPN](https://github.com/LimeHi/LimeVPN) | [whitelist.txt](https://raw.githubusercontent.com/LimeHi/LimeVPN/refs/heads/main/whitelist.txt), [blacklist.txt](https://raw.githubusercontent.com/LimeHi/LimeVPN/refs/heads/main/blacklist.txt) | VLESS, Shadowsocks, VMess | 191, 106 | раз в час |
| [luxxuria/harvester](https://github.com/luxxuria/harvester) | [ping_tested.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/ping_tested.txt), [top_600.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/top_600.txt), [non_ru.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/non_ru.txt) | VLESS | 117, 49, 45 | раз в 5–6 ч |
| [ANT1VEN0M/PODVAL-KOTA-VPN-](https://github.com/ANT1VEN0M/PODVAL-KOTA-VPN-) | [Белые_списки229.txt](https://raw.githubusercontent.com/ANT1VEN0M/PODVAL-KOTA-VPN-/refs/heads/main/%D0%91%D0%B5%D0%BB%D1%8B%D0%B5_%D1%81%D0%BF%D0%B8%D1%81%D0%BA%D0%B8229.txt), [antinet_Черные_списки.txt](https://raw.githubusercontent.com/ANT1VEN0M/PODVAL-KOTA-VPN-/refs/heads/main/antinet_%D0%A7%D0%B5%D1%80%D0%BD%D1%8B%D0%B5_%D1%81%D0%BF%D0%B8%D1%81%D0%BA%D0%B8.txt) | VLESS, Trojan, VMess, Hysteria2, Shadowsocks, AnyTLS, SOCKS, WireGuard | 70, 642 | нерегулярно |
| [btsk161/Freeinternet_byMygalaru.github.io](https://github.com/btsk161/Freeinternet_byMygalaru.github.io) | [premium.txt](https://raw.githubusercontent.com/btsk161/Freeinternet_byMygalaru.github.io/refs/heads/main/premium.txt) | VLESS, Shadowsocks, Hysteria2, Trojan | 153 | раз в 1–2 дня |
| [Diversan313/apex-parser](https://github.com/Diversan313/apex-parser) | [alive_full.txt](https://raw.githubusercontent.com/Diversan313/apex-parser/main/subs/main/alive_full.txt) | VLESS, Shadowsocks, VMess, Trojan | 595 | раз в час и чаще |
| [histeenn/VLESS-PO-GRIBI](https://github.com/histeenn/VLESS-PO-GRIBI) | [sub.txt](https://raw.githubusercontent.com/histeenn/VLESS-PO-GRIBI/main/deploy/sub.txt) | VLESS, Shadowsocks, VMess | 2891 | раз в ~7 ч |
| [OVI-vpn/bs](https://github.com/OVI-vpn/bs) | [full.txt](https://raw.githubusercontent.com/OVI-vpn/bs/refs/heads/main/full.txt) | VLESS, Shadowsocks, VMess | 251 | раз в час |

Белые и чёрные списки ниже — режимы мобильного интернета в России: при белом
списке открывается только разрешённый набор российских сайтов и адресов, при
чёрном — всё, кроме заблокированного.

## Источники

### zieng2/wl

Авторская подписка под белые списки мобильных операторов, пересобирается
каждый час. В README перечислены зеркала на Codeberg, GitLab, Mos.Hub и
GitVerse и совет гонять проверку задержки по всей подписке или включать
автовыбор. Старый файл `vless.txt` в том же репозитории теперь содержит только
заглушки с сообщением, что подписка устарела, поэтому его здесь нет.

### igareck/vpn-configs-for-russia

Отдельные списки под мобильные белые списки (по SNI и по CIDR) и под
мобильный чёрный список; по словам автора, узлы выкладываются после реальной
проверки доступности, задержки и скорости. Там же выгрузки в формате Clash,
мосты Tor и зеркала на GitLab и Bitbucket.

### hussaroff/lte-universal-checked

VLESS-узлы для LTE под белым списком из 50 с лишним источников, заранее
проверенные по реальной задержке. Сделан под клиент автора Tunnel, но это
обычный список, его прочитает любой клиент.

### RKPchannel/RKP_bypass_configs

Собирается из открытых источников скриптом автора: для белого списка он
отбирает узлы по префиксам IP и SNI, которые проходят под ограничениями. Те же
списки выложены в Clash YAML; в README сказано, что узел может
отвечать на пинг и при этом не пропускать трафик.

### Maskkost93/kizyak-vpn-4.0

`kizyakbeta7.txt` и `kizyakbeta6.txt` — под мобильные белые списки,
`kizyakbeta6BL.txt` — под чёрный (проводной и обычный мобильный интернет). В
файле для чёрного списка VLESS нет вовсе: только Hysteria2, Trojan и VMess.

### AirLinkVPN1/AirLinkVPN

VLESS под белый список. В README заявлен только VLESS Reality, но примерно
пятая часть узлов — VLESS поверх обычного TLS, а несколько записей указывают
на `111.111.111.111:111` — это заглушка, а не сервер.

### flaafix/AetrisVPN-white-list-lite, flaafix/AetrisVPN-black-list

Два репозитория одного автора: облегчённый список под белые списки и список
под чёрные. README описывают списки доменов и IP, но файлы, указанные здесь, —
подписки с серверами; в шапке файла видно число серверов и время сборки.

### ksenkovsolo/HardVPN-bypass-WhiteLists-

Репозиторий проекта HardVPN; в `WHITELIST-ALL.txt` только VLESS Reality.
Обновляется нерегулярно: последний раз файл менялся 21.09.2026.

### whoahaow/rjsxrd

Коллекция обновляется автоматически и отсеивает узлы с небезопасными
настройками (`allowInsecure`, `security=none`, слабые шифры Shadowsocks и
т. п.). В `bypass-all.txt` узлы для обхода белых списков одним файлом,
`bypass-1`…`bypass-6` — нарезка не больше 300 узлов на файл для слабых
устройств. README есть и на английском.

### kort0881/vpn-checker-backend

Проверялка: собирает публичные узлы, проверяет доступность по
TCP/TLS/WebSocket и задержку, раскладывает по пулам; `WHITE` — узлы, которые
проверку прошли. Файл большой (около 1,4 МБ, больше 4000 узлов) — на слабом
телефоне это заметно.

### LimeHi/LimeVPN

Списки под белые и чёрные списки собираются автоматически, почти целиком
VLESS Reality.

### luxxuria/harvester

Агрегатор и валидатор VLESS на Rust. В `ping_tested.txt` узлы, прошедшие
проверку URI и порта по TCP; `top_600.txt` — самые быстрые из них с
ограничением на каждого провайдера (ASN). В README есть зеркала через
jsDelivr и GitHack на случай, если GitHub недоступен.

### ANT1VEN0M/PODVAL-KOTA-VPN-

Описания у репозитория нет, файлы загружаются через веб-интерфейс GitHub. В
файле под чёрные списки самый пёстрый набор протоколов на этой странице,
вплоть до единичных узлов AnyTLS, SOCKS и WireGuard. Оба указанных файла
последний раз менялись 12.09.2026, свежие коммиты идут в другие файлы
репозитория.

### btsk161/Freeinternet_byMygalaru.github.io

Список Telegram-группы RaViraNet. Файл называется `premium.txt`, но это
обычный бесплатный публичный список.

### Diversan313/apex-parser

Сборщик с открытым кодом: берёт узлы из списков источников и Telegram,
проверяет живость, убирает дубли и фильтрует по географии. `alive_full.txt`
объединяет наборы под белые и чёрные списки; в README есть и зеркало на
GitVerse.

### histeenn/VLESS-PO-GRIBI

Собирает и проверяет бесплатные серверы примерно из 25 открытых источников;
файл весит около 1 МБ. В README предупреждение: Shadowsocks может не работать,
потому что его замедляют.

### OVI-vpn/bs

Описания у репозитория нет. В файле в основном VLESS с Reality и TLS поверх
xhttp, gRPC и WebSocket.

## Как добавить подписку в L×Box

Скопируйте raw-ссылку на файл и добавьте её как подписку — см.
[Руководство пользователя → Подписка](USER_GUIDE.ru.md#подписка).

Спасибо авторам этих репозиториев за то, что держат списки открытыми.
