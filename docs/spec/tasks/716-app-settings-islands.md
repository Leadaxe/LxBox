# 716 — App Settings: General и Diagnostics островами

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-04 |
| End date | 2026-11-04 |
| Commits | см. `git log --grep "задача 716"` |
| Related specs | §709 (VPN Settings → System/Core островами, виджет `SettingsIsland`) |

## Problem

Вкладки App Settings → General и Diagnostics делили секции заголовком
`titleMedium` и `Divider(height: 32)`. VPN Settings → System/Core с §709
оформлены островами (`SettingsIsland`: карточка, заголовок секции, разделитель).
Два экрана настроек выглядели по-разному.

## Solution

Каждая секция обеих вкладок обёрнута в `SettingsIsland` из
`app/lib/widgets/template_var_list.dart`; старые заголовки, отступы и
разделители между секциями сняты. Содержимое тайлов, тексты, иконки и
callback'и не менялись. Описания островам не выдавались: поясняющий текст
секций стоит под тайлом, а не под заголовком, и остался ребёнком. Padding
списка прежний (`_tabPadding`, 12/12/12).

Острова General (`general_tab.dart`):

- Region
- Behavior
- Quick connect
- Updates
- Feedback
- Backup & restore

Острова Diagnostics (`diagnostics_tab.dart`):

- System setup — Battery optimization, Notifications, Location (background),
  Nearby Wi-Fi devices, App info (OEM power settings)
- Developer — Debug API … Quit & reopen app
- Wi-Fi networks — Auto-record visited Wi-Fi networks и его подпись
  (новый заголовок; переводы ru/zh добавлены в `assets/l10n/*/ui.json`)

Appearance, Subscriptions, Automation не тронуты.

## Verification

- `dart analyze lib/screens/app_settings_screen` — без замечаний.
- Тестов, искавших заголовки этих вкладок, нет.
- Эмулятор (emulator-5554, сборка 2.25.19-rc.3-dev.28, 04.11.2026): General — шесть карточек
  Region / Behavior / Quick connect / Updates / Feedback / Backup & restore; Diagnostics — три
  карточки System setup / Developer / Wi-Fi networks. Лишних разделителей нет, под каждым
  заголовком одна линия, текст не обрезан, тайл Backup & restore с тем же отступом, что и
  остальные (e08bce56). Пояснения под тумблерами (Wi-Fi networks, строка «Last check» в Updates)
  по-прежнему с отступом 72 под текст тайла — как было до островов, не трогали.
