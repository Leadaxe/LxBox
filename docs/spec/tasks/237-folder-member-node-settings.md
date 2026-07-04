# §237 — Член папки: полный Node Settings + личный detour под политикой папки

> СТАТУС: реализовано (04.07.2026). Изменение фич §234/§236 по device-фидбэку.

## Что

1. **Тап по члену папки открывает тот же `NodeSettingsScreen`**, что у
   одиночного сервера (Protocol/Server/Tag+эмодзи/Detour + JSON-таб).
   Long-press — прежнее меню (Edit raw / Move / Ungroup / Delete). Битый
   член (node == null) по тапу открывает меню (ноды нет — настраивать нечего).
2. **Личный detour члена** — новое поле `FolderMember.detour` (тег outbound,
   '' = нет), редактируется в Node Settings как у одиночного.
3. **Политика папки применяется к личному detour как у подписки к родной
   цепочке ноды**:

| Политика папки | Эффект на member.detour |
|---|---|
| Use server detours | личный detour применяется |
| Add detour, Replace ON | **переписывает**: у всех folder.override |
| Add detour, Replace OFF | личный побеждает; folder.override — только членам БЕЗ личного |
| None | без detour вообще (личные тоже сняты) |

   Ограничение (осознанное): цепочка `node → личный → папочный` невозможна —
   личный detour это ссылка на ЧУЖОЙ outbound, его хвост не наш (у подписки
   append работает потому, что chain-ноды эмитятся ею самой).
4. **Перенос сохраняет личный detour**: одиночный → папка:
   `detourPolicy.overrideDetour` → `member.detour`; вынос/`keep servers`
   обратно: `member.detour` → `overrideDetour` (снят прежний trade-off §234).

## Реализация

- `FolderMember.detour` (+json `detour`, copyWith), `FolderServers.nodeDetours`
  (выровнен с `nodes` — тот же фильтр enabled+parsed).
- `ServerListBuild.build`: пер-нодная эффективная политика (личный detour
  подменяет `overrideDetour`, если папка не Replace и не None).
- `SubscriptionController.setMemberDetour`; `moveServerToFolder` /
  `_memberToUserServer` переносят detour в обе стороны.
- `NodeSettingsScreen(memberIndex:)` — ветки member/standalone: чтение ноды,
  save JSON → `updateMemberAt`, detour → `setMemberDetour`, self-exclude по
  префиксу папки.

## Связанные

§234 (папки), §236 (Test servers), §073 (append/replace), §080 (display-form
теги), §130 (AWG→WG guard — работает и для членов).
