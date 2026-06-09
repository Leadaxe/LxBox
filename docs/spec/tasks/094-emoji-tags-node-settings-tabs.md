# 094 — Эмодзи-теги серверов + node_settings вкладки (§090 G2b)

| Поле | Значение |
|------|----------|
| Статус | **In progress** |
| Тип | feature / logic-rewrite (§090 G2b, продолжение §091/G2a) |
| Решения | согласованы с юзером (эта сессия) |

## Контекст

§091 + G2a сделали detour-статус структурным (`ConfigNode.isDetour`). Ручная
⚙-пометка больше не нужна для фильтра. Юзер: «⚙ — только визуал при парсинге
подписок; в настройках одиночного сервера убрать ⚙-toggle, добавить
эмодзи-теги».

## Согласованный дизайн

### 1. Detour (готово / без изменений)
- Фильтр «Show detour» по `isDetour` — ✅ G2a (commit `0fb2f69`).
- Билдер подписок: вычисляет detour + красит ⚙ (после префикса) — **без изменений**.

### 2. subscription_detail
- Тоглы `registerDetourServers` / `registerDetourInAuto` — **остаются** (под
  «Use subscription detour servers»). Работают по detour-факту (как и сейчас).
- Reword subtitle: «Add ⚙ servers…» → «detour servers…» (⚙ теперь чисто визуал).

### 3. node_settings (одиночный UserServer) → ВКЛАДКИ
- **Tab «Settings»:** Protocol/Server info · поле **Tag** · кнопка эмодзи-пикер.
- **Tab «JSON»:** редактор JSON, **редактируемый** (вынесен из инлайна).
- ❌ **Убрать:** «Mark as detour server» ⚙-toggle (`_isMarkedDetour`/
  `_toggleDetourMark`) + дубль `registerDetour*`-тоглов (они есть в
  subscription_detail).

### 4. Эмодзи-пикер (виджет, переиспользуемый)
- Кнопка → палитра (Wrap из эмодзи-кнопок) → тап вставляет эмодзи в начало Tag.
- **Места:** node_settings (Settings tab) + **форма создания** (wizard/SOCKS).
- **Палитра:** `🏠 ⚡ 🚀 🔁 ⚙ ⭐ 🌍 🔒`.

### 5. Авто-вставка дефолтного эмодзи при СОЗДАНИИ UserServer
- Точки: `addFromInput` (paste), `addUserServer` (SOCKS-форма), wizard.
- Если в теге **нет** эмодзи → префикс по приоритету:
  1. `server == 127.0.0.1` / `localhost` → 🔁
  2. WireGuard (`WireguardSpec`) → 🏠
  3. UDP/QUIC (`Hysteria2Spec` / `TuicSpec`) → 🚀
  4. остальное (TCP: vless/vmess/trojan/ss/naive/ssh/socks/http) → ⚡
- **Персист:** эмодзи в `rawBody` (UserServer ре-деривит nodes из rawBody на
  load — in-memory `node.tag` не сохранится). Хелпер модифицирует name-часть
  rawBody: фрагмент URI (`...#name`) или `tag` в JSON-outbound.

## Файлы

- `lib/services/node_emoji.dart` (NEW) — `kEmojiPalette`, `hasEmoji(s)`,
  `defaultEmojiFor(NodeSpec)`, `prependEmojiToRawBody(rawBody, emoji)`.
- `lib/widgets/emoji_picker_button.dart` (NEW) — кнопка + палитра.
- `lib/screens/node_settings_screen.dart` — TabBar [Settings, JSON]; убрать
  ⚙-toggle + register-дубль; эмодзи-пикер на Settings.
- `lib/controllers/subscription_controller.dart` — авто-вставка в creation-путях.
- creation-форма (wizard) — эмодзи-пикер + авто-вставка.
- `lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart`
  — reword subtitle.
- Тесты: `node_emoji` (default-маппинг, hasEmoji, rawBody-prepend).

## Фазы (commit-flow)
1. **node_emoji** хелпер + тесты.
2. node_settings → вкладки + убрать ⚙/register + эмодзи-пикер виджет.
3. Авто-вставка при создании + пикер в форме создания.
4. subscription_detail reword.
5. Build + install.

## Не в скопе
- Билдер detour/⚙-логика (без изменений).
- Эмодзи у нод подписки (только UserServer; подписочные ⚙ — авто от билдера).
