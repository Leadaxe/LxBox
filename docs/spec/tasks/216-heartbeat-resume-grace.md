# §216 — Heartbeat resume-грейс + инфо о пробуждении

> **СТАТУС: РЕАЛИЗАЦИЯ.** Мелкая правка UX/лога. Без тестов.

## Зачем

В фоне status-стрим и heartbeat гасятся (§141/§164 — экономия батареи), поэтому
`lastCcStatusAt` устаревает на всё время сна. При возврате в приложение первый
heartbeat-тик видел огромную «тишину» и писал ложный
`Heartbeat: cc status silent 2905s (1/2)` — выглядит как сбой туннеля, хотя
стрим только поднимается и свежий снапшот придёт через ~1s. Пугает в DEBUG APP.

## Что сделано

1. **Грейс на первый пост-resume heartbeat-тик** — не штрафуем один раз, ждём
   восстановления стрима. Флаг `_skipNextHeartbeatFail` (heartbeat-миксин),
   взводится в `_resyncOnResume`, гасится первым же тиком или успешным снапшотом.
   Ложная `silent`-строка больше не пишется.

2. **Инфо о пробуждении в лог** — на resume (если туннель был активен) пишется
   явный маркер `Resumed from background — re-syncing tunnel …` вместо мнимой
   тревоги.

3. **SnackBar в UI (вариант B — только после долгого фона)** — при возврате,
   если фон длился дольше порога (`_bgSnackThreshold = 30s`) И туннель активен,
   показывается ненавязчивый SnackBar `Resumed — syncing tunnel…`. Короткие
   переходы (шторка/звонок/switcher) порога не достигают → спама нет.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| controller | `controllers/home_controller/heartbeat.dart` | флаг `_skipNextHeartbeatFail` + грейс в `_checkHeartbeat` |
| controller | `controllers/home_controller.dart` | инфо-лог + взвод флага в `_resyncOnResume` |
| UI | `screens/home_screen.dart` | замер длительности фона + SnackBar на resume |

## Заметки

- Не трогает watchdog-логику: если ядро реально зависло, второй тик (через 5s)
  оценит тишину честно и dead-tunnel recovery сработает как раньше.
- Порог фона для SnackBar — эвристика (30s), не настраивается.
