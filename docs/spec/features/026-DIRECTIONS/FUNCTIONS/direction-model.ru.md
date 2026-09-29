[English](direction-model.md) · [Русский](direction-model.ru.md)

# Модель Направления — именованный выход, на который ссылаются правила, узлы и группы

Направление — именованный выход со своим набором узлов (`vpn-1`, `vpn-2` или со своим
тегом), на который по тегу указывают правила, Default traffic, DNS-серверы и поля detour.

| Поле | Значение |
|------|----------|
| Фича | [026-DIRECTIONS](../FEATURE.ru.md) |
| Обещания | P1 P2 P3 P4 P5 P6 P7 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Держит список Направлений и всё, что на них ссылается. У Направления есть неизменяемый
**тег** (системный id), **название** (только для клиента), выключатель и описание состава:
какие узлы оно берёт и какие служебные опции предлагает. Три тега встроены и Направлению
недоступны: `direct-out` (выйти с телефона напрямую) и `block` (сбросить трафик) — outbound'ы
шаблона, предлагаемые внутри Направления опциями, а `vpn-1` — обязательное главное
Направление: цель Default traffic по умолчанию и запасная цель, куда попадает каждая
вылеченная ссылка. Таб **Directions** экрана Routing перечисляет их с кнопкой «Add direction
(N)» и тайлом **Default traffic**; строка показывает тег, число узлов по снимку работающего
ядра («all nodes» или «filtered» при опущенном туннеле), « · auto» и « · required».

