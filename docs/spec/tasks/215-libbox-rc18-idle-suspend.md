# §215 — ядро sing-box-lx → rc.18 (SPEC 020 idle-suspend)

> **СТАТУС: РЕАЛИЗАЦИЯ + DEVICE-VERIFIED.** Бамп пина + AAR. Ядро — пререлиз
> (на момент бампа GitHub-релиз rc.18 ещё не выложен; AAR собран локально).

## Зачем

§128 (idle-suspend) эмитит `route.lx_idle_suspend` — поле, которое ядро понимает
только с **rc.18** (SPEC 020 «idle-suspend простаивающих WG/AWG эндпоинтов»,
ветка `lx-1.14`, коммит `702f4dc0` rc.18). rc.16 (текущий пин v2.8.0) поля не
знает — конфиг с `lx_idle_suspend` не грузится.

## Решение

Бамп пина `app/android/libbox.version`: `v1.14.0-lx.1-rc.16` → `v1.14.0-lx.1-rc.18`.

**Особенность:** на момент реализации GitHub-релиз rc.18 **не выложен** (ядро в
пререлизе). Поэтому AAR собран **локально** из ветки `lx-1.14` (HEAD = тег
`v1.14.0-lx.1-rc.18`):

```
cd sing-box-lx
make lib_install          # gomobile/gobind @ v0.1.13
make lib_android          # bakes with_xhttp+with_awg+with_wireguard;
                          # Libbox.version() ← git describe
cp libbox.aar → LxBox/app/android/app/libs/libbox.aar
```

CommandClient API не менялся (SPEC 020 — route-decode + endpoint-логика внутри
ядра) — javap-проверка не нужна, native-обвязка та же.

> ⚠️ **Перед коммитом бампа `libbox.version` дождаться публикации GitHub-релиза
> rc.18** — иначе CI-сборка упадёт: `fetch-libbox.sh` качает AAR из релиза форка,
> которого пока нет. Локально AAR уже лежит (маркер `.libbox.version` = rc.18 →
> fetch скипает). Клиентский код §128 можно коммитить раньше — он безвреден при
> rc.16 (без UI-выбора порог пуст → поле не эмитится).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| pin | `app/android/libbox.version` | rc.16 → rc.18 (⚠ коммитить после релиза ядра) |
| AAR | `app/android/app/libs/libbox.aar` | локальная сборка (не в git, .gitignored) |

AAR sha256 (локальная сборка rc.18): `05f8e2922bbff5d136c042367bd2575f63674951df1961c8622c2a0ad42700e5`.

## Device-верификация (CPH2411, Android 15, ядро rc.18)

`/device` → `core_version = 1.14.0-lx.1-rc.18`. Тест idle-suspend на конфиге из
9 WG (1 реальный WARP = final + 8 синтетических недостижимых), `lx_idle_suspend=30s`:

| Проверка | Результат |
|---|---|
| suspend недостижимых+idle | 8 нод усыплены ровно `idle=30s`, edge-triggered ✓ |
| reachable (final) не гаснет | wg-1 не в suspend-списке ✓ |
| wake by=dial | `urltest wg-2` → `wake wg-2 by=dial`, recv 2→4 ✓ |
| no flap | пары suspend/wake ровные ✓ |
| kill-switch (`0`) | 0 `lx idle:` строк ✓ |
| **heap A/B (главное)** | `PopulatePools.func3` (bufsArrs) **223.93 → 89.89 MB (−134 MB)**; recv-воркеры 18→2 ✓ |

Это первое Android heap A/B для SPEC 020 (десктоп давал −31% RSS; на Android
BatchSize=128 → эффект в 10+ раз больше). Закрывает device-verification gap
RESEARCH.md. Полные результаты — sing-box-lx SPEC 020 «Android RESULTS».

## Связанные

- §128 idle-suspend (потребитель поля) ([[128-idle-suspend]]).
- §214 — предыдущий бамп rc.15→rc.16 (тот же паттерн, но AAR из релиза).
- §213 Debug API core_version (сверка версии на устройстве).
