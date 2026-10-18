# 664 — REALITY: подпись «Default (On — global)» лжёт про фрагментацию

Статус: Done (18.10.2026). Источник: GitHub issue #170 (Alex01d),
LxBox 2.25.15, VLESS + REALITY + Vision, Xray 26.10.10.

## Проблема

С §627/§636 уровни выше узла (глобальный, папка, подписка) не фрагментируют
REALITY-узел: `tls.fragment` и `tls.record_fragment` пишутся ему только при
флаге на самом узле (`applyTlsFragment`, `tls_transforms.dart`). Но секция TLS
в настройках узла (`TlsPolicyTiles`, `tls_policy_tiles.dart`) считает подпись
«Default (…)» без этого исключения и показывает «Default (On — global)», хотя
в сгенерированном и работающем конфиге поля нет. Пользователь после
обновления с ≤2.25.11 видит «включено», а связь на его сети стоит — явный
override на узле он может только угадать.

Факты из issue подтверждают, что фрагментация у REALITY работает и нужна
(7/7 против 0/7 на `ifconfig.co`), — исключение §627 остаётся, это не
про него.

## Диагностика

- `_inheritedBool` в `tls_policy_tiles.dart:57` берёт `fromAbove` папки или
  глобальный `vars[...]`; о REALITY виджет ничего не знает — у него нет
  тела outbound.
- `node_settings_screen.dart:801` строит `TlsPolicyTiles` только из
  `TlsPolicy` и `FolderServers`; признак REALITY там же не вычисляется (есть
  аналог для detour: `_underDetour` и подпись «Not applied: …»).
- `subscription_settings_tab.dart:379` — уровень источника, узлов там нет,
  не трогать.

## Решение

1. `TlsPolicyTiles` получает `bool reality` (по умолчанию `false`).
   Для полей `fragment` и `recordFragment` при `reality == true` унаследованное
   значение считается **выключенным независимо от уровней выше**, подпись
   «Default» и подпись в диалоге выбора — отдельные строки, не «Off — global»:
   - тайл: `Default (Off — not inherited by REALITY)`;
   - диалог: `Inherited: Off (REALITY ignores global, folder and subscription
     levels)`.
   `fallbackDelay` правило не касается (он пишется вместе с флагом узла).
2. `node_settings_screen.dart`: вычислить признак REALITY так же, как это
   делает `applyTlsFragment` — `tls.enabled == true` и `tls.reality.enabled
   == true` в теле outbound узла (взять тело тем же путём, которым экран
   получает detour/прочее; у члена папки — тело члена). Под секцией TLS, по
   образцу подписи detour, строка:
   `REALITY: global, folder and subscription fragmentation are not applied.
   Turn it on here if this server needs it.` — только когда `reality` и
   не `_underDetour`.
3. Строки — английские, в l10n по правилам `docs/l10n.md` (все языки, как у
   соседних строк файла).
4. Миграцию и «upgrade notice» не делаем: поведение описано в CHANGELOG
   v2.25.12 (§627); правильная подпись и подсказка закрывают разрыв.

## Проверка

- Unit-тест виджета: при `reality: true` и глобальном `tls_record_fragment =
  true` подпись тайла — новая строка, а не «Default (On — global)»; при
  `reality: false` — как раньше. Один файл, точечный прогон.
- Существующие `app/test/builder/tls_fragment_reality_test.dart` не трогать —
  генерация не меняется.
- CHANGELOG `[Unreleased]` → Fixed, EN+RU, ссылка на задачу и issue #170.

## Итог

- `TlsPolicyTiles` получил `reality` (по умолчанию `false`): у `fragment` и
  `record_fragment` при `reality` подпись тайла «Default (Off — not inherited
  by REALITY)», в диалоге — «Inherited: Off (REALITY ignores global, folder
  and subscription levels)»; `mixed_case_sni` и `fallback_delay` не тронуты.
- `node_settings_screen.dart`: признак REALITY считается в `_load` по тому
  же телу, что показывает вкладка JSON (дословный sing-box-объект или
  `emit()`), критерием `applyTlsFragment`; подсказка под секцией TLS — при
  REALITY и без detour.
- Строки — в `ru` и `zh` `ui.json`; `hardcoded_check` 0/0.
- Тест `app/test/widgets/tls_policy_tiles_reality_test.dart` (2 случая:
  REALITY и не REALITY при глобальном `tls_record_fragment = true`) зелёный.
- На устройстве и эмуляторе не проверено.
