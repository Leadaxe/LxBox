# 697 — ru-direct: у каждого DNS-сервера Яндекса свой IP и вариант Off

| Поле | Значение |
|------|----------|
| Статус | Done (preset_expand_test 77/77; эмулятор и телефон не проверены) |
| Дата начала | 2026-10-30 |
| Источник | issue #183 (@paratroop3r): в 2.25.17 автор выключал нешифрованный UDP Яндекса, в 2.25.18 такой возможности нет; просит выключать любой из трёх серверов пресета и выбирать профиль Safe/Base у DoT и DoH |
| Связанные | §684 (поправка 29.10: var `dns_plain_outbound` снят, UDP идёт через `@outbound` пресета), §354 (у ru-direct нет var `dns_server`, эмитятся все объявленные серверы), §038 (дефолты DNS ru-direct), §246 (`#if` элемента массива), SPEC 107 (`#enable`), §604 (DNS-правило со `server` на отсутствующий сервер выпадает), §247 (heal `server` у resolve-правил), §312 (DNS-группа) |

## Проблема

В 2.25.17 у пресета «Ru internet segment» был var `dns_plain_outbound`
(«UDP DNS outbound», пикер Направления, по умолчанию `vpn-1`). В пикере
всегда есть системный `block`. Автор выбрал его: `yandex_udp` шёл в
`block`, группа `dns_ru` (`fastest`) отвечала через DoT/DoH. Поправка §684
от 29.10 сняла var, UDP снова идёт Направлением пресета, сохранённое
значение не читается. Отдельного способа выключить сервер не было и нет.

DoT и DoH зашиты на `77.88.8.88` с SNI `safe.dot.dns.yandex.net`, выбрать
Base или Family нельзя. UDP выбирается из 10 адресов (`dns_ip`).

## Факты (проверено 30.10.2026 с машины разработчика)

- Профиль Яндекса задаёт IP, а не имя в TLS. DoH на `77.88.8.7` с именем
  `common.dot.dns.yandex.net` фильтрует как Family (`pornhub.com` →
  `93.158.134.250`), на `77.88.8.8` с именем `family.dot.dns.yandex.net`
  не фильтрует. Перекрёстно проверен только DoH.
- Сертификат на `:853` один для всех адресов: SAN = `*.dot.dns.yandex.net`,
  `*.doh.dns.yandex.net` и IP `77.88.8.1/2/3/7/8/88`. DoT с именами
  `common`/`safe`/`family` на `77.88.8.8`/`.88`/`.7` проходит проверку
  имени, DoH на тех же адресах отвечает `200 application/dns-message`.

## Решение (владелец 30.10.2026)

1. **Три var-списка, у каждого вариант `Off`** (значение `off`):
   - `dns_ip` — «UDP server»: прежние 10 адресов + Off. Имя var прежнее,
     сохранённый выбор пользователя не теряется.
   - `dns_dot_ip` — «DoT server»: `77.88.8.8 · Base`, `77.88.8.88 · Safe`,
     `77.88.8.7 · Family`, Off. По умолчанию `77.88.8.88`.
   - `dns_doh_ip` — «DoH server»: тот же набор, по умолчанию `77.88.8.88`.
   Подсказка у всех трёх: «The IP sets the profile. Off: not used.»
2. **SNI у DoT/DoH прежний** (`safe.dot.dns.yandex.net`): профиль от него
   не зависит, а конфиг по умолчанию остаётся байт в байт прежним.
3. **Сервер в Off не эмитится и не входит в группу.** У объекта сервера
   `#enable: {"#not": {"@<var>": "off"}}`; в `servers` группы — `#if`
   элемента массива на тот же предикат.
4. **Группа `dns_ru` объявлена последней** в `dns_servers` пресета (после
   членов) — слово владельца. У группы `#enable` = «включён хотя бы один».
   Порядок в конфиге задаёт сохранённый список DNS (`resolveDnsServersList`,
   `post_steps/dns_servers.dart`: сохранённые записи в своём порядке,
   недостающие серверы пресета дописываются в конец). Поэтому новый порядок
   получают новые установки; у существующих записи `ru-direct:*` уже лежат
   в списке (группа первой) и остаются как есть, ядру порядок безразличен.
   Сервер, выключенный через Off, снимается со списка как сирота; при
   включении он дописывается в конец.
5. **Все три Off** = группы нет, как при выключенном тумблере DNS:
   DNS-правило пресета (`server: dns_ru`) сборка снимает
   (`dnsMirrorRule`, §604), у resolve-правила Force IPv4 heal §247 снимает
   `server`, резолв идёт общим DNS; правило `predefined` для AAAA
   (serverless) остаётся.
6. **Outbound у UDP отдельно не настраивается** — UDP идёт через Outbound
   пресета (решение §684 от 29.10 не меняется). DoT/DoH — прежняя галка
   «Encrypted DNS via Outbound».
7. **Миграции нет.** Сохранённое в 2.25.17 `dns_plain_outbound = block`
   не переносится; пользователь выбирает Off сам.

## Сборка: правок кода нет

`#enable` на любом объекте обрабатывает движок подстановки
(`_walkMap`, `app/lib/services/builder/if_engine.dart:400`): при ложном
условии объект становится `Dropped`, и цикл эмиссии `dns_servers` пресета
(`app/lib/services/builder/preset_expand.dart:917`) его пропускает
(`result is! Map`). `#if` элемента массива в `servers` группы — механизм
§246.

## Затронутые файлы

- `app/assets/wizard_template.json` — пресет `ru-direct`: vars, `dns_servers`.
- `app/assets/l10n/{ru,zh}/template.json` — новые строки, снятые
  «UDP server IP» и подсказка «Applies to UDP only…».
- `app/test/services/builder/preset_expand_test.dart` — e2e на настоящем
  шаблоне: дефолты (порядок с группой в конце), UDP Off, один DoT Base,
  DoH Family, все Off.
- Golden `rich_v0` не меняется: в фикстуре хранилища записи `ru-direct:*`
  уже есть в старом порядке (см. п. 4).
- `docs/TEMPLATE.md`, `docs/spec/features/005-DNS/FUNCTIONS/builtin-dns-sets{,.ru}.md`,
  `docs/spec/features/024-TEMPLATE/FUNCTIONS/preset-bundles{,.ru}.md`,
  `docs/USER_GUIDE{,.ru}.md`, `CHANGELOG.md`.

## Проверка

1. Дефолты: в конфиге `yandex_udp` (`77.88.8.8`), `yandex_dot` и
   `yandex_doh` (`77.88.8.88`, SNI safe), затем `dns_ru` из трёх членов.
2. UDP Off: `yandex_udp` нет, группа из `yandex_dot`, `yandex_doh`.
3. DoT `77.88.8.8`, DoH Off, UDP Off: `yandex_dot` с `server: 77.88.8.8`,
   группа из одного члена.
4. Все Off: серверов пресета нет, DNS-правила `dns_ru` нет, VPN стартует.
5. Редактор правила: три списка, вариант Off в каждом.
