# 006 — Per-server detour toggles в Node Settings

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-04-20 |
| Связанные spec'ы | [`018 detour server management`](../features/018%20detour%20server%20management/spec.md), [`003 home screen`](../features/003%20home%20screen/spec.md) |

## Проблема

Когда юзер добавляет сервер руками (UserServer, один URI = одна нода), он может пометить его как detour-сервер (посредник-dialer) через toggle «Mark as detour server» — это ставит `⚙ ` префикс в tag. Но:

- **main-нода UserServer'а всё равно попадает в selector и ✨auto**, даже с `⚙ ` префиксом. `⚙ ` сегодня — чисто UI-декорация (фильтр «Show detour servers» в Home AppBar + визуал в списке нод).
- Юзер хочет: «я пометил сервер как detour → не хочу его видеть в выборе outbound'ов и не хочу чтобы auto его пинговал». Сейчас это недостижимо per-server.

На уровне подписок аналогичные toggle'ы уже есть — `registerDetourServers` и `registerDetourInAuto` в [`subscription_detail_screen.dart:294-305`](../../../app/lib/screens/subscription_detail_screen.dart:294). Они применяются ко всем detour-нодам (chained) в подписке. Но для **одиночных серверов** такого UI нет, хотя модель `UserServer` (extends `ServerList`) уже имеет свой `DetourPolicy` через наследование — просто он не редактируется из UI одного сервера.

## Решение

**Никаких новых моделей.** Используем существующий `UserServer.detourPolicy` (уже есть через [server_list.dart:14](../../../app/lib/models/server_list.dart:14)).

### Контракт UI

Node Settings экран (`node_settings_screen.dart`), секция «Info» под tag-полем:

1. **Mark as detour server** — как сейчас. Toggle ставит/снимает `⚙ ` префикс в tag.
2. **Register in VPN groups** (NEW) — видимое только когда #1 ON. Default OFF. Маппится на `entry.registerDetourServers`.
3. **Register in auto group** (NEW) — видимое только когда #1 ON. Default OFF. Маппится на `entry.registerDetourInAuto`.

Когда #1 OFF — галки #2/#3 скрыты (не disabled). Значения полей сохраняются; если юзер снова включит #1 — галки снова показываются в том же состоянии. Значения persist'ятся через существующий `SubscriptionController.persistSources()` (setters уже есть в `subscription_controller.dart:167-170`).

### Таблица эффекта (для UserServer)

| State | В VPN groups (selector) | В ✨auto urltest |
|-------|-------------------------|------------------|
| `⚙` OFF | Да (обычное поведение) | Да |
| `⚙` ON, обе галки OFF (default) | **Нет** | **Нет** |
| `⚙` ON, «VPN groups» ON | **Да** | Нет |
| `⚙` ON, «auto» ON | Нет | **Да** |
| `⚙` ON, обе ON | Да | Да |

Сервер с `⚙`, у которого обе галки OFF — **доступен как detour-звено для цепочек** (через «Detour server» dropdown у других серверов). Это основная роль detour-сервера.

### Builder изменения

Текущий [`server_list_build.dart:45-50`](../../../app/lib/services/builder/server_list_build.dart:45):

```dart
ctx.addToSelectorTagList(main);
ctx.addToAutoList(main);
for (final d in detours) {
  if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(d);
  if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(d);
}
```

Станет:

```dart
final isMainAsDetour = main.tag.startsWith(kDetourTagPrefix);
if (!isMainAsDetour) {
  ctx.addToSelectorTagList(main);
  ctx.addToAutoList(main);
} else {
  if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(main);
  if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(main);
}
for (final d in detours) {
  if (detourPolicy.registerDetourServers) ctx.addToSelectorTagList(d);
  if (detourPolicy.registerDetourInAuto) ctx.addToAutoList(d);
}
```

Ключевое: если main-тег начинается с `⚙ ` — main ведёт себя как detour-нода в смысле регистрации в proxy-группах. Для subscription-нод main обычно без `⚙` (префикс ставится только на chained detours при парсинге), значит поведение для подписок не меняется.

### Новая константа

