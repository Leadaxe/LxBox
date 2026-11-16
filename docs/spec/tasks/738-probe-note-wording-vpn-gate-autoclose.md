# 738 — «Тест серверов»: пометка про detour не называет источник; диалог «VPN is running» закрывается сам

| | |
|---|---|
| **Статус** | Done — на эмуляторе не проверено |
| **Дата** | 2026-11-16 |
| **Повод** | замечания проверки 730–733 на эмуляторе (15.11.2026), слово владельца «докрутить» / «поправить» |
| **Связанные** | [730 — detour источника в тесте серверов](730-probe-test-source-detour.md), 296 — VPN-гейт пробы |

## Docs to update

- эта задача
- [730](730-probe-test-source-detour.md) — таблица текстов пометки
- docs/USER_GUIDE.md, docs/USER_GUIDE.ru.md — текст пометки
- CHANGELOG.md — Unreleased, Fixed

## Problem

1. Диагностика узла папки с **личным** detour, который проба повторить не
   может, показывала «Detour of this source is not applied in the test — nodes
   are checked directly.» Detour там не источника, а самого узла, и узел один.
2. Диалог «VPN is running» (тест при включённом VPN) оставался на экране,
   когда VPN останавливали мимо него — из шторки, плиткой, через Automation
   или туннель падал сам. Пользователь видел предложение остановить VPN,
   который уже остановлен.

## Diagnosis

1. `probeDetourNoteText` (`app/lib/widgets/probe_detour_note.dart`) имеет один
   текст на случай «ни у одного узла detour не учтён». План пробы
   (`ProbeDetourPlan`) не различает, чей detour — источника или члена папки
   (`FolderDetourPlan.policyFor` сводит их в одну эффективную политику).
2. `ProbeGateMixin._showGateAndStop` (`app/lib/screens/probe_gate_mixin.dart`)
   ждал только нажатия кнопки, за статусом туннеля не следил.

## Solution

1. Текст больше не называет владельца detour: «Detour is not applied in the
   test — nodes are checked directly.»; для одного узла — «… the node is
   checked directly.» Различать источник и личный detour в плане не стали:
   пометке это знание не нужно.
2. Пока диалог открыт, mixin слушает `BoxVpnClient.onStatusChanged`. На
   `disconnected` диалог закрывается сам, гейт возвращает `true` (тест идёт
   дальше), `stopVPN` второй раз не вызывается. Кнопки и слушатель закрывают
   диалог через общий флаг — двойного `pop` нет.

## Verification

- `test/widgets/probe_detour_note_test.dart` — тексты пометки: один узел,
  несколько, «учтён», смешанный случай.
- `test/screens/subscription_detail_probe_detour_note_test.dart` — прежние
  сценарии с новым текстом.
- Диалог: тестом не покрыт; на эмуляторе не проверено. Сценарий: VPN включён →
  «Тест серверов» → диалог → остановить VPN из шторки → диалог закрылся, тест
  пошёл.
