[English](tls-fragmentation.md) · [Русский](tls-fragmentation.ru.md)

# Фрагментация TLS — ClientHello по частям, чтобы DPI не прочитал SNI

LxBox может делить TLS ClientHello узлов первого хопа на несколько TCP-сегментов
или TLS-записей, чтобы DPI не увидел SNI в одном пакете.

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.ru.md) |
| Обещания | P1 P2 P3 P4 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Режет ClientHello на куски, чтобы DPI не увидел SNI в одном пакете.
Два источника флагов: глобальные галки раздела «TLS Fragmentation»
(для всех прямых узлов сразу) и фрагментация, которую заложил провайдер
в Xray-подписке (для конкретного узла). Под `detour` решение оставлено
ядру: оно само включает `record_fragment`, когда явных флагов нет.

## Параметры

| Ручка | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| TLS Fragment — «Split TLS ClientHello into small TCP segments» | вкл/выкл | выкл | `tls.fragment` |
| TLS Record Fragment — «Split handshake into multiple TLS records (try this first)» | вкл/выкл | выкл | `tls.record_fragment` |
| Fallback delay | duration-строка | `500ms` | `tls.fragment_fallback_delay` |

| Режим ядра | Что делает |
|---|---|
| `fragment` | куски ClientHello — отдельными TCP-сегментами, ожидание ACK |
| `record_fragment` | куски — отдельными TLS-записями одним `Write`, без пауз |
| оба | каждая запись — своим сегментом, с ожиданием ACK |

Пауза `fragment_fallback_delay` действует там, где ACK не отследить
(в частности под `detour`).

Уровни (§636). Четыре ручки (обе галки, пауза, Mixed-case SNI) задаются
на трёх уровнях:

| Уровень | Где | Действует на |
|---|---|---|
| узел | экран узла, секция TLS (одиночный сервер, член папки) | этот узел и его родную цепочку |
| источник | вкладка настроек подписки или папки, секция TLS | все узлы источника |
| глобально | VPN Settings → Core → TLS Fragmentation | всё остальное и не заданное выше |

Каждое поле разрешается отдельно: узел → источник → глобально, первое
заданное побеждает; `Default` — «наследовать». `Off` ниже бьёт `On` выше.
Outbound'ы не из источников (шаблон, Направления, WARP) живут только по
глобальному слою. У узла подписки своего уровня нет.

## Входы / Выходы

**Входы:** галки и пауза; тела узлов после проставления `detour`;
Xray-JSON узла (`streamSettings.sockopt.dialerProxy` → `freedom` с
`settings.fragment`; `streamSettings.finalmask.tcp[]` с `type: fragment`).
**Выходы:** флаги в `tls` outbound'ов; код `detour_with_tls_fragment` в
уведомлениях узла; строка предупреждения сборки.

## Правила и инварианты

- Глобальные галки пишут флаги только outbound'ам без `detour` и с
  `tls.enabled: true`. Пауза пишется при любой включённой галке; значение,
  которое ядро не разберёт как длительность (`500`, `fast`), заменяется на
  `500ms`.
- Годность поля узлу спрашивается у реестра по телу: naive — запрещено
  (ядро падает «fragment is not supported on naive outbound»); hysteria,
  hysteria2, tuic — запрещено, QUIC не фрагментируется
  (`tls_not_applicable_quic`, контракт 1.1.118); MASQUE
  `vhttp: h3` — конфликт, пропуск молча; MASQUE `h2`/не задан — блок
  `tls{}` создаётся, если его не было, SNI не теряется.
- Флаги с `tls.engine` = `apple`/`windows` снимаются с кодом
  `tls_fragment_system_engine` (ядро отвергло бы старт).
- Узловой `tls.fragment` под `detour`, назначенным сборкой (цепочка,
  «Add detour» источника), снимается с кодом `detour_with_tls_fragment`
  (info); пауза снимается, если `record_fragment` не задан. Явный
  `record_fragment` под `detour` остаётся. `detour`, написанный внутри
  входного sing-box JSON, связь не включает.
- У авторского JSON-тела `tls.fragment` не снимается: код с пометкой
  «(not applied)».
- Xray `dialerProxy` → `freedom` с `fragment` и `finalmask.tcp` c
  `type: fragment` дают `tls.fragment: true` (не `record_fragment`), если
  TLS включён и узел не ходит через прокси-хоп; `freedom` хопом не
  считается. `packets`, `length`, `delay`, `maxSplit`
  отбрасываются без кода; две формы сразу — один флаг. У hysteria/
  hysteria2 запись не действует. Прочие `type` в `finalmask.tcp[]` —
  `json_field_unknown`.
- REALITY и фрагментация (§627, §636): галки глобального уровня и уровня
  подписки/папки REALITY-узел пропускают — массовая настройка не знает,
  примет ли сервер разрезанный ClientHello; галка, поставленная на сам узел,
  применяется. Mixed-case SNI к REALITY не применяется ни на каком уровне.
- `Off` на любом уровне флаги, пришедшие в теле узла (Xray `dialerProxy`,
  `finalmask.tcp`, авторский JSON), не снимает — только не дописывает.

- Все настройки переносимы: глобальные едут в межплатформенный бэкап как
  `vars`, политика узла и источника — полем записи `tls` (контракт 1.1.117,
  сторона LxBox; лаунчер его молча игнорирует). При слиянии совпавшие
  источник и узел держат свою политику.

## Границы

- Пинг и проба узла собирают свой конфиг, но применяют те же галки и ту же
  паузу по уровням, что туннель, — пинг проверяет путь трафика; узловой
  `tls.fragment` под `detour` пробы снимается так же, но без кода.

- Пропуск звеньев цепочки и `strip_evasion` —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.ru.md).
- Фрагментация QUIC Initial у WARP — [015-WARP](../../015-WARP/FEATURE.ru.md).
- Отключить фрагментацию под `detour` совсем нельзя: явное
  `record_fragment: false` ядро не отличает от «не задано».
- Параметры размеров и пауз Xray не эмулируются: точки разреза ядро
  выбирает само по меткам SNI.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [020F](../../../tasks/020F-security-and-dpi-bypass/spec.md) | Закрыто | Галки fragment/record_fragment, только first-hop |
| 2 | [270](../../../tasks/270-naive-tls-fragment-incompatible.md) | — | naive не получает флаги фрагментации |
| 3 | [393](../../../tasks/393-masque-config-schema-migration.md) | — | MASQUE: фрагментация на h2, пропуск h3 |
| 4 | [488](../../../tasks/488-xray-dialer-proxy-freedom-fragment.md) | Released v2.25.0 | `dialerProxy` → `freedom` с fragment → `tls.fragment` |
| 5 | [573](../../../tasks/573-xray-finalmask-tcp-fragment.md) | Released v2.25.7 | `finalmask.tcp` fragment → `tls.fragment` |
| 6 | [574](../../../tasks/574-tls-fragment-yields-to-detour.md) | Released v2.25.7 | `tls.fragment` уступает `detour` сборки и системному движку |
| 7 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | Невалидная пауза заменяется на `500ms` |
| 8 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | Пинг и проба применяют глобальную фрагментацию, как туннель |
| 9 | [636](../../../tasks/636-tls-settings-per-node-folder-subscription.md) | Implemented | Ручки на узле, папке и подписке; REALITY фрагментируется только от узлового флага |
| 10 | [642](../../../tasks/642-contract-1-1-118-sync.md) | Done | QUIC-протоколы (hysteria, hysteria2, tuic) флагов не получают |
