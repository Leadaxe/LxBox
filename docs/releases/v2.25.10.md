# L×Box v2.25.10

**A patch on top of [v2.25.9](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.9).**

The node row shows a Tailscale exit node (`via <device>`, `exit offline`, a
key-expiry warning) and a catalogue of public subscription sources is now
linked from the README. A round of audit fixes (tasks 594–607): subscriptions
and own servers, DNS and config build, backup, routing, WARP, anti-DPI, l10n
and shell. No core change — still `v1.14.2-lx.11`.

**Патч поверх [v2.25.9](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.9).**

Строка узла показывает Tailscale exit node (`via <устройство>`, `exit
offline`, предупреждение об истечении ключа), из README появилась ссылка на
каталог публичных источников подписок. Раунд фиксов по аудиту (задачи
594–607): подписки и свои серверы, DNS и сборка конфига, бэкап, роутинг,
WARP, anti-DPI, локализация и shell. Ядро не менялось — всё ещё
`v1.14.2-lx.11`.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ Added

- **Tailscale exit node in the node row ([task 608](docs/spec/tasks/608-tailscale-exit-node-in-node-row.md)).**
  With the VPN on, a node with an exit node reads `tailscale·via <device>`; an
  offline exit device shows `exit offline` in orange instead of the endpoint
  state. Less than 7 days before the device key expires, the row warns
  `key expires Nd` / `key expired` (on a NETWORKS row — instead of `running`).
  Direct vs relay stays in the Network tab: the core's status carries no path
  ([#155](https://github.com/Leadaxe/LxBox/issues/155)).
- **Catalogue of public subscription sources ([task 602](docs/spec/tasks/602-public-sources-catalog.md)),**
  EN+RU, linked from the README.

## 🔄 Changed

- **A hop chain has one name, its tag ([task 594](docs/spec/tasks/594-chain-label-removed-tag-only.md)).**
  The separate label is gone: the Direction filter and the editor title use
  the same name the user sees.
- **The `connecting` timeout grows with the node count ([task 596](docs/spec/tasks/596-connecting-timeout-scales-with-nodes.md)):**
  `max(15 s, 0.1 s × N)` plus a margin for endpoints. A subscription of
  ~230 nodes no longer has its tunnel killed right after the core started it.
- **Ping and probe apply TLS fragmentation and mixed-case SNI** the same way
  the tunnel does ([task 606](docs/spec/tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md)).

## 🩹 Fixes

- **Nodes and parsing.** Saving an INI source (WireGuard/AWG) is no longer
  taken for a JSON array ([594](docs/spec/tasks/594-ini-source-save-invalid-json.md));
  a whole number written as `0.0` is emitted as an integer ([595](docs/spec/tasks/595-integral-float-emitted-as-int.md));
  `max_concurrency: "0"` counts as unset and raises no `field_conflict` ([597](docs/spec/tasks/597-xmux-conflict-false-on-zero-string.md));
  empty fields of a v2rayN container count as absent keys ([598](docs/spec/tasks/598-vmess-empty-fields-no-warnings.md)).
- **Backup.** «Replace all» replaces only the selected categories instead of
  the whole settings document ([599](docs/spec/tasks/599-backup-replace-per-category.md));
  startup-prompt flags are not reported as unknown keys ([600](docs/spec/tasks/600-backup-startup-prompt-flags-not-unknown.md));
  replacing a backup keeps the VPN toggle mirror ([607](docs/spec/tasks/607-l10n-backup-shell-bugs-from-591.md)).
- **Routing.** A rule whose rule set is not downloaded yet stays on ([601](docs/spec/tasks/601-routing-missing-srs-keeps-enabled.md)).
- **Subscriptions and own servers ([task 603](docs/spec/tasks/603-subscription-and-own-server-bugs.md)).**
  Changing a subscription URL keeps nodes and cache until the first
  successful update; a file subscription applies import rules to its
  snapshot and its Source tab reads the cache; a broken own-server source is
  not saved; deleting an own server asks «Delete server?»; a negative
  `profile-update-interval` from the server is rejected; one request per URL
  per pass.
- **DNS and config build ([task 604](docs/spec/tasks/604-dns-build-health-directions-bugs.md)).**
  Editing SNI of a DNS server keeps the other `tls` fields; a custom DNS rule
  pointing to a missing server is dropped with a code; the proxy port is
  checked on load from storage and backup; «config outdated» fires for every
  template variable; Direction `pool_tolerance` is clamped to the core
  limit 15000.
- **Service, automation, profiler ([task 605](docs/spec/tasks/605-service-live-automation-workspaces-bugs.md)).**
  A start error gets its own notification; a core failure after an accepted
  `SWITCH_NODE` reports `VPN_ERROR(switch_failed)`; automation commands
  resync with storage on start, after a backup and on a workspace switch; the
  profiler reconnects on every tunnel start, START clears connection
  snapshots (no false `tcpClose`), the «DNS / router events off» banner is
  gone.
- **Node list, WARP, anti-DPI ([task 606](docs/spec/tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md)).**
  «Copy link» on a node without a link says so instead of doing nothing;
  dragging under a filter keeps hidden nodes in place; a custom WARP
  endpoint is checked as `host:port` before registration; an invalid TLS
  fragmentation pause is replaced with 500 ms.
- **Localisation and shell ([task 607](docs/spec/tasks/607-l10n-backup-shell-bugs-from-591.md)).**
  More strings go through translation (node copy, theme, About, Add tile,
  restore summary); the core locale follows the saved app language from
  process start; the read-only code editor offers no Cut/Paste.

## 🔧 Under the hood

- Contract 1.1.108 (registry texts only); `sync_contract --to` writes the
  full commit sha to the lock.
- Dead code found by audit 591 removed ([task 593](docs/spec/tasks/593-remove-dead-code-after-audit-591.md));
  no user-visible change.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Добавлено

- **Tailscale exit node в строке узла ([задача 608](docs/spec/tasks/608-tailscale-exit-node-in-node-row.md)).**
  При включённом VPN узел с exit node показывает `tailscale·via <устройство>`;
  офлайн-устройство exit показывает `exit offline` оранжевым вместо состояния
  эндпоинта. Меньше чем за 7 дней до истечения ключа устройства строка
  предупреждает `key expires Nd` / `key expired` (на строке NETWORKS — вместо
  `running`). Прямое соединение vs relay по-прежнему только на вкладке
  Network: статус ядра не несёт путь
  ([#155](https://github.com/Leadaxe/LxBox/issues/155)).
- **Каталог публичных источников подписок ([задача 602](docs/spec/tasks/602-public-sources-catalog.md)),**
  EN+RU, со ссылкой из README.

## 🔄 Изменено

- **У цепочки хопов одно имя — тег ([задача 594](docs/spec/tasks/594-chain-label-removed-tag-only.md)).**
  Отдельного лейбла больше нет: фильтр Direction и заголовок редактора
  используют то же имя, что видит пользователь.
- **Таймаут `connecting` растёт с числом узлов ([задача 596](docs/spec/tasks/596-connecting-timeout-scales-with-nodes.md)):**
  `max(15 с, 0.1 с × N)` плюс запас на эндпоинты. Подписка из ~230 узлов
  больше не теряет туннель сразу после старта ядра.
- **Пинг и проба применяют TLS-фрагментацию и mixed-case SNI** так же, как
  туннель ([задача 606](docs/spec/tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md)).

## 🩹 Исправления

- **Узлы и парсинг.** Сохранение INI-источника (WireGuard/AWG) больше не
  принимается за JSON-массив ([594](docs/spec/tasks/594-ini-source-save-invalid-json.md));
  целое число, записанное как `0.0`, эмитится как целое ([595](docs/spec/tasks/595-integral-float-emitted-as-int.md));
  `max_concurrency: "0"` считается неустановленным и не даёт `field_conflict`
  ([597](docs/spec/tasks/597-xmux-conflict-false-on-zero-string.md)); пустые
  поля контейнера v2rayN считаются отсутствующими ключами
  ([598](docs/spec/tasks/598-vmess-empty-fields-no-warnings.md)).
- **Бэкап.** «Replace all» заменяет только выбранные категории, а не весь
  документ настроек ([599](docs/spec/tasks/599-backup-replace-per-category.md));
  флаги startup-prompt не репортятся как неизвестные ключи
  ([600](docs/spec/tasks/600-backup-startup-prompt-flags-not-unknown.md));
  замена бэкапа сохраняет зеркало тумблера VPN
  ([607](docs/spec/tasks/607-l10n-backup-shell-bugs-from-591.md)).
- **Роутинг.** Правило, чей rule set ещё не скачан, остаётся включённым
  ([601](docs/spec/tasks/601-routing-missing-srs-keeps-enabled.md)).
- **Подписки и свои серверы ([задача 603](docs/spec/tasks/603-subscription-and-own-server-bugs.md)).**
  Смена URL подписки сохраняет узлы и кэш до первого успешного обновления;
  файловая подписка применяет import-правила к своему снапшоту, а вкладка
  Source читает кэш; битый источник своего сервера не сохраняется; удаление
  своего сервера спрашивает «Delete server?»; отрицательный
  `profile-update-interval` от сервера отклоняется; один запрос на URL за
  проход.
- **DNS и сборка конфига ([задача 604](docs/spec/tasks/604-dns-build-health-directions-bugs.md)).**
  Правка SNI DNS-сервера сохраняет остальные поля `tls`; своё DNS-правило,
  указывающее на отсутствующий сервер, отбрасывается с кодом; порт прокси
  проверяется при загрузке из хранения и бэкапа; «config outdated»
  срабатывает на каждую переменную шаблона; `pool_tolerance` Direction
  клэмпится по пределу ядра 15000.
- **Сервис, автоматизация, профайлер ([задача 605](docs/spec/tasks/605-service-live-automation-workspaces-bugs.md)).**
  Ошибка старта получает своё уведомление; сбой ядра после принятого
  `SWITCH_NODE` репортит `VPN_ERROR(switch_failed)`; команды автоматизации
  ресинкаются с хранением при старте, после бэкапа и при смене workspace;
  профайлер переподключается при каждом старте туннеля, START сбрасывает
  снимки соединений (без ложного `tcpClose`), баннер «DNS / router events
  off» убран.
- **Список узлов, WARP, anti-DPI ([задача 606](docs/spec/tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md)).**
  «Copy link» на узле без ссылки сообщает об этом вместо тишины;
  перетаскивание под фильтром сохраняет скрытые узлы на месте; свой
  WARP-эндпоинт проверяется как `host:port` до регистрации; некорректная
  пауза TLS-фрагментации заменяется на 500 мс.
- **Локализация и shell ([задача 607](docs/spec/tasks/607-l10n-backup-shell-bugs-from-591.md)).**
  Больше строк проходит через перевод (копирование узла, тема, About, Add
  tile, итог восстановления); локаль ядра следует сохранённому языку
  приложения с момента старта процесса; read-only редактор кода не предлагает
  Cut/Paste.

## 🔧 Под капотом

- Контракт 1.1.108 (только тексты реестра); `sync_contract --to` пишет в lock
  полный commit sha.
- Мёртвый код, найденный аудитом 591, удалён ([задача 593](docs/spec/tasks/593-remove-dead-code-after-audit-591.md));
  поведение для пользователя не изменилось.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.10-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.9](docs/releases/v2.25.9.md).