`NETWORKS` в выпадающем списке главного экрана — не Направление, а вид узлов вне списков
выбора — [012-LIVE_STATE · P19](../../012-LIVE_STATE/FEATURE.ru.md#обещания).

## Параметры

| Поле | Значения | Умолчание | Куда идёт |
|---|---|---|---|
| Tag | `vpn-N` (первый свободный) или свой; «System id, cannot be changed later» | `vpn-N` | тег `selector`; ссылка в правилах, DNS, detour |
| Title | любой текст; «optional — defaults to the tag» | «VPN ⓝ» для `vpn-N` (1–10; выше — «VPN 11»), иначе тег | только клиент; несёт маркер `⚙ ` detour-Направления |
| Вкл/выкл | выключатель в строке; у `vpn-1` заперт | `vpn-1` вкл, `vpn-2` выкл | выключенное Направление не эмитится |
| Include direct-out / Include block | галки | выкл | опции `direct-out` / `block` |
| Other directions | «only directions listed above this one» | — | опции-теги других селекторов |
| Node filter (regex) + Exclude matching (invert) | регистронезависимо | пусто = все узлы | состав |
| Default (regex) | «first matching node becomes default» | пусто | `default` |
| Interrupt connections on switch | вкл/выкл | вкл | `interrupt_exist_connections` |
| Include auto (urltest) и его поля | см. [группы](direction-groups-in-config.ru.md) | выкл | `<tag>-auto` |
| Use as detour | галка (у `vpn-1` скрыта) | выкл | [detour-прослойка](direction-as-detour.ru.md) |
| Default traffic | `direct` · Направление · `block` | `vpn-1` | `route.final` |

Debug API: `GET/POST /directions`, `GET/PATCH/DELETE /directions/{tag}`,
`POST /directions/reorder`; `PATCH`, ставящий флаг на `vpn-1`, получает 409.

## Входы / Выходы

**Входы:** сохранённый список; `default_directions` шаблона при первом запуске; действия
пользователя в табе, редакторе и диалоге «New direction»; Debug API; восстановленный бэкап.
**Выходы:** по `selector` на каждое включённое Направление и его двойник `-auto`
(собираются в [группах](direction-groups-in-config.ru.md)); цели для пикеров правил,
пресетов, DNS и Default traffic; одно уведомление «Direction "…" deleted/disabled — …» со
счётчиками лечения; причина конфликта тега в диалоге.

## Правила и инварианты

- **Идентичность — тег.** Правится только название; ссылки (правила, `route.final`,
  DNS-серверы, поля detour, `include`, позиции цепочек, ping-переопределения) называют тег
  или `<tag>-auto` и потому переживают переименование. На узел Направление не ссылается:
  состав — regex по итоговым тегам узлов, и адреса узлов `{folder_id?, tag}`
  ([017-BACKUP_AND_STORAGE · P17](../../017-BACKUP_AND_STORAGE/FEATURE.ru.md#обещания))
  здесь не участвуют.
- Новый тег отвергается с причиной: «Tag cannot be empty», «This tag is reserved by the
  config» (`direct-out`, `block`, `block-out`, `dns-out`, `direct`, `reject`, `drop`), «A
  direction with this tag already exists», «This tag collides with an auto twin
  (<tag>-auto)». Потолка на число Направлений нет; нумерация `vpn-N` берёт первую свободную
  позицию, а не max + 1, свои теги номеров не занимают.
- `vpn-1` нельзя выключить и удалить; загруженный список без него (правленый бэкап, импорт
  Debug API) получает его первым, включённым, с названием по умолчанию.
- Роль — разрешение (274): «Use as detour» не убирает Направление из целей правил.
- Пикер целей: `direct` первым, затем включённые Направления (`vpn-1` всегда, detour — с ⚙),
  `block` последним, красным; выключенные скрыты.
- **Удаление или выключение** переводит ссылки на `vpn-1` в хранении: цели правил,
  переопределения цели пресетов, Default traffic и DNS-серверы, называвшие Направление
  (переменная `outbound` шаблонного сервера или `detour` пользовательского, 441);
  detour-ссылки сбрасываются ([detour-прослойка](direction-as-detour.ru.md)). Повторное
  включение их не возвращает.
- Удаление дополнительно вычёркивает тег из «Other directions» остальных, из позиций
  цепочек и из ping-переопределения Направления; выключение оставляет все три (оно
  обратимо). Счётчики — в одном уведомлении: «N rule reference(s) switched to vpn-1»,
  «N detour reference(s) reset to None», «N direction option(s) removed», «N chain
  position(s) removed», «N DNS server(s) switched to vpn-1».
- Лечение хранения и списка источников в памяти — одна операция, иначе ближайшее
  сохранение воскресило бы ссылку; перезапись всего списка целиком (таб, reorder в Debug
  API) намеренно ничего не лечит.
- Смена **префикса тегов** подписки или папки переписывает литеральные вхождения старого
  префикса в Node filter и Default каждого Направления; вхождение внутри regex-конструкции
  (`R.`, `RU:?`, символьный класс) не трогается и называется в предупреждении.
- Первый запуск сеет список из шаблона; список, мигрированный и затем опустошённый, не
  пересеивается. Отсутствующий ключ записи получает умолчание; мусор в `include`
  (не-строки, пустые, дубли) отбрасывается при чтении; пустой `include` не пишется.
- Правило или Default traffic с целью, которой нет в конфиге, — fatal проверки перед стартом
  ([003-CONFIG_BUILD · P9](../../003-CONFIG_BUILD/FEATURE.ru.md#обещания)); лечение выше
  до него не доводит.

## Границы

- Состав, двойник `-auto` и `route.final` в конфиге —
  [direction-groups-in-config.md](direction-groups-in-config.ru.md); выбор на главном экране
  — [direction-selection.md](direction-selection.ru.md).
- Число узлов в строке не учитывает «Exclude matching»: считаются совпадения, даже когда
  Направление берёт остальное. Перестановка Направлений есть только в Debug API.
- DNS-сторона вылеченного сервера (fail-closed по каналу, исчезнувшему на сборке, 419) —
  [005-DNS · P2](../../005-DNS/FEATURE.ru.md#обещания).
- Лечение висячей цели при импорте правил — [004-ROUTING · P19](../../004-ROUTING/FEATURE.ru.md#обещания).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | РЕАЛИЗОВАНО | Настраиваемые каналы: вкл/выкл, regex-фильтр, default, лечение `route.final` |
| 2 | [184](../../../tasks/184-add-vpn4-channel.md) | — | Четвёртый канал |
| 3 | [201](../../../tasks/201-block-outbound-for-channels.md) | РЕАЛИЗОВАНО | Опция `block` в составе, fallback пустого фильтра |
| 4 | [202](../../../tasks/202-heal-channel-refs-on-disable.md) | РЕАЛИЗОВАНО | Лечение ссылок при выключении, без воскрешения |
| 5 | [267](../../../tasks/267-group-templates-magic-nodes.md) | — | Сид Направлений из шаблона (`default_directions`) |
| 6 | [274](../../../tasks/274-detour-role-to-permission.md) | РЕЛИЗ v2.15.6 | Detour-Направление снова доступно правилам |
| 7 | [275](../../../tasks/275-channel-mutations-detour-resync.md) | РЕЛИЗ v2.15.6 | Одна точка изменения Направлений с лечением |
| 8 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | Channels → Directions: свои теги, без потолка, `include`, страховка `vpn-1`, каскад префикса |
| 9 | [402](../../../tasks/402-direction-chain-label-removed.md) | Done | Имя Направления снято (отменено 405) |
| 10 | [405](../../../tasks/405-direction-chain-label-mobile-only.md) | Done | Имя возвращено как поле клиента |
| 11 | [408](../../../tasks/408-ping-options-groups-heal.md) | Done | Ping-переопределение снимается вместе с Направлением |
| 12 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Хранение в форме контракта; `channels` переименовывается в `directions` при чтении |
| 13 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Лечение цели в переменных пресетов и DNS-серверов → `vpn-1` |