Приватный `_detourPrefix = '⚙ '` в `node_settings_screen.dart` заменяется на public константу в модельном слое, чтобы builder мог её использовать. Кладём рядом с `kAutoOutboundTag` в [`lib/config/consts.dart`](../../../app/lib/config/consts.dart):

```dart
/// Префикс в tag'е, помечает ноду как detour-сервер (посредник-dialer, не
/// endpoint). Ставится: (a) парсером при разборе chained-нод подписки,
/// (b) юзером через toggle в node_settings_screen. Используется builder'ом
/// для решения — регистрировать эту ноду в selector/auto-группах или нет.
const String kDetourTagPrefix = '⚙ ';
```

## Scope

- Только для **UserServer** (1 server = 1 node, это инвариант проекта).
- Subscription-нод не касается. `SubscriptionServers.detourPolicy` применяется как раньше — к chained-detour'ам.
- Новая builder-логика детектит `⚙ ` в main.tag и работает **для любой** ServerList (UserServer или SubscriptionServers). Но для SubscriptionServers main обычно без `⚙` (парсер ставит только на detours), так что эффекта нет.

## Риски и edge cases

### Разобрано

- **Hypothetical: subscription main с `⚙`.** Если бы кто-то вставил подписку, где main уже имеет `⚙ ` префикс в теге — новая логика применит registerDetour* к нему. Это edge case, безопасное поведение (обе галки по default false → node скрыт в обеих группах, остаётся доступен как detour). Я это не тестировал эмпирически, но не ломает существующие сценарии.
- **Юзер снял `⚙ `, но registerDetour* в true.** Галки скрыты в UI, значения сохраняются в entry.detourPolicy. Builder не детектит `⚙` → main обычным путём в selector/auto. После повторного `⚙` ON — всё на своих местах.
- **JsonEncoder / rawBody**. `updateConnectionAt(widget.index, [jsonStr])` — сохранение node'ы через JSON. DetourPolicy сохраняется отдельно через `persistSources()` (не в node JSON). Independent path — конфликтов нет.
- **Default values persist.** `entry.registerDetourServers = false` (default) — `_replaceList` вызывается только при изменении (setter проверяет что записывается). Если юзер не трогает новые галки, они остаются false.

### Намеренно НЕ сделано

- **Auto-sync `⚙ ` при смене registerDetour\* извне.** Если debug API или другой path поменял `registerDetourServers=true` без `⚙`, UI не добавит `⚙` автоматически. Builder просто не увидит это как detour (нет префикса). Валидно — состояние становится «скрытые галки в UI, эффекта нет». Самолечится когда юзер откроет экран и поставит `⚙`.
- **Hint что сервер доступен как detour.** В UI не добавляем «этот сервер видят другие как detour» пометку. Detour dropdown у других серверов и так показывает все UserServer-ноды (см. `node_settings_screen.dart:68-76`), юзер видит список.

## Верификация

- `dart analyze lib/` — 0 issues.
- `flutter test` — без регрессий (242 теста).
- `flutter build apk --release` — compile OK.
- Manual test checklist:
  1. Добавить UserServer без `⚙`. Он в ✨auto, в selector. ✓
  2. Поставить `⚙`, обе галки OFF (default). Он исчезает из ✨auto и из selector. ✓
  3. Включить «VPN groups». Появляется в selector, но не в auto. ✓
  4. Включить «auto». Появляется и в auto. ✓
  5. Сервер-посредник — другой UserServer в его detour-dropdown'е видит это имя. ✓
  6. Subscription-нод не затронут — подписка с 10 main-нодами + chained-detours, все 10 в ✨auto, detour'ы по текущей политике подписки.

## Файлы

| Файл | Изменение |
|------|-----------|
| `lib/config/consts.dart` | + `kDetourTagPrefix = '⚙ '` |
| `lib/screens/node_settings_screen.dart` | Замена приватной `_detourPrefix` на импорт. + 2 SwitchListTile под существующим «Mark as detour server» (visible только когда `⚙` ON). |
| `lib/services/builder/server_list_build.dart` | + import `kDetourTagPrefix`. Branch для main-as-detour (`isMainAsDetour = main.tag.startsWith(kDetourTagPrefix)`) — селективно регистрировать в selector/auto. |
