# 130 — AWG-узел: подпись «WG (AWG)» + detour-список без WireGuard-целей

| Поле | Значение |
|------|----------|
| Статус | **Реализовано — на проверке на устройстве** (ядро v1.13.13-lx.9) |
| Verification | `flutter analyze --no-pub` чисто; release arm64 build пройден; установлено на тест-телефон 2026-06-16. Ручная проверка UI — за юзером. |
| Дата старта | 2026-06-16 |
| Тип | UI-изменение existing feature (detour-пикер §111 / §080) → таска |
| Цель | На экране редактирования узла: (1) показывать в подписи протокола **«WG (AWG)»** (а не просто «wireguard»); (2) если редактируемый узел — AWG, **исключить из списка detour-кандидатов все wireguard-узлы** (плоский WG + AWG); (3) если у AWG-узла уже сохранён detour на wireguard (старый конфиг) — **сбросить на None и сразу персистнуть**. |
| Причина | AWG с detour на wireguard **вешает ядро на Android** (issue [#2](https://github.com/Leadaxe/sing-box-lx/issues/2)). Ядро v1.13.13-lx.9 теперь само отвергает такой endpoint на старте (`amneziawg endpoint will not start: … AmneziaWG inside a WireGuard tunnel hangs the kernel on Android. Use a non-wireguard detour (e.g. vless)`). UI должен **не давать собрать** такую конфигурацию — guard в ядре это последняя линия, UI — первая. |
| Связанные | §111 (detour-пикер подписок); §080 (display-form detour-тегов); §097 (AWG2 obfuscation params); §128 (won't-fix `detour: direct-out`); §129 (force-stop при зависшем ядре — защита для старых конфигов); issue [#2](https://github.com/Leadaxe/sing-box-lx/issues/2) |

---

## TL;DR

> На экране редактирования узла ([`node_settings_screen.dart`](../../../app/lib/screens/node_settings_screen.dart)):
> AWG детектится как `node is WireguardSpec && node.awg != null` (у WG и AWG
> одинаковый `protocol == 'wireguard'`, различие — поле `awg`). Если узел AWG:
> подпись Protocol = «WG (AWG)» (без отдельного чипа), из detour-dropdown убрать
> всех кандидатов-`WireguardSpec`, сохранённый detour-на-wireguard сбросить на
> None + персистнуть. Для не-AWG узлов поведение не меняется.

---

## Контекст кода (где что лежит)

| Что | Файл:строка | Деталь |
|---|---|---|
| Экран редактирования узла | [`node_settings_screen.dart`](../../../app/lib/screens/node_settings_screen.dart) | `NodeSettingsScreen`, редактирует `entry.list.nodes.first` |
| Метод инициализации | `node_settings_screen.dart:57` `_load()` | строит `_availableNodes`, читает `_detour`, `_scheme` |
| Редактируемый узел | `node_settings_screen.dart:61` | `final node = nodes.first` (тип `NodeSpec`) |
| Текущая «схема» в шапке | `node_settings_screen.dart:64` | `_scheme = node.protocol` → для AWG даёт `'wireguard'` (неотличимо!) |
| detour-dropdown | `node_settings_screen.dart:220-243` | `DropdownButtonFormField<String>`, items: `'None (direct)'` + `_availableNodes` |
| Список detour-кандидатов | `node_settings_screen.dart:87-100` | цикл по `subController.entries` → `UserServer.enabled` → `n in list.nodes` (display-form тегов) |
| Текущая фильтрация | `node_settings_screen.dart:90,92,95,97` | only `UserServer`, only `enabled`, skip empty tag, skip self |
| Сохранение detour | `node_settings_screen.dart:235-241` | `entry.overrideDetour = v`; `persistSources()` |
| Модель AWG | [`node_spec.dart:443`](../../../app/lib/models/node_spec.dart) `class Awg` | поля-карта `jc/jmin/jmax/s1..s4/h1..h4/i1..` |
| AWG-признак | `node_spec.dart:571` | `WireguardSpec.awg` (тип `Awg?`, `null` = обычный WG) |
| WG/AWG protocol | `node_spec.dart:591` | `WireguardSpec.protocol => 'wireguard'` (общий для обоих) |

### Ключевые предикаты
```dart
// редактируемый узел — AmneziaWG:
final isAwg = node is WireguardSpec && node.awg != null;
// кандидат — wireguard (WG или AWG):
if (n is WireguardSpec) { /* исключить, если isAwg */ }
```

---

## Решение (согласовано)

Всё в [`node_settings_screen.dart`](../../../app/lib/screens/node_settings_screen.dart), метод `_load()` + блок шапки + detour-dropdown.

### A. Детект AWG + подпись протокола
В `_load()` после строки 61 завести `_isAwg = node is WireguardSpec && node.awg != null`.
В подписи Protocol-тайла при `_isAwg` показать **`WG (AWG)`** (вместо сырого
`node.protocol == 'wireguard'`), для не-AWG — `node.protocol` как есть. Без
отдельного Chip/Badge — единообразно с остальными протоколами (просто текст в
`subtitle`).

### B. Фильтр detour-кандидатов
В цикле построения `_availableNodes` (строки 94-98) добавить: если `_isAwg` —
пропускать кандидатов-`WireguardSpec`:
```dart
for (final n in list.nodes) {
  if (n.tag.isEmpty) continue;
  if (_isAwg && n is WireguardSpec) continue;   // §130 — AWG не может detour-ить в wireguard
  final display = TagResolver.displayTag(prefix, n.tag);
  if (display != selfDisplay) tags.add(display);
}
```
Под detour-dropdown при `_isAwg` показать hint-строку: «AmneziaWG-узлы не могут
идти через WireGuard — такие цели скрыты. Используйте non-wireguard detour (например, vless)».

### C. Сброс невалидного сохранённого detour (AWG→WG)
В `_load()`, после построения `_availableNodes` и чтения `_detour`: если `_isAwg`
и текущий `_detour` указывает на wireguard-узел (или его нет в отфильтрованном
`_availableNodes`) — **сбросить на '' (None) и сразу персистнуть**:
```dart
if (_isAwg && _detour.isNotEmpty && !_availableNodes.contains(_detour)) {
  _detour = '';
  widget.entry.overrideDetour = '';
  unawaited(widget.subController.persistSources());   // СРАЗУ — иначе юзер выйдет без сохранения
  // лог в DebugSource.app: сброшен невалидный AWG→WG detour
}
```
**Важно:** персист именно в `_load`, fire-and-forget — иначе если юзер открыл и вышел
не трогая dropdown, сброс не сохранится и сломанный detour останется в конфиге.

### Открытые вопросы (дефолты)
1. **Как понять, что сохранённый `_detour` указывает на wireguard?** `_detour` —
   это display-tag (строка), не объект. → **Дефолт: проверять `!_availableNodes.contains(_detour)`**
   — после фильтра B все wireguard-цели уже выкинуты, поэтому «сохранённый detour
   не в списке» ⇒ либо он был wireguard, либо узел удалён. В обоих случаях сброс корректен.
2. **Группы (selector/urltest) как detour-цель?** Пикер предлагает только прямые
   узлы (`n.tag`), не группы → на уровне UI не возникают. detour-на-группу-с-WG-членом
   ловит ядровый guard (#2). → **Вне скоупа UI.**
3. **Detour-цель из подписки (`SubscriptionServers`)?** Список кандидатов и сейчас
   только из `UserServer` (строка 90) — подписочные узлы не предлагаются. → Не меняем.

---

## Скоуп

**В скоупе:** `node_settings_screen.dart` — AWG-бейдж, фильтр detour-кандидатов по
`WireguardSpec` при редактировании AWG-узла, авто-сброс невалидного AWG→WG detour
с персистом.

**Вне скоупа:**
- Фикс самого зависания ядра — issue #2, форк sing-box (уже исправлено в lx.9 — guard на старте).
- Защита приложения от зависшего ядра — §129 (force-stop), уже сделано.
- detour-на-группу-с-WG-членом — ловит ядровый guard.
- Подписочные detour-цели — текущее ограничение пикера, не трогаем.

---

## Verification (план)
1. `flutter analyze` чисто.
2. Юнит/ручная: открыть редактирование AWG-узла → бейдж «AmneziaWG» виден; в detour-dropdown нет ни одного wireguard-узла (WG/AWG), есть vless/прочие; hint показан.
3. Открыть редактирование не-AWG узла (vless) → список detour не изменился, бейджа нет.
4. AWG-узел со старым detour на WG → при открытии detour сброшен на None, персистнут (проверить `lxbox_settings.json` / повторное открытие).
5. На устройстве с ядром v1.13.13-lx.9: собрать AWG-узел, убедиться что WG-detour в UI недоступен.

---

## Файлы

| Файл | Роль |
|---|---|
| [`app/lib/screens/node_settings_screen.dart`](../../../app/lib/screens/node_settings_screen.dart) | `_load()` (57), detour-dropdown (220-243), шапка — ВСЕ изменения здесь |
| [`app/lib/models/node_spec.dart`](../../../app/lib/models/node_spec.dart) | `WireguardSpec.awg` (571), `class Awg` (443) — только чтение, предикат AWG |
