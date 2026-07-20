# §292 — Быстрые дыры инварианта (proxyPort · setChannels-guard · heal-formatter · l10n)

**Тип:** refactor-pass + correctness (Шаг 1 фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec

Четыре изолированных S-фикса, каждый релизится отдельно. Общая тема — закрыть
мелкие нарушения инварианта §291 дёшево, до крупной DNS-работы. Две реальные
дыры + две гигиены.

## D — VpnModeConfig: валидация proxyPort/protocol в сеттере

**Дыра:** `proxyPort` **не валидируется** ниже UI. `vpn_mode.dart:35` берёт
`(port is int) ? port : defaultPort` — любой int проходит. Debug API
`PUT /settings/vpn_mode` может записать мусорный порт (0, 99999, negative),
который дойдёт до sing-box inbounds. `mode` валидируется, `proxyListen` тоже
(`isValidListenAddr`), а `proxyPort` и `proxyProtocol` — нет.

**Фикс:** валидатор порта (`isValidPort`: 1..65535) + protocol (`http`/`socks`)
на модели `VpnModeConfig`, вызывается в `setVpnMode` пути (и в Debug-handler
`_putVpnMode`, `settings.dart:223`). Инвариант живёт на модели — один источник,
оба входа (UI + Debug) через него. Соответствует §291 правилу 1.

**Файлы:** `lib/services/settings_storage/vpn_mode.dart` (модель+сеттер),
`lib/services/debug/handlers/settings.dart:223` (убрать возможность мусора).
**Тест:** порт вне 1..65535 → отвергается на обоих входах.

## E — setChannels: закрыть §275-щель фасадом

**Дыра:** `SettingsStorage.setChannels` **не** помечен `@visibleForTesting`
(в отличие от `updateChannel`/`deleteChannel`/`addChannel`), и есть 3 голых
вызова мимо `ChannelMutations`-heal: `routing_screen.dart:418`,
`routing_srs_cache.dart:90`, `debug/handlers/channels.dart:168`. Все три
**легитимно heal-free** (staging-буфер / srs-cache / reorder не меняет
heal-релевантных полей), но покрытие — по соглашению, не enforced.

**Фикс:** пометить `setChannels` `@visibleForTesting` (как соседей); три
легитимных вызова провести через явный heal-free вариант или задокументированный
обход, чтобы голый вызов из `lib/` краснел в CI (паттерн §275). Соответствует
§291 «guard сырых статик».

**Файлы:** `lib/services/settings_storage.dart:283`, три call-site.
**Тест:** analyze-guard — голый `setChannels` из `lib/` = warning.

## G — Shared heal-message formatter

Строка «N channels healed» строится руками в двух экранах (routing_screen +
node_list/channel_edit). Вынести в один форматтер. Тривиально.

**Файлы:** новый helper (напр. `lib/services/format_utils.dart` или рядом с
`ChannelMutations`), два call-site.

## H — l10n gap sweep

`subscription_detail_screen.dart:463` — `title: 'Custom User-Agent'` рендерится
сырой строкой (§285-нарушение: должно быть `getLocalText.s(...)`). Плюс grep по
сырым `Text('...')`/`title: '...'` в диалогах на предмет других пропусков.

**Файлы:** `subscription_detail_screen.dart:463` + найденное grep'ом.
**Тест:** ui_check-гейт (уже есть) должен ловить — проверить почему пропустил.

## Docs to update

- `CHANGELOG.md` — D (валидация порта — user-visible через API), H (l10n).
- `docs/api/debug-api-reference.md` — D (PUT /settings/vpn_mode теперь 400 на
  невалидный порт).
