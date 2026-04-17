# 044 — Jump Server Naming & Visibility

## Статус: Спека

## Контекст

При парсинге Xray JSON Array подписок, jump-серверы (chained proxy / detour) получают имя по шаблону `{основная_нода}_jump_server`. Например:

```
🇫🇮Финляндия-bypass              ← основная нода (vless)
🇫🇮Финляндия-bypass_jump_server  ← jump сервер (socks)
```

### Проблемы текущего подхода

1. **Кардинальное переименование**: jump сервер теряет своё оригинальное имя. Если у провайдера jump сервер назван `socks-helsinki-01`, он станет `🇫🇮Финляндия-bypass_jump_server` — информация потеряна

2. **Jump серверы — самостоятельные соединения**: socks-прокси может использоваться не только как jump для конкретной ноды, а для любых целей. Жёсткая привязка через имя вводит в заблуждение

3. **Загромождение списков**: jump серверы появляются в списке нод на главном экране, в node filter, в detour dropdown — хотя пользователю они обычно не нужны для ручного выбора

## Решение

### 1. Префикс вместо переименования

Jump серверам добавлять **префикс** `⚙ ` (шестерёнка + пробел), сохраняя оригинальное имя:

**Было:**
```
🇫🇮Финляндия-bypass_jump_server
```

**Стало:**
```
⚙ socks-helsinki-01
```

Или если оригинального имени нет (jump создан автоматически из Xray конфига):
```
⚙ socks 193.232.220.96:62025
```

### 2. Определение префикса

```dart
static const jumpPrefix = '⚙ ';
```

В `XrayJsonParser`: при создании jump ноды, использовать оригинальное имя из Xray конфига (если есть) или `{protocol} {host}:{port}`, и добавить префикс `⚙ `.

В `SourceLoader._dedup`: префикс не влияет на dedup — уникальность по полному тегу.

### 3. Видимость в UI

Настройка (boolean, в wizard_template.json или SettingsStorage):

```
show_jump_servers: false  (по умолчанию)
```

| Место | show_jump_servers=false | show_jump_servers=true |
|-------|----------------------|---------------------|
| Главный экран (список нод) | Скрыты | Показаны с ⚙ |
| Node filter (auto-proxy-out) | Скрыты | Показаны |
| Detour dropdown | **Всегда показаны** | Всегда показаны |
| Statistics (outbound cards) | Показаны (если есть трафик) | Показаны |
| Connections list | Показаны (в chain) | Показаны |

**Detour dropdown всегда показывает jump серверы** — это их основное предназначение.

### 4. Программная фильтрация

```dart
bool isJumpServer(String tag) => tag.startsWith('⚙ ');

// В списке нод на главном экране:
final visibleNodes = showJumpServers
    ? state.nodes
    : state.nodes.where((tag) => !tag.startsWith('⚙ ')).toList();
```

## Реализация

### XrayJsonParser

```dart
// Было:
static const _jumpSuffix = '_jump_server';
final jumpTag = '$base$_jumpSuffix';

// Стало:
static const jumpPrefix = '⚙ ';
// Использовать оригинальное имя из Xray outbound или fallback
final jumpName = jumpOutbound['tag']?.toString() 
    ?? '${jumpProtocol} ${jumpHost}:${jumpPort}';
final jumpTag = '$jumpPrefix$jumpName';
```

### NodeParser (для URI jump серверов)

Аналогично — если нода создаёт jump (ParsedJump), добавить префикс `⚙ `.

### HomeScreen

```dart
// Фильтрация jump серверов из списка нод
final displayNodes = _showJumpServers
    ? state.sortedNodes
    : state.sortedNodes.where((t) => !t.startsWith('⚙ ')).toList();
```

### NodeFilterScreen

Аналогично — скрывать jump серверы из чекбоксов (они не должны быть в urltest).

## Файлы

| Файл | Изменения |
|------|-----------|
| `xray_json_parser.dart` | `_jumpSuffix` → `jumpPrefix`, сохранять оригинальное имя |
| `node_parser.dart` | Prefix `⚙ ` для ParsedJump тегов |
| `source_loader.dart` | Dedup с учётом префикса |
| `home_screen.dart` | Фильтрация jump серверов из списка нод |
| `node_filter_screen.dart` | Фильтрация jump серверов из чекбоксов |
| `node_settings_screen.dart` | Jump серверы всегда в detour dropdown |
| `settings_storage.dart` | `show_jump_servers` boolean |
| `wizard_template.json` | Переменная `show_jump_servers` (default: false) |

## Будущие возможности (из самостоятельности jump серверов)

Когда jump серверы — отдельные сущности с `⚙` префиксом, открываются возможности:

### Массовое управление detour

- **Отключить все jump серверы** → все ноды с detour станут прямыми (обход медленных промежуточных серверов)
- **Заменить jump для всех нод** → если socks-прокси тормозит, переключить все ноды на другой jump (например WireGuard) одним действием
- **UI**: на экране Routing или отдельном экране "Jump Servers" — список `⚙`-серверов с возможностью:
  - Включить/выключить (отключённый = ноды идут напрямую)
  - Заменить (dropdown: на какой jump переключить все ноды которые используют этот)

### Мониторинг jump серверов

- В Statistics видно трафик через каждый jump сервер
- Если jump медленный — видно по скорости всех нод которые его используют
- Пинг jump серверов отдельно

### Пример сценария

Провайдер даёт 20 нод, все через один socks-jump. Jump тормозит:

1. Добавить свой WireGuard сервер как `⚙ wg-fast`
2. В настройках заменить `⚙ socks-slow` → `⚙ wg-fast` для всех нод
3. Или отключить jump вообще — ноды пойдут напрямую

## Критерии приёмки

- [ ] Jump серверы сохраняют оригинальное имя с префиксом `⚙ `
- [ ] Суффикс `_jump_server` убран
- [ ] По умолчанию jump серверы скрыты из списка нод и node filter
- [ ] Jump серверы всегда доступны в detour dropdown
- [ ] Настройка show_jump_servers в UI
- [ ] Statistics и Connections показывают jump серверы (если есть трафик)
- [ ] Dedup работает корректно с префиксом
- [ ] Detour ссылки (`outbound.detour`) используют новые имена с префиксом
