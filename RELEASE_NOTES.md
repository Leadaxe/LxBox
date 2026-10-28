# L×Box v2.25.18-rc.3

**The third release candidate on top of [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release. It contains everything from
[v2.25.18-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.2);
below are the changes since rc.2.

The core is stable again: `v1.14.4-lx.24`, on the upstream sing-box 1.14.4
base. URL Check gets findings about the config, reports a redirect as the
answer instead of a false «HTTP 0», and clears the previous result when the
check's parameters change.

**Третий релиз-кандидат поверх [v2.25.17](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.17).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается. В нём
всё из [v2.25.18-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.2);
ниже — изменения относительно rc.2.

Ядро снова стабильное: `v1.14.4-lx.24` на базе апстримного sing-box 1.14.4.
URL Check получил находки о конфиге, показывает редирект как ответ вместо
ложного «HTTP 0» и стирает прошлый результат при смене параметров проверки.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ⚠️ Read before updating

- **New upstream base.** The core moves to upstream sing-box 1.14.4. Upstream
  changed how groups are resolved; Auto (`urltest`) groups still pick a node
  per connection as before. If a group or a WireGuard node behaves
  differently after the update, report it.

## ✨ New

- **URL Check: findings.** Under the result the core lists what it noticed
  about the config, at three levels: a cause of the failure, a risk, a fact.
  For example: a package excluded from the VPN, a node that depends on a DNS
  server's detour outside the route, fake IP records lost after a restart,
  REALITY not recognizing the client. A tap on a finding highlights its
  steps.
- **URL Check: more steps.** The REALITY verdict, the wake-up of a sleeping
  WireGuard endpoint, the WireGuard handshake with the detour that carries
  it, QUIC and authentication of MASQUE and TrustTunnel, and a DNS server
  connection taken from the pool.

## 🔄 Changed

- **URL Check: a redirect is the answer.** A site that answers `301`/`302`
  shows that status and the `location` it points to; the check does not
  follow the chain. Before, such a check ended with a green «HTTP 0».
- **URL Check: no false success.** A full check that ends without an HTTP
  response and without a failed step shows a yellow «No HTTP response».
- **URL Check: the result belongs to its parameters.** Changing the URL, the
  app, the depth or From scratch clears the previous result.
- **URL Check: an empty answer explains itself.** When a DNS rule or the
  domain strategy answered without asking a DNS server, the step says so
  instead of a bare «No records».

## 🔧 Under the hood

- Core `v1.14.4-lx.24` (was `v1.14.3-lx.24-rc.2`): SPEC 139 stable, upstream
  sing-box 1.14.4 with Go 1.26.10, a data race in the Auto group's selection
  fixed.
- Below Android 10 the owner of a connection (per-app rules) is looked up by
  the core in `/proc/net` through a call from the app; the core no longer
  does it on its own.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ⚠️ Прочтите до обновления

- **Новая база апстрима.** Ядро переходит на апстримный sing-box 1.14.4.
  Апстрим изменил разбор групп; группы Auto (`urltest`) по-прежнему выбирают
  узел на каждое соединение. Если группа или WireGuard-узел после обновления
  ведут себя иначе — сообщите.

## ✨ Новое

- **URL Check: находки.** Под результатом ядро перечисляет, что заметило в
  конфиге, на трёх уровнях: причина сбоя, риск, факт. Например: пакет
  исключён из VPN, узел зависит от detour'а DNS-сервера вне маршрута, записи
  fake IP теряются после перезапуска, REALITY не узнал клиента. Тап по
  находке подсвечивает её шаги.
- **URL Check: больше шагов.** Вердикт REALITY, пробуждение спящего
  WireGuard-эндпоинта, рукопожатие WireGuard с detour'ом, который его несёт,
  QUIC и аутентификация MASQUE и TrustTunnel, соединение с DNS-сервером из
  пула.

## 🔄 Изменено

- **URL Check: редирект — это ответ.** Сайт, ответивший `301`/`302`,
  показывает этот статус и адрес из `location`; по цепочке проверка не идёт.
  Раньше такая проверка заканчивалась зелёным «HTTP 0».
- **URL Check: без ложного успеха.** Полная проверка, закончившаяся без
  HTTP-ответа и без упавшего шага, показывает жёлтое «No HTTP response».
- **URL Check: результат относится к своим параметрам.** Смена URL,
  приложения, глубины или From scratch стирает прошлый результат.
- **URL Check: пустой ответ объясняет себя.** Когда ответило правило DNS или
  стратегия домена, не спрашивая DNS-сервер, шаг говорит об этом, а не
  просто «No records».

## 🔧 Под капотом

- Ядро `v1.14.4-lx.24` (было `v1.14.3-lx.24-rc.2`): SPEC 139 в стабильном
  релизе, апстримный sing-box 1.14.4 с Go 1.26.10, исправлена гонка данных
  при выборе узла в группе Auto.
- Ниже Android 10 владельца соединения (правила по приложениям) ядро ищет в
  `/proc/net` по вызову из приложения; само оно этого больше не делает.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.18-rc.3-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.18-rc.2](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.18-rc.2) · stable / стабильный: [v2.25.17](docs/releases/v2.25.17.md).
