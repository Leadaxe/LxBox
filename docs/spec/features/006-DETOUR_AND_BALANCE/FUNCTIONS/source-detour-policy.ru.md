[English](source-detour-policy.md) · [Русский](source-detour-policy.ru.md)

# Detour источника и jump-серверы

| Поле | Значение |
|------|----------|
| Фича | [006-DETOUR_AND_BALANCE](../FEATURE.ru.md) |
| Обещания | P2 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Задаёт одним решением, как ходят все узлы подписки или папки: через
родные detour-цепочки провайдера (jump-серверы), через выбранный
пользователем outbound поверх или вместо них, либо напрямую. Решает и
видимость звеньев: по умолчанию jump-серверы работают только как хопы
и не попадают в выбор узлов.

## Параметры

Вкладка настроек подписки/папки, блок **Detour servers** (есть родные
цепочки или личные detour членов папки):

| Режим | Хранение | Что в конфиге |
|---|---|---|
| Use subscription detour servers / Use servers' own detours | use=вкл, override нет | родная цепочка как есть |
| Add detour → Outbound + **Fill missing** | use=вкл, override, replace=выкл | узел → родная цепочка → override хвостом; без цепочки — узел → override |
| Add detour → Outbound + **Replace all** | use=вкл, override, replace=вкл | родная цепочка отброшена, узел → override |
| Don't use detour servers | use=выкл | `detour` снят, override игнорируется |

Подпись «Add detour» отражает выбор: «Append an outbound to the end of
the chain» / «Fill missing → X» / «Replace all → X».

При Use и Fill missing — переключатели (хранятся независимо от режима):

| Ручка | Умолчание | Эффект |
|---|---|---|
| Register detour servers | выкл | звенья попадают в селекторы Направлений (видны в списке узлов) |
| Register detour in auto group | выкл | звенья попадают в `<tag>-auto` |

Источник без родных цепочек показывает одну строку **Detour server**
(«None — nodes connect directly» либо `Phone → X → Nodes → Internet`) —
тот же override, режим append на пустой цепочке.

## Входы / Выходы

**Входы:** узлы источника с родными звеньями (Xray `dialerProxy`,
sing-box `detour`), политика, выбранная ссылка.
**Выходы:** `detour` у узлов и последнего звена; звенья как отдельные
outbound'ы; состав селекторов и `<tag>-auto`.

## Правила и инварианты

- «Don't use» побеждает override (P2).
- Имя jump-сервера — собственный тег звена из конфига провайдера с
  префиксом источника, без декораций; звенья уникализируются общим
  аллокатором тегов.
- Звено Xray `dialerProxy` может само идти через следующее; служебные
  `freedom`/`blackhole`/`dns` звеном не бывают; негодное звено в середине
  роняет владельца — усечённый путь не собирается.
- Узел, чей тег начинается с `⚙ `, и член папки, на которого указывает
  личный detour другого члена, ведут себя как звено: в выбор узлов и
  автовыбор — только по register-переключателям.
- Папка: личный detour члена сохраняется при Use и Fill missing; при
  Replace all перекрывается папочным. Если папочный override указывает на
  своего члена X, X и всё, что достижимо из него по личным detour, ведут
  себя как Use — иначе путь замкнулся бы на X.
- Узлы автовыбора и узлы, не способные быть выходом (Tailscale без exit
  node), в пул Направлений не идут ни при какой политике.
- Неразрешившийся override — см. P1 в [node-detour.md](node-detour.ru.md).

## Границы

- «Hide detour servers / Show only detour servers» на главном экране
  (звено = узел, на который кто-то ссылается как на detour) —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.ru.md).
- Разбор `dialerProxy`/`detour` из подписки — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.ru.md).
- У подписки личного detour отдельного узла нет — только у одиночного
  сервера и члена папки.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Политика в 026 | Detour-политика подписки, jump-серверы |
| 2 | [073](../../../tasks/073-detour-append-vs-replace.md) | Released v1.9.0 | Append (умолчание) против Replace |
| 3 | [079](../../../tasks/079-detour-prefix-aware-tag-detection.md) | ✅ Реализовано | Маркер звена распознаётся и после префикса источника |
| 4 | [093](../../../tasks/093-detour-by-isdetour.md) | Done | Звено — по факту ссылок, ⚙ — только визуал; register-политики сохранены |
| 5 | [096](../../../tasks/096-unified-negate-toggle.md) | DONE | Трёхпозиционный фильтр detour на главном |
| 6 | [111](../../../tasks/111-subscription-detour-without-native-chain.md) | Done | Detour для подписки без родных цепочек |
| 7 | [239](../../../tasks/239-folder-detour-symmetry.md) | реализовано | Папка симметрична подписке: интра-цепочки, exempt |
| 8 | [245](../../../tasks/245-detour-mode-wording.md) | реализовано | «Replace all» / «Fill missing» вместо тумблера |
| 9 | [404](../../../tasks/404-dialer-proxy-signature.md) | Код готов | Имя звена — тег провайдера, без `⚙` |
| 10 | [488](../../../tasks/488-xray-dialer-proxy-freedom-fragment.md) | Released v2.25.0 | `dialerProxy` на freedom — конец цепочки |
