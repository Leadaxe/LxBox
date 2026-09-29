[English](networks-tab.md) · [Русский](networks-tab.ru.md)

# Вкладка Network — tailnet глазами телефона с переключением exit node

Вкладка Network узла Tailscale показывает, вошёл ли узел, кто ещё в tailnet,
какой пир служит выходом, и позволяет переключить выход на ходу, войти, выйти
и проверить устройство.

| Поле | Значение |
|------|----------|
| Фича | [030-TAILSCALE](../FEATURE.ru.md) |
| Обещания | P19–P24 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Превращает поток состояния tailnet от ядра в экран: блок Status (состояние,
имя сети, «signed in with a key», Sign in, Log out), This device (имя,
MagicDNS-имя, адреса, срок ключа), Exit node (пиры, предлагающие выход, None
первым, с «Save choice», когда действующий выход отличается от записанного),
Devices (сначала в сети, группы по владельцам, когда их несколько) и Ping через
tailnet. Тот же поток питает строку NETWORKS на главном экране, вкладку
Diagnostics и Debug API.

## Параметры

| Что | Значение |
|-----|----------|
| Где | экраны узла своего сервера, члена папки, узла подписки и экран просмотра из NETWORKS или «View details»; перед Diagnostics |
| Начальная вкладка | из строки NETWORKS — Network; из «View details» — прежняя |
| Список Exit node | пиры с `ExitNodeOption`, порядок как в Devices; «None» первым |
| Save choice | видна, когда действующий и записанный выход различаются и у узла есть запись источника (свой сервер или член папки) |
| Записываемое значение | адрес Tailscale действующего пира, IPv4 первым; без адресов — MagicDNS-имя, затем имя хоста; None убирает `exit_node` |
| Ping | до пяти ответов или до закрытия листа; задержка, direct или relay, адрес endpoint'а или регион ретранслятора |
| Debug API | `GET /state` → `tailscale: {тег: {backend_state, devices}}` |

## Входы / Выходы

**Входы:** поток ядра (`BackendState`, `StateText`, `AuthURL`, `NetworkName`,
`MagicDNSSuffix`, `KeyAuth`, свой узел, exit node, пиры по владельцам); статус
туннеля; тело узла; нажатия: пункт списка, Save choice, Sign in, Log out, Copy
name, Copy address, Ping.

**Выходы:** вкладка; `SetTailscaleExitNode` (`StableID` или пусто),
`TailscaleLogout`, `StartTailscalePing`; источник узла с изменённым
`exit_node` и пересобранный конфиг; снекбары «Copied», «Failed: …»; строка на
Diagnostics «This node has no exit. Check devices on the Network tab.»

## Правила и инварианты

- **Вкладка есть только у узла Tailscale** (P19); индекс вкладки Diagnostics
  сдвигается на один.
- **Без данных** (P20): VPN выключен — «Start VPN to see the network.»; записи
  от ядра по тегу ещё нет — индикатор ожидания; узел выключен или его нет в
  работающем конфиге — «The node is not in the running config.»
- **Status:** текст состояния как в строке NETWORKS (`running`, `sign-in
  needed`, `stopped`, `starting` или текст ядра); Sign in появляется в
  `NeedsLogin` при непустом `AuthURL` и открывает его в браузере; Log out
  появляется в `Running` после подтверждения, которое говорит, что узел с
  записанным ключом входа войдёт снова при следующем запуске.
- **Exit node** (P21): выбор пункта зовёт ядро и переключает выход на ходу;
  тело не трогается. Записанное значение указывает на пира, когда равно
  одному из его адресов, MagicDNS-имени (с точкой в конце или без), базовому
  имени или имени хоста без учёта регистра. Случаи расхождения и тексты у
  знака: не записан, выбран на ходу — «Not saved. Traffic is not routed
  through this node until you save the choice.»; записан, снят на ходу — «Not
  saved. The node stays in the lists, but has no exit until you save the
  choice.»; выбран другой — «Not saved. The choice is lost after restart.»
  Save choice пишет адрес в источник узла (порядок ключей сохранён),
  проверяет конфиг ядром и сохраняет узел тем же путём, что Save на вкладке
  Source; после пересборки узел переходит между NETWORKS и списками
  Направлений. У узла подписки знак есть, Save choice нет.
- **Devices** (P22): пиры кроме этого устройства, сначала в сети, затем по
  имени; отметки: `online` / `offline` с `last seen`, `key expired`, `shared`,
  `exit node`, ОС, когда известна; нажатие на имя или адрес копирует, меню
  строки — Copy name, Copy address, Ping. Группы владельцев показываются
  только при нескольких владельцах; картинки профилей не грузятся.
- **Перерисовка** не чаще раза в секунду; список ленивый.
- **Diagnostics** (P23): действующего выхода нет — проверка запросом к
  внешнему адресу скрыта и заменена строкой; при поднятом VPN решает выход
  ядра, иначе записанный `exit_node`.
- **Приватность** (P24): имена, адреса, имя сети, владельцы и ссылка входа не
  попадают в журнал приложения, дамп поддержки и Debug API.
- Подписка на состояние считается по потребителям: главный экран и каждая
  открытая вкладка держат её вместе; перезагрузка конфига переподнимает её.

## Границы

- Сама строка NETWORKS и таблица состояний —
  [012-LIVE_STATE · P19](../../012-LIVE_STATE/FEATURE.ru.md#обещания); вкладка
  Diagnostics — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.ru.md).
- Переключение выхода, Log out и Ping на устройстве с живой tailnet не
  проверены (DEVICE-PENDING).
- Не показываются: трафик по устройствам, соединения через узел, SSH,
  Taildrop, сертификаты `*.ts.net`.
- Выход, выбранный на ходу, переживает перезапуск через каталог состояния,
  пока в теле нет `exit_node`; `ephemeral: true` его теряет.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented, DEVICE-PENDING | Мост потока состояния; строка NETWORKS; решение о вкладке как follow-up |
| 2 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented, DEVICE-PENDING | Вкладка Network, exit node на ходу и Save choice, Ping, строка Diagnostics, сводка Debug API |
