[English](node-settings.md) · [Русский](node-settings.ru.md)

# Настройки узла

| Поле | Значение |
|------|----------|
| Фича | [008-NODE_EDITOR](../FEATURE.ru.md) |
| Обещания | P3 P4 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Экран своего узла — одиночного сервера или члена папки. Показывает, что это
за узел, даёт переименовать его, выбрать detour, отключить пресеты и
править источник. Открывается тапом по своему серверу в списке источников,
по члену папки, из списка выключенных ядром узлов (сразу на Diagnostics).
Заголовок экрана — текущий Tag, меняется при наборе.

## Параметры

| Вкладка | Содержимое |
|---|---|
| Settings | Protocol, Server (только чтение); Tag с палитрой эмодзи; Detour server с превью пути; Skip presets |
| Source | текст источника, редактируемый; подпись о виде источника |
| JSON | тело, которое получит ядро, только чтение, подсветка; Copy JSON; Edit JSON |
| Network | только у узла Tailscale — устройства tailnet, выбор Exit node |
| Diagnostics | диагностика и уведомления узла (009); метка на ярлыке при предупреждениях |

- **Protocol**: протокол узла; у AmneziaWG — «AmneziaWG (wireguard)».
- **Server**: `host:port`; у Tailscale — «No address (Tailscale)», у безадресного
  узла — «No address».
- **Палитра эмодзи** (14): 🏠 ⚡ 🚀 🔁 ⚙ ⭐ 🌍 🔒 ☁️ 🎭 ⛈️ 🌀 🛡️ ❤️ —
  вставка в позицию курсора с пробелом после.
- **Detour server**: «None (direct)» или цель; подпись «Traffic goes directly to
  this server.» либо «Phone → … → <тег> → Internet» — полный путь по цепочке
  detour. Выбор, запреты и политика — [006](../../006-DETOUR_AND_BALANCE/FEATURE.ru.md).
- **Skip presets**: «Presets will not add routing or DNS rules for this node.»
  Виден, только если в шаблоне есть пресет с `for_each` под тип узла; у
  подписки не бывает.

## Входы / Выходы

**Вход:** запись своего сервера или член папки; выбор пользователя.
**Выход:** изменённая запись; для Tag/Source — через Save
([source-editing.md](source-editing.ru.md)), сообщение «Saved».

## Правила и инварианты

- Detour и Skip presets записываются сразу при выборе; Tag и Source — только
  кнопкой Save в заголовке. Подтверждения при уходе с несохранённым Tag нет.
- Save пересохраняет текст Source с тегом из поля Tag: ссылка — во фрагмент,
  JSON — в поле `tag`, INI — в поле записи.
- Эмодзи в тег при правке не подставляется автоматически; его ставят
  палитрой. Отдельной «пометки detour-сервера» (⚙-переключателя) нет: ⚙ —
  обычный эмодзи палитры.
- У узла автовыбора (группы в папке) блока Detour нет вовсе.
- Член папки: detour личный, политика папки поверх него; отказ (сам на себя,
  цикл) откатывает выбор с сообщением.
- Вкладка JSON показывает тело без префикса тегов, detour и шагов сборки.

## Границы

- Узел подписки открывает не этот экран, а осмотр только для чтения —
  [subscription-node.md](subscription-node.ru.md).
- Экран «View details» узла в собранном конфиге (цепочка, зависимые) — 007/006.
- Вкладка Diagnostics — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.ru.md).
- Переименование, удаление, перенос в папку записи — 007 и
  [delete-and-duplicate.md](delete-and-duplicate.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Спека | Экран настроек своего сервера: Info, Tag, Detour |
| 2 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Вкладки, палитра эмодзи; ⚙-переключатель убран |
| 3 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | Подпись «AmneziaWG (wireguard)» осталась, запрет AWG-over-WG снят |
| 4 | [237](../../../tasks/237-folder-member-node-settings.md) | Реализовано | Тот же экран для члена папки, личный detour |
| 5 | [252](../../../tasks/252-physical-packet-route-line.md) | Реализовано | Превью полного пути пакета |
| 6 | [392F](../../../tasks/392F-node-diagnostics/spec.md) | DEVICE-PENDING | Вкладка Diagnostics |
| 7 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Выпущено v2.24.3 | Вкладки Source и JSON |
| 8 | [501](../../../tasks/501-diagnostics-notifications-merge.md) | Released в v2.25.0 | Уведомления внутри Diagnostics |
| 9 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec, реализация запущена | Переключатель Skip presets |
| 10 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented | Вкладка Network узла Tailscale |
